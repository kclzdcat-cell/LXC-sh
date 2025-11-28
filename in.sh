#!/bin/bash
set -e

echo "==========================================="
echo "   OpenVPN 入口部署 (IPv6 分流 + SSH 保护)"
echo "==========================================="

# 0. 检查是否为 root
if [[ $EUID -ne 0 ]]; then
   echo "错误：必须使用 root 用户运行此脚本！"
   exit 1
fi

# 1. 自动检测 SSH 端口 (避免用户输错导致失联)
SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $5}' | awk -F: '{print $NF}' | head -n 1)
SSH_PORT=${SSH_PORT:-22}
echo ">>> 检测到 SSH 端口为: $SSH_PORT"

# 2. 安装必要软件
echo ">>> 更新系统并安装 OpenVPN..."
apt update -y
apt install -y openvpn iptables iptables-persistent curl

# 3. 检查配置文件
if [ ! -f /root/client.ovpn ]; then
    echo "错误：未找到 /root/client.ovpn，请上传文件后重试！"
    exit 1
fi

# 4. 部署 OpenVPN 配置
echo ">>> 部署配置文件..."
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# 5. 生成 OpenVPN 启动脚本 (up.sh)
# 这是核心：在 VPN 启动时，自动设置策略路由
UP_SCRIPT="/etc/openvpn/client/up.sh"
cat >$UP_SCRIPT <<EOF
#!/bin/bash
# 清理旧规则 (防止重复)
ip -6 rule del fwmark 55 table main 2>/dev/null || true
ip -6 rule del from all table 200 2>/dev/null || true
ip -6 route flush table 200

# [关键步骤 A]：给 SSH 流量打标记 (Mark 55)
# 只要是源端口为 $SSH_PORT 的 TCP 流量，打上标记 55
ip6tables -t mangle -D OUTPUT -p tcp --sport $SSH_PORT -j MARK --set-mark 55 2>/dev/null || true
ip6tables -t mangle -A OUTPUT -p tcp --sport $SSH_PORT -j MARK --set-mark 55

# [关键步骤 B]：设置路由策略
# 优先级 1000：如果标记是 55 (SSH)，强制查 main 表 (走本地网关)
ip -6 rule add fwmark 55 table main priority 1000

# 优先级 2000：其他的流量，查 200 表 (准备走 VPN)
ip -6 rule add from all table 200 priority 2000

# [关键步骤 C]：配置 200 表的默认路由指向 VPN
# \$1 是 OpenVPN 传入的 tun 设备名 (如 tun0)
ip -6 route add default dev \$1 table 200

# 开启 IPv4 转发和 NAT (确保 IPv4 可用)
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -F
iptables -t nat -A POSTROUTING -o \$1 -j MASQUERADE
EOF
chmod +x $UP_SCRIPT

# 生成 down.sh 清理脚本
DOWN_SCRIPT="/etc/openvpn/client/down.sh"
cat >$DOWN_SCRIPT <<EOF
#!/bin/bash
ip -6 rule del fwmark 55 table main 2>/dev/null || true
ip -6 rule del from all table 200 2>/dev/null || true
ip6tables -t mangle -D OUTPUT -p tcp --sport $SSH_PORT -j MARK --set-mark 55 2>/dev/null || true
EOF
chmod +x $DOWN_SCRIPT

# 6. 修改配置文件以调用脚本
echo ">>> 修改 Client 配置以支持策略路由..."
# 先移除旧的冲突配置
sed -i '/redirect-gateway/d' /etc/openvpn/client/client.conf
sed -i '/route-ipv6/d' /etc/openvpn/client/client.conf
sed -i '/script-security/d' /etc/openvpn/client/client.conf
sed -i '/up /d' /etc/openvpn/client/client.conf
sed -i '/down /d' /etc/openvpn/client/client.conf
sed -i '/pull-filter/d' /etc/openvpn/client/client.conf

# 写入新配置
cat >> /etc/openvpn/client/client.conf <<CONF

# --- 脚本控制 ---
script-security 2
up $UP_SCRIPT
down $DOWN_SCRIPT

# --- 路由控制 ---
# 1. 接管 IPv4 (IPv4 直接用 OpenVPN 原生指令接管即可)
redirect-gateway def1

# 2. 忽略服务端推送的 IPv6 路由 (我们用脚本自己处理，防止 SSH 断连)
pull-filter ignore "route-ipv6"
pull-filter ignore "redirect-gateway-ipv6"

# 3. 必须允许获取 IPv6 地址
# (这里不写 ignore ifconfig-ipv6，确保 tun0 有 v6 地址)

# 4. 强制 DNS
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1
CONF

# 7. 系统内核设置
echo ">>> 优化内核参数..."
# 确保不禁用 IPv6
sed -i '/disable_ipv6/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1

# 8. 重启服务
echo ">>> 重启 OpenVPN 服务..."
systemctl daemon-reload
systemctl restart openvpn-client@client

# 9. 等待并验证
echo ">>> 等待 VPN 连接 (10秒)..."
sleep 10

echo "==========================================="
echo "正在验证网络..."
echo "-------------------------------------------"
echo "1. 接口检测:"
ip link show tun0 >/dev/null 2>&1 && echo "   [OK] tun0 已启动" || echo "   [ERROR] tun0 未启动!"

echo "-------------------------------------------"
echo "2. IPv4 出口检测:"
IP4=$(curl -4 -s --connect-timeout 5 ip.sb)
if [[ -n "$IP4" ]]; then
    echo "   [OK] IPv4: $IP4 (应为出口服务器IP)"
else
    echo "   [ERROR] 无法获取 IPv4"
fi

echo "-------------------------------------------"
echo "3. IPv6 出口检测 (关键):"
IP6=$(curl -6 -s --connect-timeout 5 ip.sb)
if [[ -n "$IP6" ]]; then
    echo "   [OK] IPv6: $IP6 (应为出口服务器IP)"
else
    echo "   [ERROR] 无法获取 IPv6 (请检查出口服务器是否有IPv6)"
fi

echo "==========================================="
echo "如果 SSH 没断，且上方 IPv6 显示为出口 IP，则部署完美成功！"

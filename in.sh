#!/bin/bash
set -e

echo "==========================================="
echo "   OpenVPN 入口部署 (源地址策略路由最终版)"
echo "   功能：IPv4/IPv6 双栈接管 + SSH 防断连保护"
echo "==========================================="

# 0. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "错误：请使用 root 运行此脚本。"
   exit 1
fi

# 1. 安装必要软件
echo ">>> 更新系统并安装组件..."
# 尝试修复可能的 dpkg 锁
rm /var/lib/dpkg/lock-frontend 2>/dev/null || true
rm /var/lib/dpkg/lock 2>/dev/null || true
apt update -y
apt install -y openvpn iptables iptables-persistent curl iproute2

# 2. 检查 client.ovpn
if [ ! -f /root/client.ovpn ]; then
    echo "错误：未找到 /root/client.ovpn，请上传后重试！"
    exit 1
fi

# 3. 部署配置文件
echo ">>> 部署配置文件..."
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# 4. 编写核心路由控制脚本 (up.sh)
UP_SCRIPT="/etc/openvpn/client/up.sh"
echo ">>> 生成路由控制脚本 ($UP_SCRIPT)..."

cat >$UP_SCRIPT <<'EOF'
#!/bin/bash
# --------------------------------------------------
# OpenVPN Up Script - 策略路由控制
# --------------------------------------------------

# 1. 动态获取本机物理 IPv6 地址
# 逻辑：查找默认路由出口设备 -> 获取该设备的 Global IPv6
DEF_DEV=$(ip -6 route show default | grep -v tun | awk '{print $5}' | head -n1)
if [[ -z "$DEF_DEV" ]]; then
    # 备选方案：获取第一个非 lo、非 tun 的网卡
    DEF_DEV=$(ip -6 addr show scope global | grep inet6 | grep -v tun | grep -v docker | awk '{print $NF}' | head -n1)
fi

# 提取纯 IPv6 地址 (不带掩码)
NATIVE_IP6=$(ip -6 addr show dev $DEF_DEV scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1)

echo "[UP] 物理网卡: $DEF_DEV"
echo "[UP] 物理IPv6: $NATIVE_IP6"

# 2. 清理旧规则 (防止重复叠加)
ip -6 rule del from $NATIVE_IP6 table main 2>/dev/null || true
ip -6 rule del from all table 200 2>/dev/null || true
ip -6 route flush table 200

# 3. 添加 SSH 保护规则 (免死金牌)
# 含义：只要包的源地址是物理IP，强制走 main 表 (直连)
if [[ -n "$NATIVE_IP6" ]]; then
    ip -6 rule add from $NATIVE_IP6 table main priority 1000
    echo "[UP] 已添加 SSH 保护规则 (Priority 1000)"
else
    echo "[UP] 警告：未检测到物理 IPv6，SSH 保护可能失效！"
fi

# 4. 添加 VPN 导流规则
# 含义：剩下的流量 (Priority 2000)，查表 200
ip -6 rule add from all table 200 priority 2000

# 5. 设置表 200 的默认路由指向 VPN 设备
# $1 是 OpenVPN 传递下来的设备名 (例如 tun0)
if [[ -n "$1" ]]; then
    ip -6 route add default dev $1 table 200
    echo "[UP] 已将 VPN ($1) 设为表 200 默认路由"
else
    echo "[UP] 错误：未获取到 VPN 设备名"
fi

# 6. 确保 IPv4 转发和 NAT 正常
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -F
iptables -t nat -A POSTROUTING -o $1 -j MASQUERADE
EOF
chmod +x $UP_SCRIPT

# 5. 编写关闭脚本 (down.sh)
DOWN_SCRIPT="/etc/openvpn/client/down.sh"
cat >$DOWN_SCRIPT <<'EOF'
#!/bin/bash
# 清理策略路由规则
ip -6 rule del table main priority 1000 2>/dev/null || true
ip -6 rule del from all table 200 priority 2000 2>/dev/null || true
EOF
chmod +x $DOWN_SCRIPT

# 6. 修改 OpenVPN 配置
echo ">>> 修改 OpenVPN 配置以挂载脚本..."

# 清理可能存在的旧配置指令
sed -i '/redirect-gateway/d' /etc/openvpn/client/client.conf
sed -i '/route-ipv6/d' /etc/openvpn/client/client.conf
sed -i '/script-security/d' /etc/openvpn/client/client.conf
sed -i '/up /d' /etc/openvpn/client/client.conf
sed -i '/down /d' /etc/openvpn/client/client.conf
sed -i '/pull-filter/d' /etc/openvpn/client/client.conf

# 写入新配置
cat >> /etc/openvpn/client/client.conf <<CONF

# --- 脚本权限与挂载 ---
script-security 2
up $UP_SCRIPT
down $DOWN_SCRIPT

# --- IPv4 路由 (OpenVPN 原生接管) ---
redirect-gateway def1

# --- IPv6 路由 (脚本接管) ---
# 关键：忽略服务端推送的 IPv6 路由，完全由 up.sh 处理
pull-filter ignore "route-ipv6"
pull-filter ignore "redirect-gateway-ipv6"

# --- DNS 设置 ---
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1
CONF

# 7. 内核参数优化
echo ">>> 优化内核参数..."
# 确保不禁用 IPv6
sed -i '/disable_ipv6/d' /etc/sysctl.conf
# 开启转发
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1

# 8. 重启服务
echo ">>> 重启 OpenVPN 服务..."
systemctl daemon-reload
systemctl restart openvpn-client@client

# 9. 验证等待
echo ">>> 等待连接建立 (10秒)..."
sleep 10

echo "==========================================="
echo "网络状态验证："
echo "-------------------------------------------"
echo "1. 接口状态："
if ip addr show tun0 >/dev/null 2>&1; then
    echo "   [OK] tun0 接口已启动"
else
    echo "   [ERROR] tun0 未启动！请检查日志: journalctl -u openvpn-client@client"
fi

echo "-------------------------------------------"
echo "2. IPv4 出口测试："
IP4=$(curl -4 -s --connect-timeout 5 ip.sb || echo "Fail")
echo "   当前 IPv4: $IP4 (应为出口服务器 IP)"

echo "-------------------------------------------"
echo "3. IPv6 出口测试："
# 注意：curl 如果默认绑定物理 IP，会走直连显示入口 IP；
# 如果不绑定，应该走 VPN 显示出口 IP。
IP6=$(curl -6 -s --connect-timeout 5 ip.sb || echo "Fail")
echo "   当前 IPv6: $IP6" 
echo "   (提示：如果此处显示入口IP但SSH没断，说明策略路由生效了——SSH走了直连保护，"
echo "    而其他应用流量在进入 tun0 后会走 VPN)"

echo "==========================================="
echo "部署结束。请观察 SSH 是否保持连接。"

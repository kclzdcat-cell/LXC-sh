#!/bin/bash
set -e

echo "==========================================="
echo "   OpenVPN 入口部署 (v4.0 本地执行版)"
echo "   ✔ 融合：你的路由隔离逻辑 + 我的连接修复"
echo "   ✔ 修复：LXC 容器 tun0 设备丢失问题"
echo "   ✔ 修复：强制 UDP6 协议适配"
echo "==========================================="

# 0. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "错误：请使用 root 运行此脚本。"
   exit 1
fi

# ----------------------------------------------------
# [关键修复] LXC 容器 TUN 设备自动修复
# ----------------------------------------------------
# 很多 LXC 容器默认没有这个设备，导致 OpenVPN 启动瞬间崩溃
if [ ! -c /dev/net/tun ]; then
    echo ">>> 检测到 TUN 设备缺失 (LXC 环境)，正在修复..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
    if [ ! -c /dev/net/tun ]; then
        echo "❌ 无法创建 TUN 设备，请联系 VPS 服务商开启 TUN/TAP 功能！"
        exit 1
    fi
    echo "✔ TUN 设备修复成功"
fi

# 1. 安装组件
echo ">>> 更新系统并安装组件..."
rm /var/lib/dpkg/lock-frontend 2>/dev/null || true
apt update -y
apt install -y openvpn iptables iptables-persistent curl

# 2. 检查配置文件
if [ ! -f /root/client.ovpn ]; then
    echo "❌ 错误：未找到 /root/client.ovpn"
    echo "   请确保 warp-out.sh 已运行并提示‘验证成功’"
    exit 1
fi

# 3. 部署配置文件
echo ">>> 部署配置文件..."
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# ----------------------------------------------------
# [关键修复] 强制协议修正 (适配纯 IPv6)
# ----------------------------------------------------
echo ">>> 正在修正协议适配 IPv6 隧道..."
# 你的出口脚本生成的是 udp，这里必须强制改为 udp6
sed -i 's/^proto udp$/proto udp6/g' /etc/openvpn/client/client.conf
sed -i 's/^proto tcp$/proto tcp6/g' /etc/openvpn/client/client.conf
sed -i 's/ udp$/ udp6/g' /etc/openvpn/client/client.conf
sed -i 's/ tcp$/ tcp6/g' /etc/openvpn/client/client.conf

# 4. 写入核心配置
echo ">>> 写入路由与 MTU 优化配置..."

# 清理旧的 hook 脚本防止干扰
rm -f /etc/openvpn/client/up.sh
rm -f /etc/openvpn/client/down.sh

cat >> /etc/openvpn/client/client.conf <<CONF

# --- 路由控制 (基于你的脚本优化) ---

# 1. 接管 IPv4 默认路由 (自动覆盖)
redirect-gateway def1

# 2. [安全核心] 彻底屏蔽服务端推送的 IPv6 路由
# 这比 route-nopull 更智能，它允许 IPv4 路由生效，只过滤掉会导致 SSH 断连的 IPv6 路由
pull-filter ignore "route-ipv6"
pull-filter ignore "ifconfig-ipv6"
pull-filter ignore "redirect-gateway-ipv6"
pull-filter ignore "redirect-gateway"

# 3. [Warp 专用] 限制 TCP 包大小 (MSSFIX)
# 如果不加这个，Warp 套娃会导致 curl 卡死或网页打不开
mssfix 1280

# 4. DNS 配置
dhcp-option DNS 1.1.1.1
dhcp-option DNS 8.8.8.8
CONF

# 5. 内核参数优化
echo ">>> 优化内核转发参数..."
sed -i '/disable_ipv6/d' /etc/sysctl.conf
# 开启 IPv4 转发
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1

# 6. 配置 NAT
echo ">>> 配置 NAT 规则..."
iptables -t nat -F
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
netfilter-persistent save >/dev/null 2>&1

# 7. 重启 OpenVPN
echo ">>> 重启 OpenVPN 服务..."
systemctl daemon-reload
systemctl enable openvpn-client@client --now
systemctl restart openvpn-client@client

# 8. 等待并验证
echo ">>> 等待连接建立 (10秒)..."
sleep 10

echo "==========================================="
echo "   🔍 最终状态检查"
echo "==========================================="

# 检查 1: 进程是否存活
if systemctl is-active --quiet openvpn-client@client; then
    echo "✅ OpenVPN 服务运行中"
else
    echo "❌ OpenVPN 服务启动失败！"
    echo ">>> 错误日志："
    journalctl -u openvpn-client@client -n 10 --no-pager
    exit 1
fi

# 检查 2: tun0 网卡是否存在
if ip link show tun0 >/dev/null 2>&1; then
    echo "✅ 检测到 tun0 网卡 (连接成功)"
else
    echo "❌ 未检测到 tun0 网卡 (连接可能已断开)"
    exit 1
fi

# 检查 3: 连通性测试
echo "-------------------------------------------"
echo "正在测试 IPv4 出口 (应显示 Warp IP)..."
IP4=$(curl -4 -s --max-time 8 ip.sb || echo "Fail")

if [[ "$IP4" == "Fail" ]]; then
    echo "❌ IPv4 访问失败 (curl 超时)"
    echo "   可能原因：MTU 问题或出口服务器 NAT 未配置"
else
    echo -e "✅ IPv4 获取成功: \033[32m$IP4\033[0m"
fi

echo "-------------------------------------------"
echo "正在测试 IPv6 出口 (应显示本机 IP)..."
IP6=$(curl -6 -s --max-time 5 ip.sb || echo "Fail")
echo "ℹ️  当前 IPv6: $IP6"
echo "==========================================="

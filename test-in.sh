#!/bin/bash
set -e

echo "==========================================="
echo " OpenVPN 入口部署（IPv4 策略路由版）"
echo " 功能：IPv4 入站不动，IPv4 出站走 OpenVPN"
echo " IPv6：完全不接管（SSH 永久安全）"
echo "==========================================="

# 0. 权限检查
[[ $EUID -ne 0 ]] && { echo "请使用 root 运行"; exit 1; }

# 1. 安装依赖
echo ">>> 安装依赖..."
apt update -y
apt install -y openvpn iptables iptables-persistent curl iproute2

# 2. 检查 client.ovpn
if [[ ! -f /root/client.ovpn ]]; then
  echo "❌ 未找到 /root/client.ovpn"
  exit 1
fi

# 3. 部署 OpenVPN 配置
echo ">>> 部署 OpenVPN 配置..."
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# 4. 修改 client.conf（关键）
echo ">>> 修改 OpenVPN 客户端配置（策略路由模式）..."

sed -i '/redirect-gateway/d' /etc/openvpn/client/client.conf
sed -i '/route-nopull/d' /etc/openvpn/client/client.conf

cat >> /etc/openvpn/client/client.conf <<'EOF'

# ====== 策略路由核心 ======
route-nopull

# 禁止 IPv6（SSH 生命线）
pull-filter ignore "route-ipv6"
pull-filter ignore "ifconfig-ipv6"
pull-filter ignore "redirect-gateway-ipv6"

# DNS
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1
EOF

# 5. 启用 IPv4 转发
echo ">>> 启用 IPv4 转发..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# 6. 策略路由配置
echo ">>> 配置策略路由..."

# 路由表
grep -q '^100 ovpn' /etc/iproute2/rt_tables || echo "100 ovpn" >> /etc/iproute2/rt_tables

# 清理旧规则
ip rule del fwmark 0x66 table ovpn 2>/dev/null || true
ip route flush table ovpn 2>/dev/null || true
iptables -t mangle -D OUTPUT -m mark --mark 0x66 -j ACCEPT 2>/dev/null || true
iptables -t mangle -D OUTPUT -j MARK --set-mark 0x66 2>/dev/null || true

# tun0 默认路由
ip route add default dev tun0 table ovpn

# 只标记本机新建连接（不影响入站）
iptables -t mangle -A OUTPUT -m conntrack --ctstate NEW -j MARK --set-mark 0x66
iptables -t mangle -A OUTPUT -m mark --mark 0x66 -j ACCEPT

# 策略路由规则
ip rule add fwmark 0x66 table ovpn priority 100

iptables-save >/etc/iptables/rules.v4

# 7. 启动 OpenVPN
echo ">>> 启动 OpenVPN Client..."
systemctl daemon-reexec
systemctl restart openvpn-client@client

sleep 5

# 8. 验证
echo "==========================================="
echo "验证状态："
systemctl is-active --quiet openvpn-client@client \
  && echo "✔ OpenVPN 客户端运行中" \
  || journalctl -u openvpn-client@client -n 10 --no-pager

echo
echo "IPv4 出口（应为出口机）："
curl -4 ip.sb || true

echo
echo "IPv6（应为入口机原生）："
curl -6 ip.sb || true

echo "==========================================="
echo "完成：IPv4 出站已走 OpenVPN，入站完全不受影响"

#!/bin/bash
set -e

echo "======================================"
echo " OpenVPN 入口服务器安装脚本（IPv4 + IPv6）"
echo "======================================"

apt update -y
apt install -y openvpn iptables-persistent curl

echo "检测到入口服务器公网 IPv4:"
IP4=$(curl -4 -s ip.sb)
echo "IPv4: $IP4"

echo "检测到入口服务器公网 IPv6:"
IP6=$(curl -6 -s ip.sb || echo "无 IPv6")
echo "IPv6: $IP6"

# 入口默认网卡
IN_IF=$(ip route show default | awk '/default/ {print $5}')
echo "入口服务器默认出站网卡: $IN_IF"

mkdir -p /etc/openvpn/client
cd /etc/openvpn/client

# 用户上传的 client.ovpn 必须存在
if [[ ! -f /root/client.ovpn ]]; then
    echo "❌ 未找到 /root/client.ovpn"
    exit 1
fi

cp /root/client.ovpn client.conf

# 强制添加 redirect-gateway（保证流量强制走 OpenVPN）
sed -i '/redirect-gateway/d' client.conf
echo 'redirect-gateway def1 bypass-dhcp' >> client.conf

# DNS 保险处理
echo 'dhcp-option DNS 1.1.1.1' >> client.conf

# 启用 IPv6 转发
sysctl -w net.ipv6.conf.all.forwarding=1
echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf

# 启用 IPv4 转发
sysctl -w net.ipv4.ip_forward=1
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# 启动 OpenVPN
systemctl enable openvpn-client@client.service
systemctl restart openvpn-client@client.service

sleep 3

echo ">>> 检测 tun0 状态..."
ip a show tun0 || echo "❌ tun0 不存在（OpenVPN 未连接）"

# ================================
# 核心修复：强制默认路由走 tun0
# ================================
echo ">>> 强制设置默认路由走 tun0..."
ip route replace default dev tun0 || true

# 防止重启丢失：写入 systemd 脚本保证每次自动绑定
cat >/etc/systemd/system/ovpn-route.service <<EOF
[Unit]
Description=Force VPN route
After=network-online.target openvpn-client@client.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip route replace default dev tun0

[Install]
WantedBy=multi-user.target
EOF

systemctl enable ovpn-route.service
systemctl start ovpn-route.service

# ================================
# NAT，防止入口机无法访问外网
# ================================
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
netfilter-persistent save

echo "================================="
echo " OpenVPN 入口服务器安装完成！"
echo "================================="

echo "当前出口 IP:"
curl -4 ip.sb
echo

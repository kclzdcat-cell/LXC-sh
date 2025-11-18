#!/bin/bash
set -e

echo "============================================"
echo " OpenVPN 入口服务器自动部署脚本（IPv4 + IPv6）"
echo "============================================"

apt update -y
apt install -y openvpn iptables iptables-persistent curl

# -------------------------------
# 自动检测入口网卡
# -------------------------------
ETH=$(ip -o -4 route show to default | awk '{print $5}')
echo "入口服务器出站网卡: $ETH"

# -------------------------------
# 启用 IP 转发
# -------------------------------
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding

# 永久生效
cat >/etc/sysctl.d/99-openvpn.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF

sysctl -p

# -------------------------------
# 复制 client.ovpn
# -------------------------------
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# -------------------------------
# NAT 转发（入口→出口）
# -------------------------------
iptables -t nat -A POSTROUTING -o $ETH -j MASQUERADE
netfilter-persistent save

# -------------------------------
# 启动 OpenVPN
# -------------------------------
systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

echo "=============================="
echo " OpenVPN 入口服务器安装完成！"
echo "当前出口 IPv4："
curl -4 ip.sb || true
echo "=============================="

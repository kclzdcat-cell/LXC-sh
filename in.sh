#!/bin/bash
set -e

echo "==========================================="
echo "     OpenVPN 入口服务器客户端部署 V10.0"
echo "==========================================="

apt update -y
apt install -y openvpn iptables-persistent

if [ ! -f /root/client.ovpn ]; then
    echo "未找到 /root/client.ovpn，请确认出口服务器已上传！"
    exit 1
fi

mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

echo ">>> 禁用 IPv6"
echo "net.ipv6.conf.all.disable_ipv6=1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6=1" >> /etc/sysctl.conf
sysctl -p

echo ">>> 启用 IPv4 转发"
echo 1 >/proc/sys/net/ipv4/ip_forward
sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf

echo ">>> 启动 OpenVPN 客户端"
systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

echo ">>> 当前出口 IP："
curl -4 ip.sb

echo "==========================================="
echo "入口服务器部署成功！流量应已走出口服务器"

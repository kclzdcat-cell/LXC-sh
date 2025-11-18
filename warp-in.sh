#!/bin/bash
# OpenVPN 入口服务器（客户端）安装脚本
# 适用：Debian / Ubuntu

yellow(){ echo -e "\033[33m$1\033[0m"; }
green(){ echo -e "\033[32m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

echo "============================================="
echo " OpenVPN 入口服务器自动部署脚本（IPv4 + IPv6）"
echo "============================================="

sleep 1

apt update -y
apt install -y openvpn iptables-persistent curl

#---------------------------
# 网络转发
#---------------------------
cat >/etc/sysctl.d/99-openvpn.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-openvpn.conf

#---------------------------
# 防火墙 NAT
#---------------------------
NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)

iptables -t nat -A POSTROUTING -o "$NIC" -j MASQUERADE
netfilter-persistent save

#---------------------------
# 启动 OpenVPN 客户端
#---------------------------
mkdir -p /etc/openvpn/client/
cp /root/client.ovpn /etc/openvpn/client/client.conf

systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

green "入口服务器已成功连接到出口服务器！"

echo "当前出口 IP："
curl -4 ip.sb

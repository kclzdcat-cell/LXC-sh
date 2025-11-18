#!/bin/bash
clear

echo "==============================================="
echo "  OpenVPN 入口服务器安装脚本 (IPv4 + IPv6)"
echo "==============================================="

apt update -y
apt install -y openvpn curl

# 自动检测 IPv4/IPv6
IP4=$(curl -4 -s ip.sb)
IP6=$(curl -6 -s ip.sb)

echo "入口 IPv4: $IP4"
echo "入口 IPv6: ${IP6:-未检测到}"

# 自动检测出站网卡
WAN_IF=$(ip route get 1 | awk '{print $5; exit}')
echo "入口机出站网卡: $WAN_IF"

# 获取出口服务器 IPv6：由用户输入
read -p "请输入出口服务器 IPv6 地址: " OUTIPV6

# 创建 OpenVPN 客户端配置
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# 启动 UDP 客户端
systemctl enable openvpn-client@client
systemctl start openvpn-client@client

echo
echo "============================="
echo " OpenVPN 入口服务器安装完成！"
echo "============================="

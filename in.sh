#!/bin/bash
clear
echo "======================================="
echo "     OpenVPN 入口客户端自动部署脚本"
echo "======================================="

apt update -y
apt install -y openvpn

# 启动客户端
cp /root/client.ovpn /etc/openvpn/client.conf

systemctl enable openvpn@client
systemctl restart openvpn@client

echo "======================================="
echo " OpenVPN 入口客户端已启动成功！"
echo "======================================="

sleep 2
echo "当前出口 IP:"
curl -4 ip.sb

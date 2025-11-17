#!/bin/bash
# ===============================================
#  OpenVPN 入口服务器 自动部署脚本（安全版）
#  永不修改默认路由，SSH 永不掉
# ===============================================

echo "========== OpenVPN 入口客户端安装 =========="

apt update -y
apt install openvpn -y

# 将出口上传的 client.ovpn 放入正确目录
cp /root/client.ovpn /etc/openvpn/client.conf

systemctl enable openvpn@client
systemctl restart openvpn@client

echo "========== OpenVPN 入口客户端已启动成功 =========="

echo "当前出口 IP："
curl -4 ip.sb

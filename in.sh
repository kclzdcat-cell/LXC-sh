#!/bin/bash
set -e

echo "===================================="
echo " OpenVPN 入口客户端自动部署脚本"
echo "===================================="

apt update -y
apt install -y openvpn

if [[ ! -f /root/client.ovpn ]]; then
    echo "错误：未找到 /root/client.ovpn"
    echo "请先执行出口服务器 out.sh 自动上传配置文件"
    exit 1
fi

cp /root/client.ovpn /etc/openvpn/client.conf

systemctl enable openvpn@client
systemctl restart openvpn@client

echo ""
echo "===================================="
echo " OpenVPN 入口客户端已启动成功！"
echo "===================================="
ip a | grep tun

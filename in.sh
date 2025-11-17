#!/bin/bash
set -e

echo "============================"
echo " OpenVPN 入口服务器自动部署 "
echo "============================"

apt update -y
apt install -y openvpn sshpass curl

# 关闭 IPv6 避免泄漏
echo ">>> 禁用 IPv6 ..."
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p || true

mkdir -p /etc/openvpn/

# 检查是否收到 client.ovpn
if [ ! -f "/root/client.ovpn" ]; then
    echo "错误：未找到 /root/client.ovpn"
    echo "请确认出口服务器已成功上传。"
    exit 1
fi

echo ">>> 将 client.ovpn 安装为 OpenVPN 客户端配置 ..."
mkdir -p /etc/openvpn/client/
cp /root/client.ovpn /etc/openvpn/client/client.conf

echo ">>> 开启 IPv4 转发 ..."
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
sed -i 's/net.ipv4.ip_forward=0/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
sysctl -p || true

echo ">>> 启动 OpenVPN 客户端 ..."
systemctl enable openvpn@client
systemctl restart openvpn@client
sleep 5

echo "============================"
echo " OpenVPN 入口客户端已启动！"
echo "============================"

echo "当前出口 IPv4: "
curl -4 ip.sb || echo "IPv4 连接检测失败"


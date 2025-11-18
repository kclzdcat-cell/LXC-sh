#!/bin/bash
set -e

echo "======================================"
echo " OpenVPN 入口服务器自动部署脚本 (IPv4 + IPv6)"
echo "======================================"

apt update -y
apt install -y openvpn iptables iptables-persistent curl

# ---------------------------------------------------------
# 自动检测入口服务器本机 IP（可覆盖）
# ---------------------------------------------------------
echo "检测到入口服务器公网 IPv4:"
IP4=$(curl -4 -s ip.sb || true)
echo "IPv4: $IP4"

echo "检测到入口服务器公网 IPv6:"
IP6=$(curl -6 -s ip.sb || true)
echo "IPv6: $IP6"

# ---------------------------------------------------------
# 自动检测出口网卡
# ---------------------------------------------------------
IN_IF=$(ip route show default | awk '/default/ {print $5; exit}')
echo "入口服务器出站网卡: $IN_IF"


# ---------------------------------------------------------
# 确认 client.ovpn 已存在
# ---------------------------------------------------------
if [[ ! -f "/root/client.ovpn" ]]; then
    echo "❌ /root/client.ovpn 未找到，请先从出口服务器上传！"
    exit 1
fi


# ---------------------------------------------------------
# 开启 NAT（让所有入口流量走 OpenVPN）
# ---------------------------------------------------------
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
netfilter-persistent save


# ---------------------------------------------------------
# 创建 OpenVPN 客户端配置
# ---------------------------------------------------------
mkdir -p /etc/openvpn/client

cp /root/client.ovpn /etc/openvpn/client/client.conf


# ---------------------------------------------------------
# 启动 OpenVPN 客户端
# ---------------------------------------------------------
systemctl enable openvpn-client@client.service
systemctl restart openvpn-client@client.service


echo ""
echo "======================================"
echo " OpenVPN 入口服务器安装完成！"
echo "当前出口 IPv4:"
curl -4 ip.sb
echo "======================================"

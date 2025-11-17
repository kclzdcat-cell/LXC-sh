#!/bin/bash
set -e

echo "=============================="
echo " OpenVPN 入口服务器客户端部署 "
echo "  支持 Debian / Ubuntu 全系列 "
echo "=============================="

apt update -y
apt install -y openvpn curl iproute2

# ===== 自动检测入口公网 IP =====
LOCAL_IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
echo ">>> 入口服务器公网 IP: $LOCAL_IP"

# ===== 自动检测入口网卡 =====
NET_IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
GATEWAY=$(ip route | grep default | awk '{print $3}')
echo ">>> 检测到入口网卡: $NET_IFACE"
echo ">>> 检测到网关: $GATEWAY"

# ===== 检查 client.ovpn 是否存在 =====
if [ ! -f "/root/client.ovpn" ]; then
  echo "错误：未找到 /root/client.ovpn，请手动上传！"
  exit 1
fi

mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# ===== 防止 SSH 掉线（策略路由） =====
echo "100 sshroute" > /etc/iproute2/rt_tables.d/100-sshroute.conf

ip rule add fwmark 1 table sshroute
ip route add default via $GATEWAY dev $NET_IFACE table sshroute

iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 1
iptables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 1

# ===== 开启 IP 转发 =====
sysctl -w net.ipv4.ip_forward=1

# ===== 启动 OpenVPN 客户端 =====
systemctl enable openvpn@client
systemctl restart openvpn@client
sleep 4

echo "=============================="
echo " OpenVPN 客户端已启动！"
echo " 当前出口 IPv4："
curl -4 ip.sb || echo "检测失败"
echo "=============================="

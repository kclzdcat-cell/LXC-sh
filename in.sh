#!/bin/bash
set -e

echo "============================"
echo " OpenVPN 入口服务器自动部署 "
echo "============================"

# 1. 安装 OpenVPN
apt update -y
apt install -y openvpn iproute2

if [ ! -f /root/client.ovpn ]; then
    echo "错误: /root/client.ovpn 未找到，请先运行出口脚本！"
    exit 1
fi

mkdir -p /etc/openvpn/client/
cp /root/client.ovpn /etc/openvpn/client/client.conf

# 2. 获取入口原网关（防止 SSH 断线）
ETH=$(ip route | grep default | awk '{print $5}')
GW=$(ip route | grep default | awk '{print $3}')

echo "入口网卡: $ETH"
echo "入口默认网关: $GW"

# 3. 创建策略路由规则，SSH 不走 VPN
echo "100 sshroute" >> /etc/iproute2/rt_tables 2>/dev/null || true

ip rule add fwmark 1 table sshroute
ip route add default via $GW dev $ETH table sshroute

# 4. SSH 连接流量标记
iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 1
iptables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 1

# 5. NAT & 开启路由
sysctl -w net.ipv4.ip_forward=1

# 6. 启动 OpenVPN 客户端
systemctl enable openvpn@client
systemctl restart openvpn@client

echo "============================"
echo " OpenVPN 入口服务器已启动！"
echo "============================"

出口IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
echo "当前出口 IP:"
echo "$出口IP"

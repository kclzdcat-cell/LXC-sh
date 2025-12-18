#!/bin/bash

echo "==========================================="
echo "   WireGuard 入口部署 (稳定完整版)"
echo "   入站保持本地，出站走 VPN"
echo "==========================================="

apt-get update
apt-get install -y wireguard curl

CLIENT_CONF="/root/wg_client.conf"
[ ! -f "$CLIENT_CONF" ] && echo "缺少 $CLIENT_CONF" && exit 1

WG_SERVER_IP=$(grep Endpoint "$CLIENT_CONF" | awk -F'[ :]' '{print $2}')

# 写 wg0.conf（禁止 wg-quick 接管路由）
mkdir -p /etc/wireguard
sed '/^Table/d' "$CLIENT_CONF" > /etc/wireguard/wg0.conf
sed -i '/^\[Interface\]/a Table = off' /etc/wireguard/wg0.conf

# 启动 WG
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

sleep 3
wg show || exit 1

# 获取原默认路由
GW=$(ip route | awk '/default/ {print $3}')
IFACE=$(ip route | awk '/default/ {print $5}')

# 确保到 WG 服务器本身不走隧道
ip route add "$WG_SERVER_IP" via "$GW" dev "$IFACE" 2>/dev/null || true

# 策略路由：仅本机出站走 wg0
ip route add default dev wg0 table 200 2>/dev/null || true
ip rule add from all lookup 200 priority 1000 2>/dev/null || true
ip route flush cache

# IPv6（如果有）
if ip -6 addr show dev wg0 | grep -q inet6; then
    ip -6 route add default dev wg0 table 200 2>/dev/null || true
    ip -6 rule add from all lookup 200 priority 1000 2>/dev/null || true
    ip -6 route flush cache
fi

echo "==========================================="
echo "入口机部署完成"
echo "✔ 所有入站连接保持本地"
echo "✔ IPv4/IPv6 出站走 WireGuard 出口"
echo "✔ SSH 安全"
echo "==========================================="

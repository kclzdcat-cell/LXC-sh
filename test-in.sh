#!/usr/bin/env bash
set -e

echo "=== WireGuard 入口机（手动输入 · SSH 永不掉线）==="

apt update
apt install -y wireguard iproute2 curl

read -p "出口机公网 IP: " SERVER_IP
read -p "WireGuard 端口: " SERVER_PORT
read -p "Server 公钥  : " SERVER_PUB
read -p "Client 私钥  : " CLIENT_KEY

WG_IF=wg0

# 清理旧接口
ip link del wg0 2>/dev/null || true

# 建接口
ip link add wg0 type wireguard
wg set wg0 private-key <(echo "$CLIENT_KEY") peer "$SERVER_PUB" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips 0.0.0.0/0,::/0 persistent-keepalive 25

# IP
ip addr add 10.0.0.2/24 dev wg0
ip addr add fd10::2/64 dev wg0
ip link set wg0 up

# 低优先级默认路由（SSH 不受影响）
ip route add default dev wg0 metric 100
ip -6 route add default dev wg0 metric 100

echo
echo "WireGuard 已连接"
echo "当前状态："
wg
echo
echo "出口 IP 验证："
curl -4 ip.sb

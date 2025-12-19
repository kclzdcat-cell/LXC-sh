#!/usr/bin/env bash
set -euo pipefail

echo "=== WireGuard 出口机 out.sh (无resolvconf/无wg-quick/稳定) ==="

WG_IF=wg0
WG_PORT=51820
WG_ADDR4="10.66.66.1/24"
WG_ADDR6="fd10::1/64"

WAN_IF="$(ip route | awk '/default/ {print $5; exit}')"
[ -n "${WAN_IF:-}" ] || { echo "❌ 无法识别默认外网网卡"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y wireguard iproute2 iptables curl

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

# 清理旧 wg0
ip link del "$WG_IF" 2>/dev/null || true

umask 077
SERVER_PRIV="$(wg genkey)"
SERVER_PUB="$(echo "$SERVER_PRIV" | wg pubkey)"

ip link add "$WG_IF" type wireguard
wg set "$WG_IF" listen-port "$WG_PORT" private-key <(echo "$SERVER_PRIV")
ip addr add "$WG_ADDR4" dev "$WG_IF"
ip -6 addr add "$WG_ADDR6" dev "$WG_IF"
ip link set "$WG_IF" up

# NAT + 转发
iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
iptables -C FORWARD -i "$WG_IF" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$WG_IF" -j ACCEPT
iptables -C FORWARD -o "$WG_IF" -j ACCEPT 2>/dev/null || iptables -A FORWARD -o "$WG_IF" -j ACCEPT

WAN4="$(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{print $4}' | head -n1 | cut -d/ -f1)"
WAN6="$(ip -6 -o addr show dev "$WAN_IF" scope global | awk '{print $4}' | head -n1 | cut -d/ -f1)"

echo
echo "================= 给入口机填这三项 ================="
echo "出口机公网IP(IPv4/IPv6): ${WAN4:-${WAN6:-（无）}}"
echo "WireGuard 端口: $WG_PORT"
echo "出口机 Server 公钥: $SERVER_PUB"
echo "=================================================="
echo
echo "当前 wg 状态："
wg show
echo
echo "✅ 出口机完成。下一步：去入口机运行 in.sh，手动填上面三项。"

#!/usr/bin/env bash
set -e

echo "=== WireGuard 出口机（最终稳定版）==="

# ===== 基础信息 =====
WG_IF=wg0
WG_PORT=51820
WG_ADDR=10.66.66.1/24

# ===== 安装依赖 =====
apt update -y
apt install -y wireguard iproute2 iptables curl

# ===== 开启转发 =====
sysctl -w net.ipv4.ip_forward=1

# ===== 清理旧接口 =====
ip link del $WG_IF 2>/dev/null || true

# ===== 生成密钥 =====
SERVER_PRIV=$(wg genkey)
SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)

# ===== 创建接口 =====
ip link add $WG_IF type wireguard
wg set $WG_IF private-key <(echo "$SERVER_PRIV") listen-port $WG_PORT
ip addr add $WG_ADDR dev $WG_IF
ip link set $WG_IF up

# ===== NAT =====
EXT_IF=$(ip route | awk '/default/ {print $5; exit}')
iptables -t nat -C POSTROUTING -o $EXT_IF -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o $EXT_IF -j MASQUERADE

echo
echo "================ 给入口机用的信息 ================"
echo "出口机公网 IP : $(curl -4 -s ip.sb)"
echo "WireGuard 端口: $WG_PORT"
echo "Server 公钥  : $SERVER_PUB"
echo "=================================================="
echo
wg show

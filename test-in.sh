#!/usr/bin/env bash
set -e

echo "=== WireGuard 入口机（SSH 永不断版）==="

# ===== 手动填写（来自出口机）=====
SERVER_IP="出口机公网IP"
SERVER_PORT=51820
SERVER_PUBKEY="出口机Server公钥"
# =================================

WG_IF=wg0
WG_ADDR=10.66.66.2/24

# ===== 安装依赖 =====
apt update -y
apt install -y wireguard iproute2 iptables curl

# ===== 清理旧状态 =====
ip link del $WG_IF 2>/dev/null || true
iptables -t nat -D OUTPUT -o $WG_IF -j MASQUERADE 2>/dev/null || true

# ===== 生成 Client 密钥 =====
CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)

# ===== 创建 WireGuard =====
ip link add $WG_IF type wireguard
wg set $WG_IF \
  private-key <(echo "$CLIENT_PRIV") \
  peer $SERVER_PUBKEY \
  endpoint $SERVER_IP:$SERVER_PORT \
  allowed-ips 0.0.0.0/0 \
  persistent-keepalive 25

ip addr add $WG_ADDR dev $WG_IF
ip link set $WG_IF up

# ===== 只劫持出站 =====
iptables -t nat -A OUTPUT -o $WG_IF -j MASQUERADE

echo
echo "============== 需要回填给出口机 =============="
echo "Client 公钥: $CLIENT_PUB"
echo "=============================================="
echo
wg show
echo
echo "出口 IP 验证："
curl -4 ip.sb || true

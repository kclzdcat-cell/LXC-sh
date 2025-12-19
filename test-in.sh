#!/usr/bin/env bash
set -euo pipefail

echo "=== WireGuard 入口机 in.sh (不掉SSH/全出站走WG/无fwmark) ==="

WG_IF=wg0
WG_ADDR4="10.66.66.2/24"
WG_ADDR6="fd10::2/64"
WG_TABLE=200

INMARK=1  # 保护入站连接回包的 mark

WAN_IF="$(ip route | awk '/default/ {print $5; exit}')"
WAN_GW="$(ip route | awk '/default/ {print $3; exit}')"
WAN_GW6="$(ip -6 route | awk '/default/ {print $3; exit}' | head -n1)"

[ -n "${WAN_IF:-}" ] || { echo "❌ 无法识别默认外网网卡"; exit 1; }
[ -n "${WAN_GW:-}" ] || { echo "❌ 无法识别默认 IPv4 网关"; exit 1; }

export DEBIAN_FRONTEND=noninteractive

echo "[0/6] 修复 dpkg/apt 状态 + 等待锁"
dpkg --configure -a 2>/dev/null || true
apt-get -f install -y 2>/dev/null || true
# 等 apt lock（避免你之前那种 dpkg 卡死）
for i in $(seq 1 60); do
  if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    echo "  - 等待 apt 锁... ($i/60)"
    sleep 2
  else
    break
  fi
done

echo "[1/6] 更新源 & 安装依赖"
apt-get update -y
apt-get install -y wireguard iproute2 iptables curl

echo "[2/6] 手动输入出口机信息"
read -rp "出口机公网 IP (IPv4 或 IPv6): " SERVER_IP
read -rp "WireGuard 端口(默认 51820): " SERVER_PORT
SERVER_PORT="${SERVER_PORT:-51820}"
read -rp "出口机 Server 公钥(44位Base64，以=结尾): " SERVER_PUBKEY

if ! echo "$SERVER_PUBKEY" | grep -Eq '^[A-Za-z0-9+/]{43}=$'; then
  echo "❌ 公钥格式不对，必须是 44 位 Base64，以=结尾"
  exit 1
fi

echo "[3/6] 保护所有入站连接的回包（SSH不会断）"
iptables -t mangle -C PREROUTING -i "$WAN_IF" -j CONNMARK --set-mark "$INMARK" 2>/dev/null || \
iptables -t mangle -A PREROUTING -i "$WAN_IF" -j CONNMARK --set-mark "$INMARK"
iptables -t mangle -C OUTPUT -j CONNMARK --restore-mark 2>/dev/null || \
iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark
ip rule add fwmark "$INMARK" lookup main priority 50 2>/dev/null || true

echo "[4/6] 固定出口机 endpoint 永远走原网卡（避免路由死循环）"
if echo "$SERVER_IP" | grep -q ":"; then
  # IPv6 endpoint
  if [ -n "${WAN_GW6:-}" ]; then
    ip -6 route replace "$SERVER_IP/128" via "$WAN_GW6" dev "$WAN_IF" 2>/dev/null || true
  else
    # 没有 IPv6 网关就不强行加
    true
  fi
else
  # IPv4 endpoint
  ip route replace "$SERVER_IP/32" via "$WAN_GW" dev "$WAN_IF" 2>/dev/null || true
fi

echo "[5/6] 清理旧 wg0 和旧策略（不改默认路由）"
ip rule del table "$WG_TABLE" 2>/dev/null || true
ip route flush table "$WG_TABLE" 2>/dev/null || true
ip route flush cache 2>/dev/null || true
ip link del "$WG_IF" 2>/dev/null || true

echo "[6/6] 创建 wg0 + 全出站走 WG（入站回包不受影响）"
umask 077
CLIENT_PRIV="$(wg genkey)"
CLIENT_PUB="$(echo "$CLIENT_PRIV" | wg pubkey)"

ip link add "$WG_IF" type wireguard
wg set "$WG_IF" \
  private-key <(echo "$CLIENT_PRIV") \
  peer "$SERVER_PUBKEY" \
  endpoint "${SERVER_IP}:${SERVER_PORT}" \
  allowed-ips 0.0.0.0/0,::/0 \
  persistent-keepalive 25

ip addr add "$WG_ADDR4" dev "$WG_IF"
ip -6 addr add "$WG_ADDR6" dev "$WG_IF"
ip link set "$WG_IF" up

# 默认走 WG_TABLE
ip route add default dev "$WG_IF" table "$WG_TABLE" 2>/dev/null || true
ip rule add table "$WG_TABLE" priority 200 2>/dev/null || true
ip route flush cache 2>/dev/null || true

echo
echo "================= 回填到出口机（非常关键） ================="
echo "入口机 Client 公钥: $CLIENT_PUB"
echo "在出口机执行："
echo "  wg set wg0 peer $CLIENT_PUB allowed-ips 10.66.66.2/32,fd10::2/128"
echo "=========================================================="
echo
echo "入口机 wg 状态："
wg show
echo
echo "验证（先回填peer再测）："
echo "  curl -4 --interface $WG_IF -s --max-time 10 ip.sb"
echo "  curl -4 -s --max-time 10 ip.sb"

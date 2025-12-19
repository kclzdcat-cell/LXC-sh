#!/usr/bin/env bash
set -euo pipefail

echo "=== WireGuard 入口机 in.sh (稳定版/不碰resolvconf/不掉SSH) ==="

WG_IF=wg0
WG_ADDR4="10.66.66.2/24"
WG_ADDR6="fd10::2/64"

WG_TABLE=200
WG_MARK=51820          # 给 wg 自己用的 fwmark
INMARK=1               # 保护“入站连接”的 connmark/fwmark

WAN_IF="$(ip route | awk '/default/ {print $5; exit}')"
[ -n "${WAN_IF:-}" ] || { echo "❌ 无法识别默认外网网卡"; exit 1; }

export DEBIAN_FRONTEND=noninteractive

echo "[1/5] 修复 dpkg/apt 状态 + 更新源"
dpkg --configure -a 2>/dev/null || true
apt-get -f install -y 2>/dev/null || true
apt-get update -y

echo "[2/5] 安装依赖"
apt-get install -y wireguard iproute2 iptables curl

echo "[3/5] 手动输入出口机信息"
read -rp "出口机公网 IP (IPv4 或 IPv6): " SERVER_IP
read -rp "WireGuard 端口(默认 51820): " SERVER_PORT
SERVER_PORT="${SERVER_PORT:-51820}"
read -rp "出口机 Server 公钥(44位Base64，以=结尾): " SERVER_PUBKEY

if ! echo "$SERVER_PUBKEY" | grep -Eq '^[A-Za-z0-9+/]{43}=$'; then
  echo "❌ 公钥格式不对。必须像这样 44 位 Base64："
  echo "   5pXPrl+RgawnoyZRe4PsMvA0yMsxjsR7AYtd5Ep1GBM="
  exit 1
fi

echo "[4/5] 清理旧配置（不动默认路由）"
wg-quick down "$WG_IF" 2>/dev/null || true
ip link del "$WG_IF" 2>/dev/null || true
ip rule del fwmark "$INMARK" 2>/dev/null || true
ip rule del fwmark "$WG_MARK" 2>/dev/null || true
ip rule del table "$WG_TABLE" 2>/dev/null || true
ip route flush table "$WG_TABLE" 2>/dev/null || true

# 关键：保护所有“入站建立的连接”的回包走原网卡
iptables -t mangle -C PREROUTING -i "$WAN_IF" -j CONNMARK --set-mark "$INMARK" 2>/dev/null || \
iptables -t mangle -A PREROUTING -i "$WAN_IF" -j CONNMARK --set-mark "$INMARK"
iptables -t mangle -C OUTPUT -j CONNMARK --restore-mark 2>/dev/null || \
iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark

# 让被标记为 INMARK 的流量强制走 main（也就是原网卡）
ip rule add fwmark "$INMARK" lookup main priority 50 2>/dev/null || true

echo "[5/5] 启动 wg 并切换全出站到 wg（入站回包不受影响）"
umask 077
CLIENT_PRIV="$(wg genkey)"
CLIENT_PUB="$(echo "$CLIENT_PRIV" | wg pubkey)"

ip link add "$WG_IF" type wireguard
wg set "$WG_IF" \
  private-key <(echo "$CLIENT_PRIV") \
  peer "$SERVER_PUBKEY" \
  endpoint "${SERVER_IP}:${SERVER_PORT}" \
  allowed-ips 0.0.0.0/0,::/0 \
  persistent-keepalive 25 \
  fwmark "$WG_MARK"

ip addr add "$WG_ADDR4" dev "$WG_IF"
ip -6 addr add "$WG_ADDR6" dev "$WG_IF"
ip link set "$WG_IF" up

# wg 自己的握手/控制流量不要走 wg（避免死循环）
ip rule add fwmark "$WG_MARK" lookup main priority 100 2>/dev/null || true

# 默认出站走 wg 的 table 200
ip route add default dev "$WG_IF" table "$WG_TABLE" 2>/dev/null || true
ip rule add table "$WG_TABLE" priority 200 2>/dev/null || true
ip route flush cache 2>/dev/null || true

echo
echo "================= 回填到出口机 ================="
echo "入口机 Client 公钥: $CLIENT_PUB"
echo "在出口机执行："
echo "  wg set wg0 peer $CLIENT_PUB allowed-ips 10.66.66.2/32,fd10::2/128"
echo "================================================"
echo
echo "当前 wg 状态："
wg show
echo
echo "验证：强制走 wg0 查询出口IP（如果这里还是入口机IP，说明 peer 没回填到出口机）"
curl --interface "$WG_IF" -4 -s --max-time 10 ip.sb || true
echo

#!/usr/bin/env bash
set -e

echo "=== WireGuard 入口机（防误操作稳定版）==="

# ====== 手动填写 ======
SERVER_IP="185.18.221.229"
SERVER_PORT=51820
SERVER_PUBKEY="在这里粘贴出口机真正的Server公钥"
# ======================

# ===== 校验公钥 =====
if ! echo "$SERVER_PUBKEY" | grep -Eq '^[A-Za-z0-9+/]{43}=$'; then
  echo "❌ Server 公钥格式错误"
  echo "必须是 44 位 Base64，例如："
  echo "5pXPrl+RgawnoyZRe4PsMvA0yMsxjsR7AYtd5Ep1GBM="
  exit 1
fi

WG_IF=wg0
WG_ADDR=10.66.66.2/24

# ===== 安装依赖 =====
apt update -y
apt install -y wireguard iproute2 iptables curl

# ===== 清理旧接口 =====
ip link del $WG_IF 2>/dev/null || true
iptables -t nat -D OUTPUT -o $WG_IF -j MASQUERADE 2>/dev/null || true

# ===== 生成 Client 密钥 =====
CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)

# ===== 创建 WireGuard =====
ip link add $WG_IF type wireguard
wg set $WG_IF \
  private-key <(echo "$CLIENT_PRIV") \
  peer "$SERVER_PUBKEY" \
  endpoint "$SERVER_IP:$SERVER_PORT" \
  allowed-ips 0.0.0.0/0 \
  persistent-keepalive 25

ip addr add $WG_ADDR dev $WG_IF
ip link set $WG_IF up

# ===== 只劫持出站 =====
iptables -t nat -A OUTPUT -o $WG_IF -j MASQUERADE

echo
echo "================= 重要 ================="
echo "请把下面 Client 公钥 加到出口机："
echo
echo "Client 公钥: $CLIENT_PUB"
echo
echo "出口机执行："
echo "wg set wg0 peer $CLIENT_PUB allowed-ips 10.66.66.2/32"
echo "======================================="
echo
wg show
echo
echo "出口 IP 验证："
curl -4 ip.sb || true

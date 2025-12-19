#!/usr/bin/env bash
set -euo pipefail

echo "=== WireGuard 入口机 in.sh (手动输入/全出站走WG/SSH不掉线) ==="

WG_IF=wg0
WG_ADDR4="10.66.66.2/24"
WG_TABLE=200
WG_MARK=51820

export DEBIAN_FRONTEND=noninteractive

echo "[1/6] 修复 dpkg/apt 状态 + 更新源"
dpkg --configure -a 2>/dev/null || true
apt-get -f install -y 2>/dev/null || true

# 避免你截图里那种 dpkg lock 卡死
for i in {1..30}; do
  if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    echo "  - 等待 apt 锁释放... ($i/30)"
    sleep 2
  else
    break
  fi
done

apt-get update -y

echo "[2/6] 安装依赖"
apt-get install -y wireguard iproute2 iptables curl resolvconf

echo "[3/6] 读取你的手动输入"
read -rp "出口机公网 IP (IPv4 或 IPv6): " SERVER_IP
read -rp "WireGuard 端口(默认 51820): " SERVER_PORT
SERVER_PORT="${SERVER_PORT:-51820}"
read -rp "出口机 Server 公钥(44位Base64，以=结尾): " SERVER_PUBKEY

if ! echo "$SERVER_PUBKEY" | grep -Eq '^[A-Za-z0-9+/]{43}=$'; then
  echo "❌ 公钥格式不对。必须像这样 44 位 Base64："
  echo "   5pXPrl+RgawnoyZRe4PsMvA0yMsxjsR7AYtd5Ep1GBM="
  exit 1
fi

echo "[4/6] 清理旧 wg0（不碰默认路由）"
wg-quick down "$WG_IF" 2>/dev/null || true
ip link del "$WG_IF" 2>/dev/null || true
ip rule del fwmark "$WG_MARK" 2>/dev/null || true
ip rule del table "$WG_TABLE" 2>/dev/null || true
ip route flush table "$WG_TABLE" 2>/dev/null || true

echo "[5/6] 生成入口机密钥并启动 wg0"
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
ip link set "$WG_IF" up

# ---- SSH 保护：让当前 SSH 连接继续走原网卡 ----
# 原理：对“本机发往当前 SSH 客户端”的回包，强制走 main 表（原默认路由），避免被全局导入 wg。
SSH_CLIENT_IP="$(echo "${SSH_CLIENT:-}" | awk '{print $1}')"
SSH_LOCAL_PORT="$(ss -tnp 2>/dev/null | awk -v ip="$SSH_CLIENT_IP" '
  $0 ~ ip && $0 ~ /sshd/ {
    split($4,a,":"); print a[length(a)];
    exit
  }')"

if [ -n "${SSH_CLIENT_IP:-}" ] && [ -n "${SSH_LOCAL_PORT:-}" ]; then
  echo "  - SSH 保护: 客户端=$SSH_CLIENT_IP 本地端口=$SSH_LOCAL_PORT"
  # 目的为 SSH_CLIENT_IP 的流量优先走 main
  ip rule add to "$SSH_CLIENT_IP/32" lookup main priority 50 2>/dev/null || true
  # 同时也保护本地 22/实际端口的回包路径（更稳）
  iptables -t mangle -C OUTPUT -p tcp --sport "$SSH_LOCAL_PORT" -j MARK --set-mark 0 2>/dev/null || \
  iptables -t mangle -A OUTPUT -p tcp --sport "$SSH_LOCAL_PORT" -j MARK --set-mark 0
else
  echo "  - 未检测到 SSH_CLIENT（可能不是通过 ssh 跑的），将继续执行但请小心。"
fi

# ---- 全出站走 WG：策略路由 ----
# 关键：用 fwmark 避免 wg 自己的握手流量被再次导回 wg（死循环）
wg set "$WG_IF" fwmark "$WG_MARK"

ip route add default dev "$WG_IF" table "$WG_TABLE" 2>/dev/null || true
ip rule add fwmark "$WG_MARK" lookup main priority 100 2>/dev/null || true
ip rule add table "$WG_TABLE" priority 200 2>/dev/null || true
ip route flush cache 2>/dev/null || true

echo "[6/6] 输出对接信息 & 验证"
echo
echo "================= 回填到出口机 ================="
echo "入口机 Client 公钥: $CLIENT_PUB"
echo "在出口机执行："
echo "  wg set wg0 peer $CLIENT_PUB allowed-ips 10.66.66.2/32"
echo "================================================"
echo
echo "当前 wg 状态："
wg show
echo
echo "验证出口IP（强制走wg接口）："
curl --interface "$WG_IF" -4 -s --max-time 10 ip.sb || true
echo
echo "✅ 完成。若上面显示的是出口机IP，则成功。"

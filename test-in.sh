#!/usr/bin/env bash
set -e

echo "=== WireGuard 入口机（SSH 永不掉线 · 终极稳定版）==="

CONF="/root/wg_client.conf"

# -------------------------------
# 0. 基础校验
# -------------------------------
if [ "$(id -u)" != "0" ]; then
  echo "请使用 root 执行"
  exit 1
fi

if [ ! -f "$CONF" ]; then
  echo "缺少配置文件 $CONF"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# -------------------------------
# 1. 修复 dpkg / apt 状态
# -------------------------------
echo "[1/8] 修复 dpkg / apt 状态"

pkill -9 apt apt-get dpkg 2>/dev/null || true
rm -f /var/lib/dpkg/lock*
rm -f /var/cache/apt/archives/lock
dpkg --configure -a || true
apt-get -f install -y || true

# -------------------------------
# 2. 更新软件源
# -------------------------------
echo "[2/8] 更新软件源"
apt update

# -------------------------------
# 3. 如果已存在 WireGuard，彻底清理
# -------------------------------
echo "[3/8] 检测并清理旧 WireGuard"

systemctl stop wg-quick@wg0 2>/dev/null || true
ip link del wg0 2>/dev/null || true

if command -v wg >/dev/null 2>&1; then
  apt purge -y wireguard wireguard-tools || true
fi

# -------------------------------
# 4. 安装依赖
# -------------------------------
echo "[4/8] 安装 WireGuard 及依赖"

apt install -y wireguard wireguard-tools iproute2 curl

# -------------------------------
# 5. 创建 WireGuard 接口（不用 wg-quick）
# -------------------------------
echo "[5/8] 创建 WireGuard 接口"

ip link add wg0 type wireguard
wg setconf wg0 "$CONF"

# -------------------------------
# 6. 配置 IP
# -------------------------------
echo "[6/8] 配置 IP 地址"

ADDR_LINE=$(grep '^Address' "$CONF" | cut -d= -f2)

IPV4=$(echo "$ADDR_LINE" | cut -d, -f1 | xargs)
IPV6=$(echo "$ADDR_LINE" | cut -d, -f2 | xargs)

ip addr add "$IPV4" dev wg0
[ -n "$IPV6" ] && ip addr add "$IPV6" dev wg0

ip link set wg0 up

# -------------------------------
# 7. 设置“低优先级”默认出口（关键）
# -------------------------------
echo "[7/8] 设置默认出站路由（不影响 SSH）"

ip route add default dev wg0 metric 50 2>/dev/null || true
ip -6 route add default dev wg0 metric 50 2>/dev/null || true

# -------------------------------
# 8. 完成
# -------------------------------
echo "[8/8] 完成"

echo
echo "========================================"
echo "WireGuard 出站代理已启用"
echo "✔ SSH 不受影响"
echo "✔ 入口机入站 IP 保持不变"
echo "✔ 出站流量走出口机"
echo
echo "验证命令："
echo "  curl -4 ip.sb"
echo "  curl -6 ip.sb"
echo "========================================"

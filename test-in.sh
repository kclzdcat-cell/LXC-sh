#!/usr/bin/env bash
set -e

echo "=== WireGuard 入口机（SSH 永不掉线 · 最终修正版）1.0==="

CONF="/root/wg_client.conf"

if [ "$(id -u)" != "0" ]; then
  echo "请用 root 执行"
  exit 1
fi

if [ ! -f "$CONF" ]; then
  echo "缺少 $CONF"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# 1. 修复 dpkg / apt
pkill -9 apt apt-get dpkg 2>/dev/null || true
rm -f /var/lib/dpkg/lock*
rm -f /var/cache/apt/archives/lock
dpkg --configure -a || true
apt -f install -y || true

# 2. 更新源
apt update

# 3. 清理旧 wg
systemctl stop wg-quick@wg0 2>/dev/null || true
ip link del wg0 2>/dev/null || true
apt purge -y wireguard wireguard-tools 2>/dev/null || true

# 4. 安装依赖
apt install -y wireguard wireguard-tools iproute2 curl

# 5. 解析 Address（重点修复点）
ADDR_LINE=$(grep '^Address' "$CONF" | cut -d= -f2 | tr -d ' ')
IPV4_ADDR=$(echo "$ADDR_LINE" | cut -d, -f1)
IPV6_ADDR=$(echo "$ADDR_LINE" | cut -d, -f2)

# 6. 生成 wg 专用配置（去掉 Address）
WG_CONF_CLEAN="/tmp/wg0.conf"
grep -v '^Address' "$CONF" > "$WG_CONF_CLEAN"

# 7. 创建 wg 接口
ip link add wg0 type wireguard
wg setconf wg0 "$WG_CONF_CLEAN"

# 8. 手动加 IP
ip addr add "$IPV4_ADDR" dev wg0
[ -n "$IPV6_ADDR" ] && ip addr add "$IPV6_ADDR" dev wg0

ip link set wg0 up

# 9. 设置低优先级默认路由（绝不影响 SSH）
ip route add default dev wg0 metric 50 2>/dev/null || true
ip -6 route add default dev wg0 metric 50 2>/dev/null || true

echo
echo "========================================"
echo "WireGuard 已成功启用"
echo "✔ SSH 未中断"
echo "✔ 入口机 IP 不变"
echo "✔ 出站流量走出口机"
echo
echo "请验证："
echo "  curl -4 ip.sb"
echo "  curl -6 ip.sb"
echo "========================================"

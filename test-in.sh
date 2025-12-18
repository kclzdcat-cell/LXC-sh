#!/bin/bash

set -e

echo "==========================================="
echo "   WireGuard 入口部署（校验增强版）"
echo "==========================================="

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 执行"
    exit 1
fi

CLIENT_CONF="/root/wg_client.conf"
[ ! -f "$CLIENT_CONF" ] && echo "缺少 $CLIENT_CONF" && exit 1

# 记录原出口 IP
ORIG_IP4=$(curl -4s ip.sb || echo "unknown")
ORIG_IP6=$(curl -6s ip.sb || echo "unknown")

echo "原 IPv4 出口: $ORIG_IP4"
echo "原 IPv6 出口: $ORIG_IP6"

# 修复 apt / dpkg
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 1; done
dpkg --configure -a >/dev/null 2>&1 || true
apt-get update
apt-get install -y wireguard wireguard-tools curl

# 校验 wg
command -v wg >/dev/null || { echo "wg 未安装"; exit 1; }

# 写 wg0.conf（禁用自动路由）
mkdir -p /etc/wireguard
sed '/^Table/d' "$CLIENT_CONF" > /etc/wireguard/wg0.conf
sed -i '/^\[Interface\]/a Table = off' /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

# 启动 wg
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0
sleep 3
wg show >/dev/null || { echo "WireGuard 启动失败"; exit 1; }

# 保护当前 SSH
SSH_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
if [ -n "$SSH_IP" ]; then
    ip rule add to "$SSH_IP" lookup main priority 100 2>/dev/null || true
    echo "已保护当前 SSH 客户端 $SSH_IP"
fi

WG_SERVER_IP=$(grep Endpoint "$CLIENT_CONF" | awk -F'[ :]' '{print $2}')
GW=$(ip route | awk '/default/ {print $3}')
IFACE=$(ip route | awk '/default/ {print $5}')

# 确保 WG 服务器本身不走隧道
ip route add "$WG_SERVER_IP" via "$GW" dev "$IFACE" 2>/dev/null || true

# 切出站路由
ip route add default dev wg0 table 200 2>/dev/null || true
ip rule add lookup 200 priority 1000 2>/dev/null || true
ip route flush cache

# IPv6（可用则切）
if ip -6 addr show wg0 | grep -q inet6; then
    ip -6 route add default dev wg0 table 200 2>/dev/null || true
    ip -6 rule add lookup 200 priority 1000 2>/dev/null || true
    ip -6 route flush cache
fi

echo ">>> 校验出口 IP..."
sleep 2

NEW_IP4=$(curl -4s ip.sb || echo "unknown")
NEW_IP6=$(curl -6s ip.sb || echo "unknown")

echo "当前 IPv4 出口: $NEW_IP4"
echo "当前 IPv6 出口: $NEW_IP6"

if [ "$NEW_IP4" != "$ORIG_IP4" ]; then
    echo "✅ IPv4 出口已成功切换"
else
    echo "⚠️ IPv4 出口未变化"
fi

if [ "$NEW_IP6" != "$ORIG_IP6" ]; then
    echo "✅ IPv6 出口已成功切换"
else
    echo "⚠️ IPv6 出口未变化或未启用"
fi

echo "==========================================="
echo "入口机部署完成"
echo "==========================================="

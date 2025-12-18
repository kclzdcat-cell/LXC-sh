#!/bin/bash
set -e

echo "==========================================="
echo "   WireGuard 入口部署（最终封板版）"
echo "   入站保持本地 · 出站走 VPN"
echo "==========================================="

# -----------------------------
# 基础校验
# -----------------------------
if [ "$(id -u)" != "0" ]; then
    echo "错误：请使用 root 用户运行"
    exit 1
fi

CLIENT_CONF="/root/wg_client.conf"
if [ ! -f "$CLIENT_CONF" ]; then
    echo "错误：未找到 $CLIENT_CONF"
    exit 1
fi

# -----------------------------
# 识别系统
# -----------------------------
. /etc/os-release
echo "系统识别：$PRETTY_NAME"

# -----------------------------
# 修复 apt / dpkg
# -----------------------------
echo ">>> 检查并修复 apt / dpkg 状态..."

WAIT=0
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    WAIT=$((WAIT+1))
    if [ "$WAIT" -gt 60 ]; then
        echo "错误：apt 锁超过 60 秒仍未释放"
        exit 1
    fi
    echo "apt 被占用，等待中... (${WAIT}s)"
    sleep 1
done

dpkg --configure -a >/dev/null 2>&1 || true

echo ">>> 更新软件源..."
apt-get update

# -----------------------------
# 安装 WireGuard（如缺失）
# -----------------------------
echo ">>> 检查 WireGuard 是否已安装..."

NEED_INSTALL=0

command -v wg >/dev/null 2>&1 || NEED_INSTALL=1
systemctl list-unit-files | grep -q "wg-quick@" || NEED_INSTALL=1

if [ "$NEED_INSTALL" -eq 1 ]; then
    echo ">>> WireGuard 未完整安装，开始安装..."
    apt-get install -y wireguard wireguard-tools curl || {
        echo "❌ WireGuard 安装失败"
        exit 1
    }
else
    echo "WireGuard 已安装，跳过安装"
fi

# 强校验
command -v wg >/dev/null 2>&1 || { echo "错误：wg 命令不存在"; exit 1; }
systemctl list-unit-files | grep -q "wg-quick@" || { echo "错误：wg-quick 服务不存在"; exit 1; }

# -----------------------------
# 记录原出口 IP
# -----------------------------
ORIG_IP4=$(curl -4s ip.sb || echo "unknown")
ORIG_IP6=$(curl -6s ip.sb || echo "unknown")

echo "原 IPv4 出口: $ORIG_IP4"
echo "原 IPv6 出口: $ORIG_IP6"

# -----------------------------
# 生成 wg0.conf（禁止自动路由）
# -----------------------------
echo ">>> 生成 WireGuard 配置..."

mkdir -p /etc/wireguard
sed '/^Table/d' "$CLIENT_CONF" > /etc/wireguard/wg0.conf
sed -i '/^\[Interface\]/a Table = off' /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

# -----------------------------
# 启动 WireGuard
# -----------------------------
echo ">>> 启动 WireGuard..."
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

sleep 3
wg show >/dev/null || {
    echo "❌ WireGuard 未成功启动"
    exit 1
}

# -----------------------------
# 保护当前 SSH 会话
# -----------------------------
SSH_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
if [ -n "$SSH_IP" ]; then
    ip rule add to "$SSH_IP" lookup main priority 100 2>/dev/null || true
    echo "已保护当前 SSH 客户端：$SSH_IP"
fi

# -----------------------------
# 策略路由（仅影响出站）
# -----------------------------
WG_SERVER_IP=$(grep Endpoint "$CLIENT_CONF" | awk -F'[ :]' '{print $2}')
GW=$(ip route | awk '/default/ {print $3}')
IFACE=$(ip route | awk '/default/ {print $5}')

# 确保 WG 服务器本身不走隧道
ip route add "$WG_SERVER_IP" via "$GW" dev "$IFACE" 2>/dev/null || true

# IPv4 出站走 WG
ip route add default dev wg0 table 200 2>/dev/null || true
ip rule add lookup 200 priority 1000 2>/dev/null || true
ip route flush cache

# IPv6（如果 wg0 有 IPv6）
if ip -6 addr show dev wg0 | grep -q inet6; then
    ip -6 route add default dev wg0 table 200 2>/dev/null || true
    ip -6 rule add lookup 200 priority 1000 2>/dev/null || true
    ip -6 route flush cache
fi

# -----------------------------
# 出口 IP 校验
# -----------------------------
echo ">>> 校验出口 IP..."
sleep 2

NEW_IP4=$(curl -4s ip.sb || echo "unknown")
NEW_IP6=$(curl -6s ip.sb || echo "unknown")

echo "当前 IPv4 出口: $NEW_IP4"
echo "当前 IPv6 出口: $NEW_IP6"

[ "$NEW_IP4" != "$ORIG_IP4" ] && echo "✅ IPv4 出口切换成功" || echo "⚠️ IPv4 出口未变化"
[ "$NEW_IP6" != "$ORIG_IP6" ] && echo "✅ IPv6 出口切换成功" || echo "⚠️ IPv6 未切换或不可用"

echo "==========================================="
echo "入口机部署完成"
echo "==========================================="

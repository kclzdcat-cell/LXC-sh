#!/bin/bash
set -e

echo "==========================================="
echo " WireGuard 入口机部署（工程兜底完整版）"
echo " 系统要求：Debian 12"
echo " 功能：SSH 保留 | 出站走 WG"
echo "==========================================="

# 必须 root
if [ "$(id -u)" != "0" ]; then
  echo "❌ 请使用 root 执行"
  exit 1
fi

# -------------------------------
# 0. 基础环境修复
# -------------------------------
echo ">>> 修复 apt / dpkg 状态"
export DEBIAN_FRONTEND=noninteractive
rm -f /var/lib/dpkg/lock*
rm -f /var/lib/apt/lists/lock
rm -f /var/cache/apt/archives/lock
dpkg --configure -a || true

echo ">>> 更新软件源"
apt update

# -------------------------------
# 1. WireGuard 检测 & 重新安装
# -------------------------------
echo ">>> 检测 WireGuard 是否已安装"

if command -v wg >/dev/null 2>&1; then
  echo "⚠️ 已检测到 WireGuard，执行清理重装"

  systemctl stop wg-quick@wg0 2>/dev/null || true
  systemctl disable wg-quick@wg0 2>/dev/null || true

  rm -f /etc/wireguard/wg0.conf
  apt remove -y wireguard wireguard-tools || true
fi

echo ">>> 安装 WireGuard 及依赖"
apt install -y wireguard wireguard-tools iptables curl

# -------------------------------
# 2. 检查客户端配置
# -------------------------------
if [ ! -f /root/wg_client.conf ]; then
  echo "❌ 未找到 /root/wg_client.conf"
  echo "请先从出口机上传客户端配置"
  exit 1
fi

# -------------------------------
# 3. 应用 WireGuard 配置
# -------------------------------
echo ">>> 写入 wg0.conf"
mkdir -p /etc/wireguard
cp /root/wg_client.conf /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

echo ">>> 启动 WireGuard"
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

sleep 3
wg show wg0 >/dev/null || {
  echo "❌ WireGuard 启动失败"
  exit 1
}

echo "✅ WireGuard 已成功启动"

# -------------------------------
# 4. DNS 强制修复（防止再次断网）
# -------------------------------
echo ">>> 修复并锁定 DNS"
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
chattr +i /etc/resolv.conf

# -------------------------------
# 5. 策略路由（SSH 永久保护）
# -------------------------------
echo ">>> 配置策略路由（SSH 保留）"

SSH_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')

# 清空旧规则
ip rule flush
ip rule add pref 0 lookup local
ip rule add pref 32766 lookup main
ip rule add pref 32767 lookup default

# SSH 流量走本地
ip rule add to "$SSH_IP" lookup main priority 100

# 抑制 main 默认路由
ip rule add table main suppress_prefixlength 0 priority 200

# WG 出口表
ip route flush table 200
ip route add default dev wg0 table 200
ip rule add lookup 200 priority 300

ip route flush cache

# -------------------------------
# 6. 验证
# -------------------------------
echo ">>> 验证出口 IP"
NEW_IP=$(curl -4 ip.sb || echo "unknown")

echo "当前 IPv4 出口: $NEW_IP"
echo "==========================================="
echo "🎉 入口机部署完成"
echo "✔ SSH 保持可用"
echo "✔ DNS 正常"
echo "✔ 所有 IPv4 出站流量走 WireGuard"
echo "==========================================="

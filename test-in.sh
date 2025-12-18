#!/bin/bash
set -e

echo "==========================================="
echo " WireGuard 入口机部署（客户端）"
echo "==========================================="

if [ "$(id -u)" != "0" ]; then
  echo "请使用 root 执行"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# -----------------------------
# 1. 安装依赖
# -----------------------------
apt update
apt install -y wireguard wireguard-tools iproute2 iptables curl

# -----------------------------
# 2. 检查配置
# -----------------------------
if [ ! -f /root/wg_client.conf ]; then
  echo "❌ 未找到 /root/wg_client.conf"
  exit 1
fi

mkdir -p /etc/wireguard
cp /root/wg_client.conf /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

# -----------------------------
# 3. 启动 WireGuard
# -----------------------------
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

sleep 3

# -----------------------------
# 4. 验证
# -----------------------------
echo "WireGuard 状态："
wg show

echo
echo "IPv4 出口："
curl -4 ip.sb || true

echo "IPv6 出口："
curl -6 ip.sb || true

echo "==========================================="
echo "入口机完成："
echo "- 入站不变"
echo "- 所有出站已走出口机"
echo "==========================================="

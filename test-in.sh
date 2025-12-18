#!/bin/bash
set -e

echo "=== WireGuard 入口机部署（SSH 安全最终版）==="

# root 检查
if [ "$(id -u)" != "0" ]; then
  echo "必须 root 执行"
  exit 1
fi

# 必须有客户端配置
if [ ! -f /root/wg_client.conf ]; then
  echo "缺少 /root/wg_client.conf"
  exit 1
fi

# 安装依赖
apt update
apt install -y wireguard iproute2 iptables curl

# 记录当前 SSH 对端 IP（关键）
SSH_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')

if [ -z "$SSH_IP" ]; then
  echo "未检测到 SSH_CLIENT，可能不是通过 SSH 登录，终止"
  exit 1
fi

echo "SSH 对端 IP: $SSH_IP"

# 写 WG 配置
mkdir -p /etc/wireguard
cp /root/wg_client.conf /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

# 添加 SSH 保护路由（最关键的一行）
ip rule add to $SSH_IP lookup main priority 100 2>/dev/null || true

# 启动 WG
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

sleep 2

echo "=== 验证 ==="
wg show

echo "--- 出口 IPv4 ---"
curl -4 ip.sb || true

echo "--- 出口 IPv6 ---"
curl -6 ip.sb || true

echo "=== 入口机部署完成 ==="
echo "SSH 已被保护，不会断"

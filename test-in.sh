#!/usr/bin/env bash
set -e

echo "=== WireGuard 入口机（SSH 永不掉线版）==="

# 1. 修复 dpkg / 更新
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a || true
apt-get update -y
apt-get install -y wireguard iproute2 iptables curl

# 2. 停旧 wg
wg-quick down wg0 2>/dev/null || true
ip link del wg0 2>/dev/null || true

# 3. 交互输入
read -rp "出口机公网 IP（IPv4 或 IPv6）: " SERVER_IP
read -rp "WireGuard 端口 [51820]: " WG_PORT
WG_PORT=${WG_PORT:-51820}
read -rp "Server 公钥: " SERVER_PUB
read -rp "Client 私钥: " CLIENT_PRIV

# 4. 获取当前 SSH IP（保命）
SSH_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')

# 5. 写配置
mkdir -p /etc/wireguard
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.0.2/24, fd10::2/64
PrivateKey = ${CLIENT_PRIV}
DNS = 8.8.8.8,1.1.1.1

# SSH 保命规则：SSH 走原路由
PostUp = ip rule add to ${SSH_IP} lookup main priority 50
PostDown = ip rule del to ${SSH_IP} lookup main priority 50

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${SERVER_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/wg0.conf

# 6. 启动
wg-quick up wg0

echo
echo "=== WireGuard 已启动 ==="
wg show
echo
echo "出口 IP 校验："
curl -4 ip.sb || true
curl -6 ip.sb || true

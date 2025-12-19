#!/usr/bin/env bash
set -e

echo "=== WireGuard 入口机（SSH 永不掉线版）==="

[ "$(id -u)" != "0" ] && echo "请使用 root 执行" && exit 1

# 基础依赖
apt update
apt install -y wireguard iproute2 curl

# 询问出口信息
read -rp "出口机公网 IP: " SERVER_IP
read -rp "WireGuard 端口 [51820]: " SERVER_PORT
SERVER_PORT=${SERVER_PORT:-51820}
read -rp "Server 公钥: " SERVER_PUB

# 清理旧接口
wg-quick down wg0 2>/dev/null || true
ip link del wg0 2>/dev/null || true

# 生成客户端密钥
CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)

# 写配置（不写 DNS！！）
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.0.2/24, fd10::2/64
PrivateKey = $CLIENT_PRIV

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_IP:$SERVER_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/wg0.conf

# 启动
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

sleep 2

echo
echo "========== 客户端公钥（填到出口机） =========="
echo "$CLIENT_PUB"
echo "=============================================="
echo

# 验证
echo "WireGuard 状态："
wg show || true

echo
echo "出口 IP 验证："
curl -4 ip.sb || true

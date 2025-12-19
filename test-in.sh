#!/usr/bin/env bash
set -e

echo "=== WireGuard 入口机（SSH 永不掉版） ==="

# 1. 修复 dpkg / apt
dpkg --configure -a || true
apt update
apt install -y wireguard iproute2 curl

# 2. 读取用户输入
read -rp "出口机公网 IP: " SERVER_IP
read -rp "WireGuard 端口: " SERVER_PORT
read -rp "Server 公钥: " SERVER_PUB
read -rp "Client 私钥: " CLIENT_PRIV

# 3. 清理旧配置
wg-quick down wg0 2>/dev/null || true
rm -f /etc/wireguard/wg0.conf

# 4. 写客户端配置（这是关键）
cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.0.2/24, fd10::2/64
PrivateKey = $CLIENT_PRIV
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = ${SERVER_IP}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/wg0.conf

# 5. 启动
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

# 6. 验证
echo
echo "WireGuard 状态："
wg show

echo
echo "出口 IP 验证："
curl -4 ip.sb || true
curl -6 ip.sb || true

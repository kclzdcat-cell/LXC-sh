#!/usr/bin/env bash
set -e

echo "=== WireGuard 出口机（最终稳定版） ==="

# 1. 基础环境
apt update
apt install -y wireguard iptables iproute2 curl

# 2. 开启转发
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# 3. 清理旧 wg0
wg-quick down wg0 2>/dev/null || true
rm -f /etc/wireguard/wg0.conf

# 4. 生成密钥
SERVER_PRIV=$(wg genkey)
SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)

CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)

# 5. 写 server 配置
cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24, fd10::1/64
ListenPort = 51820
PrivateKey = $SERVER_PRIV

PostUp   = iptables -t nat -A POSTROUTING -o \$(ip route | awk '/default/ {print \$5; exit}') -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o \$(ip route | awk '/default/ {print \$5; exit}') -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.0.0.2/32, fd10::2/128
EOF

chmod 600 /etc/wireguard/wg0.conf

# 6. 启动
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

# 7. 显示给入口机用的信息
PUB_IP=$(curl -4 -s ip.sb || echo "unknown")

echo
echo "=========== 给入口机填写的信息 ==========="
echo "出口机公网 IP : $PUB_IP"
echo "WireGuard 端口 : 51820"
echo "Server 公钥   : $SERVER_PUB"
echo "Client 私钥   : $CLIENT_PRIV"
echo "==========================================="

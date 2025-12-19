#!/usr/bin/env bash
set -e

WG_IF="wg0"
WG_PORT=51820
WG_NET4="10.66.66.0/24"
WG_IP4="10.66.66.1/24"

echo "== WireGuard 出口机部署 =="

apt update -y
apt install -y wireguard iptables iproute2 curl

# 开启转发
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# 清理旧接口
wg-quick down ${WG_IF} 2>/dev/null || true
ip link del ${WG_IF} 2>/dev/null || true

# 生成密钥
SERVER_PRIV=$(wg genkey)
SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)

CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)

# 写配置
cat > /etc/wireguard/${WG_IF}.conf <<EOF
[Interface]
Address = ${WG_IP4}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}

PostUp = iptables -t nat -A POSTROUTING -o \$(ip route | awk '/default/ {print \$5}') -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o \$(ip route | awk '/default/ {print \$5}') -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = 10.66.66.2/32
EOF

# 启动
wg-quick up ${WG_IF}
systemctl enable wg-quick@${WG_IF}

echo
echo "===== 入口机需要用的信息 ====="
echo "出口机 IP      : $(curl -4 -s ip.sb)"
echo "WireGuard 端口 : ${WG_PORT}"
echo "Server 公钥    : ${SERVER_PUB}"
echo "Client 私钥    : ${CLIENT_PRIV}"
echo "================================"

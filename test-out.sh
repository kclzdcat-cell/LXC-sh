#!/usr/bin/env bash
set -e

echo "=== WireGuard 出口机（稳定手动对接版）==="

# 1. 修复 dpkg / 更新系统
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a || true
apt-get update -y
apt-get install -y wireguard iptables iproute2 curl

# 2. 开启转发
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# 3. 清理旧 wg0
wg-quick down wg0 2>/dev/null || true
ip link del wg0 2>/dev/null || true

# 4. 生成密钥
WG_DIR=/etc/wireguard
mkdir -p $WG_DIR
chmod 700 $WG_DIR
cd $WG_DIR

wg genkey | tee server.key | wg pubkey > server.pub
wg genkey | tee client.key | wg pubkey > client.pub

SERVER_PRIV=$(cat server.key)
SERVER_PUB=$(cat server.pub)
CLIENT_PUB=$(cat client.pub)
CLIENT_PRIV=$(cat client.key)

# 5. 获取出口机公网 IP
PUB4=$(curl -4 -s ip.sb || true)
PUB6=$(curl -6 -s ip.sb || true)

# 6. 写 wg0.conf
cat > wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24, fd10::1/64
ListenPort = 51820
PrivateKey = ${SERVER_PRIV}

PostUp = iptables -t nat -A POSTROUTING -o \$(ip route | awk '/default/ {print \$5; exit}') -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o \$(ip route | awk '/default/ {print \$5; exit}') -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = 10.0.0.2/32, fd10::2/128
EOF

chmod 600 wg0.conf

# 7. 启动
wg-quick up wg0

echo
echo "================ 给入口机填写的信息 ================"
echo "出口机 IPv4 : ${PUB4}"
echo "出口机 IPv6 : ${PUB6}"
echo "WireGuard 端口 : 51820"
echo "Server 公钥   : ${SERVER_PUB}"
echo "Client 私钥   : ${CLIENT_PRIV}"
echo "===================================================="
echo
wg show

#!/usr/bin/env bash
set -e

echo "=== WireGuard 出口机（稳定手动对接版）==="

apt update
apt install -y wireguard iptables iproute2 curl

# 开转发
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# 变量
WG_PORT=51820
WG_IF=wg0
WG_IPV4=10.0.0.1/24
WG_IPV6=fd10::1/64
EXT_IF=$(ip route | awk '/default/ {print $5}')

# 生成密钥
umask 077
wg genkey | tee /root/server.key | wg pubkey > /root/server.pub
wg genkey | tee /root/client.key | wg pubkey > /root/client.pub

# 写 wg0.conf
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = $WG_IPV4,$WG_IPV6
ListenPort = $WG_PORT
PrivateKey = $(cat /root/server.key)

PostUp   = iptables -t nat -A POSTROUTING -o $EXT_IF -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $EXT_IF -j MASQUERADE

[Peer]
PublicKey = $(cat /root/client.pub)
AllowedIPs = 10.0.0.2/32,fd10::2/128
EOF

wg-quick up wg0
systemctl enable wg-quick@wg0

PUB_IP=$(curl -4 -s ip.sb)

echo
echo "================= 给入口机用的信息 ================="
echo "出口机公网 IP     : $PUB_IP"
echo "WireGuard 端口     : $WG_PORT"
echo "Server 公钥        : $(cat /root/server.pub)"
echo "Client 私钥        : $(cat /root/client.key)"
echo "===================================================="
echo
echo "当前 WireGuard 状态："
wg

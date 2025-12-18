#!/bin/bash

set -e

echo "==========================================="
echo "   WireGuard 出口部署（校验增强版）"
echo "==========================================="

apt-get update
apt-get install -y wireguard wireguard-tools iptables ip6tables curl sshpass

PUBLIC_IP4=$(curl -4s ip.sb || curl -4s ifconfig.me)
DEFAULT_IFACE=$(ip -4 route | awk '/default/ {print $5}' | head -n1)

mkdir -p /etc/wireguard
cd /etc/wireguard || exit 1
umask 077

wg genkey | tee server_private.key | wg pubkey > server_public.key
wg genkey | tee client_private.key | wg pubkey > client_public.key

SERVER_PRIVATE_KEY=$(cat server_private.key)
SERVER_PUBLIC_KEY=$(cat server_public.key)
CLIENT_PRIVATE_KEY=$(cat client_private.key)
CLIENT_PUBLIC_KEY=$(cat client_public.key)

cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24, fd00::1/64
ListenPort = 51820
PrivateKey = $SERVER_PRIVATE_KEY

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = 10.0.0.2/32, fd00::2/128
EOF

CLIENT_CONF="/root/wg_client.conf"
cat > "$CLIENT_CONF" <<EOF
[Interface]
Address = 10.0.0.2/24, fd00::2/64
PrivateKey = $CLIENT_PRIVATE_KEY
DNS = 8.8.8.8,1.1.1.1,2001:4860:4860::8888

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $PUBLIC_IP4:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

iptables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE
iptables -A FORWARD -i wg0 -j ACCEPT
ip6tables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null || true
ip6tables -A FORWARD -i wg0 -j ACCEPT 2>/dev/null || true

systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo "==========================================="
echo "出口机 WireGuard 已启动"
echo "客户端配置文件：$CLIENT_CONF"
echo "==========================================="

read -p "是否上传客户端配置到入口机？(y/n): " UP

if [[ "$UP" =~ ^[Yy]$ ]]; then
    read -p "入口 IP: " IN_IP
    read -p "入口 SSH 端口(默认22): " IN_PORT
    IN_PORT=${IN_PORT:-22}
    read -p "入口 SSH 用户(默认root): " IN_USER
    IN_USER=${IN_USER:-root}
    read -s -p "入口 SSH 密码: " IN_PASS
    echo

    ssh-keygen -R "$IN_IP" >/dev/null 2>&1 || true
    ssh-keygen -R "[$IN_IP]:$IN_PORT" >/dev/null 2>&1 || true

    echo ">>> 正在上传配置文件..."
    sshpass -p "$IN_PASS" scp -P "$IN_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$CLIENT_CONF" "$IN_USER@$IN_IP:/root/wg_client.conf"

    echo ">>> 校验入口机文件是否存在..."
    sshpass -p "$IN_PASS" ssh -p "$IN_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$IN_USER@$IN_IP" \
        "test -f /root/wg_client.conf"

    if [ $? -eq 0 ]; then
        echo "✅ 配置文件已成功上传并确认存在"
    else
        echo "❌ 上传失败：入口机未检测到配置文件"
    fi
fi

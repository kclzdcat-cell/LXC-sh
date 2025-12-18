#!/bin/bash

echo "==========================================="
echo "   WireGuard 出口部署 (稳定完整版)"
echo "   功能：作为 VPN 出口服务器"
echo "==========================================="

# 安装依赖
echo ">>> 安装WireGuard..."
apt-get update
apt-get install -y wireguard iptables ip6tables curl sshpass

# 获取公网 IPv4
PUBLIC_IP4=$(curl -4s ip.sb || curl -4s ifconfig.me || curl -4s icanhazip.com)
echo "公网 IPv4: $PUBLIC_IP4"

# 获取默认网卡
DEFAULT_IFACE=$(ip -4 route | awk '/default/ {print $5}' | head -n1)
echo "默认网卡: $DEFAULT_IFACE"

# 生成密钥
umask 077
mkdir -p /etc/wireguard
cd /etc/wireguard || exit 1

wg genkey | tee server_private.key | wg pubkey > server_public.key
wg genkey | tee client_private.key | wg pubkey > client_public.key

SERVER_PRIVATE_KEY=$(cat server_private.key)
SERVER_PUBLIC_KEY=$(cat server_public.key)
CLIENT_PRIVATE_KEY=$(cat client_private.key)
CLIENT_PUBLIC_KEY=$(cat client_public.key)

# 服务器配置
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24, fd00::1/64
ListenPort = 51820
PrivateKey = $SERVER_PRIVATE_KEY

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = 10.0.0.2/32, fd00::2/128
EOF

# 客户端配置
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

# 开启转发
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# NAT
iptables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE
iptables -A FORWARD -i wg0 -j ACCEPT

ip6tables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null || true
ip6tables -A FORWARD -i wg0 -j ACCEPT 2>/dev/null || true

# 启动 WG
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo "==========================================="
echo "WireGuard 出口机已启动"
echo "客户端配置：$CLIENT_CONF"
echo "==========================================="

# ===== 上传客户端配置 =====
echo "是否要将客户端配置上传到入口服务器？(y/n)"
read -r UPLOAD_CHOICE

if [[ "$UPLOAD_CHOICE" =~ ^[Yy]$ ]]; then
    read -p "入口 IP: " IN_IP
    read -p "入口 SSH 端口(默认22): " IN_PORT
    IN_PORT=${IN_PORT:-22}
    read -p "入口 SSH 用户(默认root): " IN_USER
    IN_USER=${IN_USER:-root}
    read -s -p "入口 SSH 密码: " IN_PASS
    echo

    mkdir -p /root/.ssh
    ssh-keygen -R "$IN_IP" >/dev/null 2>&1 || true
    ssh-keygen -R "[$IN_IP]:$IN_PORT" >/dev/null 2>&1 || true

    sshpass -p "$IN_PASS" scp \
        -P "$IN_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$CLIENT_CONF" \
        "$IN_USER@$IN_IP:/root/"

    echo "配置文件已上传到入口机"
fi

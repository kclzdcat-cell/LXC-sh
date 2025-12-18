#!/bin/bash
set -e

echo "==========================================="
echo " WireGuard 出口机部署（Debian 12 稳定版）"
echo "==========================================="

# 必须 root
if [ "$(id -u)" != "0" ]; then
  echo "请使用 root 执行"
  exit 1
fi

echo ">>> 安装依赖"
apt update
apt install -y wireguard iptables curl sshpass

echo ">>> 启用 IPv4 转发"
sysctl -w net.ipv4.ip_forward=1
echo net.ipv4.ip_forward=1 > /etc/sysctl.d/99-wg.conf

EXT_IF=$(ip route | awk '/default/ {print $5}')
echo "外网接口: $EXT_IF"

echo ">>> 生成密钥"
mkdir -p /etc/wireguard
cd /etc/wireguard

wg genkey | tee server.key | wg pubkey > server.pub
wg genkey | tee client.key | wg pubkey > client.pub

SERVER_PRIV=$(cat server.key)
SERVER_PUB=$(cat server.pub)
CLIENT_PRIV=$(cat client.key)
CLIENT_PUB=$(cat client.pub)

PUBLIC_IP=$(curl -4 ip.sb)

echo ">>> 写入 wg0.conf"
cat > wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIV

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.0.0.2/32
EOF

echo ">>> 防火墙/NAT（关键）"
iptables -F
iptables -t nat -F
iptables -P FORWARD ACCEPT

iptables -A FORWARD -i wg0 -o "$EXT_IF" -j ACCEPT
iptables -A FORWARD -i "$EXT_IF" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o "$EXT_IF" -j MASQUERADE

echo ">>> 启动 WireGuard"
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo ">>> 生成客户端配置"
cat > /root/wg_client.conf <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.0.0.2/24
DNS = 8.8.8.8,1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $PUBLIC_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

echo "==========================================="
echo "WireGuard 出口机完成"
echo "客户端配置: /root/wg_client.conf"
echo "==========================================="

read -p "是否上传客户端配置到入口机？(y/n): " UP

if [[ "$UP" =~ ^[Yy]$ ]]; then
  read -p "入口机 IP: " IN_IP
  read -p "入口机 SSH 端口(默认22): " IN_PORT
  IN_PORT=${IN_PORT:-22}
  read -p "入口机用户(默认root): " IN_USER
  IN_USER=${IN_USER:-root}
  read -s -p "入口机密码: " IN_PASS
  echo

  sshpass -p "$IN_PASS" scp \
    -P "$IN_PORT" \
    -o StrictHostKeyChecking=no \
    /root/wg_client.conf \
    "$IN_USER@$IN_IP:/root/"

  echo "✅ 客户端配置已上传"
fi

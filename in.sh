#!/bin/bash
set -e

echo "=== 安装 WireGuard ==="
apt update -y
apt install wireguard -y

WG_DEV="wg0"
WG_SG_NET="10.10.0.2/24"

# =====👉 这里必须修改 👈=====
NO_IP="填出口服务器的公网IP"
NO_PUB="填出口服务器公钥"
# ============================

echo "=== 生成入口密钥 ==="
SG_PRIV=$(wg genkey)
SG_PUB=$(echo "$SG_PRIV" | wg pubkey)

echo "入口公钥（请复制到出口服务器加入 Peer）："
echo "$SG_PUB"
echo ""

cat >/etc/wireguard/$WG_DEV.conf <<EOF
[Interface]
Address = $WG_SG_NET
PrivateKey = $SG_PRIV

[Peer]
PublicKey = $NO_PUB
Endpoint = $NO_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/$WG_DEV.conf

echo "=== 启动 WireGuard ==="
wg-quick up wg0
systemctl enable wg-quick@wg0

echo "=== 设置默认路由走挪威 ==="
# 确保本地能访问出口服务器
NO_GW="10.10.0.1"
ip route add default via $NO_GW dev wg0 || true

echo "=== 完成！所有流量现在应走出口服务器出口 ==="
echo "测试：curl ipinfo.io"

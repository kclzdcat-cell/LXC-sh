#!/bin/bash
set -e

echo "=== 安装 WireGuard ==="
apt update -y
apt install wireguard -y

WG_PORT=51820
WG_NET="10.10.0.1/24"
WG_DEV="wg0"

echo "=== 生成密钥 ==="
NO_PRIV=$(wg genkey)
NO_PUB=$(echo "$NO_PRIV" | wg pubkey)

echo "出口服务器公钥（请复制到新加坡脚本里）:"
echo "$NO_PUB"
echo ""

cat >/etc/wireguard/$WG_DEV.conf <<EOF
[Interface]
Address = $WG_NET
ListenPort = $WG_PORT
PrivateKey = $NO_PRIV

PostUp   = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

SaveConfig = true
EOF

chmod 600 /etc/wireguard/$WG_DEV.conf

echo "=== 启动 WireGuard ==="
wg-quick up wg0
systemctl enable wg-quick@wg0

echo "=== 完成！请记录出口公钥（上面输出的）==="
echo "等会把入口的公钥加入 peer。"

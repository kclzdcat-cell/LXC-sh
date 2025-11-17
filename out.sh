#!/bin/bash
set -e

echo "============================================"
echo "     WireGuard 出口服务器 自动部署脚本"
echo "      用于所有来自入口服务器的出口 NAT"
echo "============================================"
echo ""

WG_DEV="wg0"
WG_PORT=51820
WG_NET="10.10.0.1/24"
OUT_IF="eth0"

echo "=== 1. 安装 WireGuard ==="
apt update -y
apt install wireguard -y

echo ""
echo "=== 2. 生成出口服务器密钥 ==="
OUT_PRIV=$(wg genkey)
OUT_PUB=$(echo "$OUT_PRIV" | wg pubkey)

echo "出口服务器公钥（请在入口服务器脚本输入此公钥）:"
echo ""
echo "   $OUT_PUB"
echo ""

echo "=== 3. 写入 WireGuard 配置 ==="

cat >/etc/wireguard/$WG_DEV.conf <<EOF
[Interface]
Address = $WG_NET
ListenPort = $WG_PORT
PrivateKey = $OUT_PRIV

# NAT 出口
PostUp   = iptables -t nat -A POSTROUTING -o $OUT_IF -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $OUT_IF -j MASQUERADE

SaveConfig = true
EOF

chmod 600 /etc/wireguard/$WG_DEV.conf

echo "=== 4. 启动 WireGuard ==="
wg-quick up wg0
systemctl enable wg-quick@wg0

echo ""
echo "============================================"
echo "          🎉 出口服务器已部署成功！"
echo "============================================"
echo "请将以下信息填入入口服务器脚本 (sg-entrance.sh)："
echo ""
echo "👉 出口服务器公网 IP: $(curl -s ifconfig.me)"
echo "👉 出口服务器 WireGuard 公钥: $OUT_PUB"
echo ""
echo "等待入口服务器连接后，记得执行："
echo ""
echo "  wg set wg0 peer <入口服务器公钥> allowed-ips 10.10.0.2/32"
echo ""

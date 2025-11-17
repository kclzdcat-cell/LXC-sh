#!/bin/bash
set -e

echo "============================================"
echo " WireGuard 出口服务器 自动部署脚本"
echo "   网卡自动检测（无需写死 eth0 / ens18）"
echo "============================================"
echo ""

WG_DEV="wg0"
WG_PORT=51820
WG_NET="10.10.0.1/24"

# ===============================
# 自动检测默认出口网卡
# ===============================
OUT_IF=$(ip route get 8.8.8.8 | awk '{print $5}')
echo "检测到出口网卡：$OUT_IF"

if [[ -z "$OUT_IF" ]]; then
    echo "❌ 无法自动检测网卡，请检查网络状态！"
    exit 1
fi

echo "=== 1. 安装 WireGuard ==="
apt update -y
apt install wireguard -y

echo ""
echo "=== 2. 生成出口服务器密钥 ==="
OUT_PRIV=$(wg genkey)
OUT_PUB=$(echo "$OUT_PRIV" | wg pubkey)

echo "出口服务器公钥："
echo "   $OUT_PUB"
echo ""

echo "=== 3. 写入 /etc/wireguard/wg0.conf ==="

cat >/etc/wireguard/$WG_DEV.conf <<EOF
[Interface]
Address = $WG_NET
ListenPort = $WG_PORT
PrivateKey = $OUT_PRIV

PostUp   = iptables -t nat -A POSTROUTING -o $OUT_IF -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $OUT_IF -j MASQUERADE

SaveConfig = true
EOF

chmod 600 /etc/wireguard/$WG_DEV.conf

echo "=== 4. 启动 WireGuard（强制重启）==="

wg-quick down wg0 2>/dev/null || true
wg-quick up wg0

systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

echo ""
echo "============================================"
echo "   🎉 出口服务器 WireGuard 已成功启动！"
echo "============================================"
echo "出口服务器网卡：$OUT_IF"
echo "出口服务器公网 IP：$(curl -s ifconfig.me)"
echo "出口服务器 WireGuard 公钥：$OUT_PUB"
echo ""
echo "请把该公钥与 IP 填入入口服务器脚本 (sg-entrance.sh)。"
echo ""

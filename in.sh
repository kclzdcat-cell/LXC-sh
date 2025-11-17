#!/bin/bash
set -e

echo "============================================"
echo "   WireGuard 新加坡端自动安装与配置脚本"
echo "       入口：服务器 → 出口：其他服务器"
echo "============================================"
echo ""

# -------------------------------
# 用户输入出口服务器信息
# -------------------------------
read -p "请输入出口服务器公网 IP: " OUT_IP
read -p "请输入出口服务器 WireGuard 公钥: " OUT_PUB

if [[ -z "$OUT_IP" || -z "$OUT_PUB" ]]; then
    echo "❌ 错误：出口服务器 IP 和公钥不能为空！"
    exit 1
fi

WG_DEV="wg0"
WG_SG_NET="10.10.0.2/24"

echo ""
echo "✔ 出口服务器 IP: $OUT_IP"
echo "✔ 出口服务器公钥: $OUT_PUB"
echo ""

read -p "确认无误？(y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    echo "已取消。"
    exit 1
fi

echo ""
echo "=== 1. 安装 WireGuard ==="
apt update -y
apt install wireguard -y

# -------------------------------
# 生成新加坡端密钥
# -------------------------------
echo ""
echo "=== 2. 生成入口端密钥 ==="
SG_PRIV=$(wg genkey)
SG_PUB=$(echo "$SG_PRIV" | wg pubkey)

echo ""
echo "------------------------------------"
echo "请将以下新加坡公钥添加到出口服务器 Peer："
echo ""
echo "   $SG_PUB"
echo ""
echo "------------------------------------"
echo ""

# -------------------------------
# 写入 WG 配置
# -------------------------------
echo "=== 3. 写入 WireGuard 配置文件 ==="

cat >/etc/wireguard/$WG_DEV.conf <<EOF
[Interface]
Address = $WG_SG_NET
PrivateKey = $SG_PRIV

[Peer]
PublicKey = $OUT_PUB
Endpoint = $OUT_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/$WG_DEV.conf

echo "=== 4. 启动 WireGuard ==="
wg-quick up wg0
systemctl enable wg-quick@wg0

# -------------------------------
# 默认路由改为出口服务器
# -------------------------------
echo "=== 5. 设置默认路由走出口服务器 ==="
OUT_GW="10.10.0.1"
ip route add default via $OUT_GW dev wg0 || true

echo ""
echo "============================================"
echo "   🎉 配置完成！所有流量已走出口服务器"
echo "============================================"
echo "测试命令：curl ipinfo.io"
echo ""

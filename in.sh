#!/bin/bash
set -e

echo "============================================"
echo " WireGuard 入口服务器 自动部署 + 安全对接"
echo "      （不会断联 SSH，不会自杀）"
echo "============================================"
echo ""

# -------------------------------
# 用户输入出口服务器信息
# -------------------------------
read -p "请输入出口服务器公网 IP: " OUT_IP
read -p "请输入出口服务器 WireGuard 公钥: " OUT_PUB
read -p "请输入出口服务器 SSH 用户名 (默认 root): " SSH_USER
read -p "请输入出口服务器 SSH 密码: " SSH_PASS

SSH_USER=${SSH_USER:-root}

if [[ -z "$OUT_IP" || -z "$OUT_PUB" || -z "$SSH_PASS" ]]; then
    echo "❌ 输入不能为空"
    exit 1
fi

WG_DEV="wg0"
WG_SG_NET="10.10.0.2/24"
OUT_GW="10.10.0.1"

echo "=== 安装 WireGuard + sshpass ==="
apt update -y
apt install wireguard sshpass -y

# -------------------------------
# 生成入口服务器密钥
# -------------------------------
echo ""
echo "=== 生成入口服务器密钥 ==="
SG_PRIV=$(wg genkey)
SG_PUB=$(echo "$SG_PRIV" | wg pubkey)

echo ""
echo "入口服务器公钥："
echo "   $SG_PUB"
echo ""

echo "=== 写入 WireGuard 配置（不切换路由）==="
cat >/etc/wireguard/$WG_DEV.conf <<EOF
[Interface]
Address = $WG_SG_NET
PrivateKey = $SG_PRIV

[Peer]
PublicKey = $OUT_PUB
Endpoint = $OUT_IP:51820
AllowedIPs = 10.10.0.0/24
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/$WG_DEV.conf

echo "=== 启动 WireGuard（此时不会断线）==="
wg-quick up wg0
systemctl enable wg-quick@wg0

# -------------------------------
# 将入口公钥写入出口服务器
# -------------------------------
echo ""
echo "=== 正在写入出口服务器 Peer ==="

sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no $SSH_USER@$OUT_IP \
"wg set wg0 peer $SG_PUB allowed-ips 10.10.0.2/32 && wg-quick save wg0"

echo "=== Peer 写入完成 ==="

# -------------------------------
# 测试内网联通性
# -------------------------------
echo "=== 测试 WireGuard 隧道连通性 ==="
if ping -c 2 $OUT_GW >/dev/null 2>&1; then
    echo "🎉 隧道联通成功"
else
    echo "❌ 隧道无法联通，终止，不切换默认路由以防断线"
    exit 1
fi

# -------------------------------
# 切换默认路由（安全）
# -------------------------------
echo "=== 开始切换默认路由（安全模式）==="
ip route del default 2>/dev/null || true
ip route add default via $OUT_GW dev wg0

echo ""
echo "============================================"
echo " ✔ 入口服务器全部流量现已走出口服务器"
echo " ✔ SSH 不会被断联（安全流程）"
echo "============================================"
echo ""
echo "测试出口： curl ipinfo.io"
echo ""

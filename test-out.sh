#!/usr/bin/env bash
set -e

echo "=== WireGuard 出口机（最终稳定版）==="

# 必须 root
[ "$(id -u)" != "0" ] && echo "请使用 root 执行" && exit 1

# 基础依赖
apt update
apt install -y wireguard iptables iproute2 curl

# 清理旧接口
wg-quick down wg0 2>/dev/null || true
ip link del wg0 2>/dev/null || true

# 开启转发
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# 生成密钥
WG_PRIV=$(wg genkey)
WG_PUB=$(echo "$WG_PRIV" | wg pubkey)

# 写 wg0.conf
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24, fd10::1/64
ListenPort = 51820
PrivateKey = $WG_PRIV

PostUp = iptables -t nat -A POSTROUTING -o \$(ip route | awk '/default/ {print \$5; exit}') -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o \$(ip route | awk '/default/ {print \$5; exit}') -j MASQUERADE
EOF

chmod 600 /etc/wireguard/wg0.conf

# 启动
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

# 输出给入口机用的信息
PUB_IP=$(curl -4 -s ip.sb || echo "获取失败")

echo
echo "========== 给入口机填写 =========="
echo "出口机公网 IP : $PUB_IP"
echo "WireGuard 端口 : 51820"
echo "Server 公钥   : $WG_PUB"
echo "=================================="
echo
echo "出口机部署完成"

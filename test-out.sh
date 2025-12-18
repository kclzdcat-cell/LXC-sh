#!/bin/bash
set -e

echo "==========================================="
echo "   WireGuard 出口部署（最终自适应版）"
echo "   适配 Debian 11 / 12 / 13 & Ubuntu"
echo "==========================================="

# -------- 基础环境 --------
if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 执行"
    exit 1
fi

. /etc/os-release
echo "系统识别：$PRETTY_NAME"

# -------- 修复 apt / dpkg --------
echo ">>> 修复 apt / dpkg 状态..."
WAIT=0
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    WAIT=$((WAIT+1))
    [ "$WAIT" -gt 60 ] && echo "apt 锁超时" && exit 1
    sleep 1
done
dpkg --configure -a >/dev/null 2>&1 || true

apt-get update

# -------- 安装依赖 --------
echo ">>> 安装 WireGuard 及基础依赖..."
apt-get install -y wireguard wireguard-tools curl sshpass || {
    echo "依赖安装失败"
    exit 1
}

# -------- iptables / nft 处理 --------
if ! command -v iptables >/dev/null 2>&1; then
    if [[ "$ID" == "debian" && "$VERSION_ID" -ge 13 ]]; then
        echo "Debian 13+，尝试安装 iptables-nft..."
        apt-get install -y iptables-nft || true
    fi
fi

command -v iptables >/dev/null 2>&1 || {
    echo "⚠️ iptables 命令不可用，但系统可能使用 nftables"
}

# -------- 获取公网 IP --------
PUBLIC_IP4=$(curl -4s ip.sb || curl -4s ifconfig.me)
DEFAULT_IFACE=$(ip -4 route | awk '/default/ {print $5}' | head -n1)

echo "公网 IPv4: $PUBLIC_IP4"
echo "默认网卡: $DEFAULT_IFACE"

# -------- 生成 WireGuard 配置 --------
umask 077
mkdir -p /etc/wireguard
cd /etc/wireguard || exit 1

wg genkey | tee server_private.key | wg pubkey > server_public.key
wg genkey | tee client_private.key | wg pubkey > client_public.key

SERVER_PRIVATE_KEY=$(cat server_private.key)
SERVER_PUBLIC_KEY=$(cat server_public.key)
CLIENT_PRIVATE_KEY=$(cat client_private.key)
CLIENT_PUBLIC_KEY=$(cat client_public.key)

cat > wg0.conf <<EOF
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

# -------- 启用转发 & NAT --------
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

iptables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE
iptables -A FORWARD -i wg0 -j ACCEPT
ip6tables -t nat -A POSTROUTING -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null || true
ip6tables -A FORWARD -i wg0 -j ACCEPT 2>/dev/null || true

# -------- 启动 WireGuard --------
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

wg show || { echo "WireGuard 启动失败"; exit 1; }

echo "==========================================="
echo "出口机 WireGuard 已就绪"
echo "客户端配置：$CLIENT_CONF"
echo "==========================================="

# -------- 上传配置 --------
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

    sshpass -p "$IN_PASS" scp -P "$IN_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$CLIENT_CONF" "$IN_USER@$IN_IP:/root/wg_client.conf"

    sshpass -p "$IN_PASS" ssh -p "$IN_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$IN_USER@$IN_IP" "test -f /root/wg_client.conf" \
        && echo "✅ 配置文件上传成功" \
        || echo "❌ 上传失败"
fi

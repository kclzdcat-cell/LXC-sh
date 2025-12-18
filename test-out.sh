#!/bin/bash
set -e

echo "==========================================="
echo " WireGuard 出口机部署（IPv4 + IPv6 终极版）"
echo " Debian 12"
echo "==========================================="

# -------- 基础校验 --------
if [ "$(id -u)" != "0" ]; then
  echo "❌ 请使用 root 执行"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# -------- 安装依赖 --------
apt update
apt install -y wireguard wireguard-tools iptables ip6tables curl openssh-client

# -------- 开启转发 --------
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

cat > /etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF

# -------- 获取外网接口 --------
EXT_IF=$(ip route | awk '/default/ {print $5}')

# -------- 生成密钥 --------
mkdir -p /etc/wireguard
cd /etc/wireguard

wg genkey | tee server.key | wg pubkey > server.pub
wg genkey | tee client.key | wg pubkey > client.pub

# -------- 配置 wg0 --------
cat > wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24, fd10:10::1/64
ListenPort = 51820
PrivateKey = $(cat server.key)

[Peer]
PublicKey = $(cat client.pub)
AllowedIPs = 10.0.0.2/32, fd10:10::2/128
EOF

# -------- 防火墙 & NAT --------
iptables -P FORWARD ACCEPT
iptables -F
iptables -t nat -F

ip6tables -P FORWARD ACCEPT
ip6tables -F
ip6tables -t nat -F

# IPv4 NAT
iptables -A FORWARD -i wg0 -o "$EXT_IF" -j ACCEPT
iptables -A FORWARD -i "$EXT_IF" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o "$EXT_IF" -j MASQUERADE

# IPv6 NAT66（关键）
ip6tables -A FORWARD -i wg0 -o "$EXT_IF" -j ACCEPT
ip6tables -A FORWARD -i "$EXT_IF" -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
ip6tables -t nat -A POSTROUTING -s fd10:10::/64 -o "$EXT_IF" -j MASQUERADE

# -------- 启动 WireGuard --------
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

# -------- 生成客户端配置 --------
PUB4=$(curl -4 -s ip.sb)

cat > /root/wg_client.conf <<EOF
[Interface]
Address = 10.0.0.2/24, fd10:10::2/64
PrivateKey = $(cat client.key)
DNS = 8.8.8.8, 2001:4860:4860::8888

[Peer]
PublicKey = $(cat server.pub)
Endpoint = ${PUB4}:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

echo "==========================================="
echo "出口机完成"
echo "客户端配置：/root/wg_client.conf"
echo "==========================================="

# -------- 上传到入口机 --------
read -p "是否上传客户端配置到入口机？(y/n): " UP

if [[ "$UP" =~ ^[Yy]$ ]]; then
  read -p "入口机 IP: " IN_IP
  read -p "入口机用户 (默认 root): " IN_USER
  IN_USER=${IN_USER:-root}

  ssh-keygen -f /root/.ssh/known_hosts -R "$IN_IP" 2>/dev/null || true
  scp -o StrictHostKeyChecking=no /root/wg_client.conf ${IN_USER}@${IN_IP}:/root/

  echo "✅ 已上传到入口机"
fi

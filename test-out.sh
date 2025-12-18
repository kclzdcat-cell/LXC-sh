#!/bin/bash
set -e

echo "==========================================="
echo " WireGuard 出口机部署（最终稳定版）"
echo "==========================================="

# root
if [ "$(id -u)" != "0" ]; then
  echo "请使用 root 执行"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# -----------------------------
# 1. 安装依赖（Debian 12 正确）
# -----------------------------
apt update
apt install -y wireguard wireguard-tools iptables iproute2 curl sshpass openssh-client

# -----------------------------
# 2. 基础变量
# -----------------------------
EXT_IF=$(ip route | awk '/default/ {print $5}')
WG_PORT=51820
WG_DIR=/etc/wireguard
CLIENT_CONF=/root/wg_client.conf

mkdir -p $WG_DIR
cd $WG_DIR

# -----------------------------
# 3. 生成密钥（如不存在）
# -----------------------------
[ -f server.key ] || wg genkey | tee server.key | wg pubkey > server.pub
[ -f client.key ] || wg genkey | tee client.key | wg pubkey > client.pub

SERVER_PRIV=$(cat server.key)
SERVER_PUB=$(cat server.pub)
CLIENT_PRIV=$(cat client.key)
CLIENT_PUB=$(cat client.pub)

PUB_IP=$(curl -4 -s ip.sb)

# -----------------------------
# 4. 写服务端配置
# -----------------------------
cat > wg0.conf <<EOF
[Interface]
Address = 10.66.66.1/24, fd66::1/64
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}

PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = sysctl -w net.ipv6.conf.all.forwarding=1
PostUp = iptables -t nat -A POSTROUTING -o ${EXT_IF} -j MASQUERADE
PostUp = ip6tables -t nat -A POSTROUTING -o ${EXT_IF} -j MASQUERADE

PostDown = iptables -t nat -D POSTROUTING -o ${EXT_IF} -j MASQUERADE
PostDown = ip6tables -t nat -D POSTROUTING -o ${EXT_IF} -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = 10.66.66.2/32, fd66::2/128
EOF

# -----------------------------
# 5. 客户端配置
# -----------------------------
cat > ${CLIENT_CONF} <<EOF
[Interface]
Address = 10.66.66.2/24, fd66::2/64
PrivateKey = ${CLIENT_PRIV}
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${PUB_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

echo
echo "⚠️ 即将启动 WireGuard，SSH 可能短暂断开（正常）"
sleep 5

systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0 || true

echo "==========================================="
echo "出口机部署完成"
echo "客户端配置：${CLIENT_CONF}"
echo "==========================================="

# -----------------------------
# 6. 上传到入口机
# -----------------------------
read -p "是否上传客户端配置到入口机？(y/n): " UP

if [[ "$UP" =~ ^[Yy]$ ]]; then
  read -p "入口机 IP: " IN_IP
  read -p "入口机 SSH 用户(默认 root): " IN_USER
  IN_USER=${IN_USER:-root}
  read -s -p "入口机 SSH 密码: " IN_PASS
  echo

  ssh-keygen -f /root/.ssh/known_hosts -R "$IN_IP" 2>/dev/null || true

  sshpass -p "$IN_PASS" scp \
    -o StrictHostKeyChecking=no \
    ${CLIENT_CONF} ${IN_USER}@${IN_IP}:/root/

  echo "✅ 已上传到入口机 /root/wg_client.conf"
fi

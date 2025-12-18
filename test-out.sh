#!/bin/bash
set -e

echo "=== WireGuard 出口机部署（最终稳定版）==="

# 必须 root
if [ "$(id -u)" != "0" ]; then
  echo "必须使用 root 执行"
  exit 1
fi

# 系统检测
. /etc/os-release
echo "系统: $PRETTY_NAME"

# 更新 & 安装
apt update
apt install -y wireguard iptables iproute2 curl sshpass

# 外网网卡
EXT_IF=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
echo "外网接口: $EXT_IF"

# 开启转发（永久）
cat >/etc/sysctl.d/99-wg-forward.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl --system >/dev/null

# 生成密钥
mkdir -p /etc/wireguard
cd /etc/wireguard
umask 077

wg genkey | tee server.key | wg pubkey > server.pub
wg genkey | tee client.key | wg pubkey > client.pub

SERVER_PRIV=$(cat server.key)
SERVER_PUB=$(cat server.pub)
CLIENT_PRIV=$(cat client.key)
CLIENT_PUB=$(cat client.pub)

# 写服务端配置
cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24, fd10::1/64
ListenPort = 51820
PrivateKey = $SERVER_PRIV

PostUp   = iptables -t nat -A POSTROUTING -o $EXT_IF -j MASQUERADE
PostUp   = ip6tables -t nat -A POSTROUTING -o $EXT_IF -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $EXT_IF -j MASQUERADE
PostDown = ip6tables -t nat -D POSTROUTING -o $EXT_IF -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.0.0.2/32, fd10::2/128
EOF

# 启动 WG
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

# 生成客户端配置（入口机用）
PUB_IP=$(curl -4 -s ip.sb)

cat >/root/wg_client.conf <<EOF
[Interface]
Address = 10.0.0.2/24, fd10::2/64
PrivateKey = $CLIENT_PRIV
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $PUB_IP:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

echo "客户端配置生成: /root/wg_client.conf"

# 是否上传到入口机
read -p "是否通过 SSH 上传客户端配置到入口机？(y/n): " UP

if [[ "$UP" =~ ^[Yy]$ ]]; then
  read -p "入口机 IP: " IN_IP
  read -p "SSH 端口(默认22): " IN_PORT
  IN_PORT=${IN_PORT:-22}
  read -p "SSH 用户(默认root): " IN_USER
  IN_USER=${IN_USER:-root}
  read -s -p "SSH 密码: " IN_PASS
  echo

  mkdir -p /root/.ssh
  ssh-keygen -R "$IN_IP" >/dev/null 2>&1 || true
  ssh-keygen -R "[$IN_IP]:$IN_PORT" >/dev/null 2>&1 || true

  sshpass -p "$IN_PASS" scp \
    -P "$IN_PORT" \
    -o StrictHostKeyChecking=no \
    /root/wg_client.conf \
    "$IN_USER@$IN_IP:/root/wg_client.conf"

  echo "已上传到入口机 /root/wg_client.conf"
fi

echo "=== 出口机部署完成 ==="

#!/usr/bin/env bash
set -e

echo "=== WireGuard 出口机部署（最终稳定版）==="

# 1. 基础依赖
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y wireguard iproute2 iptables iptables-persistent curl sshpass

# 2. 开启转发
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# 3. 获取外网接口
WAN_IF=$(ip route | grep default | awk '{print $5}' | head -n1)

# 4. 清理旧配置
systemctl stop wg-quick@wg0 2>/dev/null || true
rm -rf /etc/wireguard
mkdir -p /etc/wireguard
cd /etc/wireguard
umask 077

# 5. 生成密钥
wg genkey | tee server.key | wg pubkey > server.pub
wg genkey | tee client.key | wg pubkey > client.pub

SERVER_PRIV=$(cat server.key)
SERVER_PUB=$(cat server.pub)
CLIENT_PRIV=$(cat client.key)
CLIENT_PUB=$(cat client.pub)

# 6. 获取出口 IP
PUB4=$(curl -4 -s ip.sb || true)
PUB6=$(curl -6 -s ip.sb || true)

# 7. 服务端配置
cat > wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24, fd10::1/64
ListenPort = 51820
PrivateKey = $SERVER_PRIV

PostUp = iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $WAN_IF -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.0.0.2/32, fd10::2/128
EOF

# 8. 启动 WG（不影响 SSH）
wg-quick up wg0

# 9. 客户端配置
cat > /root/wg_client.conf <<EOF
[Interface]
Address = 10.0.0.2/24, fd10::2/64
PrivateKey = $CLIENT_PRIV
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = ${PUB4}:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

echo "客户端配置已生成：/root/wg_client.conf"

# 10. 复制到入口机
read -p "是否复制到入口机？(y/n): " C
if [[ "$C" == "y" ]]; then
  read -p "入口机 IP: " IN_IP
  read -p "SSH 端口(默认22): " IN_PORT
  IN_PORT=${IN_PORT:-22}
  read -p "SSH 用户(默认root): " IN_USER
  IN_USER=${IN_USER:-root}
  read -s -p "SSH 密码: " IN_PASS
  echo

  mkdir -p /root/.ssh
  ssh-keygen -f /root/.ssh/known_hosts -R "$IN_IP" >/dev/null 2>&1 || true
  ssh-keygen -f /root/.ssh/known_hosts -R "[$IN_IP]:$IN_PORT" >/dev/null 2>&1 || true

  sshpass -p "$IN_PASS" scp \
    -o StrictHostKeyChecking=no \
    -P "$IN_PORT" \
    /root/wg_client.conf \
    "$IN_USER@$IN_IP:/root/wg_client.conf"

  echo "已复制到入口机 /root/wg_client.conf"
fi

echo "=== 出口机部署完成 ==="

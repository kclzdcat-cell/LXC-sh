#!/usr/bin/env bash
set -e

echo "=== WireGuard 出口机（稳定服务端）==="

### 0. 基础修复
rm -f /var/lib/dpkg/lock*
rm -f /var/cache/apt/archives/lock
dpkg --configure -a || true

### 1. 安装依赖
apt update
apt install -y wireguard iproute2 iptables curl

### 2. 开启转发
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

### 3. 清理旧 WG
ip link del wg0 2>/dev/null || true

### 4. 生成密钥
SERVER_PRIV=$(wg genkey)
SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)

### 5. 创建接口
ip link add wg0 type wireguard
ip addr add 10.0.0.1/24 dev wg0
ip link set wg0 up

### 6. 配置 WireGuard（先不加 peer）
wg set wg0 private-key <(echo "$SERVER_PRIV") listen-port 51820

### 7. NAT（IPv4）
WAN_IF=$(ip route | awk '/default/ {print $5; exit}')
iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE

### 8. 显示给入口机的信息
echo
echo "========== 给入口机填写的信息 =========="
echo "出口机公网 IPv4 : $(curl -4 -s ip.sb)"
echo "WireGuard 端口  : 51820"
echo "Server 公钥     : $SERVER_PUB"
echo "=========================================="
echo

### 9. 当前状态
wg show

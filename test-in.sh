#!/usr/bin/env bash
set -e

echo "=== WireGuard 入口机（出站全走 WG / SSH 永不掉）==="

### 0. 修复 dpkg
rm -f /var/lib/dpkg/lock*
rm -f /var/cache/apt/archives/lock
dpkg --configure -a || true

### 1. 安装依赖
apt update
apt install -y wireguard iproute2 iptables curl

### 2. 用户输入（手动，最稳）
read -p "出口机公网 IP: " SERVER_IP
read -p "WireGuard 端口 [51820]: " SERVER_PORT
SERVER_PORT=${SERVER_PORT:-51820}
read -p "出口机 Server 公钥: " SERVER_PUB

### 3. 清理旧配置（不影响 SSH）
wg-quick down wg0 2>/dev/null || true
ip link del wg0 2>/dev/null || true
ip rule del fwmark 51820 table 51820 2>/dev/null || true
ip route flush table 51820 2>/dev/null || true
iptables -t mangle -F || true

### 4. 生成客户端密钥
CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)

### 5. 创建 WG 接口
ip link add wg0 type wireguard
ip addr add 10.0.0.2/24 dev wg0

wg set wg0 \
  private-key <(echo "$CLIENT_PRIV") \
  peer "$SERVER_PUB" \
  endpoint "$SERVER_IP:$SERVER_PORT" \
  allowed-ips 0.0.0.0/0 \
  persistent-keepalive 25

ip link set wg0 up

### 6. 策略路由（核心，不动默认路由）
grep -q "^51820 wg$" /etc/iproute2/rt_tables || echo "51820 wg" >> /etc/iproute2/rt_tables

wg set wg0 fwmark 51820
ip route add default dev wg0 table 51820
ip rule add fwmark 51820 table 51820

### 7. 只标记“出站流量”
iptables -t mangle -A OUTPUT -j MARK --set-mark 51820
iptables -t mangle -A OUTPUT -p tcp --sport 22 -j RETURN

### 8. 输出信息
echo
echo "========== 需要添加到出口机的 Peer =========="
echo "Client 公钥 : $CLIENT_PUB"
echo "AllowedIPs  : 10.0.0.2/32"
echo "=============================================="
echo

echo "=== WireGuard 状态 ==="
wg show
echo
echo "=== 出口 IP 验证 ==="
curl -4 ip.sb || true

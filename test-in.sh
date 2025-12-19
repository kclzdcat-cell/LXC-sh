#!/usr/bin/env bash
set -e

WG_IF="wg0"
WG_MARK=51820
WG_TABLE=51820

# ====== 你从出口机复制过来的信息 ======
SERVER_IP="出口机公网IP"
SERVER_PORT=51820
SERVER_PUBKEY="出口机Server公钥"
CLIENT_PRIVKEY="Client私钥"
# ======================================

apt update -y
apt install -y wireguard iptables iproute2 curl

# 清理旧环境
wg-quick down ${WG_IF} 2>/dev/null || true
ip link del ${WG_IF} 2>/dev/null || true
iptables -t mangle -F
ip rule del fwmark ${WG_MARK} table ${WG_TABLE} 2>/dev/null || true
ip route flush table ${WG_TABLE}

# 创建 WG 接口
ip link add ${WG_IF} type wireguard
wg set ${WG_IF} private-key <(echo "${CLIENT_PRIVKEY}") peer ${SERVER_PUBKEY} endpoint ${SERVER_IP}:${SERVER_PORT} allowed-ips 0.0.0.0/0 persistent-keepalive 25

ip addr add 10.66.66.2/24 dev ${WG_IF}
ip link set ${WG_IF} up

# ===== 核心：策略路由（不会断 SSH） =====

# 1. WG fwmark
wg set ${WG_IF} fwmark ${WG_MARK}

# 2. WG 路由表
ip route add default dev ${WG_IF} table ${WG_TABLE}
ip rule add fwmark ${WG_MARK} table ${WG_TABLE}

# 3. mangle OUTPUT（顺序非常关键）
iptables -t mangle -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -t mangle -A OUTPUT -p tcp --dport 22 -j RETURN
iptables -t mangle -A OUTPUT -o lo -j RETURN
iptables -t mangle -A OUTPUT -j MARK --set-mark ${WG_MARK}

# 刷新缓存
ip route flush cache

echo
echo "=== WireGuard 已启用（SSH 不会断） ==="
echo "当前出口 IP："
curl -4 ip.sb || true

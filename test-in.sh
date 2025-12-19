#!/usr/bin/env bash
set -euo pipefail

# =====================================================
# OpenVPN Ingress v2.4 (SSH-SAFE FINAL)
# 核心原则：
# - OpenVPN 绝不改默认路由
# - 不使用 redirect-gateway
# - route-nopull + 策略路由
# - connmark 保护 SSH 生命周期
# =====================================================

VPN_IF="tun0"
VPN_MARK="0x1"
VPN_TABLE="100"

echo "========================================="
echo " OpenVPN 入口部署 v2.4"
echo " SSH 永不断 | 不改默认路由 | IPv4 出站走 VPN"
echo "========================================="

[[ $EUID -eq 0 ]] || { echo "❌ 需要 root"; exit 1; }
[[ -f /root/client.ovpn ]] || { echo "❌ /root/client.ovpn 不存在"; exit 1; }

# ---------- 依赖 ----------
apt update -y
apt install -y openvpn iproute2 iptables iptables-persistent conntrack curl

# ---------- 清理 ----------
iptables -t mangle -F || true
ip rule del fwmark ${VPN_MARK} lookup main 2>/dev/null || true
ip rule del lookup ${VPN_TABLE} 2>/dev/null || true
ip route flush table ${VPN_TABLE} 2>/dev/null || true

# ---------- OpenVPN Client ----------
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# ★★ 核心：彻底禁止 OpenVPN 接管路由 ★★
sed -i '/redirect-gateway/d' /etc/openvpn/client/client.conf
sed -i '/route-ipv6/d' /etc/openvpn/client/client.conf

grep -q "route-nopull" /etc/openvpn/client/client.conf || cat >> /etc/openvpn/client/client.conf <<'EOF'

# ===== SSH SAFE MODE =====
route-nopull
pull-filter ignore redirect-gateway
pull-filter ignore route-ipv6
pull-filter ignore ifconfig-ipv6
EOF

# ---------- SSH connmark（仅基于端口） ----------
iptables -t mangle -A PREROUTING \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j CONNMARK --set-mark ${VPN_MARK}

iptables -t mangle -A PREROUTING \
  -m connmark --mark ${VPN_MARK} \
  -j MARK --set-mark ${VPN_MARK}

ip rule add priority 100 fwmark ${VPN_MARK} lookup main

# ---------- 启动 OpenVPN ----------
systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

echo "[IN] 等待 tun0（最多 20 秒）..."
for i in {1..20}; do
  ip link show ${VPN_IF} >/dev/null 2>&1 && break
  sleep 1
done

ip link show ${VPN_IF} >/dev/null 2>&1 || {
  echo "❌ tun0 未出现，未动路由，SSH 安全"
  exit 1
}

# ---------- 策略路由 ----------
ip route add default dev ${VPN_IF} table ${VPN_TABLE}
ip rule add priority 200 lookup ${VPN_TABLE}

iptables-save >/etc/iptables/rules.v4

# ---------- 验证 ----------
echo
echo "IPv4 出口（应为出口机）："
curl -4 --max-time 6 ip.sb || true
echo
echo "IPv6（应为入口本地）："
curl -6 --max-time 6 ip.sb || true

echo
echo "✅ 完成：v2.4"
echo "SSH 永不断 | 默认路由未改"

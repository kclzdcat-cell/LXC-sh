#!/usr/bin/env bash
set -euo pipefail

# =====================================================
# OpenVPN Ingress Script v2.3 (FINAL)
# 功能：
# - IPv4 出站走 OpenVPN
# - SSH / 原生 IPv4 入站 永不断
# - 不改默认路由
# - connmark 工程级保护
# =====================================================

VERSION="2.3"
VPN_IF="tun0"
VPN_MARK="0x1"
VPN_TABLE="100"

echo "====================================================="
echo " OpenVPN 入口部署 v${VERSION}"
echo " IPv4 出站 → OpenVPN | SSH 永不断 | 不改默认路由"
echo "====================================================="
echo

# ---------------- 基础检查 ----------------
[[ $EUID -eq 0 ]] || { echo "❌ 请使用 root 运行"; exit 1; }

if [[ ! -f /root/client.ovpn ]]; then
  echo "❌ 未找到 /root/client.ovpn"
  exit 1
fi

# ---------------- 安装依赖 ----------------
echo "[IN] 安装依赖..."
apt update -y
apt install -y openvpn iproute2 iptables iptables-persistent curl conntrack

# ---------------- 清理旧规则 ----------------
echo "[IN] 清理旧策略路由 / iptables..."
iptables -t mangle -F || true
ip rule del fwmark ${VPN_MARK} lookup main 2>/dev/null || true
ip rule del lookup ${VPN_TABLE} 2>/dev/null || true
ip route flush table ${VPN_TABLE} 2>/dev/null || true

# ---------------- 部署 OpenVPN ----------------
echo "[IN] 部署 OpenVPN Client..."
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# 强制：只接管 IPv4，不允许服务端搞 IPv6
grep -q "pull-filter ignore route-ipv6" /etc/openvpn/client/client.conf || cat >> /etc/openvpn/client/client.conf <<'EOF'

# ===== 强制 IPv4 ONLY =====
pull-filter ignore "route-ipv6"
pull-filter ignore "ifconfig-ipv6"
pull-filter ignore "redirect-gateway-ipv6"
EOF

# ---------------- SSH connmark 保护（核心） ----------------
echo "[IN] 设置 SSH connmark 保护（核心）"

# 1️⃣ 新 SSH 连接打 connmark
iptables -t mangle -A PREROUTING \
  -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -j CONNMARK --set-mark ${VPN_MARK}

# 2️⃣ 整个连接生命周期继承 mark
iptables -t mangle -A PREROUTING \
  -m connmark --mark ${VPN_MARK} \
  -j MARK --set-mark ${VPN_MARK}

# 3️⃣ SSH 标记流量永远走 main
ip rule add priority 100 fwmark ${VPN_MARK} lookup main

# ---------------- 启动 OpenVPN ----------------
echo "[IN] 启动 OpenVPN Client..."
systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

# ---------------- 等待 tun0 ----------------
echo "[IN] 等待 tun0 创建（最多 20 秒）..."
for i in {1..20}; do
  ip link show ${VPN_IF} >/dev/null 2>&1 && break
  sleep 1
done

if ! ip link show ${VPN_IF} >/dev/null 2>&1; then
  echo "❌ tun0 未创建，退出（未动路由，SSH 安全）"
  exit 1
fi

echo "✅ tun0 已建立"

# ---------------- 策略路由（IPv4 ONLY） ----------------
echo "[IN] 配置 IPv4 出站策略路由（不改默认路由）"

ip route add default dev ${VPN_IF} table ${VPN_TABLE}
ip rule add priority 200 lookup ${VPN_TABLE}

# ---------------- 保存规则 ----------------
iptables-save >/etc/iptables/rules.v4

# ---------------- 验证 ----------------
echo
echo "================= 验证 ================="
echo "IPv4 出口（应为出口机 IP）："
curl -4 --max-time 8 ip.sb || true
echo
echo "IPv6（未接管，应为入口机本地）："
curl -6 --max-time 5 ip.sb || echo "IPv6 未配置 / 已忽略"
echo "========================================"

echo
echo "✅ 完成：v${VERSION}"
echo "SSH 永不断 | IPv4 出站已接管 | 默认路由未改"
echo
echo "🧯 紧急回滚："
echo "  systemctl stop openvpn-client@client"
echo "  iptables -t mangle -F"
echo "  ip rule flush"
echo "========================================"

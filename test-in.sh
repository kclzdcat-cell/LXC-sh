#!/bin/bash
set -euo pipefail

# =========================================================
# OpenVPN Ingress Script
# Mode   : IPv4 出站接管 + SSH 永不掉（策略路由）1
# Version: 2.0 (SSH SAFE FIX)
# =========================================================

SCRIPT_VERSION="2.0"

echo "=================================================="
echo " OpenVPN 入口部署 v${SCRIPT_VERSION}"
echo " IPv4 出站接管 | SSH 永不断 | 不改默认路由"
echo "=================================================="
echo

# ---------- 基础检查 ----------
if [[ $EUID -ne 0 ]]; then
  echo "请用 root 运行"; exit 1
fi

# ---------- 变量 ----------
OVPN_IF="tun0"
OVPN_TABLE="100"
OVPN_MARK="0x66"

MAIN_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
MAIN_GW=$(ip route get 1.1.1.1 | awk '{print $3; exit}')

log(){ echo -e "\n[IN] $*\n"; }

log "检测到主网卡：${MAIN_IF} via ${MAIN_GW}"

# ---------- 安装依赖 ----------
log "安装依赖"
apt update -y
apt install -y openvpn iproute2 iptables iptables-persistent curl

# ---------- 检查 client.ovpn ----------
if [[ ! -f /root/client.ovpn ]]; then
  echo "❌ 未找到 /root/client.ovpn"; exit 1
fi

# ---------- 部署 OpenVPN ----------
log "部署 OpenVPN Client"
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# ---------- 清理旧规则 ----------
log "清理旧策略路由"
ip rule del fwmark ${OVPN_MARK} table ${OVPN_TABLE} 2>/dev/null || true
ip route flush table ${OVPN_TABLE} 2>/dev/null || true
iptables -t mangle -F OUTPUT || true

# ---------- 启动 OpenVPN ----------
log "启动 OpenVPN"
systemctl daemon-reload
systemctl enable --now openvpn-client@client

log "等待 OpenVPN 建立隧道..."
sleep 5

# ---------- 校验 tun0 ----------
if ! ip link show ${OVPN_IF} >/dev/null 2>&1; then
  echo "❌ tun0 未出现，OpenVPN 可能启动失败"
  systemctl status openvpn-client@client --no-pager
  exit 1
fi

# ---------- 关键修复点：SSH 永久放行 ----------
log "配置 SSH 永不接管规则（关键）"

# 1️⃣ SSH 端口直接 RETURN（回包不会被打 mark）
iptables -t mangle -A OUTPUT -p tcp --sport 22 -j RETURN

# 2️⃣ 所有已建立连接 RETURN（防止现有会话被切）
iptables -t mangle -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

# 3️⃣ 只有 NEW 连接才打 mark
iptables -t mangle -A OUTPUT -m conntrack --ctstate NEW -j MARK --set-mark ${OVPN_MARK}

# ---------- 策略路由 ----------
log "配置策略路由（仅 IPv4 出站）"

ip route add default dev ${OVPN_IF} table ${OVPN_TABLE}
ip rule add fwmark ${OVPN_MARK} table ${OVPN_TABLE}

ip route flush cache

# ---------- 验证 ----------
log "验证出口"

echo "IPv4 出口："
curl -4 --max-time 10 ip.sb || true
echo

echo "IPv6（应为本机，不受影响）："
curl -6 --max-time 10 ip.sb || true

echo
echo "=================================================="
echo "✅ 完成："
echo "- SSH / 入站流量：原网卡 (${MAIN_IF})"
echo "- IPv4 出站：OpenVPN (${OVPN_IF})"
echo "- 默认路由：未修改"
echo
echo "🆘 紧急回滚："
echo "   systemctl stop openvpn-client@client"
echo "   ip rule flush"
echo "   iptables -t mangle -F OUTPUT"
echo "=================================================="

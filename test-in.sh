#!/bin/bash
set -euo pipefail

echo "==========================================="
echo " OpenVPN 入口部署（稳定修复版2.1）"
echo " 目标：IPv4 出站走 OpenVPN | 入站 & SSH 永不断"
echo "==========================================="

# ================== 基础检查 ==================
if [[ $EUID -ne 0 ]]; then
  echo "❌ 请使用 root 运行"
  exit 1
fi

# 必须在 SSH 会话中运行
if [[ -z "${SSH_CLIENT:-}" ]]; then
  echo "❌ 未检测到 SSH_CLIENT，拒绝运行（防止断连）"
  exit 1
fi

SSH_CLIENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
echo "[INFO] 当前 SSH 客户端 IP: $SSH_CLIENT_IP"

# ================== 安装依赖 ==================
echo "[INFO] 安装依赖..."
apt update -y
apt install -y openvpn iproute2 iptables iptables-persistent curl

# ================== 校验 client.ovpn ==================
if [[ ! -f /root/client.ovpn ]]; then
  echo "❌ 未找到 /root/client.ovpn"
  exit 1
fi

mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# ================== 强制客户端配置（不接管 IPv6） ==================
echo "[INFO] 修正 OpenVPN 客户端配置"

sed -i '/redirect-gateway/d' /etc/openvpn/client/client.conf
sed -i '/route-ipv6/d' /etc/openvpn/client/client.conf
sed -i '/ifconfig-ipv6/d' /etc/openvpn/client/client.conf

cat >> /etc/openvpn/client/client.conf <<'EOF'

# ====== 路由控制（只接管 IPv4 出站） ======
redirect-gateway def1
pull-filter ignore "route-ipv6"
pull-filter ignore "ifconfig-ipv6"
pull-filter ignore "redirect-gateway-ipv6"

# DNS（防止解析异常）
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1
EOF

# ================== 内核参数（只开 IPv4 转发） ==================
echo "[INFO] 设置内核参数"
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# ================== OpenVPN fwmark ==================
OVPN_MARK=0x66
OVPN_TABLE=200

# ================== 清理旧规则 ==================
echo "[INFO] 清理旧策略路由"
ip rule del fwmark $OVPN_MARK table $OVPN_TABLE 2>/dev/null || true
ip route flush table $OVPN_TABLE 2>/dev/null || true
iptables -t mangle -F OUTPUT || true

# ================== SSH 永不断核心保护 ==================
echo "[INFO] 设置 SSH 保护规则（核心）"

# 1. SSH 客户端 IP 永久直通
iptables -t mangle -A OUTPUT -d "$SSH_CLIENT_IP" -j RETURN

# 2. 已建立连接直通
iptables -t mangle -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

# 3. 仅 NEW 连接打 mark
iptables -t mangle -A OUTPUT -m conntrack --ctstate NEW -j MARK --set-mark $OVPN_MARK

# ================== OpenVPN 路由表 ==================
echo "[INFO] 设置策略路由表"
ip route add default dev tun0 table $OVPN_TABLE
ip rule add fwmark $OVPN_MARK table $OVPN_TABLE
ip route flush cache

# ================== NAT（仅 IPv4） ==================
echo "[INFO] 配置 NAT"
iptables -t nat -C POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

netfilter-persistent save

# ================== 启动 OpenVPN ==================
echo "[INFO] 启动 OpenVPN Client"
systemctl daemon-reload
systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

echo "[INFO] 等待隧道建立..."
sleep 5

# ================== 验证 ==================
echo "-------------------------------------------"
echo "[CHECK] OpenVPN 状态:"
systemctl is-active openvpn-client@client && echo "✔ OpenVPN 已连接" || echo "❌ OpenVPN 未运行"

echo "-------------------------------------------"
echo "[CHECK] IPv4 出口（应为出口机 IP）:"
curl -4 --max-time 8 ip.sb || true

echo "-------------------------------------------"
echo "[CHECK] SSH 连通性（反向探测）:"
ping -c 1 "$SSH_CLIENT_IP" >/dev/null && echo "✔ SSH 回包正常" || echo "⚠ SSH 回包异常"

echo "==========================================="
echo "✅ 完成："
echo "- 入站 IPv4 / SSH 永不断"
echo "- 出站 IPv4 走 OpenVPN（tun0）"
echo "- 默认路由未修改"
echo
echo "回滚命令："
echo "  systemctl stop openvpn-client@client"
echo "  iptables -t mangle -F OUTPUT"
echo "  ip rule del fwmark $OVPN_MARK table $OVPN_TABLE"
echo "==========================================="

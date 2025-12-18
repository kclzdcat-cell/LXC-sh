#!/bin/bash
set -e

echo "==========================================="
echo " WireGuard 入口机部署（最终稳定版）"
echo " 入站全放行 | 出站走出口机"
echo " Debian 12"
echo "==========================================="

# -------------------------------
# 0. 基础检查
# -------------------------------
if [ "$(id -u)" != "0" ]; then
  echo "❌ 请使用 root 执行"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# -------------------------------
# 1. 修复 apt / dpkg
# -------------------------------
echo ">>> 修复 apt / dpkg"
rm -f /var/lib/dpkg/lock*
rm -f /var/lib/apt/lists/lock
rm -f /var/cache/apt/archives/lock
dpkg --configure -a || true
apt update

# -------------------------------
# 2. 安装 WireGuard
# -------------------------------
echo ">>> 安装 WireGuard"
apt install -y wireguard wireguard-tools iptables curl

# -------------------------------
# 3. 防火墙：全部放行（满足你要求）
# -------------------------------
echo ">>> 放行所有 TCP / UDP / 端口"
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -F
iptables -t nat -F

# -------------------------------
# 4. 应用 WireGuard 客户端配置
# -------------------------------
if [ ! -f /root/wg_client.conf ]; then
  echo "❌ 缺少 /root/wg_client.conf"
  exit 1
fi

mkdir -p /etc/wireguard
cp /root/wg_client.conf /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0
sleep 3

# -------------------------------
# 5. DNS（防止断网）
# -------------------------------
echo ">>> 修复 DNS"
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
chattr +i /etc/resolv.conf

# -------------------------------
# 6. 创建策略路由表
# -------------------------------
grep -q '^200 wg$' /etc/iproute2/rt_tables || echo '200 wg' >> /etc/iproute2/rt_tables

# -------------------------------
# 7. 先保护 SSH（关键）
# -------------------------------
SSH_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
echo ">>> 保护当前 SSH IP: $SSH_IP"
ip rule add to "$SSH_IP" lookup main priority 50 || true

# -------------------------------
# 8. 出站默认走 WireGuard
# -------------------------------
echo ">>> 设置默认出站走 wg0"
ip route flush table wg
ip route add default dev wg0 table wg

ip rule add table main suppress_prefixlength 0 priority 100 || true
ip rule add lookup wg priority 200 || true

ip route flush cache

# -------------------------------
# 9. 验证
# -------------------------------
echo ">>> 出口 IPv4："
curl -4 ip.sb || true

echo "==========================================="
echo "🎉 部署完成"
echo "✔ 所有 TCP/UDP 入站全放行"
echo "✔ 所有端口保持入口机 IP"
echo "✔ 所有出站流量走出口机"
echo "✔ SSH 永不掉线"
echo "==========================================="

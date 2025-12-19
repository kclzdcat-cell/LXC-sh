#!/bin/bash
set -e

echo "=== WireGuard 入口机（SSH 永不掉线 · 稳定版）==="

# 必须 root
if [ "$(id -u)" != "0" ]; then
  echo "必须使用 root 执行"
  exit 1
fi

####################################
# 0. 修复 dpkg / apt 锁 & 状态
####################################
echo "[0/7] 修复 dpkg / apt 状态"

# 停止可能占用 apt 的服务
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

# 等待锁释放（最多 30 秒）
for i in {1..30}; do
  if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    break
  fi
  echo "等待 apt 锁释放... ($i)"
  sleep 1
done

# 强制修复 dpkg
dpkg --configure -a || true
apt-get -f install -y || true

####################################
# 1. 更新软件源
####################################
echo "[1/7] 更新软件源"
apt update

####################################
# 2. 安装必要依赖
####################################
echo "[2/7] 安装 WireGuard 及依赖"
apt install -y \
  wireguard \
  iproute2 \
  iptables \
  curl

####################################
# 3. 检查客户端配置
####################################
echo "[3/7] 检查 wg_client.conf"

if [ ! -f /root/wg_client.conf ]; then
  echo "❌ 缺少 /root/wg_client.conf"
  exit 1
fi

mkdir -p /etc/wireguard
cp /root/wg_client.conf /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

####################################
# 4. 启动 WireGuard（不改任何默认路由）
####################################
echo "[4/7] 启动 WireGuard（不影响 SSH）"

systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

sleep 2

if ! wg show wg0 >/dev/null 2>&1; then
  echo "❌ WireGuard 未正常启动"
  exit 1
fi

####################################
# 5. 只让 wg0 自己的流量走出口机
####################################
echo "[5/7] 配置“仅 wg0 源地址走出口机”"

WG_IP4=$(ip -4 addr show wg0 | awk '/inet /{print $2}' | cut -d/ -f1)

if [ -z "$WG_IP4" ]; then
  echo "❌ wg0 未获得 IPv4 地址"
  exit 1
fi

echo "wg0 IPv4: $WG_IP4"

# 清理旧规则（安全）
ip rule del from "$WG_IP4" table 200 2>/dev/null || true
ip route flush table 200 2>/dev/null || true

# table 200 默认走 wg0
ip route add default dev wg0 table 200

# 只有 wg0 源地址才用 table 200
ip rule add from "$WG_IP4" table 200 priority 1000

ip route flush cache

####################################
# 6. 验证（SSH 不断）
####################################
echo "[6/7] 验证"

echo "默认路由（仍是入口机）："
ip route | grep default || true

echo "通过 wg0 的出口 IP："
curl --interface wg0 -4 ip.sb || echo "IPv4 测试失败"
curl --interface wg0 -6 ip.sb || echo "IPv6 测试失败"

####################################
# 7. 完成
####################################
echo "[7/7] 完成"

echo "========================================"
echo "✔ SSH / 所有入站端口：完全不受影响"
echo "✔ 系统默认出口：入口机原 IP"
echo "✔ 通过 wg0 的流量：出口机 IP"
echo ""
echo "用法示例："
echo "  curl --interface wg0 https://ip.sb"
echo "========================================"

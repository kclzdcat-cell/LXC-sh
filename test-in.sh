#!/bin/bash
set -e

echo "=== WireGuard 入口机（SSH 永不掉线版）==="

# 必须 root
if [ "$(id -u)" != "0" ]; then
  echo "必须使用 root 执行"
  exit 1
fi

# 检查客户端配置
if [ ! -f /root/wg_client.conf ]; then
  echo "缺少 /root/wg_client.conf"
  exit 1
fi

echo "[1/6] 更新系统并安装依赖"
apt update
apt install -y wireguard iproute2 iptables curl

echo "[2/6] 写入 WireGuard 配置"
mkdir -p /etc/wireguard
cp /root/wg_client.conf /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

echo "[3/6] 启动 WireGuard（不改任何路由）"
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

sleep 2
wg show

echo "[4/6] 设置“仅 wg0 自己的流量走出口机”"

# 获取 wg0 IPv4
WG_IP=$(ip -4 addr show wg0 | awk '/inet /{print $2}' | cut -d/ -f1)

if [ -z "$WG_IP" ]; then
  echo "wg0 没有 IPv4，退出"
  exit 1
fi

echo "wg0 IPv4: $WG_IP"

# 清理旧规则（安全）
ip rule del from "$WG_IP" table 200 2>/dev/null || true
ip route flush table 200

# 表 200：默认走 wg0
ip route add default dev wg0 table 200

# 只有“源地址是 wg0 的流量”才走 table 200
ip rule add from "$WG_IP" table 200 priority 1000

ip route flush cache

echo "[5/6] 验证（SSH 不会断）"
echo "当前主机默认出口（不变）："
ip route | grep default

echo "通过 wg0 的出口："
curl --interface wg0 -4 ip.sb || true
curl --interface wg0 -6 ip.sb || true

echo "[6/6] 完成"

echo "======================================"
echo "✔ SSH / 入站流量：完全不受影响"
echo "✔ 主机默认出口：仍是入口机 IP"
echo "✔ 需要走出口机的流量：用 wg0"
echo ""
echo "示例："
echo "  curl --interface wg0 https://ip.sb"
echo "======================================"

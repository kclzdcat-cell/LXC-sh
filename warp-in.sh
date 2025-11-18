#!/bin/bash
set -e

echo "============================================"
echo " OpenVPN 入口服务器自动部署脚本（防断线版）"
echo "============================================"

apt update -y
apt install -y openvpn iptables iptables-persistent curl

# -------------------------------
# 自动检测入口网卡
# -------------------------------
ETH=$(ip -o -4 route show to default | awk '{print $5}')
echo "入口服务器出站网卡: $ETH"

# -------------------------------
# 开启 IP 转发
# -------------------------------
echo 1 >/proc/sys/net/ipv4/ip_forward
echo 1 >/proc/sys/net/ipv6/conf/all/forwarding

cat >/etc/sysctl.d/99-openvpn.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF

sysctl -p

# -------------------------------
# 放入 client.ovpn
# -------------------------------
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# -------------------------------
# NAT
# -------------------------------
iptables -t nat -A POSTROUTING -o $ETH -j MASQUERADE
netfilter-persistent save

# -------------------------------
# 启动 OpenVPN 客户端
# -------------------------------
systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

echo "等待 OpenVPN 隧道建立..."

# -------------------------------
# 等待 tun0 出现（最多 20 秒）
# -------------------------------
for i in {1..20}; do
    if ip a show tun0 > /dev/null 2>&1; then
        echo "tun0 已建立，准备切换默认路由..."
        TUN_READY=1
        break
    fi
    sleep 1
done

# -------------------------------
# 如果隧道未建立，不切路由 → 防止 SSH 断开
# -------------------------------
if [[ -z "$TUN_READY" ]]; then
    echo "❌ OpenVPN 尚未连接成功，已取消切换路由（SSH 不会断）"
    exit 0
fi

# -------------------------------
# 隧道已成功 → 切换默认路由
# -------------------------------
echo "✔ 切换默认路由至 tun0"
ip route replace default dev tun0

echo "=============================="
echo " OpenVPN 入口服务器安装完成！"
echo "当前出口 IPv4："
curl -4 ip.sb
echo "=============================="

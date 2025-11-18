#!/bin/bash
set -e

echo "==========================================="
echo " OpenVPN 入口服务器部署脚本（最终稳定版）"
echo " 完全兼容 OpenVPN 2.6+"
echo " IPv6 本地出站 | IPv4 走出口服务器 WARP"
echo "==========================================="

apt update -y
apt install -y openvpn iproute2 curl

CFG="/etc/openvpn/client/client.ovpn"
mkdir -p /etc/openvpn/client

#======================================================
# 获取 client.ovpn
#======================================================
if [[ ! -f "/root/client.ovpn" ]]; then
    echo "❌ 未找到 /root/client.ovpn"
    exit 1
fi

cp /root/client.ovpn "$CFG"

#======================================================
# 去除旧版协议 udp-client / tcp-client
#======================================================
sed -i 's/udp-client/udp/g' "$CFG"
sed -i 's/tcp-client/tcp/g' "$CFG"

#======================================================
# 禁止 redirect-gateway（避免 SSH 断线）
#======================================================
sed -i '/redirect-gateway/d' "$CFG"

#======================================================
# 创建 systemd 服务
#======================================================
cat >/etc/systemd/system/openvpn-client@client.service <<EOF
[Unit]
Description=OpenVPN Client (client)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/openvpn --config /etc/openvpn/client/client.ovpn --route-noexec
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

sleep 2

#======================================================
# 检查 tun0 是否建立
#======================================================
if ! ip a | grep -q tun0; then
    echo "❌ OpenVPN 未成功建立连接（tun0 不存在）"
    exit 1
fi

echo "✔ OpenVPN 已成功连接（检测到 tun0）"

echo ">>> 设置 IPv4 走 OpenVPN 出口..."

# 获取 tun0 网关（动态获取，防止并非 10.8.0.1）
TUN_GW=$(ip route | grep "tun0" | grep "proto kernel" | awk '{print $3}')

if [[ -z "$TUN_GW" ]]; then
    TUN_GW="10.8.0.1"
fi

echo "检测到 OpenVPN 网关: $TUN_GW"

# 清理旧规则
ip rule del prio 10000 2>/dev/null || true
ip route flush table 100 2>/dev/null || true

# tun0 走出的路由表
ip route add default via $TUN_GW dev tun0 table 100

# 强制所有 IPv4 走 table 100
ip rule add from 0.0.0.0/0 table 100 prio 10000

# 添加 DNS（必须）
echo "nameserver 1.1.1.1" >/etc/resolv.conf

echo ">>> IPv4 路由修复完成！"

echo "==========================================="
echo " ✔ IPv4 已全部通过出口服务器（WARP）出站"
echo " ✔ IPv6 继续使用本地公网"
echo "==========================================="

systemctl status openvpn-client@client --no-pager || true

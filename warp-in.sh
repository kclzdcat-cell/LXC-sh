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

#======================================================
# 入口服务器 IPv4 全部通过出口（WARP）走
#======================================================
TUN_GW="10.8.0.1"
TABLE_ID=100

ip rule del table $TABLE_ID 2>/dev/null || true
ip route flush table $TABLE_ID 2>/dev/null || true

ip route add default via $TUN_GW dev tun0 table $TABLE_ID
ip rule add from all lookup $TABLE_ID priority 10000

echo "==========================================="
echo " ✔ IPv4 已全部通过出口服务器（WARP）出站"
echo " ✔ IPv6 继续使用本地公网"
echo "==========================================="

systemctl status openvpn-client@client --no-pager || true

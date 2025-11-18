#!/bin/bash
set -e

echo "==========================================="
echo " OpenVPN 入口服务器部署脚本（最终稳定版）"
echo " 完全兼容 OpenVPN 2.6+"
echo " IPv6 保持本地出站 | IPv4 自动走出口服务器 WARP"
echo "==========================================="

apt update -y
apt install -y openvpn curl iproute2

mkdir -p /etc/openvpn/client

CFG="/etc/openvpn/client/client.ovpn"

#======================================================
#   检查 client.ovpn 是否存在
#======================================================
if [[ ! -f "/root/client.ovpn" ]]; then
    echo "❌ 未找到 /root/client.ovpn"
    exit 1
fi

cp /root/client.ovpn "$CFG"

#======================================================
#   修复所有 remote（适配 OpenVPN 2.6）
#======================================================
sed -i 's/\sudp$/ udp-client/g' "$CFG"
sed -i 's/\stcp$/ tcp-client/g' "$CFG"

sed -i '/remote error/d' "$CFG"
sed -i '/remote code/d' "$CFG"
sed -i '/remote Error/d' "$CFG"
sed -i '/remote null/d' "$CFG"
sed -i '/^remote\s*$/d' "$CFG"

#======================================================
#   禁止接管默认路由（否则 SSH 会断）
#======================================================
sed -i '/redirect-gateway/d' "$CFG"

#======================================================
#   创建 OpenVPN systemd 服务（与你出口脚本匹配）
#======================================================
cat >/etc/systemd/system/openvpn-client@client.service <<EOF
[Unit]
Description=OpenVPN Client (client)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/openvpn --config /etc/openvpn/client/client.ovpn \
    --route-noexec
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
#   获取 tun0 信息（OpenVPN 2.6+）
#======================================================
TUN_IP=$(ip -4 addr show tun0 | grep inet | awk '{print $2}' | cut -d/ -f1)
TUN_GW="10.8.0.1"

if [[ -z "$TUN_IP" ]]; then
    echo "❌ OpenVPN 未成功建立连接（tun0 未就绪）"
    exit 1
fi

echo "检测到 OpenVPN IPv4: $TUN_IP"

#======================================================
#   创建策略路由：所有 IPv4 → 走出口服务器（WARP）
#======================================================
TABLE_ID=100

# 清理旧规则
ip rule del table $TABLE_ID 2>/dev/null || true
ip route flush table $TABLE_ID 2>/dev/null || true

# 添加专用路由表
ip route add default via $TUN_GW dev tun0 table $TABLE_ID

# 所有 IPv4 流量进 table 100
ip rule add from all lookup $TABLE_ID priority 10000

# 禁止影响 IPv6
# （因为 IPv6 不能走出口服务器）
# 所以什么都不用设置，IPv6 默认走本地网卡

echo "==========================================="
echo " IPv4 出站流量现已全部走出口服务器的 WARP IPv4"
echo " IPv6 不受影响，继续用本地公网 IPv6"
echo "==========================================="

systemctl status openvpn-client@client --no-pager || true

echo "==========================================="
echo " OpenVPN 入口服务器部署完成！"
echo " IPv4 → 出口服务器（WARP IPv4）"
echo " IPv6 → 本地公网 IPv6"
echo "==========================================="

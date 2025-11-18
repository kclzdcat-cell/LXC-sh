#!/bin/bash
set -e

echo "==========================================="
echo " OpenVPN 入口服务器部署脚本（最终稳定版）"
echo " 完全兼容 OpenVPN 2.6+"
echo " 防止默认路由被接管（SSH 不断线）"
echo " 自动修复 remote 参数，绝不出错"
echo "==========================================="

apt update -y
apt install -y openvpn curl

mkdir -p /etc/openvpn/client

#======================================================
#   必须检测 client.ovpn 是否存在
#======================================================
if [[ ! -f "/root/client.ovpn" ]]; then
    echo "❌ 未找到 /root/client.ovpn"
    echo "请先从出口服务器上传后再运行本脚本！"
    exit 1
fi

# 复制到 OpenVPN 目录
cp /root/client.ovpn /etc/openvpn/client/client.ovpn

#======================================================
#   自动修复 OpenVPN 2.6 不兼容的 remote 写法
#======================================================

CFG="/etc/openvpn/client/client.ovpn"

# 修复 remote udp → udp-client
sed -i 's/\sudp$/ udp-client/g' "$CFG"

# 修复 remote tcp → tcp-client
sed -i 's/\stcp$/ tcp-client/g' "$CFG"

# 删除所有 remote 错误行（error code / 500 / null 等）
sed -i '/remote error/d' "$CFG"
sed -i '/remote code/d' "$CFG"
sed -i '/remote Error/d' "$CFG"
sed -i '/remote null/d' "$CFG"

# 删除空 remote 行
sed -i '/^remote\s*$/d' "$CFG"

#======================================================
#   禁止入口服务器被 redirect-gateway 接管默认路由
#======================================================
sed -i '/redirect-gateway/d' "$CFG"

#======================================================
#   Systemd 服务（OpenVPN 官方推荐方式）
#======================================================

cat >/etc/systemd/system/openvpn-client@client.service <<EOF
[Unit]
Description=OpenVPN Client (client)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/openvpn --config /etc/openvpn/client/client.ovpn \
    --route-noexec --redirect-gateway bypass-dhcp
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

sleep 1
echo ">>> OpenVPN 客户端状态："
systemctl status openvpn-client@client --no-pager || true

echo "==========================================="
echo " OpenVPN 入口服务器部署完成！"
echo "==========================================="

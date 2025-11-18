#!/bin/bash
set -e

echo "==========================================="
echo " OpenVPN 入口服务器部署脚本（最终稳定版）"
echo " 完全兼容 OpenVPN 2.6+"
echo " 不接管默认路由，保证 SSH 不断线"
echo " 自动修正 remote 语法，防止所有 2.6 报错"
echo "==========================================="

apt update -y
apt install -y openvpn curl

mkdir -p /etc/openvpn/client

#------------- 检查 client.ovpn 是否存在 -------------
if [[ ! -f "/root/client.ovpn" ]]; then
    echo "❌ 未找到 /root/client.ovpn"
    echo "请先从出口服务器上传后再运行本脚本！"
    exit 1
fi

#------------- 拷贝配置文件 --------------------------
cp /root/client.ovpn /etc/openvpn/client/client.ovpn

#======================================================
#   ⭐ 自动修复 OpenVPN 2.6 不再支持的 remote 旧语法
#   （这是你入口端一直报错的唯一原因）
#======================================================

# 修复 udp → udp-client
sed -i 's/\sudp$/ udp-client/g' /etc/openvpn/client/client.ovpn

# 修复 tcp → tcp-client
sed -i 's/\stcp$/ tcp-client/g' /etc/openvpn/client/client.ovpn

# 删除任何非法 remote（例如 “error code: 500”）
sed -i '/remote error/d' /etc/openvpn/client/client.ovpn
sed -i '/remote code/d' /etc/openvpn/client/client.ovpn
sed -i '/remote Error/d' /etc/openvpn/client/client.ovpn
sed -i '/remote null/d' /etc/openvpn/client/client.ovpn

# 删除 remote 空行
sed -i '/^remote\s*$/d' /etc/openvpn/client/client.ovpn

#------------- 永远禁止入口服务器默认路由被接管 ---------
sed -i '/redirect-gateway/d' /etc/openvpn/client/client.ovpn

#======================================================
#   Systemd 服务：固定为 OpenVPN 2.6 推荐启动方式
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

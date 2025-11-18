#!/bin/bash
set -e

echo "==========================================="
echo " OpenVPN 入口服务器部署脚本（最终稳定版）"
echo " 避免默认路由被接管 | 完全兼容 OpenVPN 2.6+"
echo "==========================================="

apt update -y
apt install -y openvpn curl

mkdir -p /etc/openvpn/client

#------------- 检查 client.ovpn 是否存在 -------------
if [[ ! -f "/root/client.ovpn" ]]; then
    echo "未找到 /root/client.ovpn"
    echo "请先从出口服务器上传后再运行本脚本！"
    exit 1
fi

#--------------- 拷贝 client.ovpn -------------------
cp /root/client.ovpn /etc/openvpn/client/client.ovpn

#--------------- 移除默认路由 push ------------------
# 出口端已 push redirect-gateway ，入口端必须禁止
sed -i '/redirect-gateway/d' /etc/openvpn/client/client.ovpn

#--------------- 强制兼容 OpenVPN 2.6 ---------------
# 自动将 udp / tcp 旧语法修复为 udp-client / tcp-client
sed -i 's/remote \(.*\) udp$/remote \1 udp-client/' /etc/openvpn/client/client.ovpn
sed -i 's/remote \(.*\) tcp$/remote \1 tcp-client/' /etc/openvpn/client/client.ovpn

#--------------- Systemd 自定义服务 -----------------
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

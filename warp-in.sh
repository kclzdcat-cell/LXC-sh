#!/bin/bash
set -e

echo "==========================================="
echo " OpenVPN 入口服务器部署脚本（兼容 Easy-RSA 版本）"
echo " 不修改默认路由，不断 SSH"
echo "==========================================="

apt update -y
apt install -y openvpn curl

mkdir -p /etc/openvpn/client

#------------- 找 client.ovpn ----------------
if [[ ! -f "/root/client.ovpn" ]]; then
    echo "未找到 /root/client.ovpn"
    echo "请先从出口服务器上传后再运行本脚本！"
    exit 1
fi

cp /root/client.ovpn /etc/openvpn/client/client.ovpn


#------------- 禁止入口服务器抢默认路由（必须） -------------
sed -i '/redirect-gateway/d' /etc/openvpn/client/client.ovpn


#------------- 创建 systemd 服务（正确方法） -------------
cat >/etc/systemd/system/openvpn-client@client.service <<EOF
[Unit]
Description=OpenVPN Client (client)
After=network-online.target

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
echo ">>> 查看 OpenVPN 客户端状态："
systemctl status openvpn-client@client --no-pager || true

echo "==========================================="
echo " OpenVPN 入口服务器部署完成！"
echo "==========================================="

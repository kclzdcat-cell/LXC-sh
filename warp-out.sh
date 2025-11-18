#!/bin/bash
clear
echo "==============================================="
echo "   OpenVPN 出口服务器自动部署脚本（稳定版）"
echo "==============================================="

apt update -y
apt install -y openvpn easy-rsa curl iptables iptables-persistent

EASYRSA_DIR="/etc/openvpn/easy-rsa"
rm -rf $EASYRSA_DIR
make-cadir $EASYRSA_DIR
cd $EASYRSA_DIR

./easyrsa init-pki
echo | ./easyrsa build-ca nopass
./easyrsa gen-dh
./easyrsa build-server-full server nopass
./easyrsa build-client-full client nopass

OUT_IPV6=$(ip -6 addr show | grep global | awk '{print $2}' | cut -d/ -f1)
OUT_NIC=$(ip -6 addr | grep global | awk '{print $NF}' | head -1)

echo "检测出口服务器 IPv6: $OUT_IPV6"

cat >/etc/openvpn/server.conf <<EOF
port 1194
proto tcp6
dev tun
ca $EASYRSA_DIR/pki/ca.crt
cert $EASYRSA_DIR/pki/issued/server.crt
key $EASYRSA_DIR/pki/private/server.key
dh $EASYRSA_DIR/pki/dh.pem
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 ipv6 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-GCM
verb 3
EOF

systemctl enable openvpn@server
systemctl restart openvpn@server

cat >/root/client.ovpn <<EOF
client
dev tun
proto tcp6
remote $OUT_IPV6 1194
nobind
persist-key
persist-tun
cipher AES-256-GCM
verb 3

<ca>
$(cat $EASYRSA_DIR/pki/ca.crt)
</ca>
<cert>
$(cat $EASYRSA_DIR/pki/issued/client.crt)
</cert>
<key>
$(cat $EASYRSA_DIR/pki/private/client.key)
</key>
EOF

echo "==============================================="
echo "出口服务器 OpenVPN 部署完成"
echo "client.ovpn 文件已生成：/root/client.ovpn"
echo ""
echo "请在入口服务器运行 in.sh，它会自动下载文件"
echo "出口服务器 IPv6： $OUT_IPV6"
echo "==============================================="

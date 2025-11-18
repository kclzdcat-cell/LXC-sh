#!/bin/bash
set -e

echo "============================================"
echo "  OpenVPN 出口服务器自动部署脚本（IPv6 入站）"
echo "============================================"

# ------------------------#
#  检测系统版本
# ------------------------#
if ! command -v apt >/dev/null 2>&1; then
    echo "此脚本仅支持 Debian / Ubuntu"
    exit 1
fi

apt update -y
apt install -y openvpn easy-rsa iptables iptables-persistent curl unzip cron

# ------------------------#
#  自动检测网卡
# ------------------------#
NIC=$(ip -6 route get 2001:4860:4860::8888 | awk '/dev/{print $5}')
echo "出口网卡：$NIC"

# ------------------------#
#  Easy-RSA 初始化
# ------------------------#
EASYRSA=/etc/openvpn/easy-rsa
rm -rf $EASYRSA
make-cadir $EASYRSA
cd $EASYRSA
./easyrsa init-pki
echo -en "\n" | ./easyrsa build-ca nopass
./easyrsa gen-dh
./easyrsa build-server-full server nopass
./easyrsa build-client-full client nopass

# ------------------------#
#  生成 server.conf
# ------------------------#
cat >/etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun

ca $EASYRSA/pki/ca.crt
cert $EASYRSA/pki/issued/server.crt
key $EASYRSA/pki/private/server.key
dh $EASYRSA/pki/dh.pem

server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"

keepalive 10 120
persist-key
persist-tun
user nobody
group nogroup
verb 3
explicit-exit-notify 1
EOF

systemctl enable openvpn@server
systemctl restart openvpn@server

sleep 2

# ------------------------#
#  设置 NAT（出口走 WARP IPv4）
# ------------------------#
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE
ip6tables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE

netfilter-persistent save

# ------------------------#
#  生成 client.ovpn
# ------------------------#
SERVER_IPV6=$(ip -6 addr show $NIC | grep global | awk '{print $2}' | cut -d/ -f1)

cat >/root/client.ovpn <<EOF
client
dev tun
proto udp
remote $SERVER_IPV6 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verb 3

<ca>
$(cat $EASYRSA/pki/ca.crt)
</ca>

<cert>
$(sed -n '/BEGIN/,/END/p' $EASYRSA/pki/issued/client.crt)
</cert>

<key>
$(cat $EASYRSA/pki/private/client.key)
</key>
EOF

echo "出口 client.ovpn 已生成：/root/client.ovpn"

# ------------------------#
#  自动上传到入口服务器
# ------------------------#
read -p "是否自动上传到入口服务器？(y/n): " UP

if [[ "$UP" == "y" ]]; then
    read -p "入口服务器 IPv4/IPv6: " INIP
    read -p "入口 SSH 端口(默认22): " INPORT
    INPORT=${INPORT:-22}
    read -p "SSH 用户(默认 root): " INUSER
    INUSER=${INUSER:-root}
    read -p "SSH 密码: " INPASS

    echo "清理 known_hosts..."
    ssh-keygen -R "[$INIP]:$INPORT" >/dev/null 2>&1 || true

    apt install -y sshpass
    echo "正在上传 client.ovpn ..."
    sshpass -p "$INPASS" scp -P $INPORT /root/client.ovpn $INUSER@$INIP:/root/
    echo "上传成功!"
fi

echo "OpenVPN 出口服务器部署完成!"

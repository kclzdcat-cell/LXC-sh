#!/bin/bash
set -e

echo "============================================"
echo "  OpenVPN 出口服务器自动部署脚本（IPv6 入站）"
echo "============================================"

apt update -y
apt install -y openvpn easy-rsa iptables iptables-persistent curl

# ==========================================================
#   自动检测出口网卡名称（绝对不会把 IPv6 当网卡名）
# ==========================================================
NIC=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')

if [ -z "$NIC" ]; then
    NIC=$(ip -6 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
fi

if [[ "$NIC" =~ ^(lo|tun|docker|vnet) ]]; then
    NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE "lo|tun|docker|vnet" | head -n1)
fi

echo "出口网卡检测结果：$NIC"

# ==========================================================
#  Easy-RSA 初始化
# ==========================================================
EASYRSA=/etc/openvpn/easy-rsa
rm -rf $EASYRSA
make-cadir $EASYRSA
cd $EASYRSA
./easyrsa init-pki
echo -en "\n" | ./easyrsa build-ca nopass
./easyrsa gen-dh
./easyrsa build-server-full server nopass
./easyrsa build-client-full client nopass

# ==========================================================
#  生成 server.conf
# ==========================================================
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
verb 3
explicit-exit-notify 1
EOF

systemctl enable openvpn@server
systemctl restart openvpn@server

sleep 2

# ==========================================================
#  NAT（使用正确网卡）
# ==========================================================
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE
netfilter-persistent save

# ==========================================================
#  获取 IPv6（不会误判）
# ==========================================================
SERVER_IPV6=$(ip -6 addr show $NIC | awk '/scope global/ {print $2}' | head -n1 | cut -d/ -f1)
echo "检测到出口 IPv6：$SERVER_IPV6"

# ==========================================================
#  生成 client.ovpn
# ==========================================================
cat >/root/client.ovpn <<EOF
client
dev tun
proto udp
remote $SERVER_IPV6 1194
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

echo "出口配置文件生成：/root/client.ovpn"

# ==========================================================
#  自动上传
# ==========================================================
read -p "是否上传 client.ovpn 到入口服务器？(y/n): " UP

if [[ "$UP" == "y" ]]; then
    apt install -y sshpass
    read -p "入口服务器 IP: " INIP
    read -p "入口 SSH 端口(默认22): " INPORT
    INPORT=${INPORT:-22}
    read -p "入口用户(默认 root): " INUSER
    INUSER=${INUSER:-root}
    read -p "入口密码: " INPASS

    ssh-keygen -R "[$INIP]:$INPORT" 2>/dev/null || true

    sshpass -p "$INPASS" scp -P $INPORT /root/client.ovpn $INUSER@$INIP:/root/
    echo "上传成功！"
fi

echo "出口服务器部署完成！"

#!/bin/bash
clear

echo "==============================================="
echo "  OpenVPN 出口服务器自动部署脚本 (IPv6 入站 + WARP IPv4 出站)"
echo "==============================================="

# ---------------------------
# 安装依赖
# ---------------------------
apt update -y
apt install -y openvpn easy-rsa iptables iptables-persistent curl

# ---------------------------
# 自动检测出口网卡
# ---------------------------
WAN_IF=$(ip route get 1 | awk '{print $5; exit}')
echo "出口网卡: $WAN_IF"

# ---------------------------
# 获取出口机 IPv6 地址（入站地址）
# ---------------------------
IPV6_ADDR=$(ip -6 addr show dev $WAN_IF | grep "scope global" | head -n 1 | awk '{print $2}' | cut -d/ -f1)

if [[ -z "$IPV6_ADDR" ]]; then
    echo "❌ 未检测到 IPv6 地址，无法作为出口服务器！"
    exit 1
fi

echo "出口服务器入站 IPv6: $IPV6_ADDR"

# ---------------------------
# 创建 easy-rsa PKI
# ---------------------------
mkdir -p /etc/openvpn/easy-rsa
ln -sf /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/
cd /etc/openvpn/easy-rsa

./easyrsa init-pki
echo -en "\n" | ./easyrsa build-ca nopass
./easyrsa gen-dh
./easyrsa build-server-full server nopass
./easyrsa build-client-full client nopass

# ---------------------------
# 复制证书与密钥
# ---------------------------
cd /etc/openvpn
cp easy-rsa/pki/ca.crt .
cp easy-rsa/pki/issued/server.crt .
cp easy-rsa/pki/private/server.key .
cp easy-rsa/pki/dh.pem .

# ---------------------------
# 生成 server.conf（UDP 1194）
# ---------------------------
cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp6
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
topology subnet
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-GCM
user nobody
group nogroup
persist-key
persist-tun
status openvpn-status.log
verb 3
EOF

# ---------------------------
# 生成 server-tcp.conf（TCP 443）
# ---------------------------
cat > /etc/openvpn/server-tcp.conf <<EOF
port 443
proto tcp6
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
topology subnet
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-GCM
user nobody
group nogroup
persist-key
persist-tun
status openvpn-status-tcp.log
verb 3
EOF

# ---------------------------
# NAT：内网 → 出口 WARP IPv4
# ---------------------------
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding

iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $WAN_IF -j MASQUERADE

iptables-save > /etc/iptables/rules.v4

# ---------------------------
# 启动 OpenVPN 服务
# ---------------------------
systemctl enable openvpn@server
systemctl start openvpn@server

systemctl enable openvpn@server-tcp
systemctl start openvpn@server-tcp

# ---------------------------
# 生成 client.ovpn
# ---------------------------
CLIENT=/root/client.ovpn

cat > $CLIENT <<EOF
client
dev tun
proto udp6
remote $IPV6_ADDR 1194
resolv-retry infinite
nobind
persist-key
persist-tun
cipher AES-256-GCM
verb 3

<ca>
$(cat /etc/openvpn/ca.crt)
</ca>
<cert>
$(cat /etc/openvpn/easy-rsa/pki/issued/client.crt)
</cert>
<key>
$(cat /etc/openvpn/easy-rsa/pki/private/client.key)
</key>
EOF

echo "client.ovpn 已生成：/root/client.ovpn"

# ---------------------------
# 上传到入口服务器
# ---------------------------
read -p "是否自动上传到入口服务器？(y/n): " UP

if [[ "$UP" == "y" ]]; then
    read -p "入口服务器 IP: " INIP
    read -p "入口 SSH 端口(默认22): " INPORT
    INPORT=${INPORT:-22}
    read -p "入口 SSH 用户名(默认 root): " INUSER
    INUSER=${INUSER:-root}
    read -s -p "入口 SSH 密码: " INPASS
    echo ""

    apt install -y sshpass
    sshpass -p "$INPASS" scp -P $INPORT /root/client.ovpn ${INUSER}@${INIP}:/root/
    echo "上传完成！"
fi

echo "==============================================="
echo " 出口服务器部署完成！"
echo "==============================================="

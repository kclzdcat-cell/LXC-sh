#!/bin/bash
set -e

echo "============================================"
echo " OpenVPN 出口服务器部署脚本（IPv6 入站 + WARP IPv4 出站）"
echo "============================================"

# -------------------------------
# 检测系统并安装
# -------------------------------
apt update -y
apt install -y openvpn easy-rsa iptables iptables-persistent curl

# -------------------------------
# 自动检测出口网卡
# -------------------------------
ETH=$(ip -o -4 route show to default | awk '{print $5}')
echo "出口网卡: $ETH"

# -------------------------------
# 自动检测出口服务器真实 IPv6 入站
# -------------------------------
IPV6=$(ip -6 addr show dev "$ETH" | grep 'global' | awk '{print $2}' | cut -d'/' -f1 | head -n1)

if [[ -z "$IPV6" ]]; then
    echo "❌ 未检测到出口服务器可用 IPv6 地址！无法用于入口连接！"
    exit 1
fi

echo "出口服务器 IPv6 入站: $IPV6"

# -------------------------------
# 重置 Easy-RSA PKI
# -------------------------------
EASY=/etc/openvpn/easy-rsa
mkdir -p $EASY
cd /etc/openvpn
cp -r /usr/share/easy-rsa/* easy-rsa/
cd $EASY

./easyrsa init-pki <<EOF
yes
EOF

./easyrsa build-ca nopass <<EOF





EOF

# 生成服务器证书
./easyrsa build-server-full server nopass

# 生成客户端证书
./easyrsa build-client-full client nopass

# DH 参数
./easyrsa gen-dh

# -------------------------------
# 复制证书到 /etc/openvpn/
# -------------------------------
cd /etc/openvpn
cp $EASY/pki/ca.crt .
cp $EASY/pki/dh.pem .
cp $EASY/pki/issued/server.crt .
cp $EASY/pki/private/server.key .

# -------------------------------
# 生成 server.conf（IPv6 入站）
# -------------------------------
cat >/etc/openvpn/server.conf <<EOF
port 1194
proto udp6
dev tun

server 10.8.0.0 255.255.255.0
server-ipv6 fddd:1194:1194:1194::/64

push "redirect-gateway def1 ipv6 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS6 2606:4700:4700::1111"

keepalive 10 120
cipher AES-256-CBC
persist-key
persist-tun

user nobody
group nogroup

ca   ca.crt
cert server.crt
key  server.key
dh   dh.pem

explicit-exit-notify 1
EOF

# -------------------------------
# 启动 OpenVPN 服务
# -------------------------------
systemctl enable openvpn@server
systemctl restart openvpn@server

sleep 3

# -------------------------------
# NAT 转发（IPv4 → WARP IPv4，IPv6 → 出口机）
# -------------------------------
echo "配置 NAT 转发 ..."

# IPv4
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $ETH -j MASQUERADE

# IPv6
ip6tables -t nat -A POSTROUTING -s fddd:1194:1194:1194::/64 -o $ETH -j MASQUERADE

netfilter-persistent save

# -------------------------------
# 生成 client.ovpn
# -------------------------------
CLIENTCFG=/root/client.ovpn

cat >$CLIENTCFG <<EOF
client
dev tun
proto udp6
remote $IPV6 1194

resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server

cipher AES-256-CBC
verb 3

<ca>
$(cat /etc/openvpn/ca.crt)
</ca>

<cert>
$(cat $EASY/pki/issued/client.crt)
</cert>

<key>
$(cat $EASY/pki/private/client.key)
</key>
EOF

echo "client.ovpn 已生成: /root/client.ovpn"

# -------------------------------
# SSH 上传到入口服务器
# -------------------------------
read -p "是否自动上传 client.ovpn 到入口服务器？(y/n): " UP

if [[ "$UP" == "y" ]]; then
    read -p "入口服务器 IPv4/IPv6: " INIP
    read -p "入口 SSH 端口（默认22）: " INPORT
    read -p "入口 SSH 用户名（默认 root）: " INUSER
    read -p "入口 SSH 密码: " INPASS

    INPORT=${INPORT:-22}
    INUSER=${INUSER:-root}

    apt install -y sshpass

    sshpass -p "${INPASS}" scp -P ${INPORT} -o StrictHostKeyChecking=no /root/client.ovpn ${INUSER}@${INIP}:/root/
    echo "上传成功！"
fi

echo "=============================="
echo " 出口服务器部署完成！"
echo "=============================="

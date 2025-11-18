#!/bin/bash
set -e

echo "============================================"
echo " OpenVPN 出口服务器自动部署脚本（IPv6 入站 + IPv4/WARP 出站）"
echo "============================================"

apt update -y
apt install -y openvpn easy-rsa iptables iptables-persistent curl sshpass

# 自动检测出口网卡 (IPv6 默认路由)
ETH=$(ip -o -6 route show default | awk '{print $5}' | head -n 1)
if [[ -z "$ETH" ]]; then
    ETH=$(ip -o link show | awk -F': ' '/: e/{print $2}' | head -n 1)
fi
echo "出口服务器网卡: $ETH"

# 检测入站 IPv6
IN6=$(ip -6 addr show dev $ETH | sed -n 's/.*inet6 \([^ ]*\) scope global.*/\1/p' | cut -d/ -f1 | head -n 1)
if [[ -z "$IN6" ]]; then
    echo "❌ 未检测到出口服务器可用 IPv6 地址！无法作为入口的连接目标！"
    exit 1
fi
echo "出口服务器可用 IPv6: $IN6"

echo "清理旧 OpenVPN 配置..."
rm -rf /etc/openvpn/easy-rsa
rm -rf /etc/openvpn/server.conf
systemctl stop openvpn@server 2>/dev/null || true

# 初始化 EasyRSA
make-cadir /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa
./easyrsa init-pki

echo -ne "\n" | ./easyrsa build-ca nopass
./easyrsa gen-req server nopass
echo "yes" | ./easyrsa sign-req server server
./easyrsa gen-dh

./easyrsa gen-req client nopass
echo "yes" | ./easyrsa sign-req client client

echo "生成 server.conf ..."

cat >/etc/openvpn/server.conf <<EOF
port 1194
proto udp6
dev tun

sndbuf 0
rcvbuf 0

ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
dh /etc/openvpn/easy-rsa/pki/dh.pem

server 10.8.0.0 255.255.255.0

push "redirect-gateway def1"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"

keepalive 10 120
persist-key
persist-tun

user nobody
group nogroup
EOF

echo "配置 NAT..."
iptables -t nat -A POSTROUTING -o $ETH -j MASQUERADE
netfilter-persistent save

systemctl enable openvpn@server
systemctl restart openvpn@server

CLIENT=/root/client.ovpn
echo "生成 client.ovpn..."

cat > $CLIENT <<EOF
client
dev tun
proto udp6
remote $IN6 1194
resolv-retry infinite
nobind
persist-key
persist-tun

remote-cert-tls server

redirect-gateway def1
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1

<ca>
$(cat /etc/openvpn/easy-rsa/pki/ca.crt)
</ca>
<cert>
$(cat /etc/openvpn/easy-rsa/pki/issued/client.crt)
</cert>
<key>
$(cat /etc/openvpn/easy-rsa/pki/private/client.key)
</key>
EOF

echo "client.ovpn 已生成：/root/client.ovpn"

# 自动上传
read -p "是否自动上传 client.ovpn 到入口服务器？(y/n): " UP

if [[ "$UP" == "y" ]]; then
    read -p "入口服务器 IPv4/IPv6: " IN_IP
    read -p "入口 SSH 端口(默认 22): " IN_PORT
    IN_PORT=${IN_PORT:-22}
    read -p "入口 SSH 用户(默认 root): " IN_USER
    IN_USER=${IN_USER:-root}
    read -p "入口 SSH 密码: " IN_PASS

    echo "清理入口服务器旧 SSH 指纹..."
    ssh-keygen -R "$IN_IP" >/dev/null 2>&1 || true

    echo "上传 client.ovpn..."
    sshpass -p "$IN_PASS" scp -P $IN_PORT /root/client.ovpn ${IN_USER}@${IN_IP}:/root/ || {
        echo "⚠️ 上传失败，但出口服务器 OpenVPN 已正常运行。"
    }

fi

echo "==============================="
echo " OpenVPN 出口服务器安装完成！"
echo "==============================="
echo "client.ovpn 位于: /root/client.ovpn"

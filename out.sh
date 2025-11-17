#!/bin/bash
echo "=== OpenVPN 出口服务器自动部署脚本 ==="
echo "网卡自动检测..."

NIC=$(ip route show default | awk '{print $5}' | head -1)
echo "检测到出口网卡: $NIC"

echo "=== 1. 安装 OpenVPN 与 Easy-RSA ==="
apt update -y
apt install -y openvpn easy-rsa iptables

echo "=== 2. 初始化 OpenVPN ==="
make-cadir /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa

./easyrsa init-pki
echo -ne "\n" | ./easyrsa build-ca nopass
./easyrsa gen-dh
./easyrsa build-server-full server nopass
./easyrsa build-client-full client nopass
./easyrsa gen-crl

cd /etc/openvpn/easy-rsa/pki
cp ca.crt issued/server.crt private/server.key dh.pem /etc/openvpn/
cp issued/client.crt private/client.key /etc/openvpn/

echo "=== 3. 生成服务端配置 ==="
cat >/etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 1.0.0.1"
keepalive 10 120
cipher AES-256-CBC
user nobody
group nogroup
persist-key
persist-tun
status openvpn-status.log
verb 3
EOF

echo "=== 4. 开启 NAT 转发 ==="
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE
apt install -y iptables-persistent
netfilter-persistent save

echo "开启 IPv4 forward..."
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p

echo "=== 5. 启动 OpenVPN 服务 ==="
systemctl enable openvpn@server
systemctl restart openvpn@server

echo "=== 6. 导出客户端配置到 /root/client.ovpn ==="
CLIENT_IP=$(curl -4 -s ifconfig.me)

cat >/root/client.ovpn <<EOF
client
dev tun
proto udp
remote $CLIENT_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
verb 3

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

echo ""
echo "==============================="
echo " OpenVPN 出口服务器部署成功！"
echo " 客户端配置文件: /root/client.ovpn"
echo "==============================="

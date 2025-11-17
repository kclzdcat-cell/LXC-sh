#!/bin/bash
set -e

echo "============================"
echo " OpenVPN 出口服务器自动部署 "
echo "============================"

# 1. 安装 OpenVPN + Easy-RSA
apt update -y
apt install -y openvpn easy-rsa sshpass

make-cadir /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa

# 2. 初始化 PKI
./easyrsa init-pki
echo | ./easyrsa build-ca nopass

# 3. 生成服务端证书
./easyrsa gen-req server nopass
./easyrsa sign-req server server

# 4. 生成 Diffie-Hellman
./easyrsa gen-dh

# 5. 生成客户端证书
./easyrsa gen-req client nopass
./easyrsa sign-req client client

# 6. 复制证书到 /etc/openvpn
cd /etc/openvpn
cp easy-rsa/pki/ca.crt .
cp easy-rsa/pki/issued/server.crt .
cp easy-rsa/pki/private/server.key .
cp easy-rsa/pki/dh.pem .

# 7. 生成 server.conf
cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
persist-key
persist-tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
status openvpn-status.log
verb 3
EOF

# 8. 启动 OpenVPN
systemctl enable openvpn@server
systemctl restart openvpn@server

echo "OpenVPN 出口服务器已启动!"

出口IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
echo "出口服务器外网IP: $出口IP"

# 9. 创建客户端配置 client.ovpn
cat > /root/client.ovpn <<EOF
client
dev tun
proto udp
remote $出口IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
auth-nocache
remote-cert-tls server
redirect-gateway def1
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1

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

echo ">>> 客户端配置文件: /root/client.ovpn"

echo ""
echo "============================"
echo " 请填写入口服务器 SSH 账号信息 "
echo "============================"
read -p "入口服务器 IP: " ENT_IP
read -p "入口服务器 用户名: " ENT_USER
read -p "入口服务器 密码: " ENT_PASS

echo ">>> 正在上传 client.ovpn 到入口服务器 ..."
sshpass -p "$ENT_PASS" scp -o StrictHostKeyChecking=no /root/client.ovpn $ENT_USER@$ENT_IP:/root/

echo ""
echo "上传成功！client.ovpn 已放到入口服务器 /root/"
echo ""

echo "============================"
echo " OpenVPN 出口机部署成功！ "
echo "============================"

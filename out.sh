#!/bin/bash
set -e

echo "============================"
echo " OpenVPN 出口服务器自动部署 "
echo "============================"

apt update -y
apt install -y openvpn easy-rsa sshpass

# ===========================
# 1. 清理旧环境（关键修复点）
# ===========================
rm -rf /etc/openvpn/easy-rsa
rm -rf /etc/openvpn/server.conf
rm -rf /etc/openvpn/server/
rm -rf /etc/openvpn/dh.pem
rm -rf /etc/openvpn/ca.crt
rm -rf /etc/openvpn/server.key
rm -rf /etc/openvpn/server.crt

mkdir -p /etc/openvpn/easy-rsa
make-cadir /etc/openvpn/easy-rsa

# ===========================
# 2. 生成 CA、证书
# ===========================
cd /etc/openvpn/easy-rsa
./easyrsa init-pki
echo | ./easyrsa build-ca nopass

./easyrsa gen-req server nopass
./easyrsa sign-req server server

./easyrsa gen-dh

./easyrsa gen-req client nopass
./easyrsa sign-req client client

# ===========================
# 3. 复制证书到 OpenVPN 目录
# ===========================
cd /etc/openvpn
cp easy-rsa/pki/ca.crt .
cp easy-rsa/pki/issued/server.crt .
cp easy-rsa/pki/private/server.key .
cp easy-rsa/pki/dh.pem .

# ===========================
# 4. 生成 server.conf
# ===========================
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

# ===========================
# 5. 启动 OpenVPN 服务
# ===========================
systemctl enable openvpn@server
systemctl restart openvpn@server

echo "OpenVPN 服务已启动!"

出口IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
echo "出口服务器外网 IP: $出口IP"

# ===========================
# 6. 生成 client.ovpn
# ===========================
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

echo ""
echo "客户端配置文件已生成: /root/client.ovpn"
echo ""

# ===========================
# 7. 上传 client.ovpn 到入口服务器
# ===========================
echo "============================"
echo " 请填写入口服务器 SSH 信息 "
echo "============================"

read -p "入口服务器 IP: " ENT_IP
read -p "入口服务器 用户名: " ENT_USER
read -p "入口服务器 密码: " ENT_PASS

echo ""
echo ">>> 正在上传 client.ovpn ..."
sshpass -p "$ENT_PASS" scp -o StrictHostKeyChecking=no /root/client.ovpn $ENT_USER@$ENT_IP:/root/

echo ""
echo "上传成功，入口服务器文件路径: /root/client.ovpn"
echo ""

echo "============================"
echo " OpenVPN 出口服务器部署成功！"
echo "============================"

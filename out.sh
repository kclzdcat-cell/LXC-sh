#!/bin/bash
set -e

echo "============================"
echo " OpenVPN 出口服务器自动部署 "
echo "============================"

apt update -y
apt install -y openvpn easy-rsa sshpass

echo ">>> 清理旧 OpenVPN 环境 ..."
rm -rf /etc/openvpn/server.conf
rm -rf /etc/openvpn/easy-rsa
rm -rf /etc/openvpn/server
rm -rf /etc/openvpn/*.crt
rm -rf /etc/openvpn/*.key
rm -rf /etc/openvpn/*.pem

mkdir -p /etc/openvpn/easy-rsa

echo ">>> 复制 Easy-RSA 模板（Debian12 正确方式）"
cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/

cd /etc/openvpn/easy-rsa
chmod +x ./easyrsa

# =======================
# 1. 初始化 PKI
# =======================
./easyrsa init-pki

echo ">>> 生成 CA..."
echo | ./easyrsa build-ca nopass

echo ">>> 生成服务器证书..."
./easyrsa gen-req server nopass
echo yes | ./easyrsa sign-req server server

echo ">>> 生成 Diffie-Hellman ..."
./easyrsa gen-dh

echo ">>> 生成客户端证书..."
./easyrsa gen-req client nopass
echo yes | ./easyrsa sign-req client client

# =======================
# 2. 复制证书到 OpenVPN
# =======================
cd /etc/openvpn

cp easy-rsa/pki/ca.crt .
cp easy-rsa/pki/issued/server.crt .
cp easy-rsa/pki/private/server.key .
cp easy-rsa/pki/dh.pem .

# =======================
# 3. 创建 server.conf
# =======================
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

echo ">>> 启动 OpenVPN 服务 ..."
systemctl enable openvpn@server
systemctl restart openvpn@server

出口IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
echo ""
echo "出口服务器 IP: $出口IP"
echo ""

# =======================
# 4. 生成 client.ovpn
# =======================
cat > /root/client.ovpn <<EOF
client
dev tun
proto udp
remote $出口IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth-nocache
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
echo "客户端配置文件已生成：/root/client.ovpn"
echo ""

# =======================
# 5. 上传 client.ovpn 到入口服务器
# =======================
echo "============================"
echo " 请输入入口服务器 SSH 信息 "
echo "============================"

read -p "入口服务器 IP: " ENT_IP
read -p "入口服务器 用户名: " ENT_USER
read -p "入口服务器 密码: " ENT_PASS

echo ""
echo ">>> 正在上传 client.ovpn ..."
sshpass -p "$ENT_PASS" scp -o StrictHostKeyChecking=no /root/client.ovpn $ENT_USER@$ENT_IP:/root/

echo ""
echo "上传成功，入口服务器路径：/root/client.ovpn"
echo ""
echo "============================"
echo " OpenVPN 出口服务器部署完成！"
echo "============================"

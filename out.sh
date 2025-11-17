#!/bin/bash
set -e

echo "============================"
echo " OpenVPN 出口服务器自动部署 "
echo "============================"

# 输入入口服务器信息
read -p "请输入入口服务器 IP: " IN_IP
read -p "请输入入口服务器 SSH 用户名: " IN_USER
read -p "请输入入口服务器 SSH 密码: " IN_PASS

apt update -y
apt install -y openvpn easy-rsa sshpass curl

echo ">>> 清理旧配置 ..."
rm -rf /etc/openvpn/server.conf
rm -rf /etc/openvpn/easy-rsa
rm -rf /etc/openvpn/*.crt
rm -rf /etc/openvpn/*.key
rm -rf /etc/openvpn/*.pem

mkdir -p /etc/openvpn/easy-rsa
cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/

cd /etc/openvpn/easy-rsa
chmod +x ./easyrsa

echo ">>> 初始化 PKI ..."
./easyrsa init-pki

echo | ./easyrsa build-ca nopass

echo ">>> 生成服务器证书 ..."
./easyrsa gen-req server nopass
echo yes | ./easyrsa sign-req server server

echo ">>> 生成 Diffie-Hellman ..."
./easyrsa gen-dh

echo ">>> 生成客户端证书 ..."
./easyrsa gen-req client nopass
echo yes | ./easyrsa sign-req client client

cd /etc/openvpn
cp easy-rsa/pki/ca.crt .
cp easy-rsa/pki/issued/server.crt .
cp easy-rsa/pki/private/server.key .
cp easy-rsa/pki/dh.pem .

# 创建 OpenVPN 服务器配置
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

systemctl enable openvpn@server
systemctl restart openvpn@server

# 获取出口服务器公网IP
OUTIP=$(curl -s ip.sb || curl -s ifconfig.me)

# 生成客户端 ovpn 文件
cat > /root/client.ovpn <<EOF
client
dev tun
proto udp
remote $OUTIP 1194
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

echo ">>> 正在上传 client.ovpn 到入口服务器 ..."

sshpass -p "$IN_PASS" scp -o StrictHostKeyChecking=no /root/client.ovpn $IN_USER@$IN_IP:/root/client.ovpn

echo "============================"
echo "出口服务器部署完成！"
echo "客户端文件已上传到入口服务器：/root/client.ovpn"
echo "============================"

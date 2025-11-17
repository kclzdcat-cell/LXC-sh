#!/bin/bash
clear
echo "======================================="
echo "     OpenVPN 出口服务器自动部署脚本"
echo "======================================="

# === 输入入口服务器信息 ===
read -p "请输入入口服务器 IP: " ENT_IP
read -p "请输入入口服务器 SSH 用户名(root): " ENT_USER
read -p "请输入入口服务器 SSH 密码: " ENT_PWD

# === 检测出口网卡 ===
NET_IF=$(ip route get 8.8.8.8 | awk '{print $5;exit}')
echo "检测到出口服务器网卡: $NET_IF"

apt update -y
apt install -y openvpn easy-rsa sshpass iptables-persistent

# 创建并初始化 PKI
make-cadir /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa
./easyrsa init-pki
echo -ne "\n" | ./easyrsa build-ca nopass

# 生成服务端证书
./easyrsa gen-dh
./easyrsa build-server-full server nopass

# 生成客户端证书
./easyrsa build-client-full client nopass

# 生成 TLS 密钥
openvpn --genkey secret /etc/openvpn/tls.key

# 复制证书文件
cp pki/ca.crt /etc/openvpn/
cp pki/issued/server.crt /etc/openvpn/
cp pki/private/server.key /etc/openvpn/
cp pki/issued/client.crt /etc/openvpn/
cp pki/private/client.key /etc/openvpn/
cp dh.pem /etc/openvpn/

# === 写入 OpenVPN 服务器配置 ===
cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
auth SHA256
cipher AES-256-GCM
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
keepalive 10 120
persist-key
persist-tun
status openvpn-status.log
verb 3
explicit-exit-notify 1
client-to-client
tls-auth tls.key 0
EOF

# === 开启流量转发 & NAT ===
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
sysctl -p

iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $NET_IF -j MASQUERADE
netfilter-persistent save

# 启动 OpenVPN
systemctl enable openvpn@server
systemctl restart openvpn@server

# === 生成 client.ovpn 并打包证书 ===
cat > /root/client.ovpn <<EOF
client
dev tun
proto udp
remote $(curl -4 ip.sb) 1194
resolv-retry infinite
nobind
persist-key
persist-tun
auth-nocache

redirect-gateway def1
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1

<ca>
$(cat /etc/openvpn/ca.crt)
</ca>
<cert>
$(cat /etc/openvpn/client.crt)
</cert>
<key>
$(cat /etc/openvpn/client.key)
</key>
<tls-auth>
$(cat /etc/openvpn/tls.key)
</tls-auth>
key-direction 1
EOF

echo ">>> 客户端配置文件已生成: /root/client.ovpn"

# === 上传文件到入口服务器 ===
echo ">>> 正在上传 client.ovpn 至入口服务器 ..."
sshpass -p "$ENT_PWD" scp -o StrictHostKeyChecking=no /root/client.ovpn ${ENT_USER}@${ENT_IP}:/root/client.ovpn

echo ">>> 上传完毕！"

echo "======================================="
echo " OpenVPN 出口服务器部署成功！"
echo " 客户端文件位于入口服务器: /root/client.ovpn"
echo "======================================="

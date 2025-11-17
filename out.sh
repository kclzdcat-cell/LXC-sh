#!/bin/bash
set -e

echo "====================================="
echo "   OpenVPN 出口服务器自动部署脚本   "
echo "   支持 Debian / Ubuntu 全系列      "
echo "====================================="

# ===== 输入入口服务器 SSH 信息 =====
echo ""
echo "请输入入口服务器 SSH 信息（用于自动上传 client.ovpn）"
read -p "入口服务器 IP: " IN_IP
read -p "SSH 用户名（默认 root）: " IN_USER
IN_USER=${IN_USER:-root}
read -p "SSH 端口（默认 22）: " IN_PORT
IN_PORT=${IN_PORT:-22}
read -p "SSH 密码: " IN_PASS

# ===== 安装依赖 =====
apt update -y
apt install -y openvpn easy-rsa sshpass curl iptables iptables-persistent

# ===== 自动随机端口 =====
OVPN_PORT=$(shuf -i 20000-40000 -n 1)
echo ">>> 随机分配 OpenVPN 端口: $OVPN_PORT"

# ===== 自动检测出口公网 IP =====
PUBLIC_IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
echo ">>> 检测到出口公网 IP: $PUBLIC_IP"

# ===== 自动检测出口网卡 =====
NET_IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
echo ">>> 检测到出口网卡: $NET_IFACE"

# ===== 清理旧环境 =====
echo ">>> 清理旧 OpenVPN 配置 ..."
rm -rf /etc/openvpn/easy-rsa
rm -rf /etc/openvpn/server.conf
rm -rf /etc/openvpn/*.crt /etc/openvpn/*.key /etc/openvpn/*.pem

mkdir -p /etc/openvpn/easy-rsa
cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa

cd /etc/openvpn/easy-rsa
chmod +x ./easyrsa

# ===== 初始化 PKI =====
./easyrsa init-pki

echo | ./easyrsa build-ca nopass

./easyrsa gen-req server nopass
echo yes | ./easyrsa sign-req server server

./easyrsa gen-dh

./easyrsa gen-req client nopass
echo yes | ./easyrsa sign-req client client

# ===== 复制证书到 OpenVPN 目录 =====
cd /etc/openvpn
cp easy-rsa/pki/ca.crt .
cp easy-rsa/pki/issued/server.crt .
cp easy-rsa/pki/private/server.key .
cp easy-rsa/pki/dh.pem .

# ===== 生成 server.conf =====
cat > /etc/openvpn/server.conf <<EOF
port $OVPN_PORT
proto udp
dev tun

server 10.8.0.0 255.255.255.0
topology subnet

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"

keepalive 10 120
persist-key
persist-tun

cipher AES-256-CBC
auth SHA256

ca ca.crt
cert server.crt
key server.key
dh dh.pem

status openvpn-status.log
verb 3
EOF

# ===== 启动 OpenVPN 服务 =====
systemctl enable openvpn@server
systemctl restart openvpn@server

# ===== 设置 NAT =====
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$NET_IFACE" -j MASQUERADE
iptables-save > /etc/iptables/rules.v4

# ===== 生成 client.ovpn =====
cat > /root/client.ovpn <<EOF
client
dev tun
proto udp
remote $PUBLIC_IP $OVPN_PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server

redirect-gateway def1 bypass-dhcp
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1

cipher AES-256-CBC
auth SHA256

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
echo ">>> client.ovpn 文件已生成: /root/client.ovpn"
echo ""

# ===== 自动上传 client.ovpn 到入口服务器 =====
echo ">>> 正在上传 client.ovpn 到入口服务器 ..."

sshpass -p "$IN_PASS" scp -P "$IN_PORT" -o StrictHostKeyChecking=no /root/client.ovpn $IN_USER@$IN_IP:/root/client.ovpn

echo ""
echo "====================================="
echo "   OpenVPN 出口服务器部署完成！     "
echo " client.ovpn 已上传到入口服务器 /root/"
echo "====================================="

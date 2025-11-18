#!/bin/bash
set -e

echo "======================================"
echo " OpenVPN 出口服务器自动部署脚本"
echo " IPv6 入站 + WARP IPv4 出站"
echo "======================================"

# ---------------------------------------------------------
# 自动检测出口网卡 & IPv6
# ---------------------------------------------------------
OUT_IF=$(ip -o -6 addr show | awk '/global/ {print $2; exit}')
[[ -z "$OUT_IF" ]] && echo "❌ 未检测到 IPv6 网卡" && exit 1

OUT_IPV6=$(ip -6 addr show dev $OUT_IF | awk '/global/ {print $2; exit}' | cut -d'/' -f1)
echo "检测到 IPv6: $OUT_IPV6"
read -p "如需手动输入新的 IPv6，请输入（回车默认）: " CUSTOM_IPV6
[[ -n "$CUSTOM_IPV6" ]] && OUT_IPV6="$CUSTOM_IPV6"

# ---------------------------------------------------------
# 安装组件
# ---------------------------------------------------------
apt update -y
apt install -y openvpn easy-rsa iptables iptables-persistent curl

# ---------------------------------------------------------
# 清理旧 PKI
# ---------------------------------------------------------
rm -rf /etc/openvpn/easy-rsa
mkdir -p /etc/openvpn/easy-rsa
cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa

cd /etc/openvpn/easy-rsa
./easyrsa init-pki

# ---------------------------------------------------------
# 非交互生成证书
# ---------------------------------------------------------
EASYRSA_BATCH=1 ./easyrsa build-ca nopass
EASYRSA_BATCH=1 ./easyrsa gen-req server nopass
EASYRSA_BATCH=1 ./easyrsa sign-req server server
EASYRSA_BATCH=1 ./easyrsa gen-req client nopass
EASYRSA_BATCH=1 ./easyrsa sign-req client client

# ---------------------------------------------------------
# 拷贝证书
# ---------------------------------------------------------
mkdir -p /etc/openvpn/server
cp pki/ca.crt /etc/openvpn/server/
cp pki/issued/server.crt /etc/openvpn/server/
cp pki/private/server.key /etc/openvpn/server/

# ---------------------------------------------------------
# 生成 server.conf（删除 dh.pem，使用 ECDH）
# ---------------------------------------------------------
cat >/etc/openvpn/server/server.conf <<EOF
port 443
proto tcp6
dev tun
topology subnet

ca ca.crt
cert server.crt
key server.key

# 使用 ECDH 替代 DH（无需 dh.pem）
ecdh-curve prime256v1

server 10.8.0.0 255.255.255.0
push "redirect-gateway def1"
push "dhcp-option DNS 1.1.1.1"

keepalive 10 120
cipher AES-256-CBC
auth SHA256
persist-key
persist-tun
verb 3
EOF

# ---------------------------------------------------------
# NAT（流量出口到 WARP IPv4）
# ---------------------------------------------------------
iptables -t nat -A POSTROUTING -o $OUT_IF -j MASQUERADE
netfilter-persistent save

# ---------------------------------------------------------
# 启动 OpenVPN
# ---------------------------------------------------------
systemctl enable openvpn-server@server.service
systemctl restart openvpn-server@server.service

# ---------------------------------------------------------
# 生成 client.ovpn
# ---------------------------------------------------------
CLIENT_OVPN="/root/client.ovpn"

cat >$CLIENT_OVPN <<EOF
client
dev tun
proto tcp6
remote $OUT_IPV6 443
resolv-retry infinite
nobind
persist-key
persist-tun

<ca>
$(cat pki/ca.crt)
</ca>

<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' pki/issued/client.crt)
</cert>

<key>
$(cat pki/private/client.key)
</key>

cipher AES-256-CBC
auth SHA256
verb 3
EOF

echo "client.ovpn 已生成：$CLIENT_OVPN"

# ---------------------------------------------------------
# SSH 上传 client.ovpn
# ---------------------------------------------------------
read -p "是否上传 client.ovpn 到入口服务器？(y/n): " UP

if [[ "$UP" == "y" || "$UP" == "Y" ]]; then
    read -p "入口服务器 IP/域名: " IN_IP
    read -p "SSH 端口(默认22): " IN_PORT
    read -p "SSH 用户名(默认root): " IN_USER
    echo -n "SSH 密码: "; read -s IN_PASS; echo

    [[ -z "$IN_PORT" ]] && IN_PORT=22
    [[ -z "$IN_USER" ]] && IN_USER=root

    apt install -y sshpass
    sshpass -p "$IN_PASS" scp -P $IN_PORT -o StrictHostKeyChecking=no /root/client.ovpn $IN_USER@$IN_IP:/root/
fi

echo "=============================="
echo " 出口服务器部署完成！"
echo "=============================="

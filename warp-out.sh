#!/bin/bash
set -e

echo "======================================="
echo "   OpenVPN 出口服务器安装脚本（稳定版）"
echo "======================================="

# ========== 1. 更新系统 ==========
apt update -y
apt install -y openvpn iptables iptables-persistent curl wget unzip sshpass openssl net-tools

# ========== 2. 安装 Easy-RSA ==========
EASYRSA_DIR="/etc/openvpn/easy-rsa"
rm -rf $EASYRSA_DIR
mkdir -p $EASYRSA_DIR
cd /etc/openvpn

wget -q https://github.com/OpenVPN/easy-rsa/releases/download/v3.1.7/EasyRSA-3.1.7.tgz
tar xzf EasyRSA-3.1.7.tgz
mv EasyRSA-3.1.7/* easy-rsa/
rm -rf EasyRSA-3.1.7.tgz

cd $EASYRSA_DIR
./easyrsa init-pki
echo | ./easyrsa build-ca nopass

# ========== 3. 生成 server 证书 ==========
./easyrsa gen-dh
./easyrsa gen-req server nopass
./easyrsa sign-req server server

# ========== 4. 生成 client 证书 ==========
./easyrsa gen-req client nopass
./easyrsa sign-req client client

# ========== 5. 生成 server.conf ==========
WAN_IF=$(ip route get 1.1.1.1 | awk '/dev/ {print $5}')
[[ -z $WAN_IF ]] && WAN_IF=$(ip -6 route get 240c::6666 | awk '/dev/ {print $5}')

cat >/etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca $EASYRSA_DIR/pki/ca.crt
cert $EASYRSA_DIR/pki/issued/server.crt
key $EASYRSA_DIR/pki/private/server.key
dh $EASYRSA_DIR/pki/dh.pem
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-GCM
user nobody
group nogroup
persist-key
persist-tun
status /var/log/openvpn-status.log
verb 3
EOF

systemctl enable openvpn@server
systemctl restart openvpn@server

# ========== 6. 生成 client.ovpn ==========
CLIENT_FILE="/root/client.ovpn"
SERVER_IP=$(curl -s4 ip.sb || curl -s6 ip.sb)

cat > $CLIENT_FILE <<EOF
client
dev tun
proto udp
remote $SERVER_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
verb 3

<ca>
$(cat $EASYRSA_DIR/pki/ca.crt)
</ca>
<cert>
$(cat $EASYRSA_DIR/pki/issued/client.crt)
</cert>
<key>
$(cat $EASYRSA_DIR/pki/private/client.key)
</key>
EOF

echo
echo "出口服务器 client.ovpn 已生成： $CLIENT_FILE"

# ========== 7. 询问是否上传 ==========
read -p "是否上传 client.ovpn 到入口服务器？(y/n): " UP

if [[ $UP != "y" ]]; then
    echo "已跳过上传。"
    exit 0
fi

# 输入入口服务器信息
read -p "入口服务器 IP（支持 IPv4 / IPv6）: " INIP
read -p "入口 SSH 端口 (默认22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}
read -p "入口 SSH 用户（默认 root）: " SSH_USER
SSH_USER=${SSH_USER:-root}
read -p "入口服务器 SSH 密码: " SSH_PASS

echo ">>> 清理入口服务器 known_hosts 冲突..."
ssh-keygen -R "[$INIP]:$SSH_PORT" >/dev/null 2>&1 || true

echo ">>> 等待入口服务器 SSH 稳定..."
sleep 3

echo ">>> 开始使用 SSH 管道上传 client.ovpn（最稳定方式）"

sshpass -p "$SSH_PASS" ssh -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ${SSH_USER}@${INIP} "cat > /root/client.ovpn" < /root/client.ovpn

if [[ $? -eq 0 ]]; then
    echo "=============================="
    echo "✔ 文件上传成功！"
    echo "=============================="
else
    echo "=============================="
    echo "❌ 上传失败，请检查 SSH 信息"
    echo "=============================="
fi

echo "OpenVPN 出口服务器部署完成！"

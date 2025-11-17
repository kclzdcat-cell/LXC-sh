#!/bin/bash
# ===============================================
#  OpenVPN 出口服务器 自动部署脚本（安全版）
#  绝不会影响入口服务器默认网关
# ===============================================

echo "========== OpenVPN 出口服务器安装开始 =========="

apt update -y
apt install openvpn easy-rsa sshpass -y

# -----------------------------------------------
# 创建 Easy-RSA 目录
# -----------------------------------------------
make-cadir /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa

#-----------------------------
# 初始化 PKI
#-----------------------------
./easyrsa init-pki
EASYRSA_BATCH=1 ./easyrsa build-ca nopass

#-----------------------------
# 生成服务端证书
#-----------------------------
EASYRSA_BATCH=1 ./easyrsa gen-req server nopass
EASYRSA_BATCH=1 ./easyrsa sign-req server server

#-----------------------------
# 生成客户端证书（client）
#-----------------------------
EASYRSA_BATCH=1 ./easyrsa gen-req client nopass
EASYRSA_BATCH=1 ./easyrsa sign-req client client

#-----------------------------
# 生成 DH 参数
#-----------------------------
./easyrsa gen-dh

#-----------------------------
# 生成 TLS 密钥
#-----------------------------
openvpn --genkey secret /etc/openvpn/ta.key

# 复制文件到 OpenVPN 目录
cp pki/ca.crt pki/issued/server.crt pki/private/server.key \
   pki/dh.pem /etc/openvpn/

# -----------------------------------------------
# 写入服务端配置
# -----------------------------------------------
cat >/etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
auth SHA256
tls-auth ta.key 0
topology subnet
server 10.8.0.0 255.255.255.0

# 让入口服务器访问出口服务器所在的公网
push "route 0.0.0.0 0.0.0.0"

keepalive 10 120
persist-key
persist-tun
duplicate-cn
verb 3
EOF

# -----------------------------
# 开启 NAT
# -----------------------------
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-openvpn.conf
sysctl -p

# NAT 规则
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$(ip route get 8.8.8.8 | awk '{print $5}')" -j MASQUERADE
apt install iptables-persistent -y

# -----------------------------
# 启动 OpenVPN
# -----------------------------
systemctl enable openvpn@server
systemctl restart openvpn@server

# -----------------------------
# 生成 client.ovpn
# -----------------------------
cat >/root/client.ovpn <<EOF
client
dev tun
proto udp
remote $(curl -4 -s ifconfig.me) 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
key-direction 1

<ca>
$(cat /etc/openvpn/ca.crt)
</ca>

<cert>
$(cat /etc/openvpn/easy-rsa/pki/issued/client.crt)
</cert>

<key>
$(cat /etc/openvpn/easy-rsa/pki/private/client.key)
</key>

<tls-auth>
$(cat /etc/openvpn/ta.key)
</tls-auth>
EOF

echo "========== 客户端文件已生成：/root/client.ovpn =========="

# -----------------------------
# 上传 client.ovpn 到入口服务器
# -----------------------------
read -p "请输入入口服务器 IP: " INIP
read -p "请输入入口服务器 SSH 用户名: " INUSER
read -s -p "请输入入口服务器 SSH 密码: " INPASS
echo ""

sshpass -p "$INPASS" scp -o StrictHostKeyChecking=no /root/client.ovpn ${INUSER}@${INIP}:/root/

echo ">>> 上传完成！client.ovpn 已放到入口服务器的 /root/ 目录"

echo "========== 出口服务器部署完成 =========="

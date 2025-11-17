#!/bin/bash
# ==========================================
# OpenVPN 出口服务器一键安装脚本
# 适用于：Ubuntu/Debian（含 Debian 12）
# 作者：ChatGPT（优化增强版）
# ==========================================

set -e

echo "=== OpenVPN 出口服务器 自动部署开始 ==="

# 获取服务器公网 IP
SERVER_IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)

echo "出口服务器公网 IP: $SERVER_IP"

# 安装依赖
apt update
apt install -y openvpn easy-rsa iptables iptables-persistent curl

# 创建 Easy-RSA 目录
mkdir -p /etc/openvpn/easy-rsa
ln -sf /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/
cd /etc/openvpn/easy-rsa

# 初始化 PKI
./easyrsa init-pki

# 构建 CA（无密码）
echo -ne "\n" | ./easyrsa build-ca nopass

# 生成服务器证书请求
echo -ne "\n" | ./easyrsa gen-req server nopass

# 签署服务器证书
echo -ne "yes\n" | ./easyrsa sign-req server server

# 生成 Diffie-Hellman
./easyrsa gen-dh

# 创建 HMAC key（防止攻击）
openvpn --genkey --secret ta.key

# 拷贝证书与密钥
cp pki/ca.crt /etc/openvpn/
cp pki/issued/server.crt /etc/openvpn/
cp pki/private/server.key /etc/openvpn/
cp pki/dh.pem /etc/openvpn/
cp ta.key /etc/openvpn/

# 生成服务端配置文件
cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun

ca ca.crt
cert server.crt
key server.key 
dh dh.pem
tls-auth ta.key 0

server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"

keepalive 10 120
cipher AES-256-CBC
auth SHA256
user nobody
group nogroup
persist-key
persist-tun
status openvpn-status.log
verb 3
EOF

# 开启 IPv4 转发
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
sysctl -p /etc/sysctl.d/99-openvpn.conf

# 自动设置 NAT（自动检测出口网卡）
WAN_IF=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $WAN_IF -j MASQUERADE

# 保存 iptables
netfilter-persistent save

# 启动 OpenVPN 服务
systemctl enable openvpn@server
systemctl restart openvpn@server

# 检查服务状态
if systemctl is-active --quiet openvpn@server; then
    echo "=== OpenVPN 出口服务器部署成功！==="
else
    echo "❌ OpenVPN 启动失败，请检查："
    echo "journalctl -xeu openvpn@server"
    exit 1
fi

# 生成客户端配置模板
cat > /root/client.ovpn <<EOF
client
dev tun
proto udp
remote $SERVER_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
auth SHA256
key-direction 1
verb 3

<ca>
$(cat /etc/openvpn/ca.crt)
</ca>
<tls-auth>
$(cat /etc/openvpn/ta.key)
</tls-auth>
EOF

echo "客户端模板已生成：/root/client.ovpn"
echo "==== 全部完成 ===="

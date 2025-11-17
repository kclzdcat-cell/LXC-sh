#!/bin/bash
set -e

echo "===================================="
echo " OpenVPN 出口服务器自动部署脚本"
echo " 自动生成 client.ovpn 并上传到入口服务器"
echo "===================================="

# 输入入口服务器信息
read -p "请输入入口服务器 IP: " IN_IP
while [[ -z "$IN_IP" ]]; do
    echo "入口服务器 IP 不能为空！"
    read -p "请输入入口服务器 IP: " IN_IP
done

read -p "请输入入口服务器 SSH 用户名（默认 root）: " IN_USER
IN_USER=${IN_USER:-root}

read -s -p "请输入入口服务器 SSH 密码: " IN_PASS
echo ""
while [[ -z "$IN_PASS" ]]; do
    echo "密码不能为空！"
    read -s -p "请输入入口服务器 SSH 密码: " IN_PASS
    echo ""
done

echo "入口服务器信息确认："
echo "  IP: $IN_IP"
echo "  用户: $IN_USER"
echo "------------------------------------"

apt update -y
apt install -y openvpn easy-rsa sshpass iptables-persistent

# 初始化 Easy-RSA
make-cadir /etc/openvpn/easy-rsa || true
cd /etc/openvpn/easy-rsa
./easyrsa init-pki
echo "yes" | ./easyrsa build-ca nopass
./easyrsa gen-dh
./easyrsa build-server-full server nopass
./easyrsa build-client-full client nopass
./easyrsa gen-crl

# 拷贝到 OpenVPN 目录
cp pki/ca.crt /etc/openvpn/
cp pki/dh.pem /etc/openvpn/
cp pki/issued/server.crt /etc/openvpn/
cp pki/private/server.key /etc/openvpn/
cp pki/crl.pem /etc/openvpn/

# 生成 server.conf
cat >/etc/openvpn/server.conf <<EOF
port 51820
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
crl-verify crl.pem
server 10.10.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
cipher AES-256-GCM
user nobody
group nogroup
persist-key
persist-tun
status openvpn-status.log
log-append /var/log/openvpn.log
verb 3
EOF

# 启用 NAT
echo 1 >/proc/sys/net/ipv4/ip_forward
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p

iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -o $(ip route | grep default | awk '{print $5}') -j MASQUERADE
netfilter-persistent save

# 生成 client.ovpn
CLIENT_CONF="/root/client.ovpn"

cat >"$CLIENT_CONF" <<EOF
client
dev tun
proto udp
remote $IN_IP 51820
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
verb 3

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

systemctl enable openvpn@server
systemctl restart openvpn@server

echo ""
echo "======================================="
echo " OpenVPN 出口服务器部署成功！"
echo " 客户端配置文件：$CLIENT_CONF"
echo "======================================="
echo ""

# 自动上传到入口服务器
echo ">>> 正在将 client.ovpn 上传到入口服务器..."

sshpass -p "$IN_PASS" scp -o StrictHostKeyChecking=no "$CLIENT_CONF" ${IN_USER}@${IN_IP}:/root/ \
    && echo ">>> 上传成功！文件已存放在入口服务器 /root/client.ovpn" \
    || echo ">>> 上传失败！请检查网络与密码是否正确。"

echo ""
echo "======================================="
echo " 脚本执行完毕"
echo "======================================="

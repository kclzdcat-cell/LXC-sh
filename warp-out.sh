#!/bin/bash

green()  { echo -e "\033[32m$1\033[0m"; }
red()    { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

clear
echo "======================================================="
echo " OpenVPN 出口服务器自动部署脚本 (IPv6 入站 + WARP IPv4 出站)"
echo "======================================================="

#---------------- 系统检测 ----------------#
if [[ -f /etc/debian_version ]]; then
    OS="debian"
    apt update -y
    apt install -y openvpn easy-rsa iptables iptables-persistent curl
elif [[ -f /etc/lsb-release ]]; then
    OS="ubuntu"
    apt update -y
    apt install -y openvpn easy-rsa iptables iptables-persistent curl
else
    red "不支持的系统！仅支持 Debian / Ubuntu"
    exit 1
fi

#---------------- 检测网卡 ----------------#
NIC=$(ip route get 2001:4860:4860::8888 2>/dev/null | awk '/dev/ {print $5; exit}')
if [[ -z "$NIC" ]]; then
    NIC=$(ip -6 -o addr show scope global | awk '{print $2}' | head -n1)
fi

green "出口网卡: $NIC"

#---------------- 检测入口可连 IPv6 ----------------#
OUT_IPV6=$(ip -6 -o addr show dev "$NIC" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)

if [[ -z "$OUT_IPV6" ]]; then
    red "未检测到出口服务器可用 IPv6 地址！无法用于入口连接！"
    exit 1
fi

green "出口服务器入站 IPv6: $OUT_IPV6"

#---------------- 配置 Easy-RSA ----------------#
mkdir -p /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa

# 自动删除旧 PKI
rm -rf /etc/openvpn/easy-rsa/pki
mkdir -p /etc/openvpn/easy-rsa/pki

cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/

# 强制初始化 PKI（不会出现 yes 提示）
echo "" | ./easyrsa init-pki

# 建 CA（无交互）
echo -e "server\n" | ./easyrsa build-ca nopass

# 生成服务器证书（无交互）
echo -e "server\n" | ./easyrsa build-server-full server nopass

# 生成客户端证书（无交互）
echo -e "client\n" | ./easyrsa build-client-full client nopass

# 生成 Diffie-Hellman
./easyrsa gen-dh

#---------------- 创建 OpenVPN server.conf（双协议） ----------------#
mkdir -p /etc/openvpn/server

cat >/etc/openvpn/server/server.conf <<EOF
port 1194
proto udp6
dev tun
ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
dh /etc/openvpn/easy-rsa/pki/dh.pem
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
persist-key
persist-tun
user nobody
group nogroup
cipher AES-256-GCM
auth SHA256
verb 3
EOF

# TCP 443
cat >/etc/openvpn/server/server-tcp.conf <<EOF
port 443
proto tcp6
dev tun
ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
dh /etc/openvpn/easy-rsa/pki/dh.pem
server 10.9.0.0 255.255.255.0
push "redirect-gateway def1"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
persist-key
persist-tun
user nobody
group nogroup
cipher AES-256-GCM
auth SHA256
verb 3
EOF

# 启动服务
systemctl enable openvpn@server
systemctl enable openvpn@server-tcp
systemctl restart openvpn@server
systemctl restart openvpn@server-tcp

#---------------- NAT 与 IPv6/IPv4 转发 ----------------#
echo 1 >/proc/sys/net/ipv4/ip_forward
echo 1 >/proc/sys/net/ipv6/conf/all/forwarding

iptables -t nat -A POSTROUTING -o "$NIC" -j MASQUERADE
ip6tables -t nat -A POSTROUTING -o "$NIC" -j MASQUERADE

netfilter-persistent save

#---------------- 生成 client.ovpn ----------------#
CLIENT_OVPN="/root/client.ovpn"

cat >$CLIENT_OVPN <<EOF
client
dev tun
proto udp6
remote $OUT_IPV6 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
verb 3

<ca>
$(cat /etc/openvpn/easy-rsa/pki/ca.crt)
</ca>

<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' /etc/openvpn/easy-rsa/pki/issued/client.crt)
</cert>

<key>
$(cat /etc/openvpn/easy-rsa/pki/private/client.key)
</key>
EOF

green "client.ovpn 已生成: $CLIENT_OVPN"

#---------------- 可选：上传到入口服务器 ----------------#
read -p "是否自动上传 client.ovpn 到入口服务器？(y/n): " UP

if [[ $UP == "y" ]]; then
    read -p "入口服务器 IP: " IN_IP
    read -p "SSH 用户名 (默认 root): " IN_USER
    IN_USER=${IN_USER:-root}
    read -p "SSH 端口 (默认 22): " IN_PORT
    IN_PORT=${IN_PORT:-22}

    scp -P $IN_PORT $CLIENT_OVPN ${IN_USER}@${IN_IP}:/root/client.ovpn
    green "已成功上传到入口服务器！"
fi

green "======================================================="
green "   出口服务器 OpenVPN 部署完毕 (支持 IPv6 入站 + WARP IPv4 出站)"
green "   入口服务器运行 in.sh 即可完成对接"
green "======================================================="

#!/bin/bash
echo "=== OpenVPN 出口服务器自动部署脚本 ==="
echo "网卡自动检测..."

NIC=$(ip route show default | awk '{print $5}' | head -1)
echo "检测到出口网卡: $NIC"

echo "=== 1. 安装 OpenVPN 与 Easy-RSA ==="
apt update -y
apt install -y openvpn easy-rsa iptables

echo "=== 2. 初始化 OpenVPN ==="
make-cadir /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa

./easyrsa init-pki
echo -ne "\n" | ./easyrsa build-ca nopass
./easyrsa gen-dh
./easyrsa build-server-full server nopass
./easyrsa build-client-full client nopass
./easyrsa gen-crl

cd /etc/openvpn/easy-rsa/pki
cp ca.crt issued/server.crt private/server.key dh.pem /etc/openvpn/
cp issued/client.crt private/client.key /etc/openvpn/

echo "=== 3. 生成服务端配置 ==="
cat >/etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dh

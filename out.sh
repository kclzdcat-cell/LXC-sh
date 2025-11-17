#!/bin/bash
set -e

echo "==========================================="
echo "     OpenVPN 出口服务器自动部署脚本 V10.0"
echo "==========================================="

# ----------- 公网 IP -----------
PUB_IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
echo "出口服务器公网 IP: $PUB_IP"

# ----------- 自动检测网卡 -----------
NIC=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
echo "检测到出网网卡: $NIC"

apt update -y
apt install -y openvpn easy-rsa sshpass iptables-persistent net-tools

mkdir -p /etc/openvpn/server
mkdir -p /etc/openvpn/easy-rsa
cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/

cd /etc/openvpn/easy-rsa

echo ">>> 初始化 CA ..."
./easyrsa init-pki
yes "" | ./easyrsa build-ca nopass

echo ">>> 生成服务器证书 ..."
yes "" | ./easyrsa build-server-full server nopass

echo ">>> 生成 Diffie-Hellman ..."
./easyrsa gen-dh

echo ">>> 生成客户端证书 ..."
yes "" | ./easyrsa build-client-full client nopass

# ----------- 复制密钥 -----------
cp pki/ca.crt /etc/openvpn/server/
cp pki/dh.pem /etc/openvpn/server/
cp pki/private/server.key /etc/openvpn/server/
cp pki/issued/server.crt /etc/openvpn/server/
cp pki/private/client.key /etc/openvpn/server/
cp pki/issued/client.crt /etc/openvpn/server/

# ----------- 自动检测 UDP/TCP 端口 -----------
find_free_port() {
  local PORT=$1
  while ss -tuln | grep -q ":$PORT "; do
    PORT=$((PORT+1))
  done
  echo $PORT
}

UDP_PORT=$(find_free_port 1194)
TCP_PORT=$(find_free_port 443)

echo "UDP 端口: $UDP_PORT"
echo "TCP 端口: $TCP_PORT"

# ----------- server.conf（UDP）-----------
cat >/etc/openvpn/server/server.conf <<EOF
port $UDP_PORT
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem

server 10.8.0.0 255.255.255.0
keepalive 10 120
data-ciphers AES-256-GCM:AES-256-CBC
auth SHA256

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"

persist-key
persist-tun
user nobody
group nogroup
status openvpn-status.log
verb 3
EOF

# ----------- server-tcp.conf（TCP） -----------
cat >/etc/openvpn/server/server-tcp.conf <<EOF
port $TCP_PORT
proto tcp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem

server 10.9.0.0 255.255.255.0
keepalive 10 120
data-ciphers AES-256-GCM:AES-256-CBC
auth SHA256

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"

persist-key
persist-tun
user nobody
group nogroup
status openvpn-status-tcp.log
verb 3
EOF

echo ">>> 开启 NAT & 转发 ..."

echo 1 >/proc/sys/net/ipv4/ip_forward
sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf

iptables -t nat -A POSTROUTING -s 10.8.0.0/16 -o $NIC -j MASQUERADE
iptables-save >/etc/iptables/rules.v4

echo ">>> 启动 OpenVPN 服务端 ..."

systemctl enable openvpn-server@server
systemctl restart openvpn-server@server

systemctl enable openvpn-server@server-tcp
systemctl restart openvpn-server@server-tcp

# ----------- 生成 client.ovpn（包含 UDP + TCP）-----------
CLIENT_FILE="/root/client.ovpn"

cat >$CLIENT_FILE <<EOF
client
dev tun
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
cipher AES-256-GCM
auth-nocache
resolv-retry infinite

# UDP + TCP 双协议自动支持
remote $PUB_IP $UDP_PORT udp
remote $PUB_IP $TCP_PORT tcp

<ca>
$(cat /etc/openvpn/server/ca.crt)
</ca>

<cert>
$(cat /etc/openvpn/server/client.crt)
</cert>

<key>
$(cat /etc/openvpn/server/client.key)
</key>
EOF

echo "client.ovpn 生成完成：/root/client.ovpn"

# ----------- 上传到入口服务器 -----------
echo
echo "请输入入口服务器 SSH 信息用于上传 client.ovpn"
read -p "入口服务器 IP：" IN_IP
read -p "入口 SSH 端口(默认22)：" IN_PORT
IN_PORT=${IN_PORT:-22}
read -p "入口 SSH 用户名(默认root)：" IN_USER
IN_USER=${IN_USER:-root}
read -p "入口 SSH 密码：" IN_PASS

sshpass -p "$IN_PASS" scp -P $IN_PORT -o StrictHostKeyChecking=no $CLIENT_FILE $IN_USER@$IN_IP:/root/

echo
echo "上传成功！入口服务器 /root/client.ovpn 已更新"
echo "出口服务器部署完成！"
echo "==========================================="

#!/bin/bash
set -e

echo "==========================================="
echo "  OpenVPN 出口服务器自动部署脚本 V10.1 (稳定版)"
echo "==========================================="

# ----------- 公网 IP -----------
PUB_IP=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
echo "出口服务器公网 IP: $PUB_IP"

# ----------- 自动检测网卡 -----------
NIC=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
echo "检测到出网网卡: $NIC"

apt update -y
apt install -y openvpn easy-rsa sshpass iptables-persistent net-tools curl

# ----------- 安全删除旧 pki（否则会触发交互导致失败）-----------
rm -rf /etc/openvpn/easy-rsa
mkdir -p /etc/openvpn/easy-rsa
cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/

cd /etc/openvpn/easy-rsa

# ----------- 强制非交互模式（关键修复）-----------
export EASYRSA_BATCH=1
export EASYRSA_REQ_CN="server"

echo ">>> 初始化 PKI ..."
./easyrsa init-pki

echo ">>> 生成 CA（无密码） ..."
./easyrsa build-ca nopass

echo ">>> 生成服务器证书 ..."
./easyrsa build-server-full server nopass

echo ">>> 生成 Diffie-Hellman ..."
./easyrsa gen-dh

echo ">>> 生成客户端证书 ..."
export EASYRSA_REQ_CN="client"
./easyrsa build-client-full client nopass

# ----------- 拷贝证书文件 -----------
cp pki/ca.crt /etc/openvpn/
cp pki/dh.pem /etc/openvpn/
cp pki/issued/server.crt /etc/openvpn/
cp pki/private/server.key /etc/openvpn/
cp pki/issued/client.crt /etc/openvpn/
cp pki/private/client.key /etc/openvpn/

# ----------- 自动检测端口 -----------
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

# ----------- server.conf (UDP) -----------
cat >/etc/openvpn/server.conf <<EOF
port $UDP_PORT
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem

server 10.8.0.0 255.255.255.0
keepalive 10 120
cipher AES-256-GCM
auth SHA256

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"

persist-key
persist-tun
verb 3
EOF

# ----------- server-tcp.conf (TCP) -----------
cat >/etc/openvpn/server-tcp.conf <<EOF
port $TCP_PORT
proto tcp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem

server 10.9.0.0 255.255.255.0
keepalive 10 120
cipher AES-256-GCM
auth SHA256

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"

persist-key
persist-tun
verb 3
EOF

# ----------- 开启 NAT 转发 -----------
echo 1 >/proc/sys/net/ipv4/ip_forward
sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf

iptables -t nat -A POSTROUTING -s 10.8.0.0/16 -o $NIC -j MASQUERADE
iptables-save >/etc/iptables/rules.v4

# ----------- 启动 OpenVPN -----------
systemctl enable openvpn@server
systemctl restart openvpn@server

systemctl enable openvpn@server-tcp
systemctl restart openvpn@server-tcp

# ----------- 生成 client.ovpn -----------
CLIENT="/root/client.ovpn"

cat >$CLIENT <<EOF
client
dev tun
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
auth-nocache
resolv-retry infinite

remote $PUB_IP $UDP_PORT udp
remote $PUB_IP $TCP_PORT tcp

<ca>
$(cat /etc/openvpn/ca.crt)
</ca>

<cert>
$(cat /etc/openvpn/client.crt)
</cert>

<key>
$(cat /etc/openvpn/client.key)
</key>
EOF

echo "client.ovpn 生成成功：/root/client.ovpn"

# ----------- 上传到入口服务器 -----------
echo "请输入入口服务器 SSH 信息："
read -p "入口 IP：" IN_IP
read -p "入口端口(默认22)：" IN_PORT
IN_PORT=${IN_PORT:-22}
read -p "入口 SSH 用户(默认root)：" IN_USER
IN_USER=${IN_USER:-root}
read -p "入口 SSH 密码：" IN_PASS

sshpass -p "$IN_PASS" scp -P $IN_PORT -o StrictHostKeyChecking=no $CLIENT $IN_USER@$IN_IP:/root/

echo "上传成功！出口服务器部署完毕！"
echo "==========================================="

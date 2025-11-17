#!/bin/bash
set -e

echo "==========================================="
echo " OpenVPN 出口服务器自动部署脚本 V12（IPv4 + IPv6 双栈）"
echo "==========================================="

#----------- 检测出口 IPv4 / IPv6 -----------
PUB_IP4=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
PUB_IP6=$(curl -s ipv6.ip.sb || echo "")

echo "出口 IPv4: $PUB_IP4"
echo "出口 IPv6: ${PUB_IP6:-未检测到 IPv6}"

#----------- 检测网卡 -----------
NIC=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
echo "出口网卡: $NIC"

apt update -y
apt install -y openvpn easy-rsa sshpass iptables-persistent curl

#----------- 重建 PKI -----------
rm -rf /etc/openvpn/easy-rsa
mkdir -p /etc/openvpn/easy-rsa
cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/
cd /etc/openvpn/easy-rsa

export EASYRSA_BATCH=1

echo ">>> 初始化 PKI ..."
./easyrsa init-pki

echo ">>> 生成 CA ..."
./easyrsa build-ca nopass

echo ">>> 生成服务器证书 ..."
./easyrsa build-server-full server nopass

echo ">>> 生成客户端证书 ..."
./easyrsa build-client-full client nopass

echo ">>> 生成 DH 参数 ..."
./easyrsa gen-dh

#----------- 拷贝证书 -----------
cp pki/ca.crt /etc/openvpn/
cp pki/dh.pem /etc/openvpn/
cp pki/issued/server.crt /etc/openvpn/
cp pki/private/server.key /etc/openvpn/
cp pki/issued/client.crt /etc/openvpn/
cp pki/private/client.key /etc/openvpn/

#----------- 查找空闲端口 -----------
find_free_port() {
  p=$1
  while ss -tuln | grep -q ":$p "; do
    p=$((p+1))
  done
  echo $p
}

UDP_PORT=$(find_free_port 1194)
TCP_PORT=$(find_free_port 443)

echo "UDP端口 = $UDP_PORT"
echo "TCP端口 = $TCP_PORT"

#----------- 启用 IPv4 / IPv6 转发 -----------

echo 1 >/proc/sys/net/ipv4/ip_forward
sed -i 's/^#*net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf

echo 1 >/proc/sys/net/ipv6/conf/all/forwarding || true
sed -i 's/^#*net.ipv6.conf.all.forwarding=.*/net.ipv6.conf.all.forwarding=1/' /etc/sysctl.conf || true

#----------- 配置 NAT (IPv4) -----------
iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -o $NIC -j MASQUERADE

#----------- 配置 NAT (IPv6) 可用才启用 -----------
HAS_IPV6=0
if [[ -n "$PUB_IP6" ]]; then
    if command -v ip6tables >/dev/null; then
        HAS_IPV6=1
        echo "检测到 IPv6，启用 IPv6 NAT..."
        ip6tables -t nat -A POSTROUTING -s fd00:1234::/64 -o $NIC -j MASQUERADE || true
    fi
fi

iptables-save >/etc/iptables/rules.v4
ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true

#----------- server.conf（UDP）-----------
cat >/etc/openvpn/server.conf <<EOF
port $UDP_PORT
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem

server 10.8.0.0 255.255.255.0
server-ipv6 fd00:1234::/64

push "redirect-gateway def1 ipv6 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS6 2620:119:35::35"
push "dhcp-option DNS6 2606:4700:4700::1111"

keepalive 10 120
cipher AES-256-GCM
auth SHA256
persist-key
persist-tun
verb 3
EOF

#----------- server-tcp.conf（TCP）-----------
cat >/etc/openvpn/server-tcp.conf <<EOF
port $TCP_PORT
proto tcp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem

server 10.9.0.0 255.255.255.0
server-ipv6 fd00:1234::/64

push "redirect-gateway def1 ipv6 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS6 2620:119:35::35"
push "dhcp-option DNS6 2606:4700:4700::1111"

keepalive 10 120
cipher AES-256-GCM
auth SHA256
persist-key
persist-tun
verb 3
EOF

#----------- 启动服务 -----------
systemctl enable openvpn@server
systemctl restart openvpn@server
systemctl enable openvpn@server-tcp
systemctl restart openvpn@server-tcp

#----------- 生成 client.ovpn -----------
CLIENT=/root/client.ovpn
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

remote $PUB_IP4 $UDP_PORT udp
remote $PUB_IP4 $TCP_PORT tcp
EOF

# 自动加入 IPv6 远程
if [[ $HAS_IPV6 -eq 1 ]]; then
cat >>$CLIENT <<EOF
remote $PUB_IP6 $UDP_PORT udp
remote $PUB_IP6 $TCP_PORT tcp
EOF
fi

cat >>$CLIENT <<EOF

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

echo "client.ovpn 已生成：/root/client.ovpn"

#----------- 上传到入口服务器 -----------
echo "请输入入口服务器 SSH 信息："
read -p "入口 IP：" IN_IP
read -p "入口端口(默认22)：" IN_PORT
IN_PORT=${IN_PORT:-22}
read -p "入口 SSH 用户(默认root)：" IN_USER
IN_USER=${IN_USER:-root}
read -p "入口 SSH 密码：" IN_PASS

sshpass -p "$IN_PASS" scp -P $IN_PORT -o StrictHostKeyChecking=no $CLIENT $IN_USER@$IN_IP:/root/

echo "上传成功！出口服务器部署完成！"
echo "==========================================="

#!/bin/bash
set -e

echo "==========================================="
echo " OpenVPN 出口服务器自动部署脚本（最终稳定版）"
echo " 完全兼容 OpenVPN 2.6+"
echo " 自动识别公网 IPv6（不依赖 curl，不会失败）"
echo " 只使用 IPv6 作为入口，IPv4 不写入（避免 10.x.x.x 和 WARP）"
echo " IPv4+IPv6 NAT，自带 client.ovpn 自动上传"
echo "==========================================="

#======================================================
#   自动检测公网 IPv6（不依赖 curl，永不失败）
#======================================================
PUB_IP6=$(ip -6 addr show | grep global | grep -v temporary | awk '{print $2}' | cut -d'/' -f1 | head -n 1)

if [[ -z "$PUB_IP6" ]]; then
    echo "❌ 未检测到公网 IPv6，此服务器不能作为出口服务器。"
    exit 1
fi

echo "出口服务器公网 IPv6: $PUB_IP6"

#======================================================
#   获取出口网卡
#======================================================
NIC=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
NIC=${NIC:-eth0}

echo "检测到默认出口网卡: $NIC"

apt update -y
apt install -y openvpn easy-rsa sshpass iptables-persistent

#======================================================
#   构建 PKI
#======================================================
rm -rf /etc/openvpn/easy-rsa
mkdir -p /etc/openvpn/easy-rsa
cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/
cd /etc/openvpn/easy-rsa

export EASYRSA_BATCH=1
./easyrsa init-pki
./easyrsa build-ca nopass
./easyrsa build-server-full server nopass
./easyrsa build-client-full client nopass
./easyrsa gen-dh
openvpn --genkey secret ta.key

cp pki/ca.crt /etc/openvpn/
cp pki/dh.pem /etc/openvpn/
cp pki/issued/server.crt /etc/openvpn/
cp pki/private/server.key /etc/openvpn/
cp pki/issued/client.crt /etc/openvpn/
cp pki/private/client.key /etc/openvpn/
cp ta.key /etc/openvpn/

#======================================================
#   固定端口
#======================================================
UDP_PORT=1196
TCP_PORT=443

echo "使用 UDP 端口: $UDP_PORT"
echo "使用 TCP 端口: $TCP_PORT"

#======================================================
#   启用 IPv4/IPv6 转发
#======================================================
echo 1 >/proc/sys/net/ipv4/ip_forward
sed -i 's/^#*net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf

echo 1 >/proc/sys/net/ipv6/conf/all/forwarding
sed -i 's/^#*net.ipv6.conf.all.forwarding=.*/net.ipv6.conf.all.forwarding=1/' /etc/sysctl.conf

#======================================================
#   NAT 设置
#======================================================
iptables -t nat -A POSTROUTING -s 10.8.0.0/16 -o $NIC -j MASQUERADE
ip6tables -t nat -A POSTROUTING -s fd00:1234::/64 -o $NIC -j MASQUERADE || true

iptables-save >/etc/iptables/rules.v4
ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true

#======================================================
#   server.conf（UDP）
#======================================================
cat >/etc/openvpn/server.conf <<EOF
port $UDP_PORT
proto udp
dev tun
topology subnet
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-crypt ta.key
server 10.8.0.0 255.255.255.0
server-ipv6 fd00:1234::/64
push "redirect-gateway def1 ipv6 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS6 2606:4700:4700::1111"
cipher AES-256-GCM
auth SHA256
persist-key
persist-tun
explicit-exit-notify 1
verb 3
EOF

#======================================================
#   server-tcp.conf（TCP）
#======================================================
cat >/etc/openvpn/server-tcp.conf <<EOF
port $TCP_PORT
proto tcp
dev tun
topology subnet
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-crypt ta.key
server 10.9.0.0 255.255.255.0
server-ipv6 fd00:1234::/64
push "redirect-gateway def1 ipv6 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS6 2606:4700:4700::1111"
cipher AES-256-GCM
auth SHA256
persist-key
persist-tun
verb 3
EOF

systemctl enable openvpn@server
systemctl restart openvpn@server

systemctl enable openvpn@server-tcp
systemctl restart openvpn@server-tcp

#======================================================
#   生成 client.ovpn（只写公网 IPv6）
#======================================================
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

remote $PUB_IP6 $UDP_PORT udp-client
remote $PUB_IP6 $TCP_PORT tcp-client

<ca>
$(cat /etc/openvpn/ca.crt)
</ca>

<cert>
$(cat /etc/openvpn/client.crt)
</cert>

<key>
$(cat /etc/openvpn/client.key)
</key>

<tls-crypt>
$(cat /etc/openvpn/ta.key)
</tls-crypt>
EOF

echo "client.ovpn 已生成：/root/client.ovpn"

#======================================================
#   自动上传 client.ovpn
#======================================================
echo
echo "================= 上传 client.ovpn 到入口服务器 ================="
echo

read -p "入口服务器 IP（IPv4/IPv6）： " IN_IP
read -p "入口 SSH 端口（默认 22）： " IN_PORT
IN_PORT=${IN_PORT:-22}
read -p "入口 SSH 用户（默认 root）： " IN_USER
IN_USER=${IN_USER:-root}
read -p "入口 SSH 密码： " IN_PASS

ssh-keygen -R "$IN_IP" >/dev/null 2>&1 || true

for i in 1 2 3; do
    echo "第 $i 次上传..."
    if sshpass -p "$IN_PASS" scp -6 -P $IN_PORT -o StrictHostKeyChecking=no $CLIENT ${IN_USER}@[$IN_IP]:/root/ 2>/dev/null; then
        echo "上传成功（IPv6）！"
        break
    fi
    if sshpass -p "$IN_PASS" scp -4 -P $IN_PORT -o StrictHostKeyChecking=no $CLIENT ${IN_USER}@$IN_IP:/root/ 2>/dev/null; then
        echo "上传成功（IPv4）！"
        break
    fi
    sleep 1
done

echo "======================================================="
echo " OpenVPN 出口服务器部署完成!"
echo " client.ovpn 已上传（如显示成功）"
echo "======================================================="

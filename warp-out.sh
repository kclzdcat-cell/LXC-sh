#!/bin/bash
set -e

echo "======================================"
echo " OpenVPN 出口服务器自动部署脚本"
echo " IPv6 入站 + WARP IPv4 出站"
echo "======================================"


# ---------------------------------------------------------
# 1. 自动检测出口网卡
# ---------------------------------------------------------
OUT_IF=$(ip -o -6 addr show | awk '/global/ {print $2; exit}')
echo "出口网卡: $OUT_IF"

if [[ -z "$OUT_IF" ]]; then
    echo "❌ 未检测到出口网卡（IPv6），无法继续"
    exit 1
fi


# ---------------------------------------------------------
# 2. 自动检测出口 IPv6 入站地址
# ---------------------------------------------------------
OUT_IPV6=$(ip -6 addr show dev $OUT_IF | awk '/global/ {print $2; exit}' | cut -d'/' -f1)

echo "检测到出口服务器 IPv6 入站: $OUT_IPV6"
read -p "如需手动修改请输入新 IPv6（回车默认自动检测）: " CUSTOM_IPV6
[[ -n "$CUSTOM_IPV6" ]] && OUT_IPV6=$CUSTOM_IPV6

if [[ -z "$OUT_IPV6" ]]; then
    echo "❌ 无有效 IPv6 入站地址，无法部署"
    exit 1
fi

echo "最终将使用 IPv6: $OUT_IPV6"


# ---------------------------------------------------------
# 3. 安装 OpenVPN + Easy-RSA
# ---------------------------------------------------------
apt update -y
apt install -y openvpn easy-rsa iptables iptables-persistent curl


# ---------------------------------------------------------
# 4. 清理旧 PKI
# ---------------------------------------------------------
EASYRSA_DIR="/etc/openvpn/easy-rsa"
rm -rf $EASYRSA_DIR
mkdir -p $EASYRSA_DIR
cp -r /usr/share/easy-rsa/* $EASYRSA_DIR

cd $EASYRSA_DIR
./easyrsa init-pki


# ---------------------------------------------------------
# 5. 非交互模式生成证书
# ---------------------------------------------------------
EASYRSA_BATCH=1 ./easyrsa build-ca nopass
EASYRSA_BATCH=1 ./easyrsa gen-req server nopass
EASYRSA_BATCH=1 ./easyrsa sign-req server server
EASYRSA_BATCH=1 ./easyrsa gen-req client nopass
EASYRSA_BATCH=1 ./easyrsa sign-req client client


# ---------------------------------------------------------
# 6. 拷贝证书
# ---------------------------------------------------------
mkdir -p /etc/openvpn/server

cp pki/ca.crt /etc/openvpn/server/
cp pki/issued/server.crt /etc/openvpn/server/
cp pki/private/server.key /etc/openvpn/server/
cp pki/dh.pem /etc/openvpn/server/


# ---------------------------------------------------------
# 7. 生成 OpenVPN server.conf（TCP over IPv6）
# ---------------------------------------------------------
cat >/etc/openvpn/server/server.conf <<EOF
port 443
proto tcp6
dev tun
topology subnet

ca ca.crt
cert server.crt
key server.key
dh dh.pem

server 10.8.0.0 255.255.255.0
push "redirect-gateway def1"
push "dhcp-option DNS 1.1.1.1"

keepalive 10 120
cipher AES-256-CBC
auth SHA256
persist-key
persist-tun
verb 3
EOF


# ---------------------------------------------------------
# 8. NAT，将入口流量出口到 WARP IPv4
# ---------------------------------------------------------
iptables -t nat -A POSTROUTING -o $OUT_IF -j MASQUERADE
netfilter-persistent save


# ---------------------------------------------------------
# 9. 启动 OpenVPN
# ---------------------------------------------------------
systemctl enable openvpn-server@server.service
systemctl restart openvpn-server@server.service


# ---------------------------------------------------------
# 10. 生成 client.ovpn（供入口服务器使用）
# ---------------------------------------------------------
CLIENT_OVPN="/root/client.ovpn"

cat >$CLIENT_OVPN <<EOF
client
dev tun
proto tcp6
remote $OUT_IPV6 443
resolv-retry infinite
nobind
persist-key
persist-tun

<ca>
$(cat $EASYRSA_DIR/pki/ca.crt)
</ca>

<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' $EASYRSA_DIR/pki/issued/client.crt)
</cert>

<key>
$(cat $EASYRSA_DIR/pki/private/client.key)
</key>

cipher AES-256-CBC
auth SHA256
verb 3
EOF

echo ""
echo "client.ovpn 已生成：$CLIENT_OVPN"


# ---------------------------------------------------------
# 11. SSH 上传 client.ovpn（入口服务器）
# ---------------------------------------------------------
read -p "是否自动上传 client.ovpn 到入口服务器？(y/n): " UP

if [[ "$UP" == "y" || "$UP" == "Y" ]]; then
    read -p "入口服务器 IP/域名（可 IPv6）: " IN_IP
    read -p "SSH 端口（默认 22）: " IN_PORT
    read -p "SSH 用户名（默认 root）: " IN_USER
    echo -n "SSH 密码: "
    read -s IN_PASS
    echo

    [[ -z "$IN_PORT" ]] && IN_PORT=22
    [[ -z "$IN_USER" ]] && IN_USER=root

    apt install -y sshpass

    sshpass -p "$IN_PASS" scp -P $IN_PORT -o StrictHostKeyChecking=no /root/client.ovpn $IN_USER@$IN_IP:/root/

    echo "上传成功！"
fi


echo "======================================"
echo " 出口服务器部署完成！"
echo "======================================"

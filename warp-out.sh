#!/bin/bash
clear
echo "=========================================="
echo "  OpenVPN 出口服务器安装脚本 (IPv6 入站 + WARP IPv4 出站)"
echo "=========================================="

### 自动检测系统
if [ -f /etc/debian_version ]; then
    OS="debian"
    apt update -y
    apt install -y curl wget sudo net-tools iproute2 iptables iptables-persistent openvpn easy-rsa sshpass
else
    echo "不支持的系统，仅支持 Debian / Ubuntu"
    exit 1
fi

### 全局变量
CLIENT_OVPN="/root/client.ovpn"
EASYRSA_DIR="/etc/openvpn/easy-rsa"

### 获取出口服务器 IPv6（用作 OpenVPN Server 监听）
SERVER_IPV6=$(ip -6 addr show | grep global | awk '{print $2}' | head -n 1 | cut -d/ -f1)

if [ -z "$SERVER_IPV6" ]; then
    echo "❌ 未找到出口服务器可用 IPv6，无法作为入口的连接目标！"
    exit 1
fi

echo "出口服务器入站 IPv6: $SERVER_IPV6"

### 创建 easy-rsa 环境
rm -rf $EASYRSA_DIR
mkdir -p $EASYRSA_DIR
cp -r /usr/share/easy-rsa/* $EASYRSA_DIR
cd $EASYRSA_DIR
./easyrsa init-pki
echo yes | ./easyrsa build-ca nopass
./easyrsa gen-dh
./easyrsa build-server-full server nopass
./easyrsa build-client-full client nopass

### 生成 OpenVPN 服务器端配置
cat >/etc/openvpn/server.conf <<EOF
port 1194
proto udp6
dev tun
user nobody
group nogroup

server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"

push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"

ca $EASYRSA_DIR/pki/ca.crt
cert $EASYRSA_DIR/pki/issued/server.crt
key $EASYRSA_DIR/pki/private/server.key
dh $EASYRSA_DIR/pki/dh.pem

keepalive 10 120
persist-key
persist-tun
status /var/log/openvpn-status.log
verb 3
EOF

### 生成 client.ovpn (入口服务器使用)
cat >$CLIENT_OVPN <<EOF
client
dev tun
proto udp6
remote $SERVER_IPV6 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
verb 3

<ca>
$(cat $EASYRSA_DIR/pki/ca.crt)
</ca>

<cert>
$(cat $EASYRSA_DIR/pki/issued/client.crt)
</cert>

<key>
$(cat $EASYRSA_DIR/pki/private/client.key)
</key>
EOF

### 启动 OpenVPN
systemctl enable openvpn@server
systemctl restart openvpn@server

### 上传到入口服务器
echo
read -p "是否自动上传 client.ovpn 到入口服务器？(y/n): " UP

if [[ "$UP" == "y" ]]; then
    read -p "入口服务器 IP/域名: " IN_IP
    read -p "入口 SSH 端口(默认22): " IN_PORT
    read -p "入口 SSH 用户(默认 root): " IN_USER
    read -p "入口 SSH 密码: " IN_PASS

    IN_PORT=${IN_PORT:-22}
    IN_USER=${IN_USER:-root}

    echo "清理入口服务器 SSH 旧指纹..."
    ssh-keygen -R "$IN_IP" >/dev/null 2>&1

    echo "尝试上传 client.ovpn..."
    sshpass -p "$IN_PASS" scp -P $IN_PORT -o StrictHostKeyChecking=no "$CLIENT_OVPN" $IN_USER@$IN_IP:/root/

    if [ $? -eq 0 ]; then
        echo "✔ 上传成功！"
    else
        echo "⚠ 上传失败，请手动复制 /root/client.ovpn"
    fi
fi

echo "=========================================="
echo " OpenVPN 出口服务器配置完成！client.ovpn 已生成：/root/client.ovpn"
echo "=========================================="

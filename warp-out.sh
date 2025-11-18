#!/bin/bash

echo "========================================"
echo " OpenVPN 出口服务器安装脚本 (IPv6 入站 → IPv4/WARP 出站)"
echo "========================================"

# 检查 root
[ "$(id -u)" != "0" ] && echo "请使用 root 权限运行" && exit 1

# 安装组件
apt update -y
apt install -y openvpn easy-rsa iptables iptables-persistent curl unzip

# 获取网卡
NET=$(ip -6 route show default | awk '{print $5}' | head -n1)
[ -z "$NET" ] && NET=$(ip route show default | awk '{print $5}' | head -n1)
echo "出口网卡: $NET"

# 获取 IPv6 入站地址
SERVER_IPV6=$(ip -6 addr show "$NET" | grep global | awk '{print $2}' | cut -d/ -f1 | head -n1)
if [ -z "$SERVER_IPV6" ]; then
    echo "未发现出口服务器 IPv6 地址，无法提供入口连接！"
    exit 1
fi
echo "出口服务器 IPv6 入站: $SERVER_IPV6"

# 清理旧 PKI
rm -rf /etc/openvpn/easy-rsa
make-cadir /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa
./easyrsa init-pki
echo -ne "\n" | ./easyrsa build-ca nopass
echo -ne "\n" | ./easyrsa build-server-full server nopass
echo -ne "\n" | ./easyrsa build-client-full client nopass
./easyrsa gen-dh

mkdir -p /etc/openvpn/server

# 生成 server.conf
cat >/etc/openvpn/server/server.conf <<EOF
port 1194
proto udp
dev tun

ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
dh /etc/openvpn/easy-rsa/pki/dh.pem

server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS6 2606:4700:4700::1111"

keepalive 10 120
persist-key
persist-tun
user nobody
group nogroup
status openvpn-status.log
verb 3

local $SERVER_IPV6
EOF

systemctl enable openvpn@server
systemctl restart openvpn@server

# 生成客户端 client.ovpn
cat >/root/client.ovpn <<EOF
client
dev tun
proto udp
remote $SERVER_IPV6 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth-nocache

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

echo "client.ovpn 已生成: /root/client.ovpn"

# 上传到入口服务器
read -p "是否上传 client.ovpn 到入口服务器？(y/n): " UP
if [[ "$UP" == "y" ]]; then
    read -p "入口服务器 IPv4/IPv6: " INIP
    read -p "入口 SSH 端口(默认22): " INPORT
    INPORT=${INPORT:-22}
    read -p "入口 SSH 用户(默认 root): " INUSER
    INUSER=${INUSER:-root}
    read -p "入口 SSH 密码: " INPASS

    # 删除旧的 known_hosts 指纹
    ssh-keygen -R "[$INIP]:$INPORT" >/dev/null 2>&1
    ssh-keygen -R "$INIP" >/dev/null 2>&1

    apt install sshpass -y

    sshpass -p "$INPASS" scp -P $INPORT /root/client.ovpn $INUSER@$INIP:/root/
    if [ $? -eq 0 ]; then
        echo "上传 client.ovpn 成功！"
    else
        echo "⚠️ 上传失败，但出口服务器 OpenVPN 已正常运行。"
    fi
fi

echo "出口服务器部署完成！"

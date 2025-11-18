#!/bin/bash

clear
echo "====================================="
echo "   OpenVPN 出口服务器自动部署脚本"
echo "    IPv6 入站 + WARP IPv4 出站"
echo "====================================="

########################################
# 1. 系统检测
########################################
if ! command -v apt >/dev/null 2>&1; then
    echo "❌ 本脚本仅支持 Debian / Ubuntu 系统！"
    exit 1
fi

########################################
# 2. 更新系统 & 安装依赖
########################################
echo ">>> 更新系统 & 安装依赖"
apt update -y
apt install -y openvpn easy-rsa curl unzip iptables iptables-persistent

########################################
# 3. 自动获取出口服务器 IPv6
########################################
OUT_IPV6=$(ip -6 addr show | grep global | awk '{print $2}' | cut -d/ -f1 | head -n 1)
IFACE=$(ip -6 addr show | grep global | awk '{print $NF}' | head -n 1)

if [[ -z "$OUT_IPV6" ]]; then
    echo "❌ 无法找到出口服务器公网 IPv6！"
    exit 1
fi

echo "出口 IPv6: $OUT_IPV6"
echo "出口网卡: $IFACE"

########################################
# 4. 初始化 Easy-RSA
########################################
echo ">>> 初始化 Easy-RSA"

EASY=/etc/openvpn/easy-rsa
rm -rf $EASY
mkdir -p $EASY
cp -r /usr/share/easy-rsa/* $EASY
cd $EASY
./easyrsa init-pki
echo "server" | ./easyrsa build-ca nopass
./easyrsa gen-dh
./easyrsa build-server-full server nopass
./easyrsa build-client-full client nopass

########################################
# 5. 创建 server.conf
########################################
echo ">>> 生成 server.conf"

cat >/etc/openvpn/server.conf <<EOF
port 1194
proto tcp6
dev tun

server 10.8.0.0 255.255.255.0

push "redirect-gateway def1 ipv6 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"

ca $EASY/pki/ca.crt
cert $EASY/pki/issued/server.crt
key $EASY/pki/private/server.key
dh $EASY/pki/dh.pem

keepalive 10 120
persist-key
persist-tun

status /var/log/openvpn-status.log
verb 3
EOF

########################################
# 6. 启动 OpenVPN
########################################
systemctl enable openvpn@server
systemctl restart openvpn@server

########################################
# 7. 创建 client.ovpn
########################################
echo ">>> 生成 client.ovpn"

cat >/root/client.ovpn <<EOF
client
dev tun
proto tcp6
remote $OUT_IPV6 1194
resolv-retry infinite
nobind

persist-key
persist-tun

<ca>
$(cat $EASY/pki/ca.crt)
</ca>

<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' $EASY/pki/issued/client.crt)
</cert>

<key>
$(cat $EASY/pki/private/client.key)
</key>
EOF

echo "client.ovpn 已生成： /root/client.ovpn"

########################################
# 8. 上传到入口服务器
########################################
read -p "是否上传 client.ovpn 到入口服务器？(y/n): " UP

if [[ "$UP" == "y" || "$UP" == "Y" ]]; then

    read -p "入口服务器 IP (支持 IPv4 / IPv6): " INIP
    read -p "入口 SSH 端口(默认22): " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    read -p "入口 SSH 用户(默认 root): " SSH_USER
    SSH_USER=${SSH_USER:-root}
    read -p "入口 密码: " SSH_PASS

    echo ">>> 清理入口机 known_hosts 冲突"
    ssh-keygen -f "/root/.ssh/known_hosts" -R "$INIP" >/dev/null 2>&1

    echo ">>> 等待入口机 SSH 稳定...（3秒）"
    sleep 3

    # 识别 IPv6
    if [[ "$INIP" == *":"* ]]; then
        TARGET="[$INIP]"
    else
        TARGET="$INIP"
    fi

    echo ">>> 开始上传（自动重试 3 次）"

    for i in 1 2 3; do
        sshpass -p "$SSH_PASS" scp -P "$SSH_PORT" /root/client.ovpn ${SSH_USER}@${TARGET}:/root/
        if [[ $? -eq 0 ]]; then
            echo "✅ 上传成功！"
            exit 0
        else
            echo "⚠️ 第 $i 次上传失败，1 秒后重试..."
            sleep 1
        fi
    done

    echo "❌ 上传失败（尝试 3 次仍未成功）"
fi

echo "==============================="
echo " OpenVPN 出口服务器部署完成！"
echo "==============================="

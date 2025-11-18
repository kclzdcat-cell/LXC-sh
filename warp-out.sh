#!/bin/bash
set -e

echo "==============================================="
echo " OpenVPN 出口服务器自动部署脚本 (IPv6 入站 + WARP IPv4 出站)"
echo "==============================================="

# ----------- 系统检测 -------------
if [ -f /etc/debian_version ]; then
    OS="debian"
elif [ -f /etc/lsb-release ]; then
    OS="ubuntu"
else
    echo "仅支持 Debian / Ubuntu"
    exit 1
fi

# ----------- 安装依赖 -------------
apt update -y
apt install -y openvpn iptables iptables-persistent curl wget unzip cron resolvconf openssl

# ----------- 检查是否已有 PKI ----------------
if [ -d /etc/openvpn/easy-rsa ]; then
    echo "检测到旧的 Easy-RSA 配置，将删除旧版本..."
    rm -rf /etc/openvpn/easy-rsa
fi

# ----------- 安装 Easy-RSA v3 -----------
wget -O /tmp/easyrsa.tgz https://github.com/OpenVPN/easy-rsa/releases/download/v3.1.7/EasyRSA-3.1.7.tgz
mkdir -p /etc/openvpn/easy-rsa
tar xf /tmp/easyrsa.tgz -C /etc/openvpn/easy-rsa --strip-components 1
cd /etc/openvpn/easy-rsa

echo "初始化 PKI ..."
./easyrsa init-pki

echo "生成 CA 证书 ..."
yes "" | ./easyrsa build-ca nopass

echo "生成服务器证书 ..."
yes "" | ./easyrsa gen-req server nopass
yes "yes" | ./easyrsa sign-req server server

echo "生成客户端证书 ..."
yes "" | ./easyrsa gen-req client nopass
yes "yes" | ./easyrsa sign-req client client

echo "生成 DH 参数 ..."
./easyrsa gen-dh

# ----------- 复制证书到 OpenVPN 目录 ----------
mkdir -p /etc/openvpn/server

cp pki/ca.crt /etc/openvpn/server/
cp pki/dh.pem /etc/openvpn/server/
cp pki/issued/server.crt /etc/openvpn/server/server.crt
cp pki/private/server.key /etc/openvpn/server/server.key

# ----------- 配置 OpenVPN 服务器 ------------
WAN6=$(ip -6 addr show | grep global | awk '{print $2}' | head -n1 | cut -d'/' -f1)

if [ -z "$WAN6" ]; then
    echo "未检测到可用 IPv6，请确保出口服务器具有全球 IPv6 地址！"
    exit 1
fi

cat >/etc/openvpn/server/server.conf <<EOF
port 1194
proto udp6
dev tun
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
ca ca.crt
cert server.crt
key server.key
dh dh.pem
keepalive 10 120
persist-key
persist-tun
user nobody
group nogroup
status openvpn-status.log
verb 3
explicit-exit-notify 1
EOF

# ----------- 启动 OpenVPN 服务器 -----------
systemctl enable --now openvpn-server@server.service
sleep 2

if ! systemctl is-active --quiet openvpn-server@server.service; then
    echo "❌ OpenVPN 启动失败，请检查日志："
    journalctl -xeu openvpn-server@server.service
    exit 1
fi

echo "OpenVPN 服务已启动！ IPv6：$WAN6"
# =======================
# 生成客户端配置 client.ovpn
# =======================

CLIENT_OVPN="/root/client.ovpn"

cat > $CLIENT_OVPN <<EOF
client
dev tun
proto udp6
remote $WAN6 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
verb 3

<ca>
$(cat /etc/openvpn/server/ca.crt)
</ca>

<cert>
$(cat /etc/openvpn/easy-rsa/pki/issued/client.crt)
</cert>

<key>
$(cat /etc/openvpn/easy-rsa/pki/private/client.key)
</key>

EOF

echo ""
echo "client.ovpn 已生成： /root/client.ovpn"
echo ""

# ===========================
# 提示是否上传到入口服务器
# ===========================

read -p "是否自动上传 client.ovpn 到入口服务器？ (y/n): " UP

if [[ "$UP" == "y" || "$UP" == "Y" ]]; then
    echo ""
    echo "请输入入口服务器信息（仅用于上传，不做其他操作）"

    read -p "入口服务器 IPv4/IPv6: " INIP
    read -p "入口 SSH 端口(默认22): " INPORT
    read -p "入口 SSH 用户(默认 root): " INUSER
    read -p "入口 SSH 密码: " INPASS

    INPORT=${INPORT:-22}
    INUSER=${INUSER:-root}

    # 清理旧指纹避免 SSH 连接失败
    echo "清理旧 SSH known_hosts 指纹..."
    ssh-keygen -f "/root/.ssh/known_hosts" -R "[$INIP]:$INPORT" >/dev/null 2>&1 || true

    # 使用 sshpass 上传
    apt install -y sshpass

    echo "正在上传 client.ovpn ..."
    sshpass -p "$INPASS" scp -P $INPORT -o StrictHostKeyChecking=no $CLIENT_OVPN ${INUSER}@$INIP:/root/

    if [ $? -eq 0 ]; then
        echo "上传完成！入口服务器文件路径：/root/client.ovpn"
    else
        echo "⚠ 上传失败，请检查网络或密码"
    fi
fi

echo ""
echo "==============================================="
echo " OpenVPN 出口服务器部署完成！"
echo " client.ovpn 位于：/root/client.ovpn"
echo "==============================================="

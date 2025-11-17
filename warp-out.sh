#!/bin/bash
set -e
clear
echo "==========================================="
echo "   OpenVPN 出口服务器部署脚本（IPv4/IPv6 支持）"
echo "   基于原脚本，已二次改造"
echo "==========================================="

# 系统检测
if ! command -v apt >/dev/null 2>&1; then
    echo "本脚本仅支持 Debian / Ubuntu 系统"
    exit 1
fi

apt update -y
apt install -y openvpn easy-rsa sshpass curl iptables-persistent

# 自动检测 IPv4 / IPv6
AUTO_IP4=$(curl -s --max-time 3 ipv4.ip.sb || curl -s --max-time 3 ifconfig.me)
AUTO_IP6=$(curl -s --max-time 3 ipv6.ip.sb || echo "")

echo ""
echo "检测到的出口地址："
echo "  IPv4：${AUTO_IP4:-未检测到}"
echo "  IPv6：${AUTO_IP6:-未检测到}"
echo ""
echo "注意：如果你的 IPv4 是通过 WARP 或中转，其真实性可能受限，建议使用 IPv6 作为 OpenVPN 连接地址。"
echo ""

# 选择地址逻辑
echo "请选择用于 client.ovpn 的连接地址："
echo "  1) 使用检测到的 IPv6（推荐）"
echo "  2) 使用检测到的 IPv4（如果你确认可连）"
echo "  3) 手动输入 IP 或域名"

read -p "请输入选项 [1/2/3]： " SEL

if [[ "$SEL" == "1" ]]; then
    if [[ -z "$AUTO_IP6" ]]; then
        echo "未检测到 IPv6，请改为手动输入或选择 IPv4。"
        SEL=3
    else
        PUB_IP="$AUTO_IP6"
        USE_PROTO="udp6"
    fi
fi

if [[ "$SEL" == "2" ]]; then
    PUB_IP="$AUTO_IP4"
    USE_PROTO="udp"
fi

if [[ "$SEL" == "3" ]]; then
    read -p "请输入用于 OpenVPN 的服务器 IP 或域名： " PUB_IP
    # 自动判断是否 IPv6
    if [[ "$PUB_IP" == *":"* ]]; then
        USE_PROTO="udp6"
    else
        USE_PROTO="udp"
    fi
fi

echo ""
echo "最终使用地址： $PUB_IP"
echo "使用协议： $USE_PROTO"
echo ""

# 检测出网网卡
NIC=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
echo "检测到出网网卡： $NIC"

# PKI / 证书生成
EASY_DIR="/etc/openvpn/easy-rsa"
rm -rf "$EASY_DIR"
make-cadir "$EASY_DIR"
cd "$EASY_DIR"
./easyrsa init-pki

export EASYRSA_BATCH=1
echo "" | ./easyrsa build-ca nopass
./easyrsa build-server-full server nopass
./easyrsa build-client-full client nopass
./easyrsa gen-dh

# 复制证书
cp pki/ca.crt /etc/openvpn/
cp pki/issued/server.crt /etc/openvpn/
cp pki/private/server.key /etc/openvpn/
cp pki/dh.pem /etc/openvpn/

# 端口分配（UDP + TCP）
find_free_port() {
    p=$1
    while ss -tuln | grep -q ":$p "; do
        p=$((p+1))
    done
    echo $p
}

UDP_PORT=$(find_free_port 1194)
TCP_PORT=$(find_free_port 443)

echo "分配的端口 - UDP：$UDP_PORT  TCP：$TCP_PORT"

# 启用 IPv4 + IPv6 转发
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i 's/^#*net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf

if [[ -n "$AUTO_IP6" ]]; then
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
    sed -i 's/^#*net.ipv6.conf.all.forwarding=.*/net.ipv6.conf.all.forwarding=1/' /etc/sysctl.conf
fi

# NAT 规则
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE
iptables-save >/etc/iptables/rules.v4

if [[ -n "$AUTO_IP6" ]]; then
    if command -v ip6tables >/dev/null 2>&1 ; then
        ip6tables -t nat -A POSTROUTING -s fd00:1234::/64 -o $NIC -j MASQUERADE || true
        ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true
    fi
fi

# 生成 server.conf（UDP）
cat >/etc/openvpn/server.conf <<EOF
port $UDP_PORT
proto ${USE_PROTO}
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
server 10.8.0.0 255.255.255.0
EOF

# 如果支持 IPv6，添加 IPv6 子网 + IPv6 推送
if [[ -n "$AUTO_IP6" ]]; then
    cat >>/etc/openvpn/server.conf <<EOF
server-ipv6 fd00:1234::/64
push "redirect-gateway def1 ipv6"
push "dhcp-option DNS6 2606:4700:4700::1111"
EOF
else
    cat >>/etc/openvpn/server.conf <<EOF
push "redirect-gateway def1"
EOF
fi

cat >>/etc/openvpn/server.conf <<EOF
push "dhcp-option DNS 8.8.8.8"
persist-key
persist-tun
cipher AES-256-CBC
auth SHA256
verb 3
EOF

# 生成 server-tcp.conf（TCP）
cat >/etc/openvpn/server-tcp.conf <<EOF
port $TCP_PORT
proto tcp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
server 10.9.0.0 255.255.255.0
EOF

if [[ -n "$AUTO_IP6" ]]; then
    cat >>/etc/openvpn/server-tcp.conf <<EOF
server-ipv6 fd00:1235::/64
push "redirect-gateway def1 ipv6"
push "dhcp-option DNS6 2606:4700:4700::1111"
EOF
else
    cat >>/etc/openvpn/server-tcp.conf <<EOF
push "redirect-gateway def1"
EOF
fi

cat >>/etc/openvpn/server-tcp.conf <<EOF
push "dhcp-option DNS 8.8.8.8"
persist-key
persist-tun
cipher AES-256-CBC
auth SHA256
verb 3
EOF

# 启动服务
systemctl enable openvpn@server
systemctl restart openvpn@server
systemctl enable openvpn@server-tcp
systemctl restart openvpn@server-tcp

# 生成 client.ovpn
CLIENT_FILE="/root/client.ovpn"
cat >$CLIENT_FILE <<EOF
client
dev tun
proto ${USE_PROTO}
nobind
persist-key
persist-tun
remote $PUB_IP $UDP_PORT ${USE_PROTO}
remote $PUB_IP $TCP_PORT ${USE_PROTO}
remote-cert-tls server
redirect-gateway def1
EOF

if [[ -n "$AUTO_IP6" ]]; then
    cat >>$CLIENT_FILE <<EOF
# IPv6 support
remote $PUB_IP $UDP_PORT ${USE_PROTO}
remote $PUB_IP $TCP_PORT ${USE_PROTO}
EOF
fi

cat >>$CLIENT_FILE <<EOF

<ca>
$(cat /etc/openvpn/ca.crt)
</ca>

<cert>
$(cat /etc/openvpn/easy-rsa/pki/issued/client.crt)
</cert>

<key>
$(cat /etc/openvpn/easy-rsa/pki/private/client.key)
</key>
EOF

echo ""
echo "client.ovpn 已创建：$CLIENT_FILE"

# 上传到入口服务器
echo ""
read -p "是否自动上传 client.ovpn 到入口服务器？(y/n)：" UPLOAD
if [[ "$UPLOAD" == "y" ]]; then
    read -p "入口服务器 IP：" IN_IP
    read -p "入口 SSH 端口(默认22)：" IN_PORT
    IN_PORT=${IN_PORT:-22}
    read -p "入口 SSH 用户(默认root)：" IN_USER
    IN_USER=${IN_USER:-root}
    read -p "入口 SSH 密码：" IN_PASS

    sshpass -p "$IN_PASS" scp -P $IN_PORT -o StrictHostKeyChecking=no $CLIENT_FILE $IN_USER@$IN_IP:/root/
    echo "上传完成！"
fi

echo ""
echo "========================================"
echo "部署完成，请在入口服务器运行 in.sh"
echo "========================================"

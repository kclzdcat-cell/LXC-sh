#!/bin/bash
set -e
clear
echo "==========================================="
echo "   OpenVPN 入口服务器安装脚本（IPv4 + IPv6）"
echo "==========================================="

apt update -y
apt install -y openvpn curl iptables-persistent

# 自动检测 IPv4 / IPv6（仅显示）
IPV4=$(curl -s --max-time 3 ipv4.ip.sb || echo "")
IPV6=$(curl -s --max-time 3 ipv6.ip.sb || echo "")

echo ""
echo "检测到入口服务器 IP："
echo "  IPv4：${IPV4:-未检测到}"
echo "  IPv6：${IPV6:-未检测到}"
echo ""

# 自动检测出口网卡
NIC=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
NIC=${NIC:-eth0}

echo "自动检测到入口服务器出站网卡： $NIC"
echo ""

# 用户输入出口服务器 IP
echo "请输入出口服务器（已安装 out.sh）对外连接地址:"
read -p "出口服务器 IP/域名（可为 IPv6）： " SERVER_IP

# 选择端口
echo ""
echo "出口服务器中已启用两个端口：UDP + TCP（在 out.sh 自动配置）"
read -p "请输入出口服务器 UDP 端口（默认 1194 或 out.sh 分配的）： " UDP_PORT
read -p "请输入出口服务器 TCP 端口（默认 443 或 out.sh 分配的）： " TCP_PORT

UDP_PORT=${UDP_PORT:-1194}
TCP_PORT=${TCP_PORT:-443}

# 判断 IPv6
if [[ "$SERVER_IP" == *":"* ]]; then
    PROTO1="udp6"
    PROTO2="tcp6"
else
    PROTO1="udp"
    PROTO2="tcp"
fi

echo ""
echo "使用出口 IP：$SERVER_IP"
echo "UDP 协议：$PROTO1"
echo "TCP 协议：$PROTO2"
echo ""

# 启用 IPv4/IPv6 转发
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i "s/^#*net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/" /etc/sysctl.conf

# 如果支持 IPv6
if [[ -n "$IPV6" ]]; then
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
    sed -i "s/^#*net.ipv6.conf.all.forwarding=.*/net.ipv6.conf.all.forwarding=1/" /etc/sysctl.conf
fi

sysctl -p >/dev/null 2>&1 || true

# NAT 转发 IPv4
iptables -t nat -A POSTROUTING -o $NIC -j MASQUERADE
iptables-save >/etc/iptables/rules.v4

# NAT 转发 IPv6（如果有 IPv6）
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t nat -A POSTROUTING -o $NIC -j MASQUERADE || true
    ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true
fi

# 创建 OpenVPN 客户端配置
mkdir -p /etc/openvpn/client
cat >/etc/openvpn/client/client.conf <<EOF
client
dev tun
nobind
persist-key
persist-tun

# 出口服务器 UDP
proto $PROTO1
remote $SERVER_IP $UDP_PORT

# 出口服务器 TCP
proto $PROTO2
remote $SERVER_IP $TCP_PORT

remote-cert-tls server
auth SHA256
cipher AES-256-CBC
verb 3

# DNS
script-security 2
up /etc/openvpn/update-resolv-conf
down /etc/openvpn/update-resolv-conf
EOF

# 等待用户已上传 client.ovpn
echo ""
echo "****************************************************"
echo " 请现在把 出口服务器生成的 /root/client.ovpn 上传到："
echo "     /etc/openvpn/client/"
echo " 上传完成后，按回车继续。"
echo "****************************************************"
read -p ""

if [[ ! -f /etc/openvpn/client/client.ovpn ]]; then
    echo "错误：未找到 /etc/openvpn/client/client.ovpn"
    exit 1
fi

# 将 client.ovpn 的证书部分嵌入 client.conf
echo "" >>/etc/openvpn/client/client.conf
cat /etc/openvpn/client/client.ovpn >>/etc/openvpn/client/client.conf

# 启动 OpenVPN 客户端服务
cp /etc/openvpn/client/client.conf /etc/openvpn/client.conf
systemctl enable openvpn@client
systemctl restart openvpn@client

sleep 2
systemctl status openvpn@client --no-pager

echo ""
echo "=============================================="
echo "OpenVPN 入口服务器 已经成功连接出口服务器！"
echo "当前出口 IP："
curl -s ipv4.ip.sb; echo
curl -s ipv6.ip.sb; echo
echo "=============================================="

#!/bin/bash
clear
echo "======================================"
echo "  OpenVPN 入口服务器自动安装脚本 (IPv4 + IPv6)"
echo "======================================"

############# 自动检测入口公网IP #############
IN_IP4=$(curl -4 -s ip.sb || curl -4 -s ifconfig.me)
IN_IP6=$(curl -6 -s ip.sb || echo "未检测到 IPv6")

echo -e "检测到入口服务器公网 IPv4: \e[32m$IN_IP4\e[0m"
echo -e "检测到入口服务器公网 IPv6: \e[32m$IN_IP6\e[0m"

############# 自动检测出口网卡 #############
IFACE=$(ip route get 1 | awk '{print $5; exit}')
echo -e "\n自动检测到出口网卡: \e[32m$IFACE\e[0m"

############# 获取出口服务器信息（手动输入） #############
echo -e "\n请输入出口服务器 (已运行 out.sh) 的连接地址："
read -p "出口服务器 IP/域名(可为IPv6)： " OUT_SERVER

read -p "出口服务器 UDP 端口(默认 1194)： " OUT_UDP
OUT_UDP=${OUT_UDP:-1194}

read -p "出口服务器 TCP 端口(默认 443)： " OUT_TCP
OUT_TCP=${OUT_TCP:-443}

echo -e "\n使用出站服务器："
echo -e " IP: \e[32m$OUT_SERVER\e[0m"
echo -e " UDP 协议: \e[32mudp6\e[0m (自动适配)"
echo -e " TCP 协议: \e[32mtcp6\e[0m (自动适配，更稳定)"
echo "======================================"

############# 检查 client.ovpn 是否存在 #############
if [ ! -f /root/client.ovpn ]; then
    echo -e "\e[31m未找到 /root/client.ovpn，请确认 out.sh 已上传配置文件！\e[0m"
    exit 1
fi

# 自动替换 remote 行
echo ">>> 正在替换 client.ovpn 中的出口 IP 和端口 ..."
sed -i "s/^remote .*/remote $OUT_SERVER $OUT_TCP tcp/" /root/client.ovpn

# 强制 IPv6 / IPv4 支持
echo ">>> 添加 IPv6 / IPv4 支持 ..."
grep -q "proto" /root/client.ovpn || echo "proto tcp" >> /root/client.ovpn
grep -q "remote-cert-tls" /root/client.ovpn || echo "remote-cert-tls server" >> /root/client.ovpn

############# 安装必要组件 #############
apt update -y
apt install -y openvpn iptables-persistent curl

############# 启用 IPv4 / IPv6 转发 #############
echo ">>> 开启 IPv4 IPv6 转发 ..."
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
sed -i '/net.ipv6.conf.all.forwarding/d' /etc/sysctl.conf

echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
sysctl -p

############# 防火墙放行 #############
echo ">>> 配置防火墙 NAT 转发 ..."

# IPv4 NAT
iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
iptables -A FORWARD -i tun0 -o $IFACE -j ACCEPT
iptables -A FORWARD -i $IFACE -o tun0 -j ACCEPT

# IPv6 NAT
ip6tables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE 2>/dev/null
ip6tables -A FORWARD -i tun0 -o $IFACE -j ACCEPT 2>/dev/null
ip6tables -A FORWARD -i $IFACE -o tun0 -j ACCEPT 2>/dev/null

netfilter-persistent save

############# 启动 OpenVPN 客户端 #############
echo ">>> 启动 OpenVPN 客户端 ..."
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

systemctl enable openvpn-client@client.service
systemctl restart openvpn-client@client.service

sleep 2
systemctl status openvpn-client@client.service --no-pager

echo "======================================"
echo -e "  \e[32mOpenVPN 入口服务器安装完成！\e[0m"
echo "======================================"

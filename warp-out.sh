#!/bin/bash
# OpenVPN 出口服务器自动部署脚本（IPv6 入站 + WARP IPv4 出站）
# 适用系统：Debian / Ubuntu

yellow(){ echo -e "\033[33m$1\033[0m"; }
green(){ echo -e "\033[32m$1\033[0m"; }
red(){ echo -e "\033[31m$1\033[0m"; }

echo "============================================="
echo " OpenVPN 出口服务器安装脚本（IPv6 入站 + WARP IPv4 出站）"
echo "============================================="

sleep 1

#---------------------------
# 基础环境
#---------------------------
apt update -y
apt install -y openvpn easy-rsa curl iptables-persistent

#---------------------------
# 自动检测出口网卡（不会出错）
#---------------------------
NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)

if [[ -z "$NIC" ]]; then
    for i in eth0 ens3 enp1s0 ens5; do
        if ip link show "$i" >/dev/null 2>&1; then
            NIC=$i
            break
        fi
    done
fi

if [[ -z "$NIC" ]]; then
    red "无法检测出口网卡，退出！"
    exit 1
fi

green "出口网卡：$NIC"

#---------------------------
# 读取出口服务器 IPv6
#---------------------------
OUT_IPV6=$(ip -6 -o addr show dev "$NIC" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)

if [[ -z "$OUT_IPV6" ]]; then
    red "未检测到出口服务器可用 IPv6！入口无法连接此服务器！"
    exit 1
fi

green "出口服务器入站 IPv6：$OUT_IPV6"

#---------------------------
# 清理旧 PKI
#---------------------------
rm -rf /etc/openvpn/easy-rsa
make-cadir /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa

#---------------------------
# 初始化 PKI
#---------------------------
./easyrsa init-pki
echo -ne "\n" | ./easyrsa build-ca nopass
echo -ne "\n" | ./easyrsa build-server-full server nopass
echo -ne "\n" | ./easyrsa build-client-full client nopass
./easyrsa gen-dh

#---------------------------
# 生成 server.conf（仅 IPv6 入站）
#---------------------------
cat >/etc/openvpn/server.conf <<EOF
port 443
proto tcp6
dev tun
local $OUT_IPV6
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"

ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
dh /etc/openvpn/easy-rsa/pki/dh.pem

keepalive 10 120
persist-key
persist-tun
status /etc/openvpn/openvpn-status.log
verb 3
EOF

#---------------------------
# NAT（所有流量走出口机 IPv4-WARP）
#---------------------------
iptables -t nat -A POSTROUTING -o "$NIC" -j MASQUERADE
netfilter-persistent save

#---------------------------
# 生成 client.ovpn 文件（IPv6 入站）
#---------------------------
CLIENT_IP="$OUT_IPV6"

cat >/root/client.ovpn <<EOF
client
dev tun
proto tcp6
remote $CLIENT_IP 443
resolv-retry infinite
nobind
persist-key
persist-tun

remote-cert-tls server
auth-nocache

redirect-gateway def1
dhcp-option DNS 1.1.1.1
dhcp-option DNS 8.8.8.8

<ca>
$(cat /etc/openvpn/easy-rsa/pki/ca.crt)
</ca>
<cert>
$(awk '/BEGIN CERTIFICATE/{flag=1} flag; /END CERTIFICATE/{flag=0}' /etc/openvpn/easy-rsa/pki/issued/client.crt)
</cert>
<key>
$(cat /etc/openvpn/easy-rsa/pki/private/client.key)
</key>
EOF

#---------------------------
# 自动上传 client.ovpn 到入口服务器
#---------------------------
read -p "是否自动上传 client.ovpn 到入口服务器？ (y/n): " UP

if [[ "$UP" == "y" ]]; then
    read -p "入口服务器 IP: " INIP
    read -p "入口 SSH 端口 (默认22): " INPORT
    INPORT=${INPORT:-22}
    read -p "入口 SSH 用户名 (默认root): " INUSER
    INUSER=${INUSER:-root}
    read -p "入口 SSH 密码: " INPASS

    apt install -y sshpass
    sshpass -p "$INPASS" scp -P $INPORT /root/client.ovpn ${INUSER}@${INIP}:/root/
    green "配置文件已上传到入口服务器 /root/"
fi

green "出口服务器部署完成！"
echo "请去入口服务器运行 in.sh 完成连接。"

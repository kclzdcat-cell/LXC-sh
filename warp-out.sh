#!/bin/bash
clear
echo "=========================================================="
echo " OpenVPN 出口服务器自动部署脚本（IPv6 入站 + WARP IPv4 出站）"
echo "=========================================================="

# 检查是否是 root
if [ "$(id -u)" != "0" ]; then
  echo "❌ 请使用 root 运行！"
  exit 1
fi

# 检查系统
if ! grep -qiE "debian|ubuntu" /etc/os-release; then
  echo "❌ 此脚本仅支持 Debian / Ubuntu"
  exit 1
fi

apt update -y
apt install -y openvpn easy-rsa curl wget unzip iptables iptables-persistent sshpass

echo
echo ">>> 检测出口服务器 IPv6 ..."
OUT_IPV6=$(curl -6 --connect-timeout 3 -s ipv6.ip.sb)
if [[ -z "$OUT_IPV6" ]]; then
  # 本地抓取 IPv6
  OUT_IPV6=$(ip -6 addr show | grep global | awk '{print $2}' | cut -d/ -f1 | head -n 1)
fi

if [[ -z "$OUT_IPV6" ]]; then
  echo "❌ 未检测到出口服务器可用 IPv6！无法作为 OpenVPN 入站！"
  exit 1
fi
echo "出口服务器 IPv6 入站地址: $OUT_IPV6"

# 自动检测网卡
NIC=$(ip route | grep default | awk '{print $5}' | head -n 1)
echo "出口网卡: $NIC"

# 安装 WARP（只接管 IPv4，不接管 IPv6）
echo
echo ">>> 安装 Cloudflare WARP（接管 IPv4） ..."
curl -fsSL https://pkg.cloudflareclient.com/install.sh | bash
warp-cli register
warp-cli set-mode proxy
warp-cli set-proxy-port 40000
warp-cli connect

sleep 3
WARP_IP=$(curl -4 --proxy socks5://127.0.0.1:40000 -s ip.sb)
echo "WARP IPv4 出口: $WARP_IP"


echo
echo ">>> 初始化 Easy-RSA PKI ..."
mkdir -p /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa
rm -rf pki
easy-rsa init-pki
echo -e "server" | easy-rsa build-ca nopass

echo
echo ">>> 生成服务器证书 ..."
echo -e "server" | easy-rsa build-server-full server nopass

echo
echo ">>> 生成客户端证书 ..."
echo -e "client" | easy-rsa build-client-full client nopass

easy-rsa gen-dh
echo
echo ">>> 生成 OpenVPN server.conf ..."
cat >/etc/openvpn/server.conf <<EOF
port 1194
proto udp6
dev tun
sndbuf 0
rcvbuf 0
ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
dh /etc/openvpn/easy-rsa/pki/dh.pem
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "route-ipv6 ::/0"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-GCM
auth SHA256
persist-key
persist-tun
status openvpn-status.log
verb 3
explicit-exit-notify 1
EOF

echo
echo ">>> 启动 OpenVPN ..."
systemctl enable openvpn@server
systemctl restart openvpn@server

sleep 2


echo
echo ">>> 配置 NAT 以便 IPv4 出口走 WARP ..."
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE
ip6tables -t nat -A POSTROUTING -s 10.8.0.0/24 -j MASQUERADE
netfilter-persistent save

echo
echo ">>> 创建 client.ovpn ..."
CLIENT_FILE="/root/client.ovpn"

cat >$CLIENT_FILE <<EOF
client
dev tun
proto udp6
remote $OUT_IPV6 1194
resolv-retry infinite
nobind
persist-key
persist-tun
cipher AES-256-GCM
auth SHA256
verb 3

<ca>
$(cat /etc/openvpn/easy-rsa/pki/ca.crt)
</ca>
<cert>
$(cat /etc/openvpn/easy-rsa/pki/issued/client.crt)
</cert>
<key>
$(cat /etc/openvpn/easy-rsa/pki/private/client.key)
</key>
EOF

echo "client.ovpn 已生成: $CLIENT_FILE"
echo
echo "======================================================="
echo " 请输入入口服务器信息（用于上传 client.ovpn 文件）"
echo " 仅用于上传，不做其他操作"
echo "======================================================="
read -p "入口服务器 IPv6: " IN_IPV6
read -p "入口 SSH 端口(默认 22): " IN_PORT
read -p "入口 SSH 用户(默认 root): " IN_USER
read -p "入口 SSH 密码: " IN_PASS

IN_PORT=${IN_PORT:-22}
IN_USER=${IN_USER:-root}

echo
echo ">>> 清理入口服务器 SSH 旧指纹 ..."
ssh-keygen -f "/root/.ssh/known_hosts" -R "[$IN_IPV6]:$IN_PORT" >/dev/null 2>&1

echo
echo ">>> 上传 client.ovpn ..."
sshpass -p "$IN_PASS" scp -6 -P $IN_PORT $CLIENT_FILE ${IN_USER}@[${IN_IPV6}]:/root/

if [[ $? -eq 0 ]]; then
    echo "✅ 上传成功！"
else
    echo "⚠ 上传失败，但出口服务器已正常运行。"
fi

echo
echo "================ 安装完成 =================="
echo "client.ovpn 已生成于: /root/client.ovpn"

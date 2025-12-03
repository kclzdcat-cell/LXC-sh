#!/bin/bash
set -e

echo "==========================================="
echo " OpenVPN 出口部署 (KVM + IPv6 专用版)"
echo "==========================================="

#----------- 1. 环境检测 -----------
# 获取用于隧道连接的公网 IPv6
PUB_IP6=$(ip -6 addr show | grep global | awk '{print $2}' | cut -d'/' -f1 | head -n 1)

if [[ -z "$PUB_IP6" ]]; then
    echo "❌ 错误：本机未检测到公网 IPv6 地址！"
    exit 1
fi
echo "隧道监听地址 (IPv6): $PUB_IP6"

# 检测流量出口网卡 (Warp/IPv4)
NIC=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
echo "流量出口网卡: $NIC"

#----------- 2. 安装组件 -----------
apt update -y
apt install -y openvpn easy-rsa sshpass iptables-persistent

#----------- 3. 证书生成 (标准流程) -----------
rm -rf /etc/openvpn/easy-rsa
mkdir -p /etc/openvpn/easy-rsa
cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/
cd /etc/openvpn/easy-rsa
export EASYRSA_BATCH=1
./easyrsa init-pki
./easyrsa build-ca nopass
./easyrsa build-server-full server nopass
./easyrsa build-client-full client nopass
./easyrsa gen-dh
openvpn --genkey --secret ta.key
cp pki/ca.crt /etc/openvpn/
cp pki/dh.pem /etc/openvpn/
cp pki/issued/server.crt /etc/openvpn/
cp pki/private/server.key /etc/openvpn/
cp pki/issued/client.crt /etc/openvpn/
cp pki/private/client.key /etc/openvpn/
cp ta.key /etc/openvpn/

#----------- 4. 系统配置 (KVM优化) -----------
# 开启转发
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-openvpn.conf
sysctl --system

# 配置 NAT (IPv4 流量从 Warp 出去)
iptables -t nat -F
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE
iptables-save >/etc/iptables/rules.v4

#----------- 5. 服务端配置 (关键修改) -----------
# 使用 proto udp6 以支持 IPv6 入站连接
cat >/etc/openvpn/server.conf <<EOF
port 1194
proto udp6
dev tun
topology subnet
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-crypt ta.key
server 10.8.0.0 255.255.255.0
server-ipv6 fd00:1234::/64
# 基础推送，客户端会进行过滤
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-GCM
auth SHA256
persist-key
persist-tun
verb 3
explicit-exit-notify 1
EOF

systemctl enable openvpn@server
systemctl restart openvpn@server

#----------- 6. 生成客户端配置 (关键修改) -----------
CLIENT=/root/client.ovpn
# 直接指定 IPv6 地址和 udp6 协议
cat >$CLIENT <<EOF
client
dev tun
proto udp6
remote $PUB_IP6 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
# Warp 必需优化，防止卡死
mssfix 1280
verb 3
<ca>
$(cat /etc/openvpn/ca.crt)
</ca>
<cert>
$(cat /etc/openvpn/client.crt)
</cert>
<key>
$(cat /etc/openvpn/client.key)
</key>
<tls-crypt>
$(cat /etc/openvpn/ta.key)
</tls-crypt>
EOF

echo "client.ovpn 已生成"

#----------- 7. 自动上传 -----------
echo "请输入入口服务器 SSH 信息："
read -p "入口 IP (纯IPv6不要加[]): " IN_IP
read -p "入口 SSH 端口(默认22)：" IN_PORT
IN_PORT=${IN_PORT:-22}
read -p "入口 SSH 用户(默认root)：" IN_USER
IN_USER=${IN_USER:-root}
read -p "入口 SSH 密码：" IN_PASS

# 处理 IPv6 格式给 SCP 用
if [[ "$IN_IP" == *":"* ]]; then SCP_IP="[$IN_IP]"; else SCP_IP="$IN_IP"; fi

echo ">>> 正在上传..."
ssh-keygen -R "$IN_IP" >/dev/null 2>&1 || true
sshpass -p "$IN_PASS" scp -P $IN_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $CLIENT $IN_USER@${SCP_IP}:/root/

echo "上传完成！请前往入口服务器运行 in.sh"

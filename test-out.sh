#!/bin/bash
set -e

echo "==========================================="
echo " OpenVPN 出口服务器自动部署脚本 V1.1（IPv4 + IPv6 双栈 + 智能路由版）"
echo "==========================================="

#----------- 检测出口 IPv4 / IPv6 -----------
PUB_IP4=$(curl -s ipv4.ip.sb || curl -s ifconfig.me)
PUB_IP6=$(curl -s ipv6.ip.sb || echo "")

echo "出口 IPv4: $PUB_IP4"
echo "出口 IPv6: ${PUB_IP6:-未检测到 IPv6}"

#----------- 检测网卡 -----------
NIC=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
echo "出口网卡: $NIC"

apt update -y
apt install -y openvpn easy-rsa sshpass iptables-persistent curl

#----------- 重建 PKI -----------
rm -rf /etc/openvpn/easy-rsa
mkdir -p /etc/openvpn/easy-rsa
cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/
cd /etc/openvpn/easy-rsa

export EASYRSA_BATCH=1

echo ">>> 初始化 PKI ..."
./easyrsa init-pki

echo ">>> 生成 CA ..."
./easyrsa build-ca nopass

echo ">>> 生成服务器证书 ..."
./easyrsa build-server-full server nopass

echo ">>> 生成客户端证书 ..."
./easyrsa build-client-full client nopass

echo ">>> 生成 DH 参数 ..."
./easyrsa gen-dh

#----------- 拷贝证书 -----------
cp pki/ca.crt /etc/openvpn/
cp pki/dh.pem /etc/openvpn/
cp pki/issued/server.crt /etc/openvpn/
cp pki/private/server.key /etc/openvpn/
cp pki/issued/client.crt /etc/openvpn/
cp pki/private/client.key /etc/openvpn/

#----------- 查找空闲端口 -----------
find_free_port() {
  p=$1
  while ss -tuln | grep -q ":$p "; do
    p=$((p+1))
  done
  echo $p
}

UDP_PORT=$(find_free_port 1194)
TCP_PORT=$(find_free_port 443)

echo "UDP端口 = $UDP_PORT"
echo "TCP端口 = $TCP_PORT"

#----------- 启用 IPv4 / IPv6 转发 -----------

# 检查/etc/sysctl.conf是否存在，不存在则创建
if [ ! -f /etc/sysctl.conf ]; then
    echo "创建缺失的/etc/sysctl.conf文件..."
    touch /etc/sysctl.conf
fi

# 启用IP转发
echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "警告: 无法直接设置内核参数，将只修改配置文件"
sed -i 's/^#*net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf 2>/dev/null || echo "警告: 无法修改sysctl.conf，可能需要手动设置IP转发"

# 启用IPv6转发 (如果支持)
echo 1 >/proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo "注意: IPv6转发可能不支持，这是正常的"
sed -i 's/^#*net.ipv6.conf.all.forwarding=.*/net.ipv6.conf.all.forwarding=1/' /etc/sysctl.conf 2>/dev/null || true

#----------- 配置 NAT (IPv4) -----------
iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -o $NIC -j MASQUERADE

#----------- 配置 NAT (IPv6) 可用才启用 -----------
HAS_IPV6=0
if [[ -n "$PUB_IP6" ]]; then
    if command -v ip6tables >/dev/null; then
        HAS_IPV6=1
        echo "检测到 IPv6，启用 IPv6 NAT..."
        ip6tables -t nat -A POSTROUTING -s fd00:1234::/64 -o $NIC -j MASQUERADE 2>/dev/null || echo "警告: IPv6 NAT设置失败，可能不支持IPv6 NAT"
    fi
fi

# 保存防火墙规则，出错不中断脚本
mkdir -p /etc/iptables 2>/dev/null || true
iptables-save >/etc/iptables/rules.v4 2>/dev/null || echo "警告: 无法保存IPv4防火墙规则"
[[ $HAS_IPV6 -eq 1 ]] && ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true

#----------- server.conf（UDP）-----------
cat >/etc/openvpn/server.conf <<EOF
port $UDP_PORT
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem

server 10.8.0.0 255.255.255.0
server-ipv6 fd00:1234::/64

# 不再强制全局重定向，改为客户端可配置
# push "redirect-gateway def1 ipv6 bypass-dhcp"

# 只推送路由规则，让客户端决定如何处理
push "route 0.0.0.0 0.0.0.0"
push "route-ipv6 ::/0"

# DNS 设置
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS6 2620:119:35::35"
push "dhcp-option DNS6 2606:4700:4700::1111"

keepalive 10 120
cipher AES-256-GCM
auth SHA256
persist-key
persist-tun
verb 3
EOF

#----------- server-tcp.conf（TCP）-----------
cat >/etc/openvpn/server-tcp.conf <<EOF
port $TCP_PORT
proto tcp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem

server 10.9.0.0 255.255.255.0
server-ipv6 fd00:1234::/64

# 不再强制全局重定向，改为客户端可配置
# push "redirect-gateway def1 ipv6 bypass-dhcp"

# 只推送路由规则，让客户端决定如何处理
push "route 0.0.0.0 0.0.0.0"
push "route-ipv6 ::/0"

# DNS 设置
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS6 2620:119:35::35"
push "dhcp-option DNS6 2606:4700:4700::1111"

keepalive 10 120
cipher AES-256-GCM
auth SHA256
persist-key
persist-tun
verb 3
EOF

#----------- 启动服务 -----------
systemctl enable openvpn@server
systemctl restart openvpn@server
systemctl enable openvpn@server-tcp
systemctl restart openvpn@server-tcp

#----------- 生成 client.ovpn -----------
CLIENT=/root/client.ovpn
cat >$CLIENT <<EOF
client
dev tun
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
auth-nocache
resolv-retry infinite

remote $PUB_IP4 $UDP_PORT udp
remote $PUB_IP4 $TCP_PORT tcp
EOF

# 自动加入 IPv6 远程
if [[ $HAS_IPV6 -eq 1 ]]; then
cat >>$CLIENT <<EOF
remote $PUB_IP6 $UDP_PORT udp
remote $PUB_IP6 $TCP_PORT tcp
EOF
fi

cat >>$CLIENT <<EOF

<ca>
$(cat /etc/openvpn/ca.crt)
</ca>

<cert>
$(cat /etc/openvpn/client.crt)
</cert>

<key>
$(cat /etc/openvpn/client.key)
</key>
EOF

echo "client.ovpn 已生成：/root/client.ovpn"

#----------- 配置上传选项 -----------
echo -e "\n请选择配置文件上传方式:"
echo "1) 自动上传到入口服务器（需要SSH密码）"
echo "2) 仅生成配置文件，手动上传（适用于无法直接连接的情况）"
read -p "请选择 [1/2]: " UPLOAD_CHOICE
UPLOAD_CHOICE=${UPLOAD_CHOICE:-1}

if [[ "$UPLOAD_CHOICE" == "1" ]]; then
    #----------- 上传到入口服务器 -----------
    echo "请输入入口服务器 SSH 信息："
    read -p "入口 IP：" IN_IP
    read -p "入口端口(默认22)：" IN_PORT
    IN_PORT=${IN_PORT:-22}
    read -p "入口 SSH 用户(默认root)：" IN_USER
    IN_USER=${IN_USER:-root}
    read -p "入口 SSH 密码：" IN_PASS

    echo ">>> 正在清理旧的主机指纹..."
    mkdir -p /root/.ssh
    touch /root/.ssh/known_hosts
    # 尝试删除纯 IP 记录
    ssh-keygen -f /root/.ssh/known_hosts -R "$IN_IP" >/dev/null 2>&1 || true
    # 尝试删除 [IP]:Port 格式的记录 (非标准端口常见)
    ssh-keygen -f /root/.ssh/known_hosts -R "[$IN_IP]:$IN_PORT" >/dev/null 2>&1 || true

    echo ">>> 开始传输文件..."
    # 添加了 -o UserKnownHostsFile=/dev/null 作为双重保险，强制忽略指纹差异
    if sshpass -p "$IN_PASS" scp -P $IN_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $CLIENT $IN_USER@$IN_IP:/root/; then
        echo "上传成功！出口服务器部署完成！"
        echo "=========================================="
    else
        echo "警告: 文件上传失败。请使用以下方法手动传输文件:"
        echo "1. 使用SCP: scp $CLIENT 用户名@入口服务器IP:/root/"
        echo "2. 或直接下载文件: $CLIENT"
        echo "=========================================="
    fi
else
    echo -e "\n配置文件已生成但未上传。请手动传输以下文件到入口服务器的/root/目录:"
    echo "   $CLIENT"
    echo ""
    echo "可用的传输命令示例:"
    echo "   scp $CLIENT 用户名@入口服务器IP:/root/"
    echo ""
    echo "完成后，在入口服务器上运行入口脚本。"
    echo "=========================================="
fi

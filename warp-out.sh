#!/bin/bash
set -e

echo "==========================================="
echo " OpenVPN 出口服务器自动部署脚本（v3.3 修复版）"
echo " ✔ 协议强制 IPv6 (udp6/tcp6)"
echo " ✔ 修复 SSH 验证端口参数错误"
echo " ✔ 包含 NAT 修复与自动上传验证"
echo "==========================================="

#======================================================
#   1. 自动检测公网 IPv6
#======================================================
PUB_IP6=$(ip -6 addr show | grep global | grep -v temporary | awk '{print $2}' | cut -d'/' -f1 | head -n 1)

if [[ -z "$PUB_IP6" ]]; then
    echo "❌ 未检测到公网 IPv6，无法作为出口节点"
    exit 1
fi

echo "检测到出口公网 IPv6: $PUB_IP6"

#======================================================
#   2. 自动检测出口网卡
#======================================================
NIC=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
NIC=${NIC:-eth0}

echo "检测到出口网卡: $NIC"

apt update -y
apt install -y openvpn easy-rsa sshpass iptables-persistent

#======================================================
#   3. 初始化 PKI (证书生成)
#======================================================
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
openvpn --genkey secret ta.key

cp pki/ca.crt /etc/openvpn/
cp pki/dh.pem /etc/openvpn/
cp pki/issued/server.crt /etc/openvpn/
cp pki/private/server.key /etc/openvpn/
cp pki/issued/client.crt /etc/openvpn/
cp pki/private/client.key /etc/openvpn/
cp ta.key /etc/openvpn/

#======================================================
#   4. 端口配置
#======================================================
UDP_PORT=1196
TCP_PORT=443

echo "使用 UDP 端口: $UDP_PORT"
echo "使用 TCP 端口: $TCP_PORT"

#======================================================
#   5. 修复 NAT 转发
#======================================================
echo 1 >/proc/sys/net/ipv4/ip_forward
echo 1 >/proc/sys/net/ipv6/conf/all/forwarding

# UDP 网段 10.8.0.0/24 -> 出口网卡
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE

# TCP 网段 10.9.0.0/24 -> 出口网卡
iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o $NIC -j MASQUERADE

# IPv6 NAT
ip6tables -t nat -A POSTROUTING -s fd00:1234::/64 -o $NIC -j MASQUERADE

iptables-save >/etc/iptables/rules.v4
ip6tables-save >/etc/iptables/rules.v6

#======================================================
#   6. 生成服务端配置 server.conf (强制 udp6)
#======================================================
cat >/etc/openvpn/server.conf <<EOF
port $UDP_PORT
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
push "redirect-gateway def1 ipv6 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS6 2606:4700:4700::1111"
cipher AES-256-GCM
auth SHA256
persist-key
persist-tun
explicit-exit-notify 1
verb 3
EOF

#======================================================
#   7. 生成服务端配置 server-tcp.conf (强制 tcp6)
#======================================================
cat >/etc/openvpn/server-tcp.conf <<EOF
port $TCP_PORT
proto tcp6
dev tun
topology subnet
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-crypt ta.key
server 10.9.0.0 255.255.255.0
server-ipv6 fd00:1234::/64
push "redirect-gateway def1 ipv6 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS6 2606:4700:4700::1111"
cipher AES-256-GCM
auth SHA256
persist-key
persist-tun
verb 3
EOF

# 重启服务
systemctl enable openvpn@server
systemctl restart openvpn@server
systemctl enable openvpn@server-tcp
systemctl restart openvpn@server-tcp

#======================================================
#   8. 生成客户端配置 client.ovpn (强制 IPv6)
#======================================================
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

remote $PUB_IP6 $UDP_PORT udp6
remote $PUB_IP6 $TCP_PORT tcp6

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

echo "client.ovpn 已生成：/root/client.ovpn"

#======================================================
#   9. 自动上传与验证 (最终修复逻辑)
#======================================================
echo "=============== 上传 client.ovpn 到入口服务器 ==============="

read -p "入口服务器 IP（IPv6/IPv4，无需加[]）： " IN_IP
read -p "入口 SSH 端口（默认22）： " IN_PORT
IN_PORT=${IN_PORT:-22}
read -p "SSH 用户（默认 root）： " IN_USER
IN_USER=${IN_USER:-root}
read -p "SSH 密码： " IN_PASS

# 清理可能存在的方括号，只保留纯 IP
CLEAN_IP=$(echo "$IN_IP" | tr -d '[]')
# 清理旧主机的 Key 防止指纹报错
ssh-keygen -R "$CLEAN_IP" >/dev/null 2>&1 || true

# --- 核心修复：分离 SCP 和 SSH 的地址格式 ---
upload_and_verify() {
    local RAW_IP=$1      # 纯净 IP (给 ssh 用)
    local SCP_HOST=""    # 格式化 IP (给 scp 用)
    
    # 判断是否为 IPv6 (包含冒号)
    if [[ "$RAW_IP" == *":"* ]]; then
        SCP_HOST="[${RAW_IP}]"  # IPv6: scp 需要 [IP]
    else
        SCP_HOST="${RAW_IP}"    # IPv4: scp 直接用 IP
    fi

    local TARGET_FILE="/root/client.ovpn"
    
    echo "------------------------------------------------"
    echo ">>> 正在尝试传输..."
    echo "    SSH 目标 (验证用): ${RAW_IP}"
    echo "    SCP 目标 (传输用): ${SCP_HOST}"
    
    # 1. SCP 上传 (注意: -P 大写)
    sshpass -p "$IN_PASS" scp -P $IN_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "$CLIENT" "${IN_USER}@${SCP_HOST}:${TARGET_FILE}"
        
    if [ $? -eq 0 ]; then
        echo ">>> SCP 上传看似成功，正在进行最终验证..."
        
        # 2. SSH 远程验证 (注意: -p 小写，且使用 RAW_IP 不带括号)
        sshpass -p "$IN_PASS" ssh -p $IN_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${IN_USER}@${RAW_IP}" "ls -lh $TARGET_FILE"
            
        if [ $? -eq 0 ]; then
            echo "✅ 验证成功！文件确认存在于入口服务器。"
            return 0
        else
            echo "❌ 验证失败：虽然 SCP 没报错，但远程找不到文件 (可能是权限或路径问题)。"
            return 1
        fi
    else
        echo "❌ SCP 上传失败 (返回码 $?)。"
        return 1
    fi
}

# --- 执行 ---
# 直接传入清理后的 IP，由函数内部自动判断格式
if upload_and_verify "$CLEAN_IP"; then
    echo "======================================================="
    echo "🚀 OpenVPN 出口节点部署完成！"
    echo "✅ client.ovpn 已成功传输并验证。"
    echo "👉 下一步：请登录入口服务器，运行 warp-in.sh"
    echo "======================================================="
else
    echo "======================================================="
    echo "❌ 自动上传最终失败。"
    echo "   请手动下载 /root/client.ovpn 并上传到入口服务器的 /root/ 目录"
    echo "======================================================="
fi

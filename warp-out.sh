#!/bin/bash
set -e

echo "==========================================="
echo " OpenVPN 出口服务器自动部署脚本（最终稳定版 v3.0）"
echo " 保留全部功能：UDP+TCP、IPv6、上传等"
echo " 修复 NAT 错误 + 完整路由推送 + DNS 推送"
echo " 自动检测网卡，无需手动修改"
echo "==========================================="

#======================================================
#   自动检测公网 IPv6（绝不失败）
#======================================================
PUB_IP6=$(ip -6 addr show | grep global | grep -v temporary | awk '{print $2}' | cut -d'/' -f1 | head -n 1)

if [[ -z "$PUB_IP6" ]]; then
    echo "❌ 未检测到公网 IPv6，无法作为出口节点"
    exit 1
fi

echo "检测到出口公网 IPv6: $PUB_IP6"

#======================================================
#   自动检测出口网卡（自动识别默认路由）
#======================================================
NIC=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
NIC=${NIC:-eth0}

echo "检测到出口网卡: $NIC"

apt update -y
apt install -y openvpn easy-rsa sshpass iptables-persistent

#======================================================
#   初始化 PKI
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
#   端口保持你原来的设置
#======================================================
UDP_PORT=1196
TCP_PORT=443

echo "使用 UDP 端口: $UDP_PORT"
echo "使用 TCP 端口: $TCP_PORT"

#======================================================
#   修复 NAT（关键修复点）
#======================================================
echo 1 >/proc/sys/net/ipv4/ip_forward
echo 1 >/proc/sys/net/ipv6/conf/all/forwarding

# UDP 网段 10.8.0.0/24
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $NIC -j MASQUERADE

# TCP 网段 10.9.0.0/24
iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o $NIC -j MASQUERADE

# IPv6 NAT（保持原样）
ip6tables -t nat -A POSTROUTING -s fd00:1234::/64 -o $NIC -j MASQUERADE

iptables-save >/etc/iptables/rules.v4
ip6tables-save >/etc/iptables/rules.v6

#======================================================
#   server.conf（保持原样，仅 NAT 修复）
#======================================================
cat >/etc/openvpn/server.conf <<EOF
port $UDP_PORT
proto udp
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
#   server-tcp.conf（保持原样，仅 NAT 修复）
#======================================================
cat >/etc/openvpn/server-tcp.conf <<EOF
port $TCP_PORT
proto tcp
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

systemctl enable openvpn@server
systemctl restart openvpn@server
systemctl enable openvpn@server-tcp
systemctl restart openvpn@server-tcp

#======================================================
#   生成 client.ovpn（保持原设计）
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

remote $PUB_IP6 $UDP_PORT udp
remote $PUB_IP6 $TCP_PORT tcp

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
#   自动上传（增强版：带验证和错误显示）
#======================================================
echo "=============== 上传 client.ovpn 到入口服务器 ==============="

# 1. 获取输入信息
read -p "入口服务器 IP（IPV4/IPV6，IPV6无需加[]）： " IN_IP
read -p "入口 SSH 端口（默认22）： " IN_PORT
IN_PORT=${IN_PORT:-22}
read -p "SSH 用户（默认 root）： " IN_USER
IN_USER=${IN_USER:-root}
read -p "SSH 密码： " IN_PASS

# 清理旧的 host key 防止指纹报错
ssh-keygen -R "$IN_IP" >/dev/null 2>&1 || true
# 针对 IPv6 去掉可能用户手动输入的方括号，脚本后面会自动加
CLEAN_IP=$(echo "$IN_IP" | tr -d '[]')

# 2. 定义上传和验证函数
upload_and_verify() {
    local TYPE=$1
    local TARGET_IP=$2
    local TARGET_FILE="/root/client.ovpn"
    
    echo "------------------------------------------------"
    echo ">>> 正在尝试通过 $TYPE 传输..."
    
    # 尝试上传 (去掉 2>/dev/null 以便看到报错)
    sshpass -p "$IN_PASS" scp -P $IN_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "$CLIENT" "${IN_USER}@${TARGET_IP}:${TARGET_FILE}"
        
    if [ $? -eq 0 ]; then
        echo ">>> SCP 命令执行完毕，正在进行远程验证..."
        
        # 远程验证文件是否存在
        sshpass -p "$IN_PASS" ssh -P $IN_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            "${IN_USER}@${TARGET_IP}" "ls -lh $TARGET_FILE"
            
        if [ $? -eq 0 ]; then
            echo "✅ 验证成功！文件已存在于入口服务器：$TARGET_FILE"
            return 0
        else
            echo "❌ 验证失败：SCP 似乎成功了，但远程没找到文件 (可能路径无权限)"
            return 1
        fi
    else
        echo "❌ SCP 上传命令失败 (请检查上方报错信息)"
        return 1
    fi
}

# 3. 执行上传循环
UPLOAD_SUCCESS=0

for i in 1 2 3; do
    echo "=== 第 $i 次尝试上传 ==="
    
    # 优先尝试 IPv6 (加上方括号)
    if upload_and_verify "IPv6" "[${CLEAN_IP}]"; then
        UPLOAD_SUCCESS=1
        break
    fi
    
    # 备选：尝试 IPv4 (不加方括号，万一你输的是v4地址)
    if [[ "$CLEAN_IP" != *":"* ]]; then
        if upload_and_verify "IPv4" "${CLEAN_IP}"; then
            UPLOAD_SUCCESS=1
            break
        fi
    fi
    
    echo ">>> 等待 2 秒后重试..."
    sleep 2
done

echo "======================================================="
if [ $UPLOAD_SUCCESS -eq 1 ]; then
    echo "🚀 OpenVPN 出口节点部署完成！"
    echo "✅ client.ovpn 已成功传输并验证。"
    echo "👉 下一步：请登录入口服务器，运行 warp-in.sh"
else
    echo "❌ 自动上传失败。"
    echo "   请手动下载 /root/client.ovpn 并上传到入口服务器的 /root/ 目录"
fi
echo "======================================================="

#!/bin/bash
clear
echo "==============================================="
echo "   OpenVPN 出口服务器自动部署脚本（最终稳定版）"
echo "==============================================="

#--------------------------
# 基础组件安装
#--------------------------
apt update -y
apt install -y openvpn easy-rsa curl iptables iptables-persistent sshpass

#--------------------------
# 检测出口 IPv6
#--------------------------
OUT_IPV6=$(ip -6 addr show | grep global | awk '{print $2}' | sed 's/\/.*//')
OUT_NIC=$(ip -6 addr | grep global | awk '{print $NF}' | head -1)

echo "检测到出口服务器 IPv6：$OUT_IPV6"
echo "出口服务器网卡：$OUT_NIC"

if [[ -z "$OUT_IPV6" ]]; then
    echo "❌ 未检测到可用 IPv6，无法作为出口服务器。退出。"
    exit 1
fi

#--------------------------
# 配置 Easy-RSA PKI
#--------------------------
EASYRSA_DIR="/etc/openvpn/easy-rsa"
rm -rf $EASYRSA_DIR
make-cadir $EASYRSA_DIR
cd $EASYRSA_DIR

./easyrsa init-pki
echo | ./easyrsa build-ca nopass
./easyrsa gen-dh
./easyrsa build-server-full server nopass
./easyrsa build-client-full client nopass

#--------------------------
# 生成 server.conf
#--------------------------
cat >/etc/openvpn/server.conf <<EOF
port 1194
proto tcp6
dev tun
ca $EASYRSA_DIR/pki/ca.crt
cert $EASYRSA_DIR/pki/issued/server.crt
key $EASYRSA_DIR/pki/private/server.key
dh $EASYRSA_DIR/pki/dh.pem
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1 ipv6 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-GCM
persist-key
persist-tun
status openvpn-status.log
verb 3
EOF

#--------------------------
# 启动 OpenVPN
#--------------------------
systemctl enable openvpn@server
systemctl restart openvpn@server

sleep 2
echo ">>> OpenVPN 出口服务器已启动"

#--------------------------
# 生成 client.ovpn
#--------------------------
cat >/root/client.ovpn <<EOF
client
dev tun
proto tcp6
remote $OUT_IPV6 1194
resolv-retry infinite
nobind
persist-key
persist-tun
cipher AES-256-GCM
verb 3
<ca>
$(cat $EASYRSA_DIR/pki/ca.crt)
</ca>
<cert>
$(cat $EASYRSA_DIR/pki/issued/client.crt)
</cert>
<key>
$(cat $EASYRSA_DIR/pki/private/client.key)
</key>
EOF

echo "client.ovpn 已生成：/root/client.ovpn"

#--------------------------
# 是否上传到入口服务器？
#--------------------------
read -p "是否上传 client.ovpn 到入口服务器？(y/n): " UP
[[ "$UP" != "y" ]] && echo "跳过上传步骤。" && exit 0

read -p "入口服务器 IP（可填 IPv4 / IPv6）: " IN_IP
read -p "入口服务器 SSH 端口(默认22): " IN_PORT
IN_PORT=${IN_PORT:-22}
read -p "入口 SSH 用户(默认 root): " IN_USER
IN_USER=${IN_USER:-root}
read -p "入口 SSH 密码: " IN_PASS

# 清理 known_hosts
ssh-keygen -f "/root/.ssh/known_hosts" -R "$IN_IP" 2>/dev/null

#--------------------------
# 选择 IPv4/IPv6 上传方式
#--------------------------
echo "请选择上传方式："
echo "1) IPv4 上传"
echo "2) IPv6 上传"
read -p "输入选项(1/2): " MODE

if [[ "$MODE" == "1" ]]; then
    SCP_CMD="scp -4 -P $IN_PORT /root/client.ovpn ${IN_USER}@${IN_IP}:/root/"
else
    SCP_CMD="scp -6 -P $IN_PORT /root/client.ovpn ${IN_USER}@${IN_IP}:/root/"
fi

#--------------------------
# 自动重试上传 3 次
#--------------------------
for i in 1 2 3; do
    echo "第 $i 次上传尝试..."
    sshpass -p "$IN_PASS" $SCP_CMD && SUCCESS=1 && break
    sleep 2
done

if [[ "$SUCCESS" == "1" ]]; then
    echo "✅ 上传成功！"
else
    echo "❌ 上传失败（3 次尝试均失败）"
fi

echo "==============================================="
echo " OpenVPN 出口服务器部署完成！"
echo " client.ovpn 路径：/root/client.ovpn"
echo "==============================================="

exit 0

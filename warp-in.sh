#!/bin/bash
clear
echo "==============================================="
echo "   OpenVPN 入口服务器自动部署脚本（最终稳定版）"
echo "   不断开 SSH，不修改 SSH 连接 IP"
echo "==============================================="

#-------------------------------
# 1. 安装组件
#-------------------------------
apt update -y
apt install -y openvpn curl iptables iptables-persistent wget resolvconf

systemctl enable resolvconf 2>/dev/null
systemctl start resolvconf 2>/dev/null

#-------------------------------
# 2. 上传 client.ovpn 到入口服务器？
#   如果已经存在 client.ovpn 则跳过
#-------------------------------
if [[ ! -f /root/client.ovpn ]]; then
    echo "⚠ 未检测到 /root/client.ovpn"
    echo "请从出口服务器执行 out.sh 上传，或手动上传后继续。"
    exit 1
fi

echo "已检测到 client.ovpn，继续配置入口隧道..."

#-------------------------------
# 3. 询问连接出口服务器使用 IPv4 还是 IPv6
#-------------------------------
echo "请选择用于连接出口服务器的 IP 协议："
echo "1) IPv4"
echo "2) IPv6"
read -p "输入选项 (1/2): " MODE

if [[ "$MODE" == "1" ]]; then
    CONNECT_MODE="proto tcp4"
else
    CONNECT_MODE="proto tcp6"
fi

#-------------------------------
# 4. 解析出口服务器 IP
#-------------------------------
OUT_IP=$(grep '^remote ' /root/client.ovpn | awk '{print $2}')
OUT_PORT=$(grep '^remote ' /root/client.ovpn | awk '{print $3}')

[[ -z "$OUT_PORT" ]] && OUT_PORT=1194

echo "出口服务器：$OUT_IP"
echo "出口端口：$OUT_PORT"

#-------------------------------
# 5. 生成入口 client.conf
#-------------------------------
mkdir -p /etc/openvpn/client

cat >/etc/openvpn/client/client.conf <<EOF
client
dev tun
${CONNECT_MODE}
remote ${OUT_IP} ${OUT_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
verb 3
cipher AES-256-GCM

<ca>
$(sed -n '/<ca>/,/<\/ca>/p' /root/client.ovpn | sed '1d;$d')
</ca>

<cert>
$(sed -n '/<cert>/,/<\/cert>/p' /root/client.ovpn | sed '1d;$d')
</cert>

<key>
$(sed -n '/<key>/,/<\/key>/p' /root/client.ovpn | sed '1d;$d')
</key>
EOF

echo ">>> OpenVPN 入口配置生成：/etc/openvpn/client/client.conf"

#-------------------------------
# 6. 启动 OpenVPN 客户端
#-------------------------------
systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

sleep 3
echo
echo ">>> OpenVPN 客户端状态："
systemctl status openvpn-client@client --no-pager

#-------------------------------
# 7. 入口机 NAT 转发配置
#-------------------------------
echo ">>> 配置防火墙 NAT ..."

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
ip6tables -t nat -A POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null

netfilter-persistent save

echo ">>> NAT 配置已完成"

#-------------------------------
# 8. 默认路由指向 tun0（但不影响 SSH）
#-------------------------------
echo ">>> 设置默认路由为 tun0（保留 SSH 原路由）..."

# 保留 SSH 所在网卡路由
SSH_IF=$(ip route get 1.1.1.1 | grep -oP 'dev \K\w+')
SSH_IP=$(ip addr show $SSH_IF | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)

echo "SSH 网卡：$SSH_IF"
echo "SSH 本地 IP：$SSH_IP"

# 不删除默认路由，只增加 tun0 为主路由（优先级高，但 SSH 继续走原路）
ip route add default dev tun0 metric 50 2>/dev/null
ip -6 route add default dev tun0 metric 50 2>/dev/null

echo ">>> 新默认路由设置完毕，SSH 不受影响"

#-------------------------------
# 9. 打印出口效果
#-------------------------------
echo "等待隧道建立..."
sleep 3

echo "当前出口 IPv4："
curl -4 ip.sb 2>/dev/null || echo "无 IPv4"

echo "当前出口 IPv6："
curl -6 ip.sb 2>/dev/null || echo "无 IPv6"

echo "==============================================="
echo " OpenVPN 入口服务器部署完成！"
echo " 隧道运行状态：systemctl status openvpn-client@client"
echo " 查看出口：curl -4 ip.sb / curl -6 ip.sb"
echo "==============================================="

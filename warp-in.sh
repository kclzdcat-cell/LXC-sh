#!/bin/bash
clear
echo "==============================================="
echo "     OpenVPN 入口服务器自动部署脚本（稳定版）"
echo "==============================================="

apt update -y
apt install -y openvpn sshpass iptables iptables-persistent curl

read -p "请输入出口服务器 IPv6 地址: " OUT_IP
read -p "请输入出口服务器 SSH 用户名（默认 root）: " OUT_USER
OUT_USER=${OUT_USER:-root}
read -p "请输入出口服务器 SSH 密码: " OUT_PASS
read -p "请输入出口服务器 SSH 端口（默认22）: " OUT_PORT
OUT_PORT=${OUT_PORT:-22}

echo ">>> 开始从出口服务器下载 client.ovpn..."

ssh-keygen -f "/root/.ssh/known_hosts" -R "$OUT_IP" 2>/dev/null

# 自动重试 3 次
for i in 1 2 3; do
    echo "尝试下载（第 $i 次）..."
    sshpass -p "$OUT_PASS" scp -6 -P $OUT_PORT ${OUT_USER}@[${OUT_IP}]:/root/client.ovpn /root/ && OK=1 && break
    sleep 2
done

if [[ "$OK" != "1" ]]; then
    echo "❌ 下载失败，请检查 SSH 密码或 IPv6 连接"
    exit 1
fi

echo "✔ client.ovpn 下载成功！"

mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

echo ">>> 等待隧道建立..."
sleep 3

echo "当前出口 IPv4："
curl -4 ip.sb

echo "当前出口 IPv6："
curl -6 ip.sb

echo "==============================================="
echo " OpenVPN 入口服务器已完成部署！"
echo " 流量已走出口隧道"
echo "==============================================="

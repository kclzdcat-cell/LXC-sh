#!/bin/bash
echo "=== OpenVPN 入口服务器自动配置脚本 ==="

read -p "请输入出口服务器 IP: " OUTIP

echo "=== 1. 安装 OpenVPN ==="
apt update -y
apt install -y openvpn wget

echo "=== 2. 下载出口服务器的 client.ovpn ==="
wget http://$OUTIP:8000/client.ovpn -O /root/client.ovpn 2>/dev/null

if [ ! -f /root/client.ovpn ]; then
    echo "❌ 无法下载 client.ovpn，请确保出口服务器运行： python3 -m http.server 8000"
    exit 1
fi

echo "=== 3. 启动 OpenVPN 客户端 ==="
nohup openvpn --config /root/client.ovpn > /root/ovpn.log 2>&1 &

echo "=== 4. 设置开机自启 ==="
cat >/etc/systemd/system/openvpn-client.service <<EOF
[Unit]
Description=OpenVPN Client
After=network.target

[Service]
ExecStart=/usr/sbin/openvpn --config /root/client.ovpn
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable openvpn-client

echo ""
echo "===================================="
echo " OpenVPN 入口服务器已成功连接出口服务器！"
echo " 当前出口将使用：$OUTIP"
echo "===================================="

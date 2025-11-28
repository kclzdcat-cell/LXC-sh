#----------- 生成 入口部署脚本 (in.sh) -----------
IN_SCRIPT=/root/in.sh
cat >$IN_SCRIPT <<'EOF'
#!/bin/bash
set -e
echo "==========================================="
echo "      OpenVPN 入口部署 (SSH 防断连版)"
echo "==========================================="

echo ">>> 安装组件..."
apt update -y
apt install -y openvpn iptables iptables-persistent

if [ ! -f /root/client.ovpn ]; then
    echo "错误：未找到 /root/client.ovpn"
    exit 1
fi

echo ">>> 部署配置文件..."
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

echo ">>> 配置路由规则..."
# 修复点2：强制忽略服务端可能推送的任何网关重定向指令
# 修复点3：手动添加仅针对 IPv4 的重定向规则
cat >> /etc/openvpn/client/client.conf <<CONF

# --- 路由防断连保护 ---
# 忽略服务端推送的 redirect-gateway，防止它意外接管 IPv6
pull-filter ignore "redirect-gateway"
pull-filter ignore "route-ipv6"
pull-filter ignore "ifconfig-ipv6"

# 仅在本地启用 IPv4 网关重定向 (不影响 IPv6)
redirect-gateway def1

# 强制 DNS
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1
CONF

echo ">>> 开启 IPv4 转发..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
# 确保不禁用 IPv6
sed -i '/disable_ipv6/d' /etc/sysctl.conf
sysctl -p

echo ">>> 配置 NAT..."
iptables -t nat -F
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
netfilter-persistent save

echo ">>> 启动 VPN..."
systemctl enable openvpn-client@client
systemctl restart openvpn-client@client

echo ">>> 等待连接..."
sleep 5
echo "==========================================="
echo "验证结果："
curl -4 --connect-timeout 5 ip.sb && echo "IPv4 接管成功" || echo "IPv4 获取失败"
echo "IPv6 (SSH) 应保持畅通"
EOF
chmod +x $IN_SCRIPT
echo "入口部署脚本已生成：/root/in.sh"


#----------- 上传到入口服务器 -----------
echo "请输入入口服务器 SSH 信息："
read -p "入口 IP：" IN_IP
read -p "入口端口(默认22)：" IN_PORT
IN_PORT=${IN_PORT:-22}
read -p "入口 SSH 用户(默认root)：" IN_USER
IN_USER=${IN_USER:-root}
read -p "入口 SSH 密码：" IN_PASS

echo ">>> 清理旧指纹..."
mkdir -p /root/.ssh
touch /root/.ssh/known_hosts
ssh-keygen -f /root/.ssh/known_hosts -R "$IN_IP" >/dev/null 2>&1 || true
ssh-keygen -f /root/.ssh/known_hosts -R "[$IN_IP]:$IN_PORT" >/dev/null 2>&1 || true

echo ">>> 上传文件..."
sshpass -p "$IN_PASS" scp -P $IN_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $CLIENT $IN_SCRIPT $IN_USER@$IN_IP:/root/

echo "上传成功！"
echo "请登录入口服务器，运行：bash /root/in.sh"
echo "==========================================="

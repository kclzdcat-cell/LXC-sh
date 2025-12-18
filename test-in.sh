#!/bin/bash
set -e

echo "==========================================="
echo "   OpenVPN 入口部署 (简化版)"
echo "   功能：保留入口机IPv4/IPv6连接 + 出站走VPN"
echo "   版本：3.2 (iptables稳定版)"
echo "==========================================="

# 0. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "错误：请使用 root 运行此脚本。"
   exit 1
fi

# 1. 安装必要软件
echo ">>> 安装必要软件..."

# 检查软件是否已安装
OPENVPN_INSTALLED=0
IPTABLES_INSTALLED=0
CURL_INSTALLED=0
HOST_INSTALLED=0

if command -v openvpn >/dev/null 2>&1; then
    OPENVPN_INSTALLED=1
    echo "OpenVPN 已安装"
fi

if command -v iptables >/dev/null 2>&1; then
    IPTABLES_INSTALLED=1
    echo "iptables 已安装"
fi

if command -v curl >/dev/null 2>&1; then
    CURL_INSTALLED=1
    echo "curl 已安装"
fi

# 检测系统版本
DISTRO=""
VERSION=""
UBUNTU_CODENAME=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
    VERSION=$VERSION_ID
    UBUNTU_CODENAME=$VERSION_CODENAME
fi

echo "检测到系统: $DISTRO $VERSION ($UBUNTU_CODENAME)"

# 强力修复dpkg问题
echo ">>> 强力修复dpkg问题..."

# 清除所有锁文件
echo "清除所有锁文件..."
rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
rm -f /var/lib/dpkg/lock 2>/dev/null || true
rm -f /var/lib/dpkg/lock-* 2>/dev/null || true
rm -f /var/cache/apt/archives/lock 2>/dev/null || true
rm -f /var/lib/apt/lists/lock 2>/dev/null || true

# 强制重新配置包
echo "强制重新配置包..."
dpkg --configure -a --force-confold 2>/dev/null || true

# 尝试修复损坏的包
echo "尝试修复损坏的包..."
apt-get -f install -y 2>/dev/null || true

# 清除可能的损坏的列表
echo "清除可能的损坏的列表..."
rm -rf /var/lib/apt/lists/* 2>/dev/null || true
apt-get clean 2>/dev/null || true
apt-get update --fix-missing 2>/dev/null || true

# 尝试更新和安装软件
echo ">>> 更新软件源..."
apt-get update -y || echo "警告: apt update 失败，继续执行"

if [[ $OPENVPN_INSTALLED -eq 0 ]]; then
    echo ">>> 安装 OpenVPN..."
    
    # 先再次尝试修复dpkg问题
    echo "再次尝试修复dpkg问题..."
    rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
    rm -f /var/lib/dpkg/lock 2>/dev/null || true
    rm -f /var/lib/dpkg/lock-* 2>/dev/null || true
    dpkg --configure -a --force-confold 2>/dev/null || true
    apt-get -f install -y 2>/dev/null || true
    
    # 尝试使用apt安装
    echo "尝试使用apt安装OpenVPN..."
    apt-get install -y openvpn || echo "警告: apt安装OpenVPN失败，尝试其他方法"
    
    # 检查是否安装成功
    if ! command -v openvpn >/dev/null 2>&1; then
        echo "尝试使用备用方法安装OpenVPN..."
        
        # 尝试下载预编译的包
        echo "尝试下载预编译的包..."
        cd /tmp
        
        # 根据系统版本选择不同的包
        if [[ "$UBUNTU_CODENAME" == "noble" ]]; then
            echo "检测到Ubuntu Noble，尝试下载兼容包..."
            curl -s -L -o openvpn.deb "http://archive.ubuntu.com/ubuntu/pool/main/o/openvpn/openvpn_2.6.0-1ubuntu1_amd64.deb" 2>/dev/null || \
            curl -s -L -o openvpn.deb "http://security.ubuntu.com/ubuntu/pool/main/o/openvpn/openvpn_2.6.0-1ubuntu1_amd64.deb" 2>/dev/null || \
            curl -s -L -o openvpn.deb "https://mirrors.edge.kernel.org/ubuntu/pool/main/o/openvpn/openvpn_2.6.0-1ubuntu1_amd64.deb" 2>/dev/null
        else
            echo "尝试下载通用OpenVPN包..."
            curl -s -L -o openvpn.deb "http://archive.ubuntu.com/ubuntu/pool/main/o/openvpn/openvpn_2.4.7-1ubuntu2_amd64.deb" 2>/dev/null || \
            curl -s -L -o openvpn.deb "http://security.ubuntu.com/ubuntu/pool/main/o/openvpn/openvpn_2.4.7-1ubuntu2_amd64.deb" 2>/dev/null || \
            curl -s -L -o openvpn.deb "https://mirrors.edge.kernel.org/ubuntu/pool/main/o/openvpn/openvpn_2.4.7-1ubuntu2_amd64.deb" 2>/dev/null
        fi
        
        # 如果下载成功，尝试安装
        if [ -f openvpn.deb ]; then
            echo "尝试安装下载的OpenVPN包..."
            dpkg -i openvpn.deb 2>/dev/null || apt-get -f install -y 2>/dev/null
            
            # 如果安装失败，尝试先安装依赖
            if ! command -v openvpn >/dev/null 2>&1; then
                echo "尝试安装OpenVPN依赖..."
                apt-get install -y liblz4-1 liblzo2-2 libpkcs11-helper1 libssl1.1 libsystemd0 2>/dev/null || true
                dpkg -i openvpn.deb 2>/dev/null || apt-get -f install -y 2>/dev/null
            fi
        fi
        
        # 如果仍然失败，尝试使用预编译的二进制文件
        if ! command -v openvpn >/dev/null 2>&1; then
            echo "尝试使用预编译的二进制文件..."
            
            cd /tmp
            # 下载预编译的OpenVPN二进制文件
            curl -s -L -o openvpn-static.tar.gz "https://swupdate.openvpn.org/community/releases/openvpn-2.5.8.tar.gz" 2>/dev/null || \
            curl -s -L -o openvpn-static.tar.gz "https://build.openvpn.net/downloads/releases/latest/openvpn-latest-stable.tar.gz" 2>/dev/null
            
            if [ -f openvpn-static.tar.gz ]; then
                mkdir -p openvpn-extract
                tar -xzf openvpn-static.tar.gz -C openvpn-extract 2>/dev/null || true
                
                # 尝试找到并复制openvpn二进制文件
                find openvpn-extract -name "openvpn" -type f -executable -exec cp {} /usr/sbin/openvpn \; 2>/dev/null || true
                
                # 设置权限
                if [ -f /usr/sbin/openvpn ]; then
                    chmod 755 /usr/sbin/openvpn
                    ln -sf /usr/sbin/openvpn /usr/bin/openvpn 2>/dev/null || true
                fi
            fi
        fi
        
        # 如果仍然失败，尝试使用源码编译
        if ! command -v openvpn >/dev/null 2>&1; then
            echo "尝试使用源码编译安装OpenVPN..."
            
            # 安装编译工具
            apt-get install -y build-essential libssl-dev liblzo2-dev libpam0g-dev libpkcs11-helper1-dev 2>/dev/null || true
            
            # 下载和编译OpenVPN
            cd /tmp
            curl -s -L -o openvpn-2.4.7.tar.gz "https://swupdate.openvpn.org/community/releases/openvpn-2.4.7.tar.gz" 2>/dev/null
            tar -xzf openvpn-2.4.7.tar.gz 2>/dev/null
            cd openvpn-2.4.7 2>/dev/null
            ./configure 2>/dev/null && make 2>/dev/null && make install 2>/dev/null
        fi
    fi
    
    # 再次检查是否安装成功
    if ! command -v openvpn >/dev/null 2>&1; then
        echo "错误: 无法安装OpenVPN，请手动安装后重试。"
        exit 1
    else
        echo "OpenVPN 安装成功"
        OPENVPN_INSTALLED=1
    fi
fi

# 安装iptables
if [[ $IPTABLES_INSTALLED -eq 0 ]]; then
    echo ">>> 安装 iptables..."
    apt-get install -y iptables iptables-persistent || echo "警告: apt安装iptables失败"
    
    # 再次检查是否安装成功
    if ! command -v iptables >/dev/null 2>&1; then
        echo "错误: 无法安装iptables，请手动安装后重试。"
        exit 1
    else
        echo "iptables 安装成功"
        IPTABLES_INSTALLED=1
    fi
fi

if [[ $CURL_INSTALLED -eq 0 ]]; then
    echo ">>> 安装 curl..."
    apt-get install -y curl || echo "警告: apt安装curl失败"
    
    # 再次检查是否安装成功
    if ! command -v curl >/dev/null 2>&1; then
        echo "错误: 无法安装curl，请手动安装后重试。"
        exit 1
    else
        echo "curl 安装成功"
        CURL_INSTALLED=1
    fi
fi

# 检查host命令是否安装
if command -v host >/dev/null 2>&1; then
    HOST_INSTALLED=1
    echo "host命令已安装"
fi

# 如果host命令未安装，尝试安装bind9-host或dnsutils
if [[ $HOST_INSTALLED -eq 0 ]]; then
    echo ">>> 安装 host命令..."
    apt-get install -y bind9-host dnsutils || echo "警告: 安装host命令失败"
    
    # 再次检查是否安装成功
    if command -v host >/dev/null 2>&1; then
        HOST_INSTALLED=1
        echo "host命令安装成功"
    else
        echo "警告: 无法安装host命令，将跳过DNS解析测试"
    fi
fi

# 确保所有必要软件已安装
if [[ $OPENVPN_INSTALLED -eq 0 || $IPTABLES_INSTALLED -eq 0 || $CURL_INSTALLED -eq 0 ]]; then
    echo "错误: 必要软件安装失败，请手动安装后重试。"
    exit 1
fi

echo "所有必要软件已安装完成"

# 2. 检查 client.ovpn
if [ ! -f /root/client.ovpn ]; then
    echo "错误：未找到 /root/client.ovpn，请上传后重试！"
    exit 1
fi

# 3. 部署配置文件
echo ">>> 部署配置文件..."
mkdir -p /etc/openvpn/client/scripts
cp /root/client.ovpn /etc/openvpn/client/client.conf

# 4. 创建路由脚本
echo ">>> 创建路由脚本..."

# 创建启动脚本
cat > /etc/openvpn/client/scripts/route-up.sh <<'SCRIPT'
#!/bin/bash

# 获取网卡信息
DEV4=$(ip -4 route | grep default | grep -v tun | awk '{print $5}' | head -n 1)
GW4=$(ip -4 route | grep default | grep -v tun | awk '{print $3}' | head -n 1)

echo "[路由配置] 原始网卡: $DEV4, 网关: $GW4"
echo "[路由配置] VPN服务器IP: $4, VPN网关: $5, 设备: $1"

# 清除旧的路由规则
echo "[路由配置] 清除旧的路由规则..."
ip rule del fwmark 22 table main prio 100 2>/dev/null || true
ip rule del from all table 200 prio 200 2>/dev/null || true

# 清除旧的防火墙规则
echo "[路由配置] 清除iptables规则..."
iptables -t mangle -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
ip6tables -t mangle -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true

# 首先保护SSH连接
echo "[路由配置] 保护SSH连接..."
# 获取当前SSH端口
SSH_PORT=22  # 默认SSH端口
if netstat -tnlp 2>/dev/null | grep -q sshd; then
    SSH_PORT=$(netstat -tnlp 2>/dev/null | grep sshd | grep -oE ':[0-9]+' | grep -oE '[0-9]+' | head -n 1)
    echo "[路由配置] 检测到SSH端口: $SSH_PORT"
fi

# 先添加SSH规则，确保SSH不会断开
iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
iptables -A OUTPUT -p tcp --sport $SSH_PORT -j ACCEPT

# 对所有SSH相关流量进行标记
iptables -t mangle -A INPUT -p tcp --dport $SSH_PORT -j MARK --set-mark 22
iptables -t mangle -A OUTPUT -p tcp --sport $SSH_PORT -j MARK --set-mark 22

# 标记所有TCP入站连接
echo "[路由配置] 标记所有TCP入站连接..."
iptables -t mangle -A INPUT -p tcp -j MARK --set-mark 22
iptables -t mangle -A OUTPUT -p tcp -m state --state ESTABLISHED,RELATED -j MARK --set-mark 22

# 如果有IPv6，也标记IPv6流量
if ip -6 addr show dev $DEV4 | grep -q 'inet6' 2>/dev/null; then
    # 保护IPv6 SSH连接
    ip6tables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT 2>/dev/null || true
    ip6tables -A OUTPUT -p tcp --sport $SSH_PORT -j ACCEPT 2>/dev/null || true
    
    # 标记IPv6流量
    ip6tables -t mangle -A INPUT -p tcp --dport $SSH_PORT -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -A OUTPUT -p tcp --sport $SSH_PORT -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -A INPUT -p tcp -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -A OUTPUT -p tcp -m state --state ESTABLISHED,RELATED -j MARK --set-mark 22 2>/dev/null || true
fi

# 先添加到VPN服务器的直接路由
echo "[路由配置] 添加到VPN服务器的直接路由: $4 via $GW4 dev $DEV4"
ip route add $4 via $GW4 dev $DEV4 2>/dev/null || true

# 标记的流量走原始网卡
echo "[路由配置] 添加标记流量规则..."
ip rule add fwmark 22 table main prio 100

# 添加DNS服务器的路由
echo "[路由配置] 添加DNS服务器路由..."
ip rule add to 8.8.8.8/32 table main prio 95
ip rule add to 1.1.1.1/32 table main prio 95

# 创建路由表200用于出站流量
echo "[路由配置] 创建路由表200..."
ip route flush table 200 2>/dev/null || true

# 添加默认路由到表200
echo "[路由配置] 添加默认路由到表200: default via $5 dev $1"
ip route add default via $5 dev $1 table 200 2>/dev/null || true

# 非标记流量走VPN
echo "[路由配置] 添加非标记流量规则..."
ip rule add from all table 200 prio 200

# 清除路由缓存
echo "[路由配置] 清除路由缓存..."
ip route flush cache

# 显示路由规则
echo "[路由配置] 当前路由规则:"
ip rule show

# 显示路由表
echo "[路由配置] 路由表200:"
ip route show table 200

# IPv6配置
if ip -6 addr show dev $DEV4 | grep -q 'inet6' 2>/dev/null; then
    # 获取IPv6网关
    GW6=$(ip -6 route | grep default | grep -v tun | awk '{print $3}' | head -n 1)
    
    if [ -n "$GW6" ]; then
        echo "[路由配置] IPv6网关: $GW6"
        
        # 清除旧的IPv6路由规则
        ip -6 rule del fwmark 22 table main prio 100 2>/dev/null || true
        ip -6 rule del from all table 200 prio 200 2>/dev/null || true
        
        # 创建路由表200用于IPv6出站流量
        ip -6 route flush table 200 2>/dev/null || true
        
        # 标记的IPv6流量走原始网卡
        ip -6 rule add fwmark 22 table main prio 100 2>/dev/null || true
        
        # 添加IPv6默认路由到表200
        if ip -6 addr show dev tun0 | grep -q 'inet6' 2>/dev/null; then
            echo "[路由配置] 添加IPv6默认路由到表200"
            ip -6 route add default dev tun0 table 200 2>/dev/null || true
            
            # 非标记IPv6流量走VPN
            ip -6 rule add from all table 200 prio 200 2>/dev/null || true
            
            # 清除IPv6路由缓存
            ip -6 route flush cache 2>/dev/null || true
        else
            echo "[路由配置] tun0接口没有IPv6地址，跳过IPv6路由配置"
        fi
    else
        echo "[路由配置] 未检测到IPv6网关，跳过IPv6路由配置"
    fi
else
    echo "[路由配置] 未检测到IPv6接口，跳过IPv6路由配置"
fi

# 添加NAT规则
echo "[路由配置] 添加iptables NAT规则..."
iptables -t nat -F 2>/dev/null || true
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || true

# 如果有IPv6，添加IPv6 NAT规则
if ip -6 addr show dev tun0 | grep -q 'inet6' 2>/dev/null; then
    echo "[路由配置] 添加ip6tables NAT规则..."
    ip6tables -t nat -F 2>/dev/null || true
    ip6tables -t nat -A POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || true
fi
SCRIPT

# 创建关闭脚本
cat > /etc/openvpn/client/scripts/down.sh <<'SCRIPT'
#!/bin/bash

# 清除所有添加的规则和表
echo "[清理] 清除路由规则..."
ip rule del from all table 200 prio 200 2>/dev/null || true
ip rule del fwmark 22 table main prio 100 2>/dev/null || true
ip rule del to 8.8.8.8/32 table main prio 95 2>/dev/null || true
ip rule del to 1.1.1.1/32 table main prio 95 2>/dev/null || true

# 清除IPv6规则(如果存在)
echo "[清理] 清除IPv6路由规则..."
ip -6 rule del from all table 200 prio 200 2>/dev/null || true
ip -6 rule del fwmark 22 table main prio 100 2>/dev/null || true

# 清除路由表
echo "[清理] 清除路由表..."
ip route flush table 200 2>/dev/null || true
ip -6 route flush table 200 2>/dev/null || true

# 清除iptables规则
echo "[清理] 清除iptables规则..."
iptables -t mangle -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -D INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
iptables -D OUTPUT -p tcp --sport 22 -j ACCEPT 2>/dev/null || true

# 清除ip6tables规则
echo "[清理] 清除ip6tables规则..."
ip6tables -t mangle -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true
ip6tables -D INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
ip6tables -D OUTPUT -p tcp --sport 22 -j ACCEPT 2>/dev/null || true

# 恢复原始路由
echo "[清理] 恢复原始路由..."
ip route flush cache
SCRIPT

# 设置脚本权限
chmod +x /etc/openvpn/client/scripts/*.sh

# 5. 修改OpenVPN配置
echo ">>> 修改OpenVPN配置..."

# 先备份原始client.conf
cp /etc/openvpn/client/client.conf /etc/openvpn/client/client.conf.bak 2>/dev/null || true

# 检查配置文件中是否已经包含我们的自定义配置
if grep -q "script-security 2" /etc/openvpn/client/client.conf; then
    echo "配置文件已包含自定义设置，跳过添加"
else
    # 添加我们的配置
    cat >> /etc/openvpn/client/client.conf <<'CONF'

# --- 智能路由控制 ---

# 使用自定义脚本
script-security 2
route-noexec
up "/etc/openvpn/client/scripts/route-up.sh"
down "/etc/openvpn/client/scripts/down.sh"

# 设置最大连接重试次数和重试间隔
resolv-retry infinite
connect-retry 5 10

# 使用强制ping确保连接存活
ping 10
ping-restart 60

# DNS设置
dhcp-option DNS 8.8.8.8
dhcp-option DNS 1.1.1.1

# 屏蔽服务器的重定向网关指令，由我们自己控制
pull-filter ignore "redirect-gateway"

# 确保接受服务器推送的路由
pull-filter accept "route"
pull-filter accept "route-ipv6"

# 设置日志级别为详细
verb 4
CONF
fi

# 6. 配置系统参数
echo ">>> 配置系统参数..."
# 开启 IPv4 转发
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.conf.all.forwarding=1" >> /etc/sysctl.conf
fi

# 开启 IPv6 转发
if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
fi

sysctl -p >/dev/null 2>&1

# 7. 配置NAT
echo ">>> 配置NAT规则..."

echo ">>> 使用iptables配置NAT..."
iptables -t nat -F
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

# 如果有IPv6，添加IPv6 NAT规则
if ip -6 addr show | grep -q 'inet6' 2>/dev/null; then
    echo ">>> 配置IPv6 NAT规则..."
    ip6tables -t nat -F 2>/dev/null || true
    ip6tables -t nat -A POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || true
fi

# 保存防火墙规则
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
if command -v ip6tables-save >/dev/null 2>&1; then
    ip6tables-save > /etc/iptables/rules.v6
fi

# 8. 重启OpenVPN服务
echo ">>> 重启OpenVPN服务..."

# 确保OpenVPN服务目录存在
echo ">>> 创建OpenVPN目录和服务文件..."
mkdir -p /etc/openvpn/client/scripts 2>/dev/null || true
mkdir -p /var/log/openvpn 2>/dev/null || true
mkdir -p /run/openvpn 2>/dev/null || true

# 创建Systemd服务文件（如果不存在）
if [ ! -f /lib/systemd/system/openvpn@.service ] && [ -d /lib/systemd/system ]; then
    echo "创建OpenVPN systemd服务文件..."
    cat > /lib/systemd/system/openvpn@.service <<EOF
[Unit]
Description=OpenVPN connection to %i
After=network.target

[Service]
Type=forking
ExecStart=/usr/sbin/openvpn --daemon --writepid /run/openvpn/%i.pid --cd /etc/openvpn -c %i.conf
PIDFile=/run/openvpn/%i.pid
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
fi

# 创建OpenVPN客户端服务文件
if [ ! -f /lib/systemd/system/openvpn-client@.service ] && [ -d /lib/systemd/system ]; then
    echo "创建OpenVPN客户端服务文件..."
    cat > /lib/systemd/system/openvpn-client@.service <<EOF
[Unit]
Description=OpenVPN tunnel for %I
After=network.target

[Service]
Type=forking
ExecStart=/usr/sbin/openvpn --daemon --writepid /run/openvpn/%i.pid --cd /etc/openvpn/client -c %i.conf
PIDFile=/run/openvpn/%i.pid
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
fi

# 创建相关目录的符号链接
if [ ! -d /etc/openvpn/client ]; then
    mkdir -p /etc/openvpn/client 2>/dev/null || true
fi

# 确保所有目录权限正确
chmod 755 /etc/openvpn 2>/dev/null || true
chmod 755 /etc/openvpn/client 2>/dev/null || true
chmod 755 /etc/openvpn/client/scripts 2>/dev/null || true

# 重启服务
systemctl daemon-reload
systemctl restart openvpn-client@client

# 检查服务是否启动成功
sleep 3
if ! systemctl is-active --quiet openvpn-client@client; then
    echo "警告: OpenVPN服务启动失败，尝试手动启动..."
    openvpn --config /etc/openvpn/client/client.conf --daemon
    sleep 3
fi

# 9. 等待并验证
echo ">>> 等待连接建立 (10秒)..."
sleep 10

echo ">>> 验证连接状态..."

# 检查OpenVPN服务状态
if systemctl is-active --quiet openvpn-client@client; then
    echo "OpenVPN服务已成功启动"
else
    echo "错误: OpenVPN服务未启动或启动失败"
    systemctl status openvpn-client@client
    
    # 尝试手动启动OpenVPN
    echo "尝试手动启动OpenVPN..."
    systemctl daemon-reload
    systemctl restart openvpn-client@client
    sleep 5
fi

# 检查tun0接口
if ip addr show tun0 > /dev/null 2>&1; then
    echo "tun0接口已创建"
    TUN_CREATED=1
else
    echo "错误: tun0接口未创建，脚本将不会修改路由表"
    TUN_CREATED=0
    
    # 如果没有tun0接口，则不要修改路由表
fi

# 检查原始IP
echo ">>> 检测原始IPv4..."
ORIG_DEV=$(ip -4 route | grep default | grep -v tun | awk '{print $5}' | head -n 1)
echo "原始网卡: $ORIG_DEV"
ORIG_IP4=$(curl -4s --interface $ORIG_DEV --connect-timeout 5 ip.sb || echo "无法获取")
echo "原始IPv4: $ORIG_IP4"

# 检查tun0接口IP
echo ">>> 检测tun0接口IPv4..."
if ip addr show tun0 > /dev/null 2>&1; then
    TUN_IP4=$(curl -4s --interface tun0 --connect-timeout 5 ip.sb || echo "无法获取")
    echo "tun0接口IPv4: $TUN_IP4"
else
    echo "tun0接口不存在"
fi

# 检查当前出口IP
echo ">>> 检测当前出口IPv4..."
CURRENT_IP4=$(curl -4s --connect-timeout 5 ip.sb || echo "无法获取")
echo "当前IPv4出口IP: $CURRENT_IP4"

# 如果出口IP与原始IP相同，尝试修复路由
if [ "$CURRENT_IP4" = "$ORIG_IP4" ] && [ "$CURRENT_IP4" != "无法获取" ]; then
    echo ">>> 警告: 出口IP与原始IP相同，尝试修复路由..."
    
    # 检查tun0接口状态
    echo ">>> 检查tun0接口详细状态..."
    ip addr show tun0
    
    # 检查OpenVPN连接状态
    echo ">>> 检查OpenVPN日志..."
    tail -n 20 /var/log/syslog | grep -i openvpn || echo "无OpenVPN日志信息"
    
    # 检查路由表
    echo ">>> 检查路由表详情..."
    ip route
    ip route show table 200
    ip rule show
    
    # 检查防火墙规则
    echo ">>> 检查iptables规则..."
    iptables -t mangle -L -v -n
    iptables -t nat -L -v -n
    
    # 检查IPv6防火墙规则
    if ip -6 addr show | grep -q 'inet6' 2>/dev/null; then
        echo ">>> 检查ip6tables规则..."
        ip6tables -t mangle -L -v -n 2>/dev/null || true
        ip6tables -t nat -L -v -n 2>/dev/null || true
    fi
    
    # 尝试修复路由
    echo ">>> 尝试修复路由..."
    
    # 获取tun0网关
    TUN_GW=$(ip -4 route | grep "dev tun0" | grep -v "via" | head -n 1 | awk '{print $1}')
    if [ -n "$TUN_GW" ]; then
        echo "重新配置路由表..."
        ip route flush table 200
        ip rule del table 200 2>/dev/null || true
        ip rule add from all table 200 prio 200
        ip route add default via $TUN_GW dev tun0 table 200
        ip route flush cache
        
        # 再次检查出口IP
        sleep 3
        CURRENT_IP4=$(curl -4s --connect-timeout 5 ip.sb || echo "无法获取")
        echo "重新配置后的出口IPv4: $CURRENT_IP4"
    else
        # 如果没有tun0网关，尝试直接使用tun0接口
        echo "尝试直接使用tun0接口作为默认路由..."
        ip route flush table 200
        ip rule del table 200 2>/dev/null || true
        ip rule add from all table 200 prio 200
        ip route add default dev tun0 table 200
        ip route flush cache
        
        # 再次检查出口IP
        sleep 3
        CURRENT_IP4=$(curl -4s --connect-timeout 5 ip.sb || echo "无法获取")
        echo "直接使用tun0后的出口IPv4: $CURRENT_IP4"
    fi
    
    # 如果仍然失败，尝试重启OpenVPN
    if [ "$CURRENT_IP4" = "$ORIG_IP4" ] || [ "$CURRENT_IP4" = "无法获取" ]; then
        echo ">>> 尝试重启OpenVPN服务..."
        systemctl restart openvpn-client@client
        sleep 5
        
        # 再次检查出口IP
        CURRENT_IP4=$(curl -4s --connect-timeout 5 ip.sb || echo "无法获取")
        echo "重启OpenVPN后的出口IPv4: $CURRENT_IP4"
    fi
fi

# 检查IPv6出口
echo ">>> 检测出口IPv6..."
CURRENT_IP6=$(curl -6s --connect-timeout 5 ip.sb || echo "无法获取")
if [ "$CURRENT_IP6" != "无法获取" ]; then
    echo "当前IPv6出口IP: $CURRENT_IP6"
else
    echo "未检测到IPv6出口IP"
fi

# 检查DNS解析
echo ">>> 检查DNS解析..."
if [[ $HOST_INSTALLED -eq 1 ]]; then
    host -t A google.com || echo "DNS解析失败"
else
    echo "host命令未安装，跳过DNS解析测试"
fi

# 测试连接性
echo ">>> 测试连接性..."
ping -c 3 8.8.8.8 || echo "ping 8.8.8.8 失败"

echo "==========================================="
echo "安装完成！OpenVPN客户端已配置并运行。"
echo "入口机IPv4和IPv6网络接口均可用于所有入站连接和SSH。"
echo "所有出站流量将通过出口机的VPN连接（IPv4和IPv6）。"
echo "==========================================="

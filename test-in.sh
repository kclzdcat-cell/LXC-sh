#!/bin/bash
set -e

echo "==========================================="
echo "   OpenVPN 入口部署 (IPv4+IPv6 智能路由版)"
echo "   功能：保留SSH入口IP + 安全控制出站流量"
echo "   版本：1.6（解决openvpn失败问题）"
echo "==========================================="

# 0. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "错误：请使用 root 运行此脚本。"
   exit 1
fi

# 1. 系统检测和软件安装
echo ">>> 系统检测和软件安装..."

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

# 修复dpkg中断问题
echo ">>> 修复可能的dpkg中断问题..."
# 先清除可能的锁文件
rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
rm -f /var/lib/dpkg/lock 2>/dev/null || true
rm -f /var/cache/apt/archives/lock 2>/dev/null || true
rm -f /var/lib/apt/lists/lock 2>/dev/null || true

# 运行dpkg --configure -a修复中断的包
dpkg --configure -a 2>/dev/null || true

# 尝试修夏损坏的包
apt-get -f install -y 2>/dev/null || true

# 检查软件是否已安装
OPENVPN_INSTALLED=0
IPTABLES_INSTALLED=0
CURL_INSTALLED=0

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

install_required_packages() {
    local MISSING_PACKAGES=""
    
    if [[ $OPENVPN_INSTALLED -eq 0 ]]; then
        MISSING_PACKAGES="$MISSING_PACKAGES openvpn"
    fi
    
    if [[ $IPTABLES_INSTALLED -eq 0 ]]; then
        MISSING_PACKAGES="$MISSING_PACKAGES iptables iptables-persistent"
    fi
    
    if [[ $CURL_INSTALLED -eq 0 ]]; then
        MISSING_PACKAGES="$MISSING_PACKAGES curl"
    fi
    
    if [[ -n "$MISSING_PACKAGES" ]]; then
        echo "尝试安装缺失的软件包: $MISSING_PACKAGES"
        
        # 再次尝试修复可能的 dpkg 问题
        echo "再次检查并修复dpkg问题..."
        rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
        rm -f /var/lib/dpkg/lock 2>/dev/null || true
        rm -f /var/cache/apt/archives/lock 2>/dev/null || true
        rm -f /var/lib/apt/lists/lock 2>/dev/null || true
        dpkg --configure -a 2>/dev/null || true
        
        # 针对不同系统采用不同的安装方式
        if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
            # Ubuntu/Debian系统
            if [[ "$UBUNTU_CODENAME" == "oracular" || "$UBUNTU_CODENAME" == "noble" ]]; then
                # 特殊处理oracular版本 (旧版本或不支持的版本)
                echo "检测到Ubuntu oracular版本，正在使用备用安装方法..."
                
                # 先修复dpkg问题
                echo "先修复dpkg问题..."
                dpkg --configure -a 2>/dev/null || true
                apt-get -f install -y 2>/dev/null || true
                
                # 安装必要的依赖包
                echo "安装必要的依赖包..."
                cd /tmp
                
                # 尝试安装lsb-release
                if ! dpkg -l | grep -q lsb-release; then
                    echo "安装lsb-release..."
                    curl -s -L -o lsb-release.deb "https://mirrors.edge.kernel.org/ubuntu/pool/main/l/lsb/lsb-release_11.1.0ubuntu2_all.deb" 2>/dev/null
                    dpkg -i lsb-release.deb 2>/dev/null || apt-get -f install -y 2>/dev/null || true
                fi
                
                # 安装必要的OpenVPN依赖包
                DEPS_PKGS="liblz4-1 liblzo2-2 libpkcs11-helper1 libssl1.1 libsystemd0 debconf netfilter-persistent iptables-persistent"
                for pkg in $DEPS_PKGS; do
                    if ! dpkg -l | grep -q "$pkg"; then
                        echo "安装依赖包: $pkg"
                        curl -s -L -o "${pkg}.deb" "https://mirrors.edge.kernel.org/ubuntu/pool/main/${pkg:0:1}/${pkg%%-*}/${pkg}_*.deb" 2>/dev/null || true
                        dpkg -i "${pkg}.deb" 2>/dev/null || true
                    fi
                done
                
                # 手动创建netfilter-persistent命令
                if ! command -v netfilter-persistent >/dev/null 2>&1; then
                    echo "创建netfilter-persistent命令..."
                    cat > /usr/sbin/netfilter-persistent <<'EOF'
#!/bin/bash
case "$1" in
  save)
    iptables-save > /etc/iptables/rules.v4
    if command -v ip6tables-save >/dev/null 2>&1; then
      ip6tables-save > /etc/iptables/rules.v6
    fi
    echo "iptables rules saved"
    ;;
  reload)
    iptables-restore < /etc/iptables/rules.v4
    if command -v ip6tables-restore >/dev/null 2>&1 && [ -f /etc/iptables/rules.v6 ]; then
      ip6tables-restore < /etc/iptables/rules.v6
    fi
    echo "iptables rules reloaded"
    ;;
  *)
    echo "Usage: $0 {save|reload}"
    exit 1
    ;;
esac
EOF
                    chmod +x /usr/sbin/netfilter-persistent
                    mkdir -p /etc/iptables
                fi
                
                # 直接尝试下载和安装二进制包
                if [[ $OPENVPN_INSTALLED -eq 0 ]]; then
                    echo "尝试直接安装OpenVPN..."
                    
                    # 尝试不同版本的OpenVPN
                    OPENVPN_VERSIONS=("2.6.0-1ubuntu1" "2.5.0-1ubuntu1" "2.4.7-1ubuntu2" "2.4.4-2ubuntu1")
                    
                    for version in "${OPENVPN_VERSIONS[@]}"; do
                        echo "尝试安装OpenVPN版本: $version"
                        # 尝试多个镜像源
                        curl -s -L -o openvpn.deb "https://mirrors.edge.kernel.org/ubuntu/pool/main/o/openvpn/openvpn_${version}_amd64.deb" 2>/dev/null || \
                        curl -s -L -o openvpn.deb "http://archive.ubuntu.com/ubuntu/pool/main/o/openvpn/openvpn_${version}_amd64.deb" 2>/dev/null || \
                        curl -s -L -o openvpn.deb "http://security.ubuntu.com/ubuntu/pool/main/o/openvpn/openvpn_${version}_amd64.deb" 2>/dev/null
                        
                        if [ -f openvpn.deb ]; then
                            # 使用dpkg直接安装
                            dpkg -i openvpn.deb 2>/dev/null || apt-get -f install -y 2>/dev/null
                            # 如果安装失败，尝试修复dpkg并重新安装
                            if ! command -v openvpn >/dev/null 2>&1; then
                                echo "尝试修复dpkg并重新安装..."
                                dpkg --configure -a 2>/dev/null || true
                                apt-get -f install -y 2>/dev/null || true
                                dpkg -i openvpn.deb 2>/dev/null || true
                            fi
                            
                            # 检查是否安装成功
                            if command -v openvpn >/dev/null 2>&1; then
                                OPENVPN_INSTALLED=1
                                echo "OpenVPN 版本 $version 安装成功"
                                break
                            fi
                        fi
                    done
                    
                    # 如果上述方法都失败，尝试使用预编译的二进制包
                    if [[ $OPENVPN_INSTALLED -eq 0 ]]; then
                        echo "尝试使用预编译的OpenVPN二进制包..."
                        
                        cd /tmp
                        # 下载预编译的OpenVPN二进制文件
                        curl -s -L -o openvpn-static.tar.gz "https://swupdate.openvpn.org/community/releases/openvpn-install-2.4.9-I601-Win7.exe" 2>/dev/null || \
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
                        
                        # 如果还是失败，尝试使用源码编译
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
                        
                        # 再次检查是否安装成功
                        if command -v openvpn >/dev/null 2>&1; then
                            OPENVPN_INSTALLED=1
                            echo "OpenVPN 源码编译安装成功"
                        else
                            echo "警告: OpenVPN安装失败"
                        fi
                    fi
                fi
                
                # 确保OpenVPN服务目录存在
                mkdir -p /etc/openvpn/client 2>/dev/null || true
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
                
                # 直接确保iptables已安装 (通常基本系统已安装)
                if [[ $CURL_INSTALLED -eq 0 ]]; then
                    echo "尝试直接安装curl..."
                    cd /tmp
                    curl -s -L -o curl.deb "https://mirrors.edge.kernel.org/ubuntu/pool/main/c/curl/curl_7.74.0-1ubuntu2_amd64.deb" 2>/dev/null || wget -q "https://mirrors.edge.kernel.org/ubuntu/pool/main/c/curl/curl_7.74.0-1ubuntu2_amd64.deb" -O curl.deb
                    dpkg -i curl.deb 2>/dev/null || apt-get -f install -y 2>/dev/null
                    # 检查是否安装成功
                    if command -v curl >/dev/null 2>&1; then
                        CURL_INSTALLED=1
                        echo "curl 安装成功"
                    else
                        echo "警告: curl安装失败"
                    fi
                fi
            else
                # 其他Ubuntu/Debian版本
                apt-get update -y || echo "警告: apt update 失败，继续执行"
                apt-get install -y $MISSING_PACKAGES || echo "警告: 部分软件包安装失败"
            fi
        elif [[ "$DISTRO" == "centos" || "$DISTRO" == "rhel" || "$DISTRO" == "fedora" ]]; then
            # CentOS/RHEL/Fedora系统
            yum -y update || echo "警告: yum update 失败，继续执行"
            yum -y install epel-release || echo "警告: epel-release 安装失败"
            yum -y install openvpn iptables curl || echo "警告: 部分软件包安装失败"
        else
            echo "未知系统类型: $DISTRO，尝试使用apt..."
            apt-get update -y || echo "警告: apt update 失败，继续执行"
            apt-get install -y $MISSING_PACKAGES || echo "警告: 部分软件包安装失败"
        fi
        
        # 检查是否安装成功
        if command -v openvpn >/dev/null 2>&1; then OPENVPN_INSTALLED=1; fi
        if command -v iptables >/dev/null 2>&1; then IPTABLES_INSTALLED=1; fi
        if command -v curl >/dev/null 2>&1; then CURL_INSTALLED=1; fi
    fi
}

# 检查是否需要安装软件
if [[ $OPENVPN_INSTALLED -eq 0 || $IPTABLES_INSTALLED -eq 0 || $CURL_INSTALLED -eq 0 ]]; then
    echo "警告: 检测到缺失的软件包。"
    read -p "是否尝试安装缺失的软件包? [Y/n] " INSTALL_CHOICE
    
    if [[ -z "$INSTALL_CHOICE" || "$INSTALL_CHOICE" == "y" || "$INSTALL_CHOICE" == "Y" ]]; then
        install_required_packages
    else
        echo "跳过安装步骤，继续执行脚本..."
    fi
fi

# 再次检查关键软件
if ! command -v openvpn >/dev/null 2>&1; then
    echo "错误：OpenVPN未安装，脚本可能无法正常工作。"
    read -p "是否继续执行? [y/N] " CONTINUE_CHOICE
    if [[ "$CONTINUE_CHOICE" != "y" && "$CONTINUE_CHOICE" != "Y" ]]; then
        echo "退出脚本。"
        exit 1
    fi
fi

# 2. 检查 client.ovpn
if [ ! -f /root/client.ovpn ]; then
    echo "错误：未找到 /root/client.ovpn，请上传后重试！"
    exit 1
fi

# 3. 部署配置文件
echo ">>> 部署配置文件..."
mkdir -p /etc/openvpn/client
cp /root/client.ovpn /etc/openvpn/client/client.conf

# 4. 修改配置 (智能路由模式)
echo ">>> 配置路由规则..."

# 创建路由脚本目录
mkdir -p /etc/openvpn/client/scripts

# 清理旧的配置 (如果之前运行过)
rm -f /etc/openvpn/client/up.sh
rm -f /etc/openvpn/client/down.sh
rm -f /etc/openvpn/client/scripts/*

# 尝试清理可能残留的路由规则
ip -6 rule del table main priority 1000 2>/dev/null || true
ip -6 rule del from all table 200 2>/dev/null || true

# 检测IPv6能力
HAS_IPV6=0
OUTPUT_IPV6=$(curl -s --max-time 5 -6 ipv6.ip.sb || echo "")
if [[ -n "$OUTPUT_IPV6" ]]; then
    HAS_IPV6=1
    echo ">>> 检测到可用的IPv6: $OUTPUT_IPV6"
fi

# 配置IPV6处理方式
echo -e "\n配置IPv6路由:\n"
echo "1) 使用出口服务器的IPv6（推荐，如果出口服务器有IPv6）"
echo "2) 使用本机IPv6（保持IPv6独立）"
echo "3) 禁用所有IPv6路由（只使用IPv4）"
read -p "请选择IPv6配置方式 [1/2/3] (默认:1): " IPV6_CHOICE
IPV6_CHOICE=${IPV6_CHOICE:-1}

# 配置SSH端口处理方式
echo -e "\nSSH端口设置:\n"
echo "1) 只保留标准SSH端口(22)走原始网卡"
echo "2) 保留所有SSH相关端口(包括转发到LXC容器的端口)走原始网卡"
echo "3) 保留所有TCP端口连接走原始网卡(适用于随机分配的端口)"
read -p "请选择SSH端口处理方式 [1/2/3] (默认:3): " SSH_PORT_CHOICE
SSH_PORT_CHOICE=${SSH_PORT_CHOICE:-3}

if [[ "$SSH_PORT_CHOICE" == "2" ]]; then
    read -p "请输入需要保留的额外SSH端口(以空格分隔，例如 '2222 2223 2224'): " EXTRA_SSH_PORTS
elif [[ "$SSH_PORT_CHOICE" == "3" ]]; then
    echo "将保留所有TCP端口连接，包括随机分配的SSH端口"
fi

# 创建启动脚本
cat > /etc/openvpn/client/scripts/route-up.sh <<'SCRIPT'
#!/bin/bash

# 加载保留端口设置
if [ -f "/etc/openvpn/client/scripts/ssh_ports.conf" ]; then
    source "/etc/openvpn/client/scripts/ssh_ports.conf"
fi

# 获取网卡信息
DEV4=$(ip -4 route | grep default | grep -v tun | awk '{print $5}' | head -n 1)
GW4=$(ip -4 route | grep default | grep -v tun | awk '{print $3}' | head -n 1)

# 清除旧的路由规则
echo "清除旧的路由规则..."
ip rule del to 8.8.8.8/32 table main prio 95 2>/dev/null || true
ip rule del to 1.1.1.1/32 table main prio 95 2>/dev/null || true
ip rule del to 108.61.196.101/32 table main prio 95 2>/dev/null || true
ip rule del fwmark 22 table main prio 100 2>/dev/null || true
ip rule del from all table 200 prio 200 2>/dev/null || true

# 清除路由表
ip route flush table 200 2>/dev/null || true

# 确保有到VPN服务器的直接路由
echo "添加到VPN服务器的直接路由: $4 via $GW4 dev $DEV4"
ip route add $4 via $GW4 dev $DEV4 2>/dev/null || true

# 添加到DNS服务器的路由
echo "添加DNS服务器和IP查询服务的路由规则..."
ip rule add to 8.8.8.8/32 table main prio 95 2>/dev/null || true
ip rule add to 1.1.1.1/32 table main prio 95 2>/dev/null || true
ip rule add to 108.61.196.101/32 table main prio 95 2>/dev/null || true

# 标记的流量走原始网卡
echo "添加标记流量的路由规则..."
ip rule add fwmark 22 table main prio 100 2>/dev/null || true

# 添加默认路由到表200
echo "添加默认路由到表200: default via $5 dev $1"
ip route add default via $5 dev $1 table 200 2>/dev/null || true

# 添加策略路由规则
echo "添加策略路由规则..."
ip rule add from all table 200 prio 200 2>/dev/null || true

# 清除路由缓存
ip route flush cache

# 显示当前路由表状态
echo "当前路由表状态:"
ip route show table 200
echo "当前路由规则:"
ip rule show
ip rule add from all to 224.0.0.0/4 table main prio 100 2>/dev/null || true
ip rule add from all to 255.255.255.255 table main prio 100 2>/dev/null || true

# SSH流量标记配置

# 创建规则来处理SSH流量
# 注意: 这条规则已经在上面添加过了，这里不需要重复添加

if [[ "$SSH_PORT_CHOICE" == "1" ]]; then
    # 选项1: 只标记标准22端口
    echo "只保留标准22端口走原始网卡"
    iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 22
    iptables -t mangle -A INPUT -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A INPUT -p tcp --dport 22 -j MARK --set-mark 22
    iptables -t mangle -A FORWARD -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A FORWARD -p tcp --dport 22 -j MARK --set-mark 22

elif [[ "$SSH_PORT_CHOICE" == "2" && -n "$EXTRA_SSH_PORTS" ]]; then
    # 选项2: 标准22端口和指定的额外端口
    echo "保留标准22端口和指定的额外端口"
    # 标记22端口
    iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 22
    iptables -t mangle -A INPUT -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A INPUT -p tcp --dport 22 -j MARK --set-mark 22
    iptables -t mangle -A FORWARD -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A FORWARD -p tcp --dport 22 -j MARK --set-mark 22
    
    # 标记额外SSH端口
    echo "为额外SSH端口添加标记规则：$EXTRA_SSH_PORTS"
    for port in $EXTRA_SSH_PORTS; do
        iptables -t mangle -A OUTPUT -p tcp --sport $port -j MARK --set-mark 22
        iptables -t mangle -A OUTPUT -p tcp --dport $port -j MARK --set-mark 22
        iptables -t mangle -A INPUT -p tcp --sport $port -j MARK --set-mark 22
        iptables -t mangle -A INPUT -p tcp --dport $port -j MARK --set-mark 22
        iptables -t mangle -A FORWARD -p tcp --sport $port -j MARK --set-mark 22
        iptables -t mangle -A FORWARD -p tcp --dport $port -j MARK --set-mark 22
    done

elif [[ "$SSH_PORT_CHOICE" == "3" ]]; then
    # 选项3: 保留所有TCP端口连接，包括随机分配的SSH端口
    echo "保留所有TCP连接和转发端口"
    
    # 1. 标记标准SSH端口
    iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 22
    iptables -t mangle -A INPUT -p tcp --sport 22 -j MARK --set-mark 22
    iptables -t mangle -A INPUT -p tcp --dport 22 -j MARK --set-mark 22
    
    # 2. 标记所有转发流量
    iptables -t mangle -A FORWARD -p tcp -j MARK --set-mark 22
    
    # 3. 标记所有来自外部的新连接(即入站连接)
    iptables -t mangle -A INPUT -p tcp -m state --state NEW -j MARK --set-mark 22
fi

# 注意: 这些规则已经在route-up.sh脚本中添加过了
# 清除路由缓存
ip route flush cache
SCRIPT

# 创建关闭脚本
cat > /etc/openvpn/client/scripts/down.sh <<'SCRIPT'
#!/bin/bash

# 加载保留端口设置
if [ -f "/etc/openvpn/client/scripts/ssh_ports.conf" ]; then
    source "/etc/openvpn/client/scripts/ssh_ports.conf"
fi

# 清除所有添加的规则和表
ip rule del from all table 200 prio 200 2>/dev/null || true
ip rule del fwmark 22 table main prio 100 2>/dev/null || true
ip rule del from all to 224.0.0.0/4 table main prio 100 2>/dev/null || true 
ip rule del from all to 255.255.255.255 table main prio 100 2>/dev/null || true

# 清除IPv6规则(如果存在)
ip -6 rule del from all table 200 prio 200 2>/dev/null || true
ip -6 rule del fwmark 22 table main prio 100 2>/dev/null || true

# 清除标准SSH端口的iptables标记规则
if [[ "$SSH_PORT_CHOICE" == "1" || "$SSH_PORT_CHOICE" == "2" ]]; then
    # 清除标准22端口规则
    iptables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D INPUT -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D INPUT -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D FORWARD -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D FORWARD -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    
    ip6tables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -D INPUT -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -D INPUT -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -D FORWARD -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    ip6tables -t mangle -D FORWARD -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    
    # 处理额外的SSH端口
    if [[ "$SSH_PORT_CHOICE" == "2" && -n "$EXTRA_SSH_PORTS" ]]; then
        echo "清除额外SSH端口的标记规则..."
        for port in $EXTRA_SSH_PORTS; do
            iptables -t mangle -D OUTPUT -p tcp --sport $port -j MARK --set-mark 22 2>/dev/null || true
            iptables -t mangle -D OUTPUT -p tcp --dport $port -j MARK --set-mark 22 2>/dev/null || true
            iptables -t mangle -D INPUT -p tcp --sport $port -j MARK --set-mark 22 2>/dev/null || true
            iptables -t mangle -D INPUT -p tcp --dport $port -j MARK --set-mark 22 2>/dev/null || true
            iptables -t mangle -D FORWARD -p tcp --sport $port -j MARK --set-mark 22 2>/dev/null || true
            iptables -t mangle -D FORWARD -p tcp --dport $port -j MARK --set-mark 22 2>/dev/null || true
            
            ip6tables -t mangle -D OUTPUT -p tcp --sport $port -j MARK --set-mark 22 2>/dev/null || true
            ip6tables -t mangle -D OUTPUT -p tcp --dport $port -j MARK --set-mark 22 2>/dev/null || true
            ip6tables -t mangle -D INPUT -p tcp --sport $port -j MARK --set-mark 22 2>/dev/null || true
            ip6tables -t mangle -D INPUT -p tcp --dport $port -j MARK --set-mark 22 2>/dev/null || true
            ip6tables -t mangle -D FORWARD -p tcp --sport $port -j MARK --set-mark 22 2>/dev/null || true
            ip6tables -t mangle -D FORWARD -p tcp --dport $port -j MARK --set-mark 22 2>/dev/null || true
        done
    fi
elif [[ "$SSH_PORT_CHOICE" == "3" ]]; then
    # 清除标准22端口规则
    iptables -t mangle -D OUTPUT -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D INPUT -p tcp --sport 22 -j MARK --set-mark 22 2>/dev/null || true
    iptables -t mangle -D INPUT -p tcp --dport 22 -j MARK --set-mark 22 2>/dev/null || true
    
    # 清除转发规则
    iptables -t mangle -D FORWARD -p tcp -j MARK --set-mark 22 2>/dev/null || true
    
    # 清除新连接标记规则
    iptables -t mangle -D INPUT -p tcp -m state --state NEW -j MARK --set-mark 22 2>/dev/null || true
fi
SCRIPT

# 设置脚本权限
chmod +x /etc/openvpn/client/scripts/*.sh

# IPv6配置创建
cat > /etc/openvpn/client/scripts/ipv6-setup.sh <<'SCRIPT'
#!/bin/bash

IPV6_CHOICE=$1

if [[ "$IPV6_CHOICE" == "1" ]]; then
    # 启用IPv6 VPN路由
    echo "配置IPv6通过VPN路由..."
    
    # 记录原始IPv6路由
    GW6=$(ip -6 route show default | grep -v tun | head -n1 | awk '{print $3}')
    DEV6=$(ip -6 route show default | grep -v tun | head -n1 | awk '{print $5}')
    
    if [[ -n "$GW6" && -n "$DEV6" ]]; then
        echo "$GW6 $DEV6" > /etc/openvpn/client/scripts/orig_gateway6.txt
        
        # 添加IPv6策略路由
        ip -6 route add default dev tun0 table 200
        ip -6 rule add fwmark 22 table main prio 100
        ip -6 rule add from all table 200 prio 200
        ip -6 route flush cache
    else
        echo "没有找到有效的IPv6路由，跳过IPv6配置"
    fi
elif [[ "$IPV6_CHOICE" == "2" ]]; then
    echo "保持IPv6使用本机直接连接..."
    # 不做任何IPv6路由修改
elif [[ "$IPV6_CHOICE" == "3" ]]; then
    echo "禁用所有IPv6路由..."
    # 临时禁用IPv6
    sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1
fi
SCRIPT

chmod +x /etc/openvpn/client/scripts/ipv6-setup.sh

# 核心配置：智能路由控制
cat >> /etc/openvpn/client/client.conf <<CONF

# --- 智能路由控制 ---

# 使用自定义脚本而不是redirect-gateway
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

# 接受服务器推送的路由参数
pull-filter accept "route"
pull-filter accept "route-ipv6"

# 屏蔽服务器的重定向网关指令，由我们自己控制
pull-filter ignore "redirect-gateway"
CONF

# 5. 内核参数 (IPv4 + IPv6)
echo ">>> 优化内核参数..."
# 确保IPv6启用状态根据用户选择
if [[ "$IPV6_CHOICE" == "3" ]]; then
    # 用户选择禁用IPv6
    echo "配置系统禁用IPv6..."
    grep -v "disable_ipv6" /etc/sysctl.conf > /tmp/sysctl.conf.tmp
    echo "net.ipv6.conf.all.disable_ipv6=1" >> /tmp/sysctl.conf.tmp
    echo "net.ipv6.conf.default.disable_ipv6=1" >> /tmp/sysctl.conf.tmp
    mv /tmp/sysctl.conf.tmp /etc/sysctl.conf
else
    # 确保IPv6启用
    sed -i '/disable_ipv6/d' /etc/sysctl.conf
fi

# 开启 IPv4 转发
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# 开启 IPv6 转发 (如果IPv6启用)
if [[ "$IPV6_CHOICE" != "3" ]]; then
    if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    fi
fi

sysctl -p >/dev/null 2>&1

# 6. 配置 NAT (只针对 IPv4)
echo ">>> 配置防火墙 NAT..."
iptables -t nat -F
# 允许 tun0 出流量伪装
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
netfilter-persistent save

# 7. 重启服务
echo ">>> 重启 OpenVPN 服务..."
systemctl daemon-reload
systemctl restart openvpn-client@client

# 保存SSH端口设置到配置文件供脚本使用
cat > /etc/openvpn/client/scripts/ssh_ports.conf <<EOF
SSH_PORT_CHOICE="$SSH_PORT_CHOICE"
EXTRA_SSH_PORTS="$EXTRA_SSH_PORTS"
EOF

# 8. 应用IPv6配置
if [[ -x /etc/openvpn/client/scripts/ipv6-setup.sh ]]; then
    echo ">>> 配置IPv6路由..."
    /etc/openvpn/client/scripts/ipv6-setup.sh "$IPV6_CHOICE"
fi

# 8. 等待并验证
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
    
    # 再次检查状态
    if ! systemctl is-active --quiet openvpn-client@client; then
        echo "仍然无法启动OpenVPN，尝试手动运行..."
        mkdir -p /run/openvpn
        openvpn --config /etc/openvpn/client/client.conf --daemon
        sleep 5
    fi
fi

# 检查tun0接口
if ip addr show tun0 > /dev/null 2>&1; then
    echo "tun0接口已创建"
    
    # 确保路由表配置正确
    echo "确保路由表配置正确..."
    VPN_GW=$(ip -4 route | grep "dev tun0" | grep -v "via" | head -n 1 | awk '{print $1}')
    if [ -n "$VPN_GW" ]; then
        echo "添加默认路由到表200..."
        ip route add default via $VPN_GW dev tun0 table 200 2>/dev/null || true
        ip rule add from all table 200 prio 200 2>/dev/null || true
        ip route flush cache
    fi
else
    echo "错误: tun0接口未创建"
    echo "尝试手动启动OpenVPN..."
    openvpn --config /etc/openvpn/client/client.conf --daemon
    sleep 5
fi

# 检查原始IP
echo ">>> 检测原始IPv4..."
ORIG_IP4=$(curl -4s --interface $(ip -4 route | grep default | grep -v tun | awk '{print $5}' | head -n 1) https://ip.sb)
echo "原始IPv4: $ORIG_IP4"

# 检查出口IP
echo ">>> 检测出口IPv4..."
CURRENT_IP4=$(curl -4s https://ip.sb)
echo "当前IPv4出口IP: $CURRENT_IP4"

# 如果出口IP与原始IP相同，则路由可能有问题
if [ "$CURRENT_IP4" = "$ORIG_IP4" ]; then
    echo "警告: 出口IP与原始IP相同，尝试修复路由..."
    
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
        CURRENT_IP4=$(curl -4s https://ip.sb)
        echo "重新配置后的出口IPv4: $CURRENT_IP4"
    fi
fi

# 如果配置了IPv6，检查IPv6出口
if [[ "$IPV6_CHOICE" == "1" || "$IPV6_CHOICE" == "2" ]]; then
    echo ">>> 检测出口IPv6..."
    CURRENT_IP6=$(curl -6s https://ip.sb)
    echo "当前IPv6出口IP: $CURRENT_IP6"
    
    # 如果配置了IPv6但没有获取到IPv6地址，尝试修夏
    if [ -z "$CURRENT_IP6" ]; then
        echo "警告: 未检测到IPv6出口IP，尝试修夏..."
        if [ -f /etc/openvpn/client/scripts/ipv6-setup.sh ]; then
            echo "重新运行IPv6配置脚本..."
            /etc/openvpn/client/scripts/ipv6-setup.sh "$IPV6_CHOICE"
            sleep 3
            CURRENT_IP6=$(curl -6s https://ip.sb)
            echo "重新配置后的出口IPv6: $CURRENT_IP6"
        fi
    fi
fi

echo "=========================================="
echo "安装完成！OpenVPN客户端已配置并运行。"
echo "=========================================="

echo "=========================================="
echo "网络状态验证："
echo "-------------------------------------------"
echo "1. OpenVPN 服务状态："
if systemctl is-active --quiet openvpn-client@client; then
    echo "   [OK] 服务运行中 (Active)"
    echo "   >>> 连接日志 (最近5行)："
    journalctl -u openvpn-client@client -n 5 --no-pager
    
    # 检查tun0接口是否创建成功
    if ip addr show tun0 > /dev/null 2>&1; then
        TUN0_IP=$(ip -4 addr show tun0 | grep -oP '(?<=inet ).*(?=/')
        echo "   [OK] tun0接口已创建: IP=$TUN0_IP"
    else
        echo "   [ERROR] tun0接口未创建！"
    fi
else
    echo "   [ERROR] 服务未运行！"
    echo "   >>> 错误日志 (最后5行)："
    journalctl -u openvpn-client@client -n 5 --no-pager
fi

echo "-------------------------------------------"
echo "2. IPv4 连接测试："

# 先测试原生网络连接
echo "   原生网络测试（通过原始网卡）："
ORIG_IP4=$(curl -4 -s --connect-timeout 5 --interface $(ip route show default | grep -v tun | head -n1 | awk '{print $5}') ip.sb || echo "获取失败")
if [[ "$ORIG_IP4" != "获取失败" ]]; then
    echo -e "      原始网络可用，外网IP: \033[32m$ORIG_IP4\033[0m"
else
    echo -e "      \033[31m原始网络连接失败\033[0m (请检查网络设置)"
fi

# 再测试VPN路由
echo "   VPN路由测试（通过VPN隔离）："
TUN_IP4=""
if ip addr show tun0 > /dev/null 2>&1; then
    TUN_IP4=$(curl -4 -s --connect-timeout 8 --interface tun0 ip.sb || echo "获取失败")
    if [[ "$TUN_IP4" != "获取失败" ]]; then
        echo -e "      VPN路由正常，外网IP: \033[32m$TUN_IP4\033[0m (应为出口服务器IP)"
    else
        echo -e "      \033[31mVPN路由连接失败\033[0m (可能是DNS解析问题)"
    fi
else
    echo -e "      \033[31m未检测到tun0接口\033[0m"
fi

# 最后测试全局路由 (这应该显示出口服务器IP)
IP4=$(curl -4 -s --connect-timeout 8 ip.sb || echo "获取失败")
if [[ "$IP4" != "获取失败" ]]; then
    # 使用绿色显示 IP
    echo -e "   当前 IPv4: \033[32m$IP4\033[0m (应为出口服务器 IP)"
else
    # 使用红色显示失败
    echo -e "   当前 IPv4: \033[31m获取失败\033[0m (请检查网络或 VPN 配置)"
fi

echo "-------------------------------------------"
echo "3. IPv6 状态："
if [[ "$IPV6_CHOICE" == "1" ]]; then
    IP6=$(curl -6 -s --connect-timeout 8 ip.sb || echo "获取失败")
    if [[ "$IP6" != "获取失败" ]]; then
        echo -e "   当前 IPv6: \033[32m$IP6\033[0m (应为出口服务器 IP)"
    else
        echo -e "   当前 IPv6: \033[33m获取失败\033[0m (可能出口服务器没有IPv6)"
    fi
elif [[ "$IPV6_CHOICE" == "2" ]]; then
    IP6=$(curl -6 -s --connect-timeout 8 ip.sb || echo "获取失败")
    if [[ "$IP6" != "获取失败" ]]; then
        echo -e "   当前 IPv6: \033[32m$IP6\033[0m (使用本机 IPv6)"
    else
        echo -e "   当前 IPv6: \033[33m获取失败\033[0m (本机可能没有IPv6)"
    fi
elif [[ "$IPV6_CHOICE" == "3" ]]; then
    echo -e "   IPv6: \033[33m已禁用\033[0m (按用户选择)"
fi

echo "-------------------------------------------"
echo "4. SSH 连接状态："
if [[ "$SSH_PORT_CHOICE" == "1" ]]; then
    echo "   标准SSH端口(22)应保持正常连接。本机原始IP保持可访问。"
elif [[ "$SSH_PORT_CHOICE" == "2" ]]; then
    echo "   SSH端口(22 及 $EXTRA_SSH_PORTS)应保持正常连接。本机原始IP保持可访问。"
    echo "   指定的LXC容器转发SSH端口应正常工作。"
elif [[ "$SSH_PORT_CHOICE" == "3" ]]; then
    echo "   所有入站TCP连接（包括随机分配的SSH端口）都应保持正常。"
    echo "   所有LXC容器的转发连接应能正常工作。"
fi
echo "==========================================="

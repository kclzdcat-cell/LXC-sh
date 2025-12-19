#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# OpenVPN Egress Script (OUT)
# Base   : WireGuard out.sh 等价迁移
# Mode   : OpenVPN TCP + SSH 自动分发 client.ovpn
# Version: 1.0
# =========================================================

SCRIPT_VERSION="1.0"

echo "=================================================="
echo " OpenVPN Egress Script v${SCRIPT_VERSION}"
echo " 控制机 / 出口机"
echo "=================================================="
echo

# ================== 参数 ==================
OVPN_PORT="1194"
OVPN_NET="10.8.0.0"
OVPN_MASK="255.255.255.0"

OVPN_DIR="/etc/openvpn"
PKI_DIR="${OVPN_DIR}/pki"
CLIENT_NAME="client1"
CLIENT_OVPN="/root/client.ovpn"

log(){ echo -e "\n[OUT] $*\n"; }

# ================== 基础 ==================
need_root() {
  [[ "${EUID}" -eq 0 ]] || { echo "请用 root 运行"; exit 1; }
}

wait_apt_locks() {
  for i in {1..120}; do
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
    sleep 1
  done
}

apt_fix_and_install() {
  log "安装 OpenVPN / easy-rsa / sshpass"
  systemctl stop unattended-upgrades 2>/dev/null || true
  wait_apt_locks
  dpkg --configure -a 2>/dev/null || true
  apt-get -y -f install 2>/dev/null || true
  wait_apt_locks
  apt-get update -y
  apt-get install -y --no-install-recommends \
    openvpn easy-rsa iproute2 iptables curl sshpass
}

detect_wan_if() {
  ip route show default | awk 'NR==1{print $5}'
}

enable_forward() {
  log "开启 IPv4 转发"
  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/99-openvpn-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null
}

# ================== 清理 ==================
clean_old() {
  log "清理旧 OpenVPN"
  systemctl disable --now openvpn@server 2>/dev/null || true
  pkill openvpn 2>/dev/null || true
  rm -rf "${OVPN_DIR}/server.conf" "${PKI_DIR}" "${CLIENT_OVPN}" 2>/dev/null || true
}

# ================== PKI ==================
init_pki() {
  log "初始化 PKI"
  make-cadir "${PKI_DIR}"
  cd "${PKI_DIR}"
  ./easyrsa init-pki
  ./easyrsa --batch build-ca nopass
  ./easyrsa --batch gen-dh
  ./easyrsa --batch build-server-full server nopass
  ./easyrsa --batch build-client-full "${CLIENT_NAME}" nopass
  openvpn --genkey --secret ta.key
}

# ================== 配置 ==================
write_server_conf() {
  log "写入 server.conf"
  cat >"${OVPN_DIR}/server.conf" <<EOF
port ${OVPN_PORT}
proto tcp-server
dev tun

server ${OVPN_NET} ${OVPN_MASK}

ca ${PKI_DIR}/ca.crt
cert ${PKI_DIR}/issued/server.crt
key ${PKI_DIR}/private/server.key
dh ${PKI_DIR}/dh.pem
tls-auth ${PKI_DIR}/ta.key 0

topology subnet
keepalive 10 60
persist-key
persist-tun

# 关键：不推任何默认路由
push "route-nopull"

verb 3
EOF
}

setup_nat() {
  local wan_if="$1"
  log "配置 NAT（出口显示为出口机 IP）"
  iptables -t nat -C POSTROUTING -s ${OVPN_NET}/24 -o "${wan_if}" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s ${OVPN_NET}/24 -o "${wan_if}" -j MASQUERADE
}

# ================== client.ovpn ==================
build_client_ovpn() {
  log "生成完整 client.ovpn（内嵌证书）"
  local server_ip
  server_ip="$(curl -4 -fsS ipinfo.io/ip)"

  cat >"${CLIENT_OVPN}" <<EOF
client
dev tun
proto tcp-client
remote ${server_ip} ${OVPN_PORT}

nobind
persist-key
persist-tun
route-nopull
verb 3

<ca>
$(cat ${PKI_DIR}/ca.crt)
</ca>

<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' ${PKI_DIR}/issued/${CLIENT_NAME}.crt)
</cert>

<key>
$(cat ${PKI_DIR}/private/${CLIENT_NAME}.key)
</key>

<tls-auth>
$(cat ${PKI_DIR}/ta.key)
</tls-auth>
key-direction 1
EOF
}

# ================== SSH 传输（按你示范） ==================
ssh_transfer() {
  echo
  echo "=========== 上传到入口服务器 ==========="
  read -p "入口 IP：" IN_IP
  read -p "入口端口(默认22)：" IN_PORT
  IN_PORT=${IN_PORT:-22}
  read -p "入口 SSH 用户(默认root)：" IN_USER
  IN_USER=${IN_USER:-root}
  read -p "入口 SSH 密码：" IN_PASS

  log "清理旧的主机指纹"
  mkdir -p /root/.ssh
  touch /root/.ssh/known_hosts
  ssh-keygen -f /root/.ssh/known_hosts -R "$IN_IP" >/dev/null 2>&1 || true
  ssh-keygen -f /root/.ssh/known_hosts -R "[$IN_IP]:$IN_PORT" >/dev/null 2>&1 || true

  log "开始传输 client.ovpn"
  sshpass -p "$IN_PASS" scp -P $IN_PORT \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${CLIENT_OVPN}" \
    "${IN_USER}@${IN_IP}:/root/client.ovpn"

  log "client.ovpn 已成功上传到入口机"
}

# ================== 启动 ==================
start_openvpn() {
  log "启动 OpenVPN Server"
  systemctl enable --now openvpn@server
}

# ================== 主流程 ==================
need_root
apt_fix_and_install
enable_forward
clean_old

WAN_IF="$(detect_wan_if)"
init_pki
write_server_conf
setup_nat "${WAN_IF}"
build_client_ovpn
start_openvpn
ssh_transfer

echo
echo "✅ 出口机完成："
echo "- OpenVPN TCP 已启动"
echo "- client.ovpn 已推送到入口机 /root/client.ovpn"
echo "- 下一步：到入口机执行 in-openvpn.sh"

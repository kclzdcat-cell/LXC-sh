#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# OpenVPN Egress Script
# Version : 1.3.1
# Fix     : ta.key 路径 / PKI 路径 / systemd unit
# Mode    : 出口机（NAT 出口）
# =========================================================

SCRIPT_VERSION="1.3.1"

echo "=================================================="
echo " OpenVPN Egress Script v${SCRIPT_VERSION}"
echo " 修复版（仅修 bug，不重构）"
echo "=================================================="
echo

# ================== 参数 ==================
OVPN_DIR="/etc/openvpn"
PKI_BASE="${OVPN_DIR}/pki"
PKI_DIR="${PKI_BASE}/pki"

SERVER_CONF="${OVPN_DIR}/server.conf"
CLIENT_NAME="client1"
CLIENT_OVPN="/root/${CLIENT_NAME}.ovpn"

OVPN_PORT="1194"
OVPN_PROTO="udp"
OVPN_NET="10.8.0.0"
OVPN_MASK="255.255.255.0"

# ================== 工具函数 ==================
log(){ echo -e "\n[OUT] $*\n"; }

need_root() {
  [[ $EUID -eq 0 ]] || { echo "请用 root 运行"; exit 1; }
}

# ================== 安装依赖 ==================
install_deps() {
  log "安装 OpenVPN / Easy-RSA / 工具"
  apt-get update -y
  apt-get install -y openvpn easy-rsa iptables iproute2 curl sshpass
}

# ================== 初始化 PKI ==================
init_pki() {
  log "初始化 PKI"

  rm -rf "${PKI_BASE}"
  make-cadir "${PKI_BASE}"
  cd "${PKI_BASE}"

  ./easyrsa init-pki
  echo | ./easyrsa build-ca nopass
  ./easyrsa gen-dh

  ./easyrsa build-server-full server nopass
  ./easyrsa build-client-full "${CLIENT_NAME}" nopass

  # 生成 ta.key（注意路径）
  openvpn --genkey --secret ta.key
  mv ta.key "${PKI_DIR}/ta.key"

  log "PKI 结构检查："
  ls -l "${PKI_DIR}/ca.crt"
  ls -l "${PKI_DIR}/issued/server.crt"
  ls -l "${PKI_DIR}/private/server.key"
  ls -l "${PKI_DIR}/ta.key"
}

# ================== 写 server.conf ==================
write_server_conf() {
  log "写入 server.conf（已修正 PKI 路径）"

  cat > "${SERVER_CONF}" <<EOF
port ${OVPN_PORT}
proto ${OVPN_PROTO}
dev tun

ca ${PKI_DIR}/ca.crt
cert ${PKI_DIR}/issued/server.crt
key ${PKI_DIR}/private/server.key
dh ${PKI_DIR}/dh.pem

tls-auth ${PKI_DIR}/ta.key 0
key-direction 0

server ${OVPN_NET} ${OVPN_MASK}
topology subnet

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"

keepalive 10 120
cipher AES-256-GCM
data-ciphers AES-256-GCM
persist-key
persist-tun
user nobody
group nogroup

verb 3
EOF
}

# ================== 配置 NAT ==================
setup_nat() {
  log "配置 NAT（出口显示为出口机 IP）"
  WAN_IF=$(ip route show default | awk '{print $5}')

  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  iptables -t nat -C POSTROUTING -s ${OVPN_NET}/24 -o "${WAN_IF}" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s ${OVPN_NET}/24 -o "${WAN_IF}" -j MASQUERADE
}

# ================== 生成 client.ovpn ==================
gen_client_ovpn() {
  log "生成 client.ovpn（内嵌证书）"

  cat > "${CLIENT_OVPN}" <<EOF
client
dev tun
proto ${OVPN_PROTO}
remote $(curl -4 -s https://api.ipify.org) ${OVPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
key-direction 1
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
EOF

  echo "client.ovpn 已生成：${CLIENT_OVPN}"
}

# ================== SSH 上传 ==================
upload_client() {
  echo
  echo "========= 通过 SSH 上传 client.ovpn 到入口机 ========="
  read -p "入口 IP：" IN_IP
  read -p "入口 SSH 端口(默认22)：" IN_PORT
  IN_PORT=${IN_PORT:-22}
  read -p "入口 SSH 用户(默认root)：" IN_USER
  IN_USER=${IN_USER:-root}
  read -p "入口 SSH 密码：" IN_PASS

  ssh-keygen -f /root/.ssh/known_hosts -R "$IN_IP" >/dev/null 2>&1 || true
  ssh-keygen -f /root/.ssh/known_hosts -R "[$IN_IP]:$IN_PORT" >/dev/null 2>&1 || true

  sshpass -p "$IN_PASS" scp -P "$IN_PORT" \
    -o StrictHostKeyChecking=no \
    "${CLIENT_OVPN}" "${IN_USER}@${IN_IP}:/root/"
}

# ================== 启动 OpenVPN ==================
start_openvpn() {
  log "启动 OpenVPN Server（正确的 systemd unit）"

  systemctl enable --now openvpn-server@server

  sleep 2
  systemctl status openvpn-server@server --no-pager
}

# ================== 主流程 ==================
need_root
install_deps
init_pki
write_server_conf
setup_nat
gen_client_ovpn
upload_client
start_openvpn

echo
echo "=================================================="
echo " ✅ OpenVPN 出口部署完成（v${SCRIPT_VERSION}）"
echo "=================================================="
echo "入口机 client.ovpn 已在 /root/"
echo "如需停止：systemctl stop openvpn-server@server"

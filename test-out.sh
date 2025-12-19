#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# OpenVPN Egress Script (OUT)
# Version: 1.3
# Fix    : PKI 路径 + systemd 服务名
# Policy : 不重构，只修 bug
# =========================================================

SCRIPT_VERSION="1.3"

echo "=================================================="
echo " OpenVPN OUT Script v${SCRIPT_VERSION}"
echo " 修复 PKI 路径 & systemd 服务名"
echo "=================================================="
echo

# ================= 基础参数 =================
OVPN_DIR="/etc/openvpn"
PKI_DIR="${OVPN_DIR}/pki"
EASYRSA_DIR="${OVPN_DIR}/easy-rsa"

SERVER_CONF="${OVPN_DIR}/server.conf"
CLIENT_NAME="client1"
OVPN_PORT="1194"
OVPN_PROTO="udp"
OVPN_NET="10.8.0.0"
OVPN_MASK="255.255.255.0"

# ================= 日志函数 =================
log(){ echo -e "\n[OUT] $*\n"; }

need_root() {
  [[ $EUID -eq 0 ]] || { echo "请用 root 运行"; exit 1; }
}

# ================= 安装依赖 =================
install_deps() {
  log "安装 OpenVPN & easy-rsa"
  apt-get update -y
  apt-get install -y openvpn easy-rsa iptables openssl ca-certificates sshpass
}

# ================= 初始化 PKI =================
init_pki() {
  log "初始化 PKI"
  rm -rf "${PKI_DIR}"
  make-cadir "${PKI_DIR}"
  cd "${PKI_DIR}"

  ./easyrsa init-pki
  echo | ./easyrsa build-ca nopass
  ./easyrsa gen-dh
  openvpn --genkey --secret ta.key

  ./easyrsa build-server-full server nopass
  ./easyrsa build-client-full "${CLIENT_NAME}" nopass
}

# ================= 写 server.conf（关键修复） =================
write_server_conf() {
  log "写入 server.conf（PKI 路径修复）"

  cat > "${SERVER_CONF}" <<EOF
port ${OVPN_PORT}
proto ${OVPN_PROTO}
dev tun

ca ${PKI_DIR}/pki/ca.crt
cert ${PKI_DIR}/pki/issued/server.crt
key ${PKI_DIR}/pki/private/server.key
dh ${PKI_DIR}/pki/dh.pem
tls-auth ${PKI_DIR}/pki/ta.key 0

topology subnet
server ${OVPN_NET} ${OVPN_MASK}

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
explicit-exit-notify 1
EOF
}

# ================= NAT 配置 =================
enable_nat() {
  log "配置 NAT（出口显示为出口机 IP）"

  WAN_IF="$(ip route | awk '/default/ {print $5; exit}')"

  iptables -t nat -C POSTROUTING -s ${OVPN_NET}/24 -o "${WAN_IF}" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s ${OVPN_NET}/24 -o "${WAN_IF}" -j MASQUERADE

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

# ================= 生成 client.ovpn =================
gen_client_ovpn() {
  log "生成 client.ovpn（内嵌证书）"

  CLIENT_FILE="/root/${CLIENT_NAME}.ovpn"
  SERVER_IP="$(curl -4 -s https://api.ipify.org)"

  cat > "${CLIENT_FILE}" <<EOF
client
dev tun
proto ${OVPN_PROTO}
remote ${SERVER_IP} ${OVPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
verb 3

<ca>
$(cat ${PKI_DIR}/pki/ca.crt)
</ca>
<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' ${PKI_DIR}/pki/issued/${CLIENT_NAME}.crt)
</cert>
<key>
$(cat ${PKI_DIR}/pki/private/${CLIENT_NAME}.key)
</key>
<tls-auth>
$(cat ${PKI_DIR}/pki/ta.key)
</tls-auth>
key-direction 1
EOF

  echo
  echo "client.ovpn 已生成：${CLIENT_FILE}"
}

# ================= SSH 上传 =================
upload_client() {
  echo
  echo "=========== 上传 client.ovpn 到入口机 ==========="
  read -p "入口 IP: " IN_IP
  read -p "入口 SSH 端口(默认22): " IN_PORT
  IN_PORT=${IN_PORT:-22}
  read -p "入口 SSH 用户(默认root): " IN_USER
  IN_USER=${IN_USER:-root}
  read -p "入口 SSH 密码: " IN_PASS

  ssh-keygen -f /root/.ssh/known_hosts -R "$IN_IP" >/dev/null 2>&1 || true
  ssh-keygen -f /root/.ssh/known_hosts -R "[$IN_IP]:$IN_PORT" >/dev/null 2>&1 || true

  sshpass -p "$IN_PASS" scp -P "$IN_PORT" -o StrictHostKeyChecking=no \
    "/root/${CLIENT_NAME}.ovpn" "${IN_USER}@${IN_IP}:/root/"

  echo "✔ client.ovpn 已上传到入口机 /root/"
}

# ================= 启动 OpenVPN（关键修复） =================
start_openvpn() {
  log "启动 OpenVPN Server（正确的 systemd 服务名）"

  systemctl daemon-reexec
  systemctl enable --now openvpn-server@server

  echo
  systemctl status openvpn-server@server --no-pager
}

# ================= 主流程 =================
need_root
install_deps
init_pki
write_server_conf
enable_nat
gen_client_ovpn
upload_client
start_openvpn

echo
echo "==========================================="
echo "✅ OpenVPN 出口部署完成（v${SCRIPT_VERSION}）"
echo "入口机直接使用 /root/${CLIENT_NAME}.ovpn 连接"
echo "==========================================="

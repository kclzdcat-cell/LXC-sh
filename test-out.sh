#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# OpenVPN Egress Script
# Mode   : 方案 A（稳定优先，不改入口默认路由）
# Version: 1.2
# =========================================================

SCRIPT_VERSION="1.2"
CLIENT_NAME="client1"
VPN_NET="10.88.0.0 255.255.255.0"
VPN_IF="tun0"
VPN_PORT="1194"

PKI_BASE="/etc/openvpn/pki"
REAL_PKI="${PKI_BASE}/pki"
EASYRSA_DIR="/usr/share/easy-rsa"

log(){ echo -e "\n[OUT] $*\n"; }

need_root(){
  [[ $EUID -eq 0 ]] || { echo "请用 root 运行"; exit 1; }
}

apt_install(){
  log "安装 OpenVPN / easy-rsa / sshpass"
  apt-get update -y
  apt-get install -y openvpn easy-rsa iptables curl sshpass
}

detect_wan_if(){
  ip route show default | awk 'NR==1{print $5}'
}

setup_pki(){
  log "初始化 PKI"
  rm -rf "${PKI_BASE}"
  make-cadir "${PKI_BASE}"
  cd "${PKI_BASE}"

  ./easyrsa init-pki
  EASYRSA_BATCH=1 ./easyrsa build-ca nopass
  EASYRSA_BATCH=1 ./easyrsa gen-dh
  EASYRSA_BATCH=1 ./easyrsa build-server-full server nopass
  EASYRSA_BATCH=1 ./easyrsa build-client-full ${CLIENT_NAME} nopass
  openvpn --genkey --secret ${REAL_PKI}/ta.key
}

write_server_conf(){
  local wan_if="$1"
  log "写入 server.conf"

  cat >/etc/openvpn/server.conf <<EOF
port ${VPN_PORT}
proto udp
dev ${VPN_IF}

server ${VPN_NET}

ca ${REAL_PKI}/ca.crt
cert ${REAL_PKI}/issued/server.crt
key ${REAL_PKI}/private/server.key
dh ${REAL_PKI}/dh.pem
tls-auth ${REAL_PKI}/ta.key 0

keepalive 10 120
persist-key
persist-tun

user nobody
group nogroup

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"

verb 3

# NAT
script-security 2
up /etc/openvpn/nat.sh
EOF

  cat >/etc/openvpn/nat.sh <<EOF
#!/bin/sh
iptables -t nat -C POSTROUTING -s 10.88.0.0/24 -o ${wan_if} -j MASQUERADE \
  || iptables -t nat -A POSTROUTING -s 10.88.0.0/24 -o ${wan_if} -j MASQUERADE
EOF
  chmod +x /etc/openvpn/nat.sh
}

build_client_ovpn(){
  log "生成 client.ovpn（内嵌证书）"
  cat >/root/${CLIENT_NAME}.ovpn <<EOF
client
dev tun
proto udp
remote $(curl -4 -s ipinfo.io/ip) ${VPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verb 3
key-direction 1

<ca>
$(cat ${REAL_PKI}/ca.crt)
</ca>

<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' \
  ${REAL_PKI}/issued/${CLIENT_NAME}.crt)
</cert>

<key>
$(cat ${REAL_PKI}/private/${CLIENT_NAME}.key)
</key>

<tls-auth>
$(cat ${REAL_PKI}/ta.key)
</tls-auth>
EOF
}

ssh_upload(){
  log "通过 SSH 上传 client.ovpn 到入口机"

  read -p "入口机 IP: " IN_IP
  read -p "入口 SSH 端口(默认22): " IN_PORT
  IN_PORT=${IN_PORT:-22}
  read -p "入口 SSH 用户(默认root): " IN_USER
  IN_USER=${IN_USER:-root}
  read -s -p "入口 SSH 密码: " IN_PASS
  echo

  ssh-keygen -R "${IN_IP}" >/dev/null 2>&1 || true
  ssh-keygen -R "[${IN_IP}]:${IN_PORT}" >/dev/null 2>&1 || true

  sshpass -p "${IN_PASS}" scp -P ${IN_PORT} \
    -o StrictHostKeyChecking=no \
    /root/${CLIENT_NAME}.ovpn \
    ${IN_USER}@${IN_IP}:/root/
}

start_openvpn(){
  log "启动 OpenVPN Server"
  systemctl enable --now openvpn-server@server
  systemctl status openvpn-server@server --no-pager
}

main(){
  need_root
  apt_install
  local wan_if
  wan_if="$(detect_wan_if)"
  setup_pki
  write_server_conf "${wan_if}"
  build_client_ovpn
  ssh_upload
  start_openvpn
  log "出口机部署完成"
}

main

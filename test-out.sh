#!/usr/bin/env bash
set -euo pipefail

WG_IF="wg0"
WG_PORT_DEFAULT="51820"
WG_NET4="10.66.66.0/24"
WG_SRV4="10.66.66.1/24"
WG_CLI4="10.66.66.2/32"
WG_NET6="fd10::/64"
WG_SRV6="fd10::1/64"
WG_CLI6="fd10::2/128"

need_root() { [ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }; }

wait_apt() {
  local i=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    i=$((i+1))
    [ $i -gt 120 ] && { echo "dpkg/apt 锁超过 120 秒仍占用，先执行：ps -ef | grep apt"; exit 1; }
    sleep 1
  done
}

detect_wan_if() {
  local if4
  if4="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || true)"
  if [ -n "$if4" ]; then echo "$if4"; return; fi
  ip -6 route show default 2>/dev/null | awk '{print $5; exit}'
}

sysctl_on() {
  cat >/etc/sysctl.d/99-wg-forward.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
  sysctl --system >/dev/null
}

install_pkgs() {
  wait_apt
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    wireguard wireguard-tools iproute2 iptables nftables curl ca-certificates
}

gen_keys() {
  umask 077
  mkdir -p /etc/wireguard
  chmod 700 /etc/wireguard

  wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
  wg genkey | tee /etc/wireguard/client.key | wg pubkey > /etc/wireguard/client.pub
  wg genpsk > /etc/wireguard/psk

  SERVER_PRIV="$(cat /etc/wireguard/server.key)"
  SERVER_PUB="$(cat /etc/wireguard/server.pub)"
  CLIENT_PRIV="$(cat /etc/wireguard/client.key)"
  CLIENT_PUB="$(cat /etc/wireguard/client.pub)"
  PSK="$(cat /etc/wireguard/psk)"
}

write_server_conf() {
  local wan_if="$1"
  local port="$2"
  cat >/etc/wireguard/${WG_IF}.conf <<EOF
[Interface]
Address = ${WG_SRV4}, ${WG_SRV6}
ListenPort = ${port}
PrivateKey = ${SERVER_PRIV}

# NAT + 转发（IPv4 + IPv6）
PostUp = iptables -w -A INPUT -p udp --dport ${port} -j ACCEPT; iptables -w -A FORWARD -i ${WG_IF} -j ACCEPT; iptables -w -A FORWARD -o ${WG_IF} -j ACCEPT; iptables -w -t nat -A POSTROUTING -s ${WG_NET4} -o ${wan_if} -j MASQUERADE; ip6tables -w -A FORWARD -i ${WG_IF} -j ACCEPT; ip6tables -w -A FORWARD -o ${WG_IF} -j ACCEPT; ip6tables -w -t nat -A POSTROUTING -s ${WG_NET6} -o ${wan_if} -j MASQUERADE
PostDown = iptables -w -D INPUT -p udp --dport ${port} -j ACCEPT; iptables -w -D FORWARD -i ${WG_IF} -j ACCEPT; iptables -w -D FORWARD -o ${WG_IF} -j ACCEPT; iptables -w -t nat -D POSTROUTING -s ${WG_NET4} -o ${wan_if} -j MASQUERADE; ip6tables -w -D FORWARD -i ${WG_IF} -j ACCEPT; ip6tables -w -D FORWARD -o ${WG_IF} -j ACCEPT; ip6tables -w -t nat -D POSTROUTING -s ${WG_NET6} -o ${wan_if} -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUB}
PresharedKey = ${PSK}
AllowedIPs = ${WG_CLI4}, ${WG_CLI6}
EOF

  chmod 600 /etc/wireguard/${WG_IF}.conf
}

start_wg() {
  systemctl enable --now wg-quick@${WG_IF} || true
  systemctl restart wg-quick@${WG_IF}
}

ask_port() {
  read -r -p "WireGuard 监听端口 [默认 ${WG_PORT_DEFAULT}]: " p
  echo "${p:-$WG_PORT_DEFAULT}"
}

ask_endpoint_ip() {
  echo "请输入出口机公网 IP（IPv4 或 IPv6）。建议填你确定能连到的那个："
  read -r -p "出口机公网 IP: " eip
  echo "$eip"
}

write_client_conf() {
  local endpoint_ip="$1"
  local port="$2"
  cat >/root/wg_client.conf <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${WG_CLI4}, ${WG_CLI6}
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${PSK}
Endpoint = ${endpoint_ip}:${port}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  chmod 600 /root/wg_client.conf
}

main() {
  need_root
  echo "=== OUT：配置出口机 WireGuard Server + NAT ==="
  install_pkgs
  sysctl_on

  WAN_IF="$(detect_wan_if)"
  [ -n "$WAN_IF" ] || { echo "无法检测出口机外网网卡"; exit 1; }
  echo "外网网卡: $WAN_IF"

  PORT="$(ask_port)"
  gen_keys
  write_server_conf "$WAN_IF" "$PORT"
  start_wg

  EPIP="$(ask_endpoint_ip)"
  write_client_conf "$EPIP" "$PORT"

  echo
  echo "================= 给入口机填这 4 项（非常关键） ================="
  echo "出口机公网IP  : ${EPIP}"
  echo "WireGuard端口 : ${PORT}"
  echo "Server公钥    : ${SERVER_PUB}"
  echo "Client私钥    : ${CLIENT_PRIV}"
  echo "PresharedKey  : ${PSK}"
  echo "=================================================================="
  echo
  echo "入口机配置文件已生成：/root/wg_client.conf （可以直接 cat 看）"
  echo "出口机状态："
  wg show ${WG_IF} || true
  echo
  echo "提示：不要把 /root/wg_client.conf 发到公开地方（里面有私钥）。"
}

main "$@"

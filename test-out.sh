#!/usr/bin/env bash
set -euo pipefail

WG_IF="wg0"
WG_PORT_DEFAULT="51820"
WG_V4_NET="10.66.66.0/24"
WG_V4_SRV="10.66.66.1/24"
WG_V6_NET="fd10::/64"
WG_V6_SRV="fd10::1/64"

need_root() { [[ ${EUID:-0} -eq 0 ]] || { echo "请用 root 执行"; exit 1; }; }
os_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    wireguard wireguard-tools iproute2 iptables nftables curl ca-certificates
}
get_wan_if() {
  ip -4 route show default 2>/dev/null | awk '{print $5; exit}'
}
get_pub_ip4() { curl -4 -s --max-time 5 https://ip.sb || true; }
get_pub_ip6() { curl -6 -s --max-time 5 https://ip.sb || true; }

cleanup_old() {
  systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  wg-quick down "${WG_IF}" >/dev/null 2>&1 || true
  ip link del "${WG_IF}" >/dev/null 2>&1 || true
  rm -f "/etc/wireguard/${WG_IF}.conf"
}

enable_forwarding() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || true
  cat >/etc/sysctl.d/99-wg-forward.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
}

make_keys() {
  umask 077
  mkdir -p /etc/wireguard
  if [[ ! -f /etc/wireguard/server.key ]]; then
    wg genkey | tee /etc/wireguard/server.key >/dev/null
  fi
  wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub
}

write_conf() {
  local wan_if="$1"
  local port="$2"
  local srv_priv srv_pub
  srv_priv="$(cat /etc/wireguard/server.key)"
  srv_pub="$(cat /etc/wireguard/server.pub)"

  cat >"/etc/wireguard/${WG_IF}.conf" <<EOF
[Interface]
Address = ${WG_V4_SRV}, ${WG_V6_SRV}
ListenPort = ${port}
PrivateKey = ${srv_priv}

# NAT + Forward (IPv4)
PostUp = iptables -t nat -C POSTROUTING -s ${WG_V4_NET} -o ${wan_if} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${WG_V4_NET} -o ${wan_if} -j MASQUERADE
PostUp = iptables -C FORWARD -i ${WG_IF} -o ${wan_if} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${WG_IF} -o ${wan_if} -j ACCEPT
PostUp = iptables -C FORWARD -i ${wan_if} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${wan_if} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

PostDown = iptables -t nat -D POSTROUTING -s ${WG_V4_NET} -o ${wan_if} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -D FORWARD -i ${WG_IF} -o ${wan_if} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i ${wan_if} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

# NAT66 + Forward (IPv6) - 若内核/iptables 不支持 NAT66，此段可能无效，但不影响 IPv4
PostUp = ip6tables -t nat -C POSTROUTING -s ${WG_V6_NET} -o ${wan_if} -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -s ${WG_V6_NET} -o ${wan_if} -j MASQUERADE 2>/dev/null || true
PostUp = ip6tables -C FORWARD -i ${WG_IF} -o ${wan_if} -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -i ${WG_IF} -o ${wan_if} -j ACCEPT 2>/dev/null || true
PostUp = ip6tables -C FORWARD -i ${wan_if} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -i ${wan_if} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

PostDown = ip6tables -t nat -D POSTROUTING -s ${WG_V6_NET} -o ${wan_if} -j MASQUERADE 2>/dev/null || true
PostDown = ip6tables -D FORWARD -i ${WG_IF} -o ${wan_if} -j ACCEPT 2>/dev/null || true
PostDown = ip6tables -D FORWARD -i ${wan_if} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

# 入口机会在后续把自己的 PublicKey 给你，你再加 Peer：
# [Peer]
# PublicKey = <CLIENT_PUB>
# AllowedIPs = 10.66.66.2/32, fd10::2/128
EOF

  chmod 600 "/etc/wireguard/${WG_IF}.conf"

  echo
  echo "================ 出口机信息（填到入口机） ================"
  echo "出口机公网 IPv4: $(get_pub_ip4)"
  echo "出口机公网 IPv6: $(get_pub_ip6)"
  echo "WireGuard 端口 : ${port}"
  echo "Server 公钥    : ${srv_pub}"
  echo "=========================================================="
  echo
  echo "下一步：去入口机跑 in.sh，它会给你 CLIENT 公钥，然后你在出口机执行："
  echo "wg set ${WG_IF} peer <CLIENT_PUB> allowed-ips 10.66.66.2/32,fd10::2/128"
  echo "然后在出口机执行：systemctl restart wg-quick@${WG_IF}"
  echo
}

main() {
  need_root
  os_install
  local wan_if; wan_if="$(get_wan_if)"
  [[ -n "${wan_if}" ]] || { echo "找不到默认外网网卡"; exit 1; }

  read -r -p "WireGuard 端口（默认 ${WG_PORT_DEFAULT}）: " WG_PORT || true
  WG_PORT="${WG_PORT:-$WG_PORT_DEFAULT}"

  cleanup_old
  enable_forwarding
  make_keys
  write_conf "${wan_if}" "${WG_PORT}"

  systemctl enable --now "wg-quick@${WG_IF}"
  wg show "${WG_IF}" || true
}

main "$@"

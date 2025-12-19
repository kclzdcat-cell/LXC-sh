#!/usr/bin/env bash
set -euo pipefail

WG_IF="wg0"
WG_PORT="${WG_PORT:-51820}"
WG_ADDR4="10.66.66.1/24"
WG_ADDR6="fd10::1/64"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_IF}.conf"
WG_KEY="${WG_DIR}/${WG_IF}.key"
WG_PUB="${WG_DIR}/${WG_IF}.pub"

log(){ echo -e "\n[OUT] $*\n"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请用 root 运行"; exit 1
  fi
}

wait_apt_locks() {
  # 尽量避免 apt/dpkg 锁把你卡死
  local locks=(
    "/var/lib/dpkg/lock-frontend"
    "/var/lib/dpkg/lock"
    "/var/cache/apt/archives/lock"
  )
  for i in {1..120}; do
    local busy=0
    for l in "${locks[@]}"; do
      if fuser "$l" >/dev/null 2>&1; then busy=1; fi
    done
    [[ $busy -eq 0 ]] && return 0
    sleep 1
  done
  echo "apt/dpkg 锁太久了，先手动处理：ps aux | grep -E 'apt|dpkg'"; exit 1
}

apt_fix_and_install() {
  log "修复 dpkg/apt & 安装依赖"
  systemctl stop unattended-upgrades 2>/dev/null || true
  wait_apt_locks
  dpkg --configure -a 2>/dev/null || true
  apt-get -y -f install 2>/dev/null || true
  wait_apt_locks
  apt-get update -y

  # Debian/Ubuntu 通吃：wireguard-tools + iproute2 + iptables + curl
  apt-get install -y --no-install-recommends \
    wireguard-tools iproute2 iptables curl ca-certificates

  # 有些发行版有 wireguard 元包，装不上不算错
  apt-get install -y --no-install-recommends wireguard 2>/dev/null || true
}

detect_wan_if() {
  ip route show default 0.0.0.0/0 | awk 'NR==1{print $5}'
}

sysctl_forward() {
  log "开启 IPv4/IPv6 转发"
  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/99-wg-forward.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
  sysctl --system >/dev/null
}

clean_old() {
  log "清理旧 wg0（如果有）"
  systemctl disable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  wg-quick down "${WG_IF}" >/dev/null 2>&1 || true
  ip link del "${WG_IF}" >/dev/null 2>&1 || true
}

gen_keys() {
  log "生成/重置密钥"
  umask 077
  mkdir -p "${WG_DIR}"
  if [[ -f "${WG_KEY}" ]]; then
    # 每次重装你都想“干净”，这里直接备份再重建
    mv -f "${WG_KEY}" "${WG_KEY}.bak.$(date +%s)" || true
  fi
  if [[ -f "${WG_PUB}" ]]; then
    mv -f "${WG_PUB}" "${WG_PUB}.bak.$(date +%s)" || true
  fi
  wg genkey | tee "${WG_KEY}" | wg pubkey > "${WG_PUB}"
  chmod 600 "${WG_KEY}" "${WG_PUB}"
}

write_conf() {
  local wan_if="$1"
  log "写入 ${WG_CONF}"
  cat >"${WG_CONF}" <<EOF
[Interface]
Address = ${WG_ADDR4}, ${WG_ADDR6}
ListenPort = ${WG_PORT}
PrivateKey = $(cat "${WG_KEY}")

# NAT：让入口机的出站最终显示“出口机公网IP”
PostUp   = iptables -t nat -C POSTROUTING -o ${wan_if} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o ${wan_if} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ${wan_if} -j MASQUERADE 2>/dev/null || true

# IPv6 NAT（如果你出口机有 v6 且内核允许 nat 表）
PostUp   = ip6tables -t nat -C POSTROUTING -o ${wan_if} -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -o ${wan_if} -j MASQUERADE 2>/dev/null || true
PostDown = ip6tables -t nat -D POSTROUTING -o ${wan_if} -j MASQUERADE 2>/dev/null || true
EOF
  chmod 600 "${WG_CONF}"
}

start_wg() {
  log "启动 WireGuard"
  systemctl enable --now "wg-quick@${WG_IF}" >/dev/null
  sleep 1
}

get_pub_ip() {
  # 多个源兜底，避免你遇到的 ip.sb 403
  local ip4 ip6
  ip4="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "${ip4}" ]] && ip4="$(curl -4 -fsS --max-time 8 https://icanhazip.com 2>/dev/null | tr -d '\n' || true)"
  ip6="$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
  [[ -z "${ip6}" ]] && ip6="$(curl -6 -fsS --max-time 8 https://icanhazip.com 2>/dev/null | tr -d '\n' || true)"
  echo "${ip4}|${ip6}"
}

print_info() {
  local wan_if="$1"
  local ips server_pub
  ips="$(get_pub_ip)"
  local ip4="${ips%%|*}"
  local ip6="${ips#*|}"
  server_pub="$(cat "${WG_PUB}")"

  log "给入口机填这三项（手动填，最稳）"
  echo "出口机公网 IPv4: ${ip4:-（获取失败，手动填）}"
  echo "出口机公网 IPv6: ${ip6:-（可空）}"
  echo "WireGuard 端口  : ${WG_PORT}"
  echo "出口机 Server 公钥: ${server_pub}"
  echo
  echo "出口机当前状态："
  wg show "${WG_IF}" || true
  echo
  echo "下一步：去入口机跑 in.sh，它会给你一个 CLIENT 公钥。"
  echo "然后回到出口机执行："
  echo "  wg set ${WG_IF} peer <CLIENT_PUB> allowed-ips 10.66.66.2/32,fd10::2/128"
  echo "  wg-quick save ${WG_IF}"
  echo
  echo "（可选）如果你想确认 NAT 出口是否正常：入口机连上后，入口机 curl -4 api.ipify.org 应该显示这里的出口 IPv4。"
}

main(){
  need_root
  apt_fix_and_install
  sysctl_forward
  clean_old
  gen_keys
  local wan_if
  wan_if="$(detect_wan_if)"
  [[ -z "${wan_if}" ]] && { echo "找不到默认外网网卡"; exit 1; }
  write_conf "${wan_if}"
  start_wg
  print_info "${wan_if}"
}

main "$@"

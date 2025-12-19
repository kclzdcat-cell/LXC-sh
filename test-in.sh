#!/usr/bin/env bash
set -euo pipefail

WG_IF="wg0"
RT_TABLE_ID="200"
RT_TABLE_NAME="wgout"
MARK_IN="0x1"

WG_V4_CLI="10.66.66.2/32"
WG_V4_SRV_ALLOWED="0.0.0.0/0"
WG_V6_CLI="fd10::2/128"
WG_V6_SRV_ALLOWED="::/0"

PRIO_TO_ENDPOINT="40"
PRIO_TO_SSH="41"
PRIO_FWMARK_MAIN="100"
PRIO_DEFAULT_WG="200"

need_root() { [[ ${EUID:-0} -eq 0 ]] || { echo "请用 root 执行"; exit 1; }; }

wait_apt() {
  # 避免 dpkg/apt 被锁死
  local n=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    n=$((n+1))
    [[ $n -gt 60 ]] && { echo "apt/dpkg 锁超时"; exit 1; }
    sleep 2
  done
}

os_install() {
  export DEBIAN_FRONTEND=noninteractive
  wait_apt
  dpkg --configure -a >/dev/null 2>&1 || true
  apt-get -f install -y >/dev/null 2>&1 || true
  wait_apt
  apt-get update -y
  # 不做 upgrade，避免重启/断网风险
  apt-get install -y --no-install-recommends \
    wireguard wireguard-tools iproute2 iptables nftables curl ca-certificates
}

get_wan_if() { ip -4 route show default 2>/dev/null | awk '{print $5; exit}'; }
get_wan_gw() { ip -4 route show default 2>/dev/null | awk '{print $3; exit}'; }

is_ipv6() { [[ "$1" == *:* ]]; }

validate_pubkey() {
  local k="$1"
  # WireGuard 公钥通常 44 字符 base64 并以 "=" 结尾
  [[ ${#k} -eq 44 ]] && [[ "$k" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || { echo "❌ Server 公钥格式不对（需要 44 位 Base64 且以 = 结尾）"; exit 1; }
}

cleanup_rules() {
  # 停 wg
  systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  wg-quick down "${WG_IF}" >/dev/null 2>&1 || true
  ip link del "${WG_IF}" >/dev/null 2>&1 || true

  # 删策略路由（按 priority 删，最稳）
  for fam in "-4" "-6"; do
    ip ${fam} rule del priority "${PRIO_TO_ENDPOINT}" >/dev/null 2>&1 || true
    ip ${fam} rule del priority "${PRIO_TO_SSH}" >/dev/null 2>&1 || true
    ip ${fam} rule del priority "${PRIO_FWMARK_MAIN}" >/dev/null 2>&1 || true
    ip ${fam} rule del priority "${PRIO_DEFAULT_WG}" >/dev/null 2>&1 || true
  done

  # 清理 mangle 自定义链（IPv4/IPv6）
  iptables  -t mangle -D PREROUTING -j WG_IN_MARK >/dev/null 2>&1 || true
  iptables  -t mangle -D OUTPUT     -j WG_OUT_RESTORE >/dev/null 2>&1 || true
  iptables  -t mangle -F WG_IN_MARK >/dev/null 2>&1 || true
  iptables  -t mangle -X WG_IN_MARK >/dev/null 2>&1 || true
  iptables  -t mangle -F WG_OUT_RESTORE >/dev/null 2>&1 || true
  iptables  -t mangle -X WG_OUT_RESTORE >/dev/null 2>&1 || true

  ip6tables -t mangle -D PREROUTING -j WG_IN_MARK >/dev/null 2>&1 || true
  ip6tables -t mangle -D OUTPUT     -j WG_OUT_RESTORE >/dev/null 2>&1 || true
  ip6tables -t mangle -F WG_IN_MARK >/dev/null 2>&1 || true
  ip6tables -t mangle -X WG_IN_MARK >/dev/null 2>&1 || true
  ip6tables -t mangle -F WG_OUT_RESTORE >/dev/null 2>&1 || true
  ip6tables -t mangle -X WG_OUT_RESTORE >/dev/null 2>&1 || true

  rm -f "/etc/wireguard/${WG_IF}.conf"
}

ensure_rt_table() {
  grep -qE "^${RT_TABLE_ID}[[:space:]]+${RT_TABLE_NAME}\$" /etc/iproute2/rt_tables 2>/dev/null || \
    echo "${RT_TABLE_ID} ${RT_TABLE_NAME}" >> /etc/iproute2/rt_tables
}

make_client_keys() {
  umask 077
  mkdir -p /etc/wireguard
  wg genkey | tee /etc/wireguard/client.key >/dev/null
  wg pubkey < /etc/wireguard/client.key > /etc/wireguard/client.pub
}

write_wg_conf() {
  local endpoint_ip="$1" port="$2" server_pub="$3"
  local endpoint
  if is_ipv6 "${endpoint_ip}"; then
    endpoint="[${endpoint_ip}]:${port}"
  else
    endpoint="${endpoint_ip}:${port}"
  fi

  cat >"/etc/wireguard/${WG_IF}.conf" <<EOF
[Interface]
PrivateKey = $(cat /etc/wireguard/client.key)
Address = ${WG_V4_CLI}, ${WG_V6_CLI}
# 关键：不让 wg-quick 自己动路由（我们用策略路由）
Table = off

[Peer]
PublicKey = ${server_pub}
Endpoint = ${endpoint}
AllowedIPs = ${WG_V4_SRV_ALLOWED}, ${WG_V6_SRV_ALLOWED}
PersistentKeepalive = 25
EOF

  chmod 600 "/etc/wireguard/${WG_IF}.conf"
}

setup_connmark_chains() {
  local wan_if="$1"

  # IPv4
  iptables -t mangle -N WG_IN_MARK 2>/dev/null || true
  iptables -t mangle -N WG_OUT_RESTORE 2>/dev/null || true

  # 任何从公网口进来的包，都把“这个连接”打上 connmark（包含已建立连接，保护你正在用的 SSH）
  iptables -t mangle -F WG_IN_MARK
  iptables -t mangle -A WG_IN_MARK -j CONNMARK --set-mark "${MARK_IN}"
  iptables -t mangle -A WG_IN_MARK -j CONNMARK --restore-mark

  iptables -t mangle -F WG_OUT_RESTORE
  iptables -t mangle -A WG_OUT_RESTORE -j CONNMARK --restore-mark

  iptables -t mangle -C PREROUTING -i "${wan_if}" -j WG_IN_MARK 2>/dev/null || \
    iptables -t mangle -I PREROUTING 1 -i "${wan_if}" -j WG_IN_MARK

  iptables -t mangle -C OUTPUT -j WG_OUT_RESTORE 2>/dev/null || \
    iptables -t mangle -I OUTPUT 1 -j WG_OUT_RESTORE

  # IPv6
  ip6tables -t mangle -N WG_IN_MARK 2>/dev/null || true
  ip6tables -t mangle -N WG_OUT_RESTORE 2>/dev/null || true

  ip6tables -t mangle -F WG_IN_MARK
  ip6tables -t mangle -A WG_IN_MARK -j CONNMARK --set-mark "${MARK_IN}"
  ip6tables -t mangle -A WG_IN_MARK -j CONNMARK --restore-mark

  ip6tables -t mangle -F WG_OUT_RESTORE
  ip6tables -t mangle -A WG_OUT_RESTORE -j CONNMARK --restore-mark

  ip6tables -t mangle -C PREROUTING -i "${wan_if}" -j WG_IN_MARK 2>/dev/null || \
    ip6tables -t mangle -I PREROUTING 1 -i "${wan_if}" -j WG_IN_MARK

  ip6tables -t mangle -C OUTPUT -j WG_OUT_RESTORE 2>/dev/null || \
    ip6tables -t mangle -I OUTPUT 1 -j WG_OUT_RESTORE
}

apply_policy_routing() {
  local endpoint_ip="$1"

  ensure_rt_table

  # 路由表：所有默认走 wg0（但 wg0 不存在/没路由时会自动 fallthrough 到 main，不会把机器搞死）
  ip -4 route replace default dev "${WG_IF}" table "${RT_TABLE_ID}"
  ip -6 route replace default dev "${WG_IF}" table "${RT_TABLE_ID}" 2>/dev/null || true

  # 1) 出口机 endpoint 永远走主路由（否则握手会被自己送进 wg 形成死循环）
  if is_ipv6 "${endpoint_ip}"; then
    ip -6 rule add priority "${PRIO_TO_ENDPOINT}" to "${endpoint_ip}/128" lookup main
  else
    ip -4 rule add priority "${PRIO_TO_ENDPOINT}" to "${endpoint_ip}/32" lookup main
  fi

  # 2) 保护“当前这条 SSH 会话”（双保险）
  if [[ -n "${SSH_CLIENT:-}" ]]; then
    ssh_ip="$(awk '{print $1}' <<<"${SSH_CLIENT}")"
    if [[ -n "${ssh_ip}" ]]; then
      if is_ipv6 "${ssh_ip}"; then
        ip -6 rule add priority "${PRIO_TO_SSH}" to "${ssh_ip}/128" lookup main 2>/dev/null || true
      else
        ip -4 rule add priority "${PRIO_TO_SSH}" to "${ssh_ip}/32" lookup main 2>/dev/null || true
      fi
    fi
  fi

  # 3) 所有“入站连接”的回包（connmark=0x1）走 main
  ip -4 rule add priority "${PRIO_FWMARK_MAIN}" fwmark "${MARK_IN}" lookup main
  ip -6 rule add priority "${PRIO_FWMARK_MAIN}" fwmark "${MARK_IN}" lookup main 2>/dev/null || true

  # 4) 其余全部默认走 wg 的路由表
  ip -4 rule add priority "${PRIO_DEFAULT_WG}" lookup "${RT_TABLE_ID}"
  ip -6 rule add priority "${PRIO_DEFAULT_WG}" lookup "${RT_TABLE_ID}" 2>/dev/null || true
}

wait_handshake() {
  local server_pub="$1"
  echo "等待 WireGuard 握手（最多 60 秒）..."
  for i in $(seq 1 60); do
    # latest-handshake 为 0 表示还没握上
    hs="$(wg show "${WG_IF}" latest-handshakes 2>/dev/null | awk -v k="${server_pub}" '$1==k{print $2}')"
    [[ -n "${hs}" && "${hs}" != "0" ]] && return 0
    sleep 1
  done
  return 1
}

rollback() {
  echo
  echo "⚠️ 发生错误，正在回滚（保证不影响 SSH）..."
  cleanup_rules
  echo "回滚完成。你仍可通过原 IP/原网卡 SSH 进来。"
}

main() {
  need_root
  trap rollback ERR INT

  echo "=== 入口机 WireGuard（全出站走 WG，入站/SSH 不受影响）==="
  os_install

  local wan_if wan_gw
  wan_if="$(get_wan_if)"
  wan_gw="$(get_wan_gw)"
  [[ -n "${wan_if}" && -n "${wan_gw}" ]] || { echo "找不到默认外网网卡/网关"; exit 1; }
  echo "外网网卡: ${wan_if}"
  echo "外网网关: ${wan_gw}"

  echo "[清理旧配置]"
  cleanup_rules

  read -r -p "出口机公网 IP（IPv4 或 IPv6）: " OUT_IP
  read -r -p "WireGuard 端口（默认 51820）: " OUT_PORT || true
  OUT_PORT="${OUT_PORT:-51820}"
  read -r -p "出口机 Server 公钥（44位Base64，以=结尾）: " OUT_PUB
  validate_pubkey "${OUT_PUB}"

  echo "[生成入口机密钥]"
  make_client_keys

  echo "[写入 wg0.conf]"
  write_wg_conf "${OUT_IP}" "${OUT_PORT}" "${OUT_PUB}"

  echo "[启动 wg0（此时不改你默认路由，不会断 SSH）]"
  systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  wg-quick up "${WG_IF}"

  echo
  echo "================= 把这段 CLIENT 公钥贴到出口机 ================="
  echo "CLIENT 公钥: $(cat /etc/wireguard/client.pub)"
  echo
  echo "在出口机执行："
  echo "wg set ${WG_IF} peer $(cat /etc/wireguard/client.pub) allowed-ips 10.66.66.2/32,fd10::2/128"
  echo "systemctl restart wg-quick@${WG_IF}"
  echo "==============================================================="
  echo
  read -r -p "出口机加完 peer 并重启 wg0 后，按回车继续..." _

  if ! wait_handshake "${OUT_PUB}"; then
    echo "❌ 60 秒内没握手成功：我不会切换全出站，避免把你网搞断。"
    echo "请先在出口机确认：wg show wg0 是否看到这个 CLIENT 公钥、AllowedIPs 是否正确、端口是否放行 UDP ${OUT_PORT}"
    exit 1
  fi
  echo "✅ 握手成功"

  echo "[设置 connmark：保护所有入站连接回包走原网卡（SSH 不断）]"
  setup_connmark_chains "${wan_if}"

  echo "[应用策略路由：除入站回包外，其余出站默认走 wg0]"
  apply_policy_routing "${OUT_IP}"

  systemctl enable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || true

  echo
  echo "=== 验证 ==="
  echo "1) 入口机通过 wg 出口（应显示出口机IP）:"
  curl -4 -s --max-time 10 --interface "${WG_IF}" https://ip.sb || true
  echo
  echo "2) 入口机默认出站（现在也会走 wg，仍应是出口机IP）:"
  curl -4 -s --max-time 10 https://ip.sb || true
  echo
  echo "3) WireGuard 状态:"
  wg show "${WG_IF}" || true
  echo
  echo "✅ 完成：入站仍走原 IP，出站走出口机 IP（wg）。"
  echo
  echo "紧急关闭（随时可用，不影响原IP SSH）："
  echo "wg-quick down ${WG_IF}"
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

WG_IF="wg0"
WG_TABLE="51820"          # 独立路由表
WG_MARK="0x1"             # 保护“入站连接回包”的标记
WG_ADDR4="10.66.66.2/32"
WG_ADDR6="fd10::2/128"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_IF}.conf"
WG_KEY="${WG_DIR}/${WG_IF}.key"
WG_PUB="${WG_DIR}/${WG_IF}.pub"

log(){ echo -e "\n[IN] $*\n"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请用 root 运行"; exit 1
  fi
}

wait_apt_locks() {
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

  # 关键：iptables + wireguard-tools + iproute2 + curl
  apt-get install -y --no-install-recommends \
    wireguard-tools iproute2 iptables curl ca-certificates

  # 有些发行版有 wireguard 元包，装不上不算错
  apt-get install -y --no-install-recommends wireguard 2>/dev/null || true
}

detect_main() {
  local line
  line="$(ip route show default 0.0.0.0/0 | head -n1 || true)"
  local gw ifc
  gw="$(awk '{print $3}' <<<"$line")"
  ifc="$(awk '{print $5}' <<<"$line")"
  echo "${gw}|${ifc}"
}

clean_old() {
  log "清理旧 wg0（不动你默认路由）"
  systemctl disable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  wg-quick down "${WG_IF}" >/dev/null 2>&1 || true
  ip link del "${WG_IF}" >/dev/null 2>&1 || true

  # 清理老的策略路由（吞掉错误，不输出烦人的红字）
  ip rule del fwmark "${WG_MARK}" lookup main 2>/dev/null || true
  ip rule del lookup "${WG_TABLE}" 2>/dev/null || true
  ip -4 route flush table "${WG_TABLE}" 2>/dev/null || true
  ip -6 route flush table "${WG_TABLE}" 2>/dev/null || true

  # 清理 mangle 规则（按规则特征删，尽量不误伤）
  iptables  -t mangle -D PREROUTING -i "${MAIN_IF}" -j CONNMARK --set-mark "${WG_MARK}" 2>/dev/null || true
  iptables  -t mangle -D OUTPUT     -m connmark --mark "${WG_MARK}" -j MARK --set-mark "${WG_MARK}" 2>/dev/null || true
  ip6tables -t mangle -D PREROUTING -i "${MAIN_IF}" -j CONNMARK --set-mark "${WG_MARK}" 2>/dev/null || true
  ip6tables -t mangle -D OUTPUT     -m connmark --mark "${WG_MARK}" -j MARK --set-mark "${WG_MARK}" 2>/dev/null || true
}

gen_keys() {
  log "生成/重置入口机密钥（私钥只留在入口机，不打印）"
  umask 077
  mkdir -p "${WG_DIR}"
  if [[ -f "${WG_KEY}" ]]; then
    mv -f "${WG_KEY}" "${WG_KEY}.bak.$(date +%s)" || true
  fi
  if [[ -f "${WG_PUB}" ]]; then
    mv -f "${WG_PUB}" "${WG_PUB}.bak.$(date +%s)" || true
  fi
  wg genkey | tee "${WG_KEY}" | wg pubkey > "${WG_PUB}"
  chmod 600 "${WG_KEY}" "${WG_PUB}"
}

write_conf() {
  local server_ip="$1"
  local server_port="$2"
  local server_pub="$3"

  log "写入 ${WG_CONF}（不写 DNS，避免 resolvconf 坑）"
  cat >"${WG_CONF}" <<EOF
[Interface]
Address = ${WG_ADDR4}, ${WG_ADDR6}
PrivateKey = $(cat "${WG_KEY}")
Table = off

# 先保护所有“从原网卡进来的连接”的回包（SSH 不会断）
PostUp   = iptables -t mangle -C PREROUTING -i ${MAIN_IF} -j CONNMARK --set-mark ${WG_MARK} 2>/dev/null || iptables -t mangle -A PREROUTING -i ${MAIN_IF} -j CONNMARK --set-mark ${WG_MARK}
PostUp   = iptables -t mangle -C OUTPUT -m connmark --mark ${WG_MARK} -j MARK --set-mark ${WG_MARK} 2>/dev/null || iptables -t mangle -A OUTPUT -m connmark --mark ${WG_MARK} -j MARK --set-mark ${WG_MARK}
PostUp   = ip6tables -t mangle -C PREROUTING -i ${MAIN_IF} -j CONNMARK --set-mark ${WG_MARK} 2>/dev/null || ip6tables -t mangle -A PREROUTING -i ${MAIN_IF} -j CONNMARK --set-mark ${WG_MARK}
PostUp   = ip6tables -t mangle -C OUTPUT -m connmark --mark ${WG_MARK} -j MARK --set-mark ${WG_MARK} 2>/dev/null || ip6tables -t mangle -A OUTPUT -m connmark --mark ${WG_MARK} -j MARK --set-mark ${WG_MARK}

# endpoint 永远走原网卡（避免路由套娃导致断网）
PostUp   = ip rule add priority 50 to ${server_ip} lookup main 2>/dev/null || true

# 建一张只给 wg 用的路由表：默认走 wg0
PostUp   = ip -4 route replace default dev ${WG_IF} table ${WG_TABLE}
PostUp   = ip -6 route replace default dev ${WG_IF} table ${WG_TABLE} 2>/dev/null || true

# 回包(被标记的)走 main，其它全走 wg 表
PostUp   = ip rule add priority 100 fwmark ${WG_MARK} lookup main 2>/dev/null || true
PostUp   = ip rule add priority 200 lookup ${WG_TABLE} 2>/dev/null || true
PostUp   = ip route flush cache 2>/dev/null || true
PostUp   = ip -6 route flush cache 2>/dev/null || true

PostDown = ip rule del priority 50 to ${server_ip} lookup main 2>/dev/null || true
PostDown = ip rule del priority 100 fwmark ${WG_MARK} lookup main 2>/dev/null || true
PostDown = ip rule del priority 200 lookup ${WG_TABLE} 2>/dev/null || true
PostDown = ip -4 route flush table ${WG_TABLE} 2>/dev/null || true
PostDown = ip -6 route flush table ${WG_TABLE} 2>/dev/null || true
PostDown = iptables -t mangle -D PREROUTING -i ${MAIN_IF} -j CONNMARK --set-mark ${WG_MARK} 2>/dev/null || true
PostDown = iptables -t mangle -D OUTPUT -m connmark --mark ${WG_MARK} -j MARK --set-mark ${WG_MARK} 2>/dev/null || true
PostDown = ip6tables -t mangle -D PREROUTING -i ${MAIN_IF} -j CONNMARK --set-mark ${WG_MARK} 2>/dev/null || true
PostDown = ip6tables -t mangle -D OUTPUT -m connmark --mark ${WG_MARK} -j MARK --set-mark ${WG_MARK} 2>/dev/null || true

[Peer]
PublicKey = ${server_pub}
Endpoint = ${server_ip}:${server_port}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

  chmod 600 "${WG_CONF}"
}

start_wg() {
  log "启动 wg0（不会改你默认路由，只用策略路由把出站切到 wg）"
  systemctl enable --now "wg-quick@${WG_IF}" >/dev/null
  sleep 1
}

get_ip_v4() {
  curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
}

verify() {
  log "验证（先看握手，再看出口 IP）"
  wg show "${WG_IF}" || true
  echo

  # 先用 wg0 绑接口测（更直观）
  local via_wg
  via_wg="$(curl -4 -fsS --interface "${WG_IF}" --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  echo "curl -4 --interface ${WG_IF} api.ipify.org => ${via_wg:-（失败）}"

  local normal
  normal="$(get_ip_v4)"
  echo "curl -4 api.ipify.org (普通) => ${normal:-（失败）}"

  echo
  echo "如果 wg 已握手且出口机已加 peer：上面两个结果都应该是【出口机公网 IPv4】。"
}

# ---------- 主流程 ----------
need_root
apt_fix_and_install

# 取主路由网关和外网卡
main_info="$(detect_main)"
MAIN_GW="${main_info%%|*}"
MAIN_IF="${main_info#*|}"
[[ -z "${MAIN_GW}" || -z "${MAIN_IF}" ]] && { echo "找不到默认网关/网卡"; exit 1; }

log "检测到入口机原始出口：网卡=${MAIN_IF} 网关=${MAIN_GW}（入站/回包就靠它保命）"

# 让你手动填（你说自动识别不靠谱）
read -r -p "出口机公网 IP（IPv4 或 IPv6）： " SERVER_IP
read -r -p "WireGuard 端口（默认 51820）： " SERVER_PORT
SERVER_PORT="${SERVER_PORT:-51820}"
read -r -p "出口机 Server 公钥（44位Base64，通常以=结尾）： " SERVER_PUB

# 基本校验：避免你把“中文提示词”当 key 粘进去
if ! [[ "${SERVER_PUB}" =~ ^[A-Za-z0-9+/]{42,44}={0,2}$ ]]; then
  echo "❌ Server 公钥格式不对：请粘贴纯公钥（类似：5pXPrl+...=）"
  exit 1
fi

clean_old
gen_keys
write_conf "${SERVER_IP}" "${SERVER_PORT}" "${SERVER_PUB}"
start_wg

log "把这段 CLIENT 公钥复制到出口机执行 wg set（只需要公钥，私钥绝对不外传）"
CLIENT_PUB="$(cat "${WG_PUB}")"
echo "CLIENT 公钥: ${CLIENT_PUB}"
echo
echo "去出口机执行："
echo "  wg set ${WG_IF} peer ${CLIENT_PUB} allowed-ips 10.66.66.2/32,fd10::2/128"
echo "  wg-quick save ${WG_IF}"
echo

verify

log "紧急回滚（随时可用，不影响你原 IP 入站）："
echo "  wg-quick down ${WG_IF}"

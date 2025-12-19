#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# WireGuard Ingress Script
# Version : 2.2
# Feature :
#   - IPv4 强制走出口机
#   - IPv6 可选是否走出口机（交互选择）
#   - 完整部署流程控制（人工确认）
#   - 最终 IPv4 / IPv6 出口验证
# =========================================================

SCRIPT_VERSION="2.2"

echo "=================================================="
echo " WireGuard Ingress Script v${SCRIPT_VERSION}"
echo " IPv4 强制出口 / IPv6 可选出口"
echo "=================================================="
echo

# ================== 参数 ==================
WG_IF="wg0"
WG_TABLE="51820"
WG_MARK="0x1"
WG_MTU="1280"

WG_ADDR4="10.66.66.2/32"
WG_ADDR6="fd10::2/128"

WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_IF}.conf"
WG_KEY="${WG_DIR}/${WG_IF}.key"
WG_PUB="${WG_DIR}/${WG_IF}.pub"

# ================== IPv6 出口开关（运行时选择） ==================
USE_V6_OUT="no"

log(){ echo -e "\n[IN] $*\n"; }

# ================== 基础 ==================
need_root() {
  [[ "${EUID}" -eq 0 ]] || { echo "❌ 请用 root 运行"; exit 1; }
}

# ================== IPv6 交互选择 ==================
select_ipv6_mode() {
  echo
  echo "是否让 IPv6 也走出口机？"
  echo "  1) 否（推荐，IPv6 走入口机本地）"
  echo "  2) 是（IPv4 + IPv6 全走出口机）"
  echo
  read -r -p "请选择 [1/2]（默认 1）: " choice

  case "${choice:-1}" in
    2) USE_V6_OUT="yes" ;;
    *) USE_V6_OUT="no" ;;
  esac

  log "IPv6 出口模式：${USE_V6_OUT}"
}

wait_apt_locks() {
  for i in {1..120}; do
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
    sleep 1
  done
}

apt_fix_and_install() {
  log "安装依赖"
  systemctl stop unattended-upgrades 2>/dev/null || true
  wait_apt_locks
  dpkg --configure -a 2>/dev/null || true
  apt-get -y -f install 2>/dev/null || true
  wait_apt_locks
  apt-get update -y
  apt-get install -y --no-install-recommends \
    wireguard-tools iproute2 iptables curl ca-certificates
}

detect_main() {
  local line gw ifc
  line="$(ip route show default | head -n1)"
  gw="$(awk '{print $3}' <<<"$line")"
  ifc="$(awk '{print $5}' <<<"$line")"
  echo "${gw}|${ifc}"
}

# ================== 清理 ==================
clean_old() {
  log "清理旧 WG（不动默认路由）"
  systemctl disable --now wg-quick@${WG_IF} 2>/dev/null || true
  wg-quick down ${WG_IF} 2>/dev/null || true
  ip link del ${WG_IF} 2>/dev/null || true

  ip rule del fwmark ${WG_MARK} lookup main 2>/dev/null || true
  ip rule del lookup ${WG_TABLE} 2>/dev/null || true
  ip route flush table ${WG_TABLE} 2>/dev/null || true
  ip -6 route flush table ${WG_TABLE} 2>/dev/null || true
}

# ================== Key ==================
gen_keys() {
  log "生成入口机密钥"
  umask 077
  mkdir -p "${WG_DIR}"
  wg genkey | tee "${WG_KEY}" | wg pubkey > "${WG_PUB}"
  chmod 600 "${WG_KEY}" "${WG_PUB}"
}

# ================== 配置 ==================
write_conf() {
  local server_ip="$1"
  local server_port="$2"
  local server_pub="$3"

  local allowed_ips="0.0.0.0/0"
  [[ "${USE_V6_OUT}" == "yes" ]] && allowed_ips="0.0.0.0/0, ::/0"

  log "写入 ${WG_CONF}"

  cat >"${WG_CONF}" <<EOF
[Interface]
Address = ${WG_ADDR4}, ${WG_ADDR6}
PrivateKey = $(cat "${WG_KEY}")
Table = off

# MTU 必须在 WG 接管流量前生效
PostUp   = ip link set dev ${WG_IF} mtu ${WG_MTU}
PostDown = ip link set dev ${WG_IF} mtu 1420 || true

# 保护 SSH / 原连接
PostUp   = iptables -t mangle -A PREROUTING -i ${MAIN_IF} -j CONNMARK --set-mark ${WG_MARK}
PostUp   = iptables -t mangle -A OUTPUT -m connmark --mark ${WG_MARK} -j MARK --set-mark ${WG_MARK}

# 出口机 endpoint 永远走 main 表
PostUp   = ip rule add priority 50 to ${server_ip} lookup main

# IPv4 policy routing
PostUp   = ip route add default dev ${WG_IF} table ${WG_TABLE}
PostUp   = ip rule add priority 100 fwmark ${WG_MARK} lookup main
PostUp   = ip rule add priority 200 lookup ${WG_TABLE}

# IPv6 policy routing（可选）
PostUp   = [ "${USE_V6_OUT}" = "yes" ] && ip -6 route add default dev ${WG_IF} table ${WG_TABLE} || true
PostUp   = [ "${USE_V6_OUT}" = "yes" ] && ip -6 rule add priority 200 lookup ${WG_TABLE} || true

PostUp   = ip route flush cache

PostDown = ip rule del priority 50 to ${server_ip} lookup main
PostDown = ip rule del priority 100 fwmark ${WG_MARK} lookup main
PostDown = ip rule del priority 200 lookup ${WG_TABLE}
PostDown = ip -6 rule del priority 200 lookup ${WG_TABLE} 2>/dev/null || true
PostDown = ip route flush table ${WG_TABLE}
PostDown = ip -6 route flush table ${WG_TABLE}
PostDown = iptables -t mangle -D PREROUTING -i ${MAIN_IF} -j CONNMARK --set-mark ${WG_MARK}
PostDown = iptables -t mangle -D OUTPUT -m connmark --mark ${WG_MARK} -j MARK --set-mark ${WG_MARK}

[Peer]
PublicKey = ${server_pub}
Endpoint = ${server_ip}:${server_port}
AllowedIPs = ${allowed_ips}
PersistentKeepalive = 25
EOF
}

# ================== 启动 ==================
start_wg() {
  log "启动 WG"
  systemctl enable --now wg-quick@${WG_IF}
}

# ================== 人工同步 ==================
pause_for_peer() {
  echo
  echo "================ 等待出口机对接 ================="
  echo "请在【出口机】执行："
  echo "  wg set wg0 peer $(cat ${WG_PUB}) allowed-ips 10.66.66.2/32,fd10::2/128"
  echo "  wg-quick save wg0"
  echo
  read -r -p "出口机完成后，回到这里按 Enter 继续..." _
}

# ================== 最终验证 ==================
verify() {
  log "最终出口验证"

  echo "IPv4 出口（curl ipinfo.io）："
  curl --max-time 10 ipinfo.io || true
  echo

  echo "IPv6 出口（curl -6 ip.sb）："
  curl -6 --max-time 10 ip.sb || true
}

# ================== 主流程 ==================
need_root
select_ipv6_mode
apt_fix_and_install

main_info="$(detect_main)"
MAIN_GW="${main_info%%|*}"
MAIN_IF="${main_info#*|}"

log "入口机原始出口：${MAIN_IF} via ${MAIN_GW}"

read -r -p "出口机公网 IP： " SERVER_IP
read -r -p "WireGuard 端口（默认 51820）： " SERVER_PORT
SERVER_PORT="${SERVER_PORT:-51820}"
read -r -p "出口机 Server 公钥： " SERVER_PUB

clean_old
gen_keys
write_conf "${SERVER_IP}" "${SERVER_PORT}" "${SERVER_PUB}"
start_wg

echo
echo "====== CLIENT 公钥（复制到出口机） ======"
cat "${WG_PUB}"
echo "=========================================="

pause_for_peer
verify

echo
echo "✅ 完成（IPv6 出口模式：${USE_V6_OUT}）"

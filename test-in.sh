#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# OpenVPN Ingress Script (IN)
# Base   : 原 WireGuard in.sh 结构等价迁移
# Mode   : OpenVPN TCP + policy routing
# Version: 1.0
# =========================================================

SCRIPT_VERSION="1.0"

echo "=================================================="
echo " OpenVPN Ingress Script v${SCRIPT_VERSION}"
echo " 入口机"
echo "=================================================="
echo

# ================== 参数 ==================
OVPN_IF="tun0"
OVPN_TABLE="51820"
OVPN_MARK="0x1"
OVPN_CONF="/root/client.ovpn"

log(){ echo -e "\n[IN] $*\n"; }

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
  log "安装依赖"
  systemctl stop unattended-upgrades 2>/dev/null || true
  wait_apt_locks
  dpkg --configure -a 2>/dev/null || true
  apt-get -y -f install 2>/dev/null || true
  wait_apt_locks
  apt-get update -y
  apt-get install -y --no-install-recommends \
    openvpn iproute2 iptables curl ca-certificates
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
  log "清理旧 OpenVPN / 路由规则（不动默认路由）"
  pkill openvpn 2>/dev/null || true

  ip rule del fwmark ${OVPN_MARK} lookup ${OVPN_TABLE} 2>/dev/null || true
  ip rule del lookup ${OVPN_TABLE} 2>/dev/null || true
  ip route flush table ${OVPN_TABLE} 2>/dev/null || true

  iptables -t mangle -D OUTPUT -m connmark --mark ${OVPN_MARK} -j MARK --set-mark ${OVPN_MARK} 2>/dev/null || true
}

# ================== 启动 ==================
start_openvpn() {
  log "启动 OpenVPN Client（使用 /root/client.ovpn）"
  openvpn --config "${OVPN_CONF}" --daemon
  sleep 3
}

# ================== policy routing ==================
setup_policy() {
  log "设置 policy routing（等价 WG 版）"

  ip route add default dev ${OVPN_IF} table ${OVPN_TABLE}
  ip rule add fwmark ${OVPN_MARK} lookup ${OVPN_TABLE}
  ip rule add priority 32766 lookup main

  iptables -t mangle -A OUTPUT -m connmark --mark ${OVPN_MARK} -j MARK --set-mark ${OVPN_MARK}
}

# ================== 验证 ==================
verify() {
  log "最终出口验证"
  echo "IPv4 出口："
  curl --max-time 10 ipinfo.io || true
}

# ================== 主流程 ==================
need_root

[[ -f "${OVPN_CONF}" ]] || {
  echo "❌ 未找到 ${OVPN_CONF}，请先在出口机执行 out-openvpn.sh"
  exit 1
}

apt_fix_and_install

main_info="$(detect_main)"
MAIN_IF="${main_info#*|}"
log "入口机原始出口接口：${MAIN_IF}"

clean_old
start_openvpn
setup_policy
verify

echo
echo "✅ 完成：OpenVPN TCP 出口已接管新流量"
echo "紧急回滚："
echo "  pkill openvpn"
echo "  ip rule flush"
echo "  ip route flush table ${OVPN_TABLE}"

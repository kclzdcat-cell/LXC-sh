#!/bin/bash

echo "=============================================="
echo " LXC 机场 面板 / 节点 精准审计（v3 FINAL）"
echo " 仅识别【真实运行中的机场服务】"
echo "=============================================="
echo

PANEL_ACTIVE=()
NODE_ACTIVE=()
NODE_INACTIVE=()

for c in $(lxc list -c n --format csv); do
  echo "🔍 正在审计容器：$c"

  # ===============================
  # 1. 机场面板（v2board / xboard）
  # ===============================
  if lxc exec "$c" -- sh -c '
    # 必须是运行态
    ps aux | grep -E "php-fpm|nginx|apache" | grep -v grep >/dev/null 2>&1 || exit 1

    # 必须是 Laravel 结构
    find / -maxdepth 3 -type f -name ".env" 2>/dev/null | grep -q . || exit 1
    find / -maxdepth 3 -type f -name "artisan" 2>/dev/null | grep -q . || exit 1

    exit 0
  ' >/dev/null 2>&1; then
    echo "🚨 命中：运行中的【机场面板】"
    PANEL_ACTIVE+=("$c")
    echo
    continue
  fi

  # ===============================
  # 2. 机场节点（V2bX，运行态）
  # ===============================
  if lxc exec "$c" -- sh -c '
    # 必须有 V2bX 主进程
    ps aux | grep "[V]2bX" >/dev/null 2>&1 || exit 1

    # 必须有真实面板对接配置
    [ -f /etc/V2bX/config.json ] || exit 1
    grep -Eq "\"panel_url\".*https?://" /etc/V2bX/config.json || exit 1
    grep -Eq "\"node_id\"[[:space:]]*:[[:space:]]*[0-9]+" /etc/V2bX/config.json || exit 1

    # 必须至少一个运行期证据
    (
      ps -eo pid,ppid,cmd | grep "[V]2bX" | grep -E "sing-box|xray" ||
      ls /etc/V2bX/user/* >/dev/null 2>&1 ||
      ss -tnp | grep V2bX
    ) || exit 1

    exit 0
  ' >/dev/null 2>&1; then
    echo "⚠️ 命中：运行中的【机场节点（V2bX）】"
    NODE_ACTIVE+=("$c")
    echo
    continue
  fi

  # ===============================
  # 3. 装过但未运行（不报警）
  # ===============================
  if lxc exec "$c" -- test -d /etc/V2bX >/dev/null 2>&1; then
    echo "ℹ️ 发现 V2bX 文件，但未运行（不判定为机场）"
    NODE_INACTIVE+=("$c")
    echo
    continue
  fi

  echo "✅ 未发现机场相关服务"
  echo
done

echo "=============================================="
echo "                 审计结果汇总"
echo "=============================================="

echo
echo "🚨 运行中的【机场面板】容器："
if [ ${#PANEL_ACTIVE[@]} -eq 0 ]; then
  echo "  无"
else
  for i in "${PANEL_ACTIVE[@]}"; do
    echo "  - $i"
  done
fi

echo
echo "⚠️ 运行中的【机场节点（V2bX）】容器："
if [ ${#NODE_ACTIVE[@]} -eq 0 ]; then
  echo "  无"
else
  for i in "${NODE_ACTIVE[@]}"; do
    echo "  - $i"
  done
fi

echo
echo "ℹ️ 安装但未运行的 V2bX（仅提示，不报警）："
if [ ${#NODE_INACTIVE[@]} -eq 0 ]; then
  echo "  无"
else
  for i in "${NODE_INACTIVE[@]}"; do
    echo "  - $i"
  done
fi

echo
echo "✅ 审计完成（v3 FINAL：仅报告真实机场行为）"

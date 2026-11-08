#!/usr/bin/env bash
# PasarGuard 安全加固（幂等，可重复执行）
#
# 独立于安装器存在，原因：
#   官方 `pasarguard update` 会重建容器，可能用上游模板重写 docker-compose.yml，
#   把安装器加的 `profiles: ["admin"]` 冲掉 —— pgadmin 复活，25 端口重新暴露。
#   所以加固必须能"事后重放"，由 systemd 在开机和定时任务里自动跑。
#
# 用法：pg-cn-harden          （静默，只在有变化时输出）
#      pg-cn-harden --verbose
set -uo pipefail

PANEL_DIR="${PANEL_DIR:-/opt/pasarguard}"
COMPOSE="${PANEL_DIR}/docker-compose.yml"
ENVFILE="${PANEL_DIR}/.env"
VERBOSE="${1:-}"
CHANGED=0

say()  { (( CHANGED == 1 )) || [[ "$VERBOSE" == "--verbose" ]] && printf '[pg-cn-harden] %s\n' "$*"; }
mark() { CHANGED=1; printf '[pg-cn-harden] %s\n' "$*"; }

# ── 1. pgadmin：停掉 ────────────────────────────────────────
if command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx pgadmin; then
    docker stop pgadmin >/dev/null 2>&1 && mark "已停止 pgadmin（25 端口风险源）"
  fi
  if docker inspect pgadmin >/dev/null 2>&1; then
    if [[ "$(docker inspect pgadmin --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)" != "no" ]]; then
      docker update --restart=no pgadmin >/dev/null 2>&1 && mark "pgadmin restart 策略改为 no"
    fi
  fi
fi

# ── 2. compose 声明：把 pgadmin 移进 admin profile ──────────
# 只改运行时属性没用 —— `pasarguard up` 执行 docker compose up -d，
# 会按声明把服务拉回来。必须改声明层。
if [[ -f "$COMPOSE" ]] && grep -qE '^[[:space:]]+pgadmin:' "$COMPOSE"; then
  if ! grep -q 'profiles: \["admin"\]' "$COMPOSE"; then
    cp "$COMPOSE" "${COMPOSE}.bak.pgcn.$(date +%s)"
    python3 - "$COMPOSE" <<'PY'
import re, sys
p = sys.argv[1]
lines = open(p, encoding='utf-8').read().split('\n')
svc = next((i for i, l in enumerate(lines) if re.match(r'^services:\s*$', l)), None)
if svc is None:
    sys.exit(0)
# services 块的结束位置 = 下一个顶层键
end = next((i for i, l in enumerate(lines)
            if i > svc and re.match(r'^[a-z_]+:\s*$', l)), len(lines))
# 只在 services 块内找 pgadmin（volumes: 下可能有同名条目）
tgt = next((i for i in range(svc + 1, end)
            if re.match(r'^  pgadmin:\s*$', lines[i])), None)
if tgt is None:
    sys.exit(0)
lines.insert(tgt + 1, '    profiles: ["admin"]')
open(p, 'w', encoding='utf-8').write('\n'.join(lines))
PY
    grep -q 'profiles: \["admin"\]' "$COMPOSE" && mark "compose 已加固：pgadmin 在 admin profile 内"
  fi
fi

# ── 3. DOCS 关闭 ────────────────────────────────────────────
if [[ -f "$ENVFILE" ]]; then
  if grep -qE '^[[:space:]]*#?[[:space:]]*DOCS[[:space:]]*=' "$ENVFILE"; then
    if ! grep -qE '^DOCS[[:space:]]*=[[:space:]]*False' "$ENVFILE"; then
      sed -i 's/^#\{0,1\}[[:space:]]*DOCS[[:space:]]*=.*/DOCS = False/' "$ENVFILE"
      mark "已关闭 DOCS（重新创建容器后生效）"
    fi
  else
    echo 'DOCS = False' >> "$ENVFILE"
    mark "已追加 DOCS = False"
  fi
fi

# ── 4. iptables 兜底 ────────────────────────────────────────
# 即使 pgadmin 又跑起来、或别的服务绑了这些端口，外网也进不来。
if command -v iptables >/dev/null 2>&1; then
  ADDED=0
  for p in 25 8010 5432 6432 8443; do
    for proto in tcp udp; do
      if ! iptables -C INPUT -p "$proto" --dport "$p" ! -i lo -j DROP 2>/dev/null; then
        iptables -I INPUT 1 -p "$proto" --dport "$p" ! -i lo -j DROP 2>/dev/null && ADDED=1
      fi
    done
  done
  if (( ADDED == 1 )); then
    (( CHANGED == 1 )) || mark "已补 iptables 规则"
    if command -v netfilter-persistent >/dev/null 2>&1; then
      mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4
    fi
  fi
fi

exit 0

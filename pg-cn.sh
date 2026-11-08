#!/usr/bin/env bash
#
# PasarGuard 中文安装器 (pg-cn.sh)
#
# 定位：官方 PasarGuard/scripts 的中文安全加固外壳。
# 不重复造轮子 —— 面板与节点的核心安装仍调用官方脚本，本脚本只补官方缺的五件事：
#
#   1. 中文交互 + 全自动模式（官方无 --yes，无法自动化部署）
#   2. 国内 Docker 镜像加速（官方只有伊朗镜像方案）
#   3. 默认关闭 pgadmin 并封堵 25 端口（官方默认启动 pgadmin，宿主机 25 端口暴露）
#   4. 自动创建管理员账号（官方装完 admins 表是空的，登不进面板）
#   5. 补齐 nginx HTTPS 反代（官方 --no-ssl 模式下没有对外入口）
#
# 支持：Debian 11/12/13 · Ubuntu 20.04/22.04/24.04
#
set -euo pipefail

PGCN_VERSION="1.0.0"
OFFICIAL_PANEL_URL="https://raw.githubusercontent.com/PasarGuard/scripts/main/pasarguard.sh"

# ── 默认参数 ─────────────────────────────────────────────────
PANEL_DIR="/opt/pasarguard"
PANEL_PORT=9443          # 对外 HTTPS
INTERNAL_PORT=8000       # 官方面板内部端口（不改，减少与上游分歧）
ADMIN_USER="admin"
ADMIN_PASS=""
DOMAIN=""
DB_ENGINE="postgresql"
ASSUME_YES=0
SKIP_MIRROR=0
SKIP_HARDEN=0
SKIP_NGINX=0
USE_CN_GEOFILES=0
REINSTALL=0
SELFTEST=0

# ── 颜色 ────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; N=$'\033[0m'; BOLD=$'\033[1m'
else
  R=''; G=''; Y=''; B=''; N=''; BOLD=''
fi

step()  { printf '\n%s━━ %s%s\n' "$B$BOLD" "$*" "$N"; }
ok()    { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()   { printf '\n  %s✗ %s%s\n\n' "$R" "$*" "$N" >&2; exit 1; }
info()  { printf '    %s\n' "$*"; }

usage() {
  cat <<EOF
PasarGuard 中文安装器 v${PGCN_VERSION}

用法：sudo bash pg-cn.sh [选项]

  --yes, -y            全自动，不询问（适合脚本化部署）
  --domain <域名>      用域名签 Let's Encrypt 证书（默认用自签 IP 证书）
  --panel-port <端口>  面板对外 HTTPS 端口，默认 ${PANEL_PORT}
  --db <引擎>          数据库：postgresql（默认）| sqlite | mysql | mariadb | timescaledb
  --admin-user <名>    管理员用户名，默认 ${ADMIN_USER}
  --skip-mirror        跳过国内镜像加速配置
  --skip-harden        跳过安全加固（不建议）
  --skip-nginx         不装 nginx 反代（只留 127.0.0.1 访问）
  --cn-geofiles        为节点下载中国分流规则（Loyalsoldier）
  --reinstall          已有安装时强制重装面板（默认跳过，不动数据）
  --selftest           装完跑端到端自检（建临时用户→拉订阅→验证→清理）
  -h, --help           显示本帮助

示例：
  sudo bash pg-cn.sh                      # 交互安装
  sudo bash pg-cn.sh -y --panel-port 9443 # 全自动
  sudo bash pg-cn.sh --domain panel.example.com
EOF
}

# ── 参数解析 ────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)        ASSUME_YES=1; shift ;;
    --domain)        DOMAIN="$2"; shift 2 ;;
    --panel-port)    PANEL_PORT="$2"; shift 2 ;;
    --db)            DB_ENGINE="$2"; shift 2 ;;
    --admin-user)    ADMIN_USER="$2"; shift 2 ;;
    --skip-mirror)   SKIP_MIRROR=1; shift ;;
    --skip-harden)   SKIP_HARDEN=1; shift ;;
    --skip-nginx)    SKIP_NGINX=1; shift ;;
    --cn-geofiles)   USE_CN_GEOFILES=1; shift ;;
    --reinstall)     REINSTALL=1; shift ;;
    --selftest)      SELFTEST=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

case "$DB_ENGINE" in
  postgresql|sqlite|mysql|mariadb|timescaledb) ;;
  *) die "不支持的数据库引擎：${DB_ENGINE}" ;;
esac

# ── 前置检查 ────────────────────────────────────────────────
step "环境检查"

[[ $EUID -eq 0 ]] || die "请用 root 运行（sudo bash pg-cn.sh）"

. /etc/os-release 2>/dev/null || die "读不到 /etc/os-release"
case "${ID:-}" in
  debian|ubuntu) ok "系统：${PRETTY_NAME}" ;;
  *) die "只支持 Debian / Ubuntu，当前是 ${ID:-未知}" ;;
esac

ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
case "$ARCH" in amd64|arm64) ok "架构：${ARCH}" ;; *) die "不支持的架构：${ARCH}" ;; esac

MEM_MB=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
if (( MEM_MB < 1800 )); then
  warn "内存仅 ${MEM_MB}MB。面板约需 1.2GB，低于 1.8GB 容易 OOM。"
  (( ASSUME_YES == 1 )) || { read -rp "  仍然继续？[y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || die "已取消"; }
else
  ok "内存：${MEM_MB}MB"
fi

DISK_MB=$(df -Pm / | awk 'NR==2{print $4}')
(( DISK_MB < 8000 )) && warn "磁盘剩余 ${DISK_MB}MB，建议 8GB 以上" || ok "磁盘剩余：${DISK_MB}MB"

# 公网 IP
PUBIP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$PUBIP" ]] || PUBIP="$(curl -4 -fsS --max-time 8 https://ipv4.icanhazip.com 2>/dev/null || true)"
[[ -n "$PUBIP" ]] || die "无法获取公网 IP，请手动指定：PUBIP=x.x.x.x bash pg-cn.sh"
ok "公网 IP：${PUBIP}"

command -v curl >/dev/null || die "缺少 curl"

# ── 交互确认 ────────────────────────────────────────────────
if (( ASSUME_YES == 0 )); then
  echo
  printf '%s即将安装：%s\n' "$BOLD" "$N"
  # heredoc 内部不会执行 shell 逻辑，必须先算好再插值
  if (( SKIP_HARDEN == 1 )); then
    HARDEN_DESC="否（--skip-harden，25 端口可能对公网开放）"
  else
    HARDEN_DESC="是（关 pgadmin / 封 25 / 绑本地）"
  fi
  cat <<EOF
    面板对外端口    ${PANEL_PORT}   ← 需要在云厂商防火墙放行
    面板内部端口    ${INTERNAL_PORT}（仅 127.0.0.1）
    数据库          ${DB_ENGINE}
    管理员账号      ${ADMIN_USER}
    证书            $([[ -n "$DOMAIN" ]] && echo "Let's Encrypt（${DOMAIN}）" || echo "自签（IP:${PUBIP}）")
    安全加固        ${HARDEN_DESC}
EOF
  echo
  printf '%s安装前请在云厂商控制台放行 TCP %s 端口，否则装完外网也连不上。%s\n' "$Y" "$PANEL_PORT" "$N"
  echo
  read -rp "继续？[y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "已取消"
fi

# ── 国内镜像加速 ────────────────────────────────────────────
if (( SKIP_MIRROR == 0 )); then
  step "配置国内 Docker 镜像加速"

  MIRRORS=(
    "https://docker.1ms.run"
    "https://docker.xuanyuan.me"
    "https://dockers.xuanyuan.me"
    "https://hub.rat.dev"
  )

  # 测速：取最快的「可用」镜像。
  # 只比 time_total 是错的 —— 一个连不上的镜像会因为「失败得很快」（connection
  # refused 几毫秒就返回）反而排第一。必须先验 HTTP 状态码。
  #   Docker Registry 的 /v2/ 返回 200 或 401（带鉴权挑战）都算正常在服务。
  best=""; best_ms=99999
  for m in "${MIRRORS[@]}"; do
    out="$(curl -o /dev/null -s -w '%{http_code} %{time_total}' --max-time 4 "${m}/v2/" 2>/dev/null || echo '000 99')"
    code="${out%% *}"
    t="${out##* }"
    ms=$(awk -v t="$t" 'BEGIN{printf "%d", t*1000}')
    if [[ "$code" == "200" || "$code" == "401" ]]; then
      info "测速 ${m} → ${ms}ms（HTTP ${code}）"
      if (( ms < best_ms )); then best_ms=$ms; best=$m; fi
    else
      info "跳过 ${m}（HTTP ${code}，不可用）"
    fi
  done

  if [[ -n "$best" ]] && (( best_ms < 4000 )); then
    mkdir -p /etc/docker
    DAEMON_JSON=/etc/docker/daemon.json
    if [[ -f "$DAEMON_JSON" ]]; then
      # 只保留最近 3 份备份，避免每次重跑都堆一个
      cp "$DAEMON_JSON" "${DAEMON_JSON}.bak.$(date +%s)"
      ls -1t "${DAEMON_JSON}".bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f
      # 合并而不是覆盖：用户可能已经配了 insecure-registries / live-restore /
      # data-root 等，直接盖掉会把他们的设置弄丢。
      python3 - "$DAEMON_JSON" "$best" <<'PY' || warn "合并 daemon.json 失败，保持原样"
import json, sys
path, mirror = sys.argv[1], sys.argv[2]
try:
    cfg = json.load(open(path, encoding='utf-8'))
except Exception:
    cfg = {}
mirrors = cfg.get('registry-mirrors') or []
if mirror not in mirrors:
    mirrors.insert(0, mirror)
cfg['registry-mirrors'] = mirrors
cfg.setdefault('log-driver', 'json-file')
cfg.setdefault('log-opts', {'max-size': '50m', 'max-file': '3'})
json.dump(cfg, open(path, 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
PY
    else
      cat > "$DAEMON_JSON" <<JSON
{
  "registry-mirrors": ["${best}"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
JSON
    fi
    if systemctl is-active --quiet docker 2>/dev/null; then
      systemctl restart docker
    fi
    ok "已启用镜像加速：${best}（${best_ms}ms）"
  else
    warn "所有镜像源都超时，跳过加速（可能你已在海外，直连即可）"
  fi
else
  warn "跳过镜像加速（--skip-mirror）"
fi

# ── 下载官方脚本 ────────────────────────────────────────────
step "获取官方安装脚本"

mkdir -p /opt/pg-cn
OFFICIAL="/opt/pg-cn/pasarguard-official.sh"
if [[ -f "$OFFICIAL" ]] && [[ $(( $(date +%s) - $(stat -c %Y "$OFFICIAL") )) -lt 86400 ]]; then
  ok "使用缓存（24 小时内）"
else
  curl -fsSL --connect-timeout 10 "$OFFICIAL_PANEL_URL" -o "$OFFICIAL" \
    || die "下载官方脚本失败，检查网络"
  ok "已下载：$(wc -l < "$OFFICIAL") 行"
fi
chmod +x "$OFFICIAL"

# ── 调用官方安装 ────────────────────────────────────────────
step "安装 PasarGuard 面板"

if [[ -f "${PANEL_DIR}/docker-compose.yml" ]]; then
  ALREADY_INSTALLED=1
else
  ALREADY_INSTALLED=0
fi

if (( ALREADY_INSTALLED == 1 )) && (( REINSTALL == 0 )); then
  ok "检测到已有安装，跳过面板安装"
  info "这样做是为了不动你的数据库和用户数据。"
  info "要强制重装面板：sudo bash pg-cn.sh --reinstall"
  info "要升级面板版本：sudo pasarguard update"
else
  (( ALREADY_INSTALLED == 1 )) && warn "强制重装模式（--reinstall）：会覆盖 compose/.env，数据卷保留"

  info "这一步会拉取镜像，2-5 分钟，请耐心等待……"
  echo

  # 官方脚本没有 --yes，靠管道预喂答案。但它有三个 read 点，且**是否出现取决于状态**：
  #   1) "already installed, override?"  —— 仅当已安装
  #   2) "Enter a different port"        —— 仅当 8000 被占用（在 while 里循环）
  #   3) "install PasarGuard node?"      —— 总是
  # 写死 'y\n' 会在「干净安装」时被第 3 个问题吃掉，导致官方自己又装一遍节点；
  # 更糟的是若 8000 被占，'y' 落到第 2 个问题 → 非法端口 → 循环 → 卡死。
  # 所以：先确保端口空闲，再按「是否已安装」拼答案。
  if ss -tln 2>/dev/null | grep -qE '(^|[^0-9])127\.0\.0\.1:${INTERNAL_PORT} ' \
     || ss -tln 2>/dev/null | grep -qE '(^|[^0-9])0\.0\.0\.0:${INTERNAL_PORT} '; then
    die "内部端口 ${INTERNAL_PORT} 已被占用，官方脚本会陷入端口询问循环。
       请先释放该端口：ss -tlnp | grep :${INTERNAL_PORT}"
  fi

  ANSWERS=""
  (( ALREADY_INSTALLED == 1 )) && ANSWERS+="y"$'\n' || true
  ANSWERS+="n"$'\n'   # 是否装节点 → n（节点由本脚本下面单独装，避免重复）

  # ── 为什么后台跑 ────────────────────────────────────────────
  # 官方 install_command 的最后一句是 follow_pasarguard_logs()，也就是
  # `docker compose logs -f` —— 它永远不会返回。
  # 所以不能等它退出：起后台 + 轮询面板就绪 + 主动收尾。
  # （踩过一次：答 'n' 跳过节点，就走到这条 logs -f，卡了 20 分钟才发现
  #   安装其实早就完成了，面板一直返回 200。）
  printf '%s' "$ANSWERS" > /tmp/pgcn-answers.txt
  INSTALL_LOG=/tmp/pgcn-install.log
  : > "$INSTALL_LOG"

  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$OFFICIAL" install --database "$DB_ENGINE" --no-ssl \
      < /tmp/pgcn-answers.txt > "$INSTALL_LOG" 2>&1 &
  else
    bash "$OFFICIAL" install --database "$DB_ENGINE" --no-ssl \
      < /tmp/pgcn-answers.txt > "$INSTALL_LOG" 2>&1 &
  fi
  INSTALL_PID=$!

  PANEL_OK=0
  for i in $(seq 1 200); do
    if curl -s -o /dev/null -m 3 "http://127.0.0.1:${INTERNAL_PORT}/" 2>/dev/null; then
      PANEL_OK=1
      sleep 5          # 让 compose up 把剩余服务收尾
      break
    fi
    kill -0 "$INSTALL_PID" 2>/dev/null || break   # 它自己退出了
    sleep 3
  done

  # 收尾：干掉还在 tail 日志的进程组
  if kill -0 "$INSTALL_PID" 2>/dev/null; then
    kill -TERM -"$INSTALL_PID" 2>/dev/null || kill -TERM "$INSTALL_PID" 2>/dev/null || true
    sleep 2
    kill -KILL -"$INSTALL_PID" 2>/dev/null || true
  fi
  wait "$INSTALL_PID" 2>/dev/null || true

  # 回放日志：滤掉拉取进度和容器逐行日志，只留里程碑
  grep -aE 'installed|Installing|Using|Fetching|Skipping|ERROR|error|Error|fail|Fail' \
    "$INSTALL_LOG" 2>/dev/null | sed 's/^/    /' | tail -25 || true

  if (( PANEL_OK == 1 )); then
    ok "面板已响应 127.0.0.1:${INTERNAL_PORT}"
  else
    warn "面板未就绪，安装日志最后 20 行："
    tail -20 "$INSTALL_LOG" 2>/dev/null | sed 's/^/    /' || true
    die "面板安装失败。排查：(cd ${PANEL_DIR} && docker compose logs --tail 50)"
  fi
fi
echo

# ── 安全加固 ────────────────────────────────────────────────
if (( SKIP_HARDEN == 0 )); then
  step "安全加固"

  # 加固逻辑独立成 /usr/local/bin/pg-cn-harden，并由 systemd 在开机时和每 15 分钟
  # 重放一次。原因：官方 `pasarguard update` 可能用上游模板重写 docker-compose.yml，
  # 把下面加的 profiles 冲掉，pgadmin 复活、25 端口重新暴露。
  # 把加固做成"可重放的幂等脚本"，就不会因为一次升级静默回到不安全状态。
  install -m 0755 /dev/stdin /usr/local/bin/pg-cn-harden <<'PGCN_HARDEN_EOF'
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
PGCN_HARDEN_EOF

  ok "已安装加固脚本 /usr/local/bin/pg-cn-harden"

  cat > /etc/systemd/system/pg-cn-harden.service <<'UNIT'
[Unit]
Description=PasarGuard hardening (idempotent, re-applied after updates)
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pg-cn-harden
RemainAfterExit=yes
UNIT

  cat > /etc/systemd/system/pg-cn-harden.timer <<'UNIT'
[Unit]
Description=Re-apply PasarGuard hardening periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Unit=pg-cn-harden.service

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now pg-cn-harden.timer >/dev/null 2>&1 || true
  ok "已启用 systemd 定时重放（开机 + 每 15 分钟）"

  # 立刻跑一次
  /usr/local/bin/pg-cn-harden --verbose 2>&1 | sed 's/^/  /' || true
  ok "加固完成"
else
  warn "跳过安全加固（--skip-harden）—— 25 端口可能对公网开放"
fi

# ── 创建管理员 ──────────────────────────────────────────────
step "创建管理员账号"

docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'pasarguard-postgresql-1' \
  || die "找不到数据库容器，安装可能失败了"

pq() { docker exec -i pasarguard-postgresql-1 psql -U pasarguard -d pasarguard "$@"; }

EXISTING="$(pq -t -A -c "SELECT count(*) FROM admins;" 2>/dev/null | tr -d '[:space:]')"
EXISTING="${EXISTING:-0}"

if [[ "$EXISTING" != "0" ]]; then
  ok "已存在 ${EXISTING} 个管理员，跳过创建"
  ADMIN_PASS="（沿用已有账号密码）"
else
  # 官方脚本不建管理员 —— 装完 admins 表是空的，Web 面板根本登不进去。
  # 这是本脚本相对官方最主要的功能补齐之一。
  [[ -n "$ADMIN_PASS" ]] || ADMIN_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 18)"

  HASH="$(docker exec pasarguard-pasarguard-1 python3 -c "
import bcrypt, sys
print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(rounds=12)).decode())
" "$ADMIN_PASS" 2>/dev/null | tr -d '\r\n')"

  [[ -n "$HASH" ]] || die "生成密码哈希失败，无法创建管理员"

  ROLE_ID="$(pq -t -A -c "SELECT id FROM admin_roles WHERE is_owner LIMIT 1;" 2>/dev/null | tr -d '[:space:]')"
  ROLE_ID="${ROLE_ID:-1}"

  pq -v ON_ERROR_STOP=1 <<SQL >/dev/null
INSERT INTO admins (username, hashed_password, created_at, role_id, status)
VALUES ('${ADMIN_USER}', '${HASH}', NOW(), ${ROLE_ID}, 'active');
SQL
  ok "管理员已创建：${ADMIN_USER}（owner 角色）"
fi

# ── nginx 反代 ──────────────────────────────────────────────
if (( SKIP_NGINX == 0 )); then
  step "配置 nginx HTTPS 反代"

  command -v nginx >/dev/null 2>&1 || apt-get install -y -qq nginx >/dev/null 2>&1
  command -v nginx >/dev/null 2>&1 || die "nginx 安装失败"
  ok "nginx 已就绪"

  mkdir -p /etc/nginx/ssl

  if [[ -n "$DOMAIN" ]]; then
    # Let's Encrypt（需要域名已解析到本机 + 80 端口可达）
    info "尝试为 ${DOMAIN} 申请 Let's Encrypt 证书……"
    if command -v certbot >/dev/null 2>&1 || apt-get install -y -qq certbot >/dev/null 2>&1; then
      if certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos \
           --register-unsafely-without-email --http-01-port 80 >/dev/null 2>&1; then
        CRT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
        ok "证书申请成功"
      else
        warn "Let's Encrypt 申请失败（域名未解析 / 80 端口不通），改用自签"
        DOMAIN=""
      fi
    fi
  fi

  if [[ -z "$DOMAIN" ]]; then
    # 自签 IP 证书 —— SAN 必须含 127.0.0.1，否则本机校验会失败
    openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
      -keyout /etc/nginx/ssl/panel.key -out /etc/nginx/ssl/panel.crt \
      -subj "/CN=${PUBIP}" \
      -addext "subjectAltName=IP:${PUBIP},IP:127.0.0.1,DNS:localhost" \
      -addext "extendedKeyUsage=serverAuth" 2>/dev/null
    chmod 600 /etc/nginx/ssl/panel.key
    CRT="/etc/nginx/ssl/panel.crt"
    KEY="/etc/nginx/ssl/panel.key"
    ok "已生成自签证书（SAN：${PUBIP} + 127.0.0.1）"
  fi

  cat > /etc/nginx/sites-available/pasarguard <<NGINX
server {
    listen ${PANEL_PORT} ssl;
    server_name ${DOMAIN:-$PUBIP};

    ssl_certificate     ${CRT};
    ssl_certificate_key ${KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    client_max_body_size 50m;

    # 不要加 location /sub/ —— 面板自己的订阅路由就是 /sub/<token>，
    # 覆盖它会把所有订阅打成 404。
    location / {
        proxy_pass http://127.0.0.1:${INTERNAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }

    location = /docs         { return 404; }
    location = /redoc        { return 404; }
    location = /openapi.json { return 404; }
}

server {
    listen 80 default_server;
    server_name _;
    access_log off;
    return 444;
}
NGINX

  ln -sfn /etc/nginx/sites-available/pasarguard /etc/nginx/sites-enabled/pasarguard
  rm -f /etc/nginx/sites-enabled/default
  nginx -t >/dev/null 2>&1 || die "nginx 配置校验失败"
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx 2>/dev/null || systemctl restart nginx

  # 面板启动比 nginx reload 慢几秒，直接判会误报 502。轮询等。
  CODE=000
  for i in $(seq 1 20); do
    CODE="$(curl -sk -o /dev/null -m 5 -w '%{http_code}' "https://127.0.0.1:${PANEL_PORT}/dashboard/" 2>/dev/null || echo 000)"
    [[ "$CODE" == "200" ]] && break
    sleep 3
  done
  if [[ "$CODE" == "200" ]]; then
    ok "HTTPS 反代正常：https://${PUBIP}:${PANEL_PORT}/dashboard/ (200)"
  else
    warn "反代返回 ${CODE}"
    info "若为 502：后端未就绪，稍等再试，或看 (cd ${PANEL_DIR} && docker compose logs --tail 30)"
    info "若为 000：nginx 没起，看 systemctl status nginx"
  fi
else
  warn "跳过 nginx（--skip-nginx）—— 面板只能通过 SSH 隧道访问"
fi

# ── 节点（可选，交互式问）── ─────────────────────────────────
if (( ASSUME_YES == 0 )); then
  step "是否同时安装节点"
  echo
  echo "  节点 = 真正承载流量的 Xray 进程。面板装好但没节点的话，"
  echo "  用户连不上任何东西。"
  echo
  echo "  装在同一台机器：省一台服务器，但面板和节点共用带宽。"
  echo "  装在另一台机器：推荐生产用法，需要你有第二台 VPS。"
  echo
  read -rp "  现在装节点到本机？[y/N] " a
  if [[ "$a" =~ ^[Yy]$ ]]; then
    INSTALL_NODE=1
  else
    INSTALL_NODE=0
  fi
else
  INSTALL_NODE=1
fi

if (( INSTALL_NODE == 1 )); then
  step "安装节点"
# 面板连接节点用的是 SERVICE_PORT（gRPC），不是 API_PORT。
# 官方 systemd 版默认 62050，docker 版默认 62051 —— 从实际 .env 读，别写死。
NODE_SVC_PORT=62050
if [[ -f /opt/pg-node/.env ]]; then
  _p="$(grep -E '^SERVICE_PORT' /opt/pg-node/.env 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' "')"
  [[ -n "$_p" ]] && NODE_SVC_PORT="$_p"
fi

  if [[ -f /opt/pg-node/docker-compose.yml ]] && (( REINSTALL == 0 )); then
    # 重装节点会重新生成证书和 API Key —— 面板里已经登记的那份就对不上了，
    # 节点会一直 error。所以已装就跳过。
    ok "节点已安装，跳过（重装用 --reinstall）"
  else
    OFFICIAL_NODE="/opt/pg-cn/pg-node-official.sh"
    curl -fsSL --connect-timeout 10 \
      "https://raw.githubusercontent.com/PasarGuard/scripts/main/pg-node.sh" -o "$OFFICIAL_NODE" \
      || die "下载节点脚本失败"
    chmod +x "$OFFICIAL_NODE"

    # 节点脚本支持完整非交互参数
    bash "$OFFICIAL_NODE" install -y --self-signed \
         --service-port 62050 --api-port 62051 2>&1 | sed 's/^/    /' || \
      warn "节点安装返回非零，检查：pg-node status"
  fi

  if (( USE_CN_GEOFILES == 1 )); then
    info "下载中国分流规则……"
    bash "$OFFICIAL_NODE" geofiles --china 2>&1 | sed 's/^/    /' || \
      warn "分流规则下载失败（不影响基本功能）"
  fi

  ok "节点安装完成"
  info "接下来在面板里「添加节点」，地址填 127.0.0.1，端口填 ${NODE_SVC_PORT}"
fi

# ── 端到端自检（--selftest）─────────────────────────────────
if (( SELFTEST == 1 )); then
  step "端到端自检"

  TEMP_USER="pgcn_selftest_$$"
  CLEANUP_UID=""

  pypanel() { docker exec -i pasarguard-pasarguard-1 python3 "$@"; }

  # 建临时用户（等价于面板 UI 的「添加用户」）
  # set -e 下命令替换里任何非零都会直接退出脚本，而这段 SQL 在
  # 不同版本上可能失败（不该因此中断整个安装），所以临时关掉。
  #
  # 写法说明：不要用 COALESCE((SELECT ...), (INSERT ... RETURNING ...)) ——
  # Postgres 不允许在表达式里嵌 INSERT。改成顺序语句 + psql 变量插值。
  set +e
  SQLOUT="$(pq -t -A -q -v uname="$TEMP_USER" <<'SQL' 2>&1
INSERT INTO groups (name) SELECT 'Main'
  WHERE NOT EXISTS (SELECT 1 FROM groups);

INSERT INTO users (username, status, used_traffic, data_limit, expire,
                   data_limit_reset_strategy, note, created_at, proxy_settings, admin_id)
VALUES (:'uname', 'active', 0, 1073741824, NOW() + INTERVAL '1 day',
        'no_reset', 'selftest', NOW(),
        jsonb_build_object('vless', jsonb_build_object('id', gen_random_uuid()::text, 'flow','')),
        1);

INSERT INTO users_groups_association (user_id, groups_id)
SELECT u.id, (SELECT min(id) FROM groups) FROM users u WHERE u.username = :'uname';

SELECT id FROM users WHERE username = :'uname';
SQL
)"
  set -e

  CLEANUP_UID="$(printf '%s' "$SQLOUT" | tr -dc '0-9')"

  if [[ -z "$CLEANUP_UID" ]]; then
    warn "临时用户创建失败"
    info "SQL 输出：$(printf '%s' "$SQLOUT" | tail -3 | tr '\n' ' ')"
    info "这不影响安装本身，只是跳过端到端验证。"
  fi

  if [[ -z "$CLEANUP_UID" ]]; then
    warn "临时用户创建失败（可忽略，多为 SQL 版本差异）"
  else
    ok "临时用户已建（id=${CLEANUP_UID}）"

    TOKEN="$(pypanel -c "
import asyncio, sys
sys.path.insert(0, '/code')
from app.utils.jwt import create_subscription_token
async def m():
    print(await create_subscription_token(${CLEANUP_UID}))
asyncio.run(m())
" 2>/dev/null | tr -d '\r\n')"

    if [[ -z "$TOKEN" ]]; then
      warn "无法生成订阅 token"
    else
      ok "订阅 token 已生成"

      BODY="$(curl -sk -m 10 -o /tmp/pgcn_selftest.bin -w '%{http_code}' \
              "http://127.0.0.1:${INTERNAL_PORT}/sub/${TOKEN}" 2>/dev/null || echo 000)"
      if [[ "$BODY" == "200" ]]; then
        ok "订阅接口返回 200"
        DECODED="$(base64 -d /tmp/pgcn_selftest.bin 2>/dev/null || cat /tmp/pgcn_selftest.bin 2>/dev/null)"
        if [[ "$DECODED" == *"vless://"* ]]; then
          ok "订阅内容含 vless:// 节点（端到端打通）"
          info "样例：$(echo "$DECODED" | head -1 | cut -c1-90)…"
        else
          # 分两种情况说清楚，否则用户不知道卡在哪一步
          NODES="$(pq -t -A -c "SELECT count(*) FROM nodes;" 2>/dev/null | tr -dc '0-9')"
          HOSTS="$(pq -t -A -c "SELECT count(*) FROM hosts;" 2>/dev/null | tr -dc '0-9')"
          if [[ "${NODES:-0}" == "0" ]]; then
            warn "订阅内容为空 —— 面板里还没有节点"
            info "下一步：面板 → 节点管理 → 添加节点"
            info "  地址 127.0.0.1，端口 ${NODE_SVC_PORT}，API Key 和证书见节点安装时的输出"
          elif [[ "${HOSTS:-0}" == "0" ]]; then
            warn "节点已登记（${NODES} 个），但还没有「主机」配置"
            info "订阅内容由 hosts 表生成，添加节点时面板会自动创建。"
            info "请到面板「节点管理」里点「添加节点」走一遍，会自动生成入站和主机。"
          else
            warn "订阅内容为空（节点 ${NODES} 个，主机 ${HOSTS} 条）"
            info "检查主机是否被禁用，或用户所在分组是否被主机覆盖。"
          fi
        fi
      else
        warn "订阅接口返回 ${BODY}（期望 200）"
        [[ "$BODY" == "404" ]] && info "404 多半是 nginx 里加了 location /sub/ 把面板路由劫持了"
      fi
      rm -f /tmp/pgcn_selftest.bin
    fi

    # 清理
    pq -c "DELETE FROM users_groups_association WHERE user_id = ${CLEANUP_UID};" >/dev/null 2>&1
    pq -c "DELETE FROM users WHERE id = ${CLEANUP_UID};" >/dev/null 2>&1
    ok "临时用户已清理"
  fi
fi

# ── 验收 ────────────────────────────────────────────────────
step "验收"

PASS=0; FAILN=0
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; PASS=$((PASS+1)); else warn "$1"; FAILN=$((FAILN+1)); fi; }

chk "面板本地响应 200"       "[[ \$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:${INTERNAL_PORT}/) == 200 ]]"
chk "管理员账号存在"          "[[ \$(pq -t -A -c 'SELECT count(*) FROM admins;' | tr -d ' ') -gt 0 ]]"
chk "25 端口无公网监听"       "! ss -tln | grep -q '0.0.0.0:25 '"
chk "pgadmin 未运行"          "! docker ps --format '{{.Names}}' | grep -qx pgadmin"

if (( SKIP_NGINX == 0 )); then
  chk "HTTPS 反代返回 200"    "[[ \$(curl -sk -o /dev/null -m 5 -w '%{http_code}' https://127.0.0.1:${PANEL_PORT}/dashboard/) == 200 ]]"
  chk "/docs 已封"            "[[ \$(curl -sk -o /dev/null -m 5 -w '%{http_code}' https://127.0.0.1:${PANEL_PORT}/docs) == 404 ]]"
fi

echo
if (( FAILN == 0 )); then
  printf '  %s全部 %d 项通过%s\n' "$G$BOLD" "$PASS" "$N"
else
  printf '  %s通过 %d 项，未通过 %d 项%s\n' "$Y$BOLD" "$PASS" "$FAILN" "$N"
fi

# ── 凭据卡片 ────────────────────────────────────────────────
step "安装完成"


if (( SKIP_NGINX == 0 )); then
  PANEL_URL="https://${PUBIP}:${PANEL_PORT}/dashboard/"
else
  PANEL_URL="http://127.0.0.1:${INTERNAL_PORT}/dashboard/（需 SSH 隧道）"
fi

cat <<EOF

  ┌────────────────────────────────────────────────────────┐
  │  面板地址   ${PANEL_URL}
  │  用户名     ${ADMIN_USER}
  │  密码       ${ADMIN_PASS}
  ├────────────────────────────────────────────────────────┤
  │  配置文件   ${PANEL_DIR}/.env  （权限 600）
  │  管理命令   sudo pasarguard status
  └────────────────────────────────────────────────────────┘

  上面这组密码只在这里显示一次。现在就去存好。

EOF

cat <<EOF
  重新验收：sudo bash pg-cn.sh --selftest -y --skip-mirror
  手动加固：sudo /usr/local/bin/pg-cn-harden --verbose

EOF

cat <<EOF
  接下来三步：
    1. 在云厂商防火墙放行 TCP ${PANEL_PORT}（如果还没放）
    2. 浏览器打开面板，用上面的账号登录
    3. 左侧「节点管理」→ 添加节点 → 地址填 127.0.0.1，端口填 ${NODE_SVC_PORT}
       （${NODE_SVC_PORT} 是节点的 gRPC 端口，不是 62051 —— 62051 只给 pg-node 命令行用）

  浏览器会报证书不受信任 —— 自签证书的正常现象，
  点「高级」→「继续前往」即可。

EOF

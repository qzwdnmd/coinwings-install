#!/usr/bin/env bash
#
# Coinwings 策略后端 · 一键安装 / 管理脚本
#
#   安装：  curl -fsSL https://raw.githubusercontent.com/qzwdnmd/coinwings-install/refs/heads/main/install.sh | sudo bash -
#   管理：  coinwings <status|logs|upgrade|restart|token|uninstall|autoupdate>
#
# 单文件自包含：安装时把自身复制为 /usr/local/bin/coinwings，后续即管理 CLI。
# 不含任何源码——只 docker pull 私有镜像（镜像内仅 dist，无 src），从根上防代码泄漏。
#
set -euo pipefail

# ─────────────────────────── 可注入常量（发布时替换占位） ───────────────────────────
REGISTRY="${COINWINGS_REGISTRY:-ghcr.io}"
IMAGE_REPO="${COINWINGS_IMAGE_REPO:-ghcr.io/qzwdnmd/spread-engine}"
IMAGE_TAG="${COINWINGS_IMAGE_TAG:-latest}"
# 本脚本的托管地址：管道安装（curl | bash）无本地文件时，据此重新下载安装为管理 CLI。
SELF_URL="${COINWINGS_INSTALL_URL:-https://raw.githubusercontent.com/qzwdnmd/coinwings-install/refs/heads/main/install.sh}"
# 只读 pull 凭据：私有镜像时把下面两行占位替换为真实只读 token（仅能 pull，不能 push）。
# 注意：本脚本若托管在 公开 GitHub 仓库（raw.githubusercontent.com），切勿在此内嵌真实 token——
#       请改为 GHCR 镜像包设 public 走匿名拉取（防泄漏仍由「镜像内无源码」兜底）。
PULL_USER="__PULL_USER__"
PULL_TOKEN="__PULL_TOKEN__"

# 固定传输加密常量（与公共前端构建一致，勿改）
TRANSPORT_AES_KEY_B64="QHGLU9cv9KAmP0t2dN/rRtXP2k9M9qVKkPRkVNuS9II="
TRANSPORT_AES_IV_B64="E52sZZzZs7U+U3SCXlNzag=="

# 路径
CONFIG_DIR="/etc/coinwings-spread"
DATA_DIR="/var/lib/coinwings-spread"
ENV_FILE="${CONFIG_DIR}/.env"
COMPOSE_FILE="${CONFIG_DIR}/docker-compose.yml"
SYSTEMD_DIR="/etc/systemd/system"
SELF_BIN="/usr/local/bin/coinwings"
PORT_DEFAULT="12345"

# ─────────────────────────── 输出辅助 ───────────────────────────
c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyn=$'\033[36m'; c_bold=$'\033[1m'
log()  { printf '%s\n' "${c_cyn}▸${c_reset} $*"; }
ok()   { printf '%s\n' "${c_grn}✓${c_reset} $*"; }
warn() { printf '%s\n' "${c_ylw}!${c_reset} $*"; }
die()  { printf '%s\n' "${c_red}✗ $*${c_reset}" >&2; exit 1; }

# ─────────────────────────── 基础检查 ───────────────────────────
require_root() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行：sudo bash 或 sudo coinwings ..."
}

detect_arch() {
  local m; m="$(uname -m)"
  case "$m" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "不支持的 CPU 架构：$m（仅支持 x86_64 / arm64）" ;;
  esac
  ok "架构：$m → $ARCH"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    ok "Docker 已安装：$(docker --version | awk '{print $3}' | tr -d ',')"
  else
    log "未检测到 Docker，正在安装（官方脚本）…"
    curl -fsSL https://get.docker.com | sh || die "Docker 安装失败"
    ok "Docker 安装完成"
  fi
  # compose v2 插件
  docker compose version >/dev/null 2>&1 || die "缺少 docker compose v2 插件，请升级 Docker"
  systemctl enable --now docker >/dev/null 2>&1 || true
}

registry_login() {
  if [ "$PULL_TOKEN" = "__PULL_TOKEN__" ]; then
    warn "未注入私有镜像凭据（开发模式）。若 pull 失败请先 docker login ${REGISTRY}"
    return 0
  fi
  log "登录私有镜像仓库 ${REGISTRY} …"
  echo "$PULL_TOKEN" | docker login "$REGISTRY" -u "$PULL_USER" --password-stdin >/dev/null \
    || die "镜像仓库登录失败"
  ok "镜像仓库登录成功"
}

public_ip() {
  local ip
  ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "${ip:-<服务器IP>}"
}

# ─────────────────────────── 配置生成（幂等） ───────────────────────────
gen_secret() { openssl rand -hex 32; }

write_compose() {
  cat > "$COMPOSE_FILE" <<'YAML'
name: coinwings
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${DATABASE_NAME:-spread}
      POSTGRES_USER: ${DATABASE_USER:-postgres}
      POSTGRES_PASSWORD: ${DATABASE_PASSWORD:?DATABASE_PASSWORD required in .env}
    volumes:
      - /var/lib/coinwings-spread/pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${DATABASE_USER:-postgres} -d $${DATABASE_NAME:-spread}"]
      interval: 5s
      timeout: 3s
      retries: 12
  spread-engine:
    image: ${COINWINGS_IMAGE:?COINWINGS_IMAGE required in .env}
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    env_file:
      - /etc/coinwings-spread/.env
    environment:
      DATABASE_HOST: postgres
    ports:
      - "${PORT:-12345}:12345"
YAML
  ok "写入 ${COMPOSE_FILE}"
}

write_env_if_absent() {
  if [ -f "$ENV_FILE" ]; then
    warn "${ENV_FILE} 已存在，保留现有密钥（不覆盖）"
    # 仅刷新镜像 tag，确保升级生效
    if grep -q '^COINWINGS_IMAGE=' "$ENV_FILE"; then
      sed -i "s|^COINWINGS_IMAGE=.*|COINWINGS_IMAGE=${IMAGE_REPO}:${IMAGE_TAG}|" "$ENV_FILE"
    else
      echo "COINWINGS_IMAGE=${IMAGE_REPO}:${IMAGE_TAG}" >> "$ENV_FILE"
    fi
    return 0
  fi

  log "生成全新配置与随机密钥 …"
  GEN_DB_PASS="$(gen_secret)"
  GEN_ENC_KEY="$(gen_secret)"          # 64 hex = 32 字节，AES-256-GCM 主密钥
  GEN_CONSOLE_TOKEN="$(gen_secret)"    # 控制台访问令牌（Bearer）

  umask 077
  cat > "$ENV_FILE" <<ENV
# Coinwings 后端配置 —— 由 install.sh 生成于安装时。请妥善备份本文件！
# ENCRYPTION_KEY 一旦改变，已加密保存的交易所 API Key 将无法解密，切勿修改。

COINWINGS_IMAGE=${IMAGE_REPO}:${IMAGE_TAG}

# ── 必填（自动生成）──
DATABASE_PASSWORD=${GEN_DB_PASS}
ENCRYPTION_KEY=${GEN_ENC_KEY}
CONSOLE_TOKEN=${GEN_CONSOLE_TOKEN}

# ── 传输加密（固定常量，勿改）──
TRANSPORT_AES_KEY_B64=${TRANSPORT_AES_KEY_B64}
TRANSPORT_AES_IV_B64=${TRANSPORT_AES_IV_B64}

# ── 服务 ──
PORT=${PORT_DEFAULT}
NODE_ENV=production
LOG_LEVEL=info
ALLOWED_ORIGINS=*

# ── 数据库（host 由 compose 注入为 postgres）──
DATABASE_NAME=spread
DATABASE_USER=postgres
DATABASE_PORT=5432

# ── 交易所模式 ──
EXCHANGE_DEMO=false

# ── 代理（境外交易所需要时填；仅 REST 走代理，WS 一律裸连）──
HTTPS_PROXY=
HTTP_PROXY=
ENV
  chmod 600 "$ENV_FILE"
  ok "写入 ${ENV_FILE}（权限 600）"
}

write_systemd() {
  cat > "${SYSTEMD_DIR}/coinwings.service" <<'UNIT'
[Unit]
Description=Coinwings Spread Strategy (docker compose)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/etc/coinwings-spread
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose up -d --remove-orphans
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT

  # 自动更新 unit（默认不启用，coinwings autoupdate on 才开）
  cat > "${SYSTEMD_DIR}/coinwings-update.service" <<'UNIT'
[Unit]
Description=Coinwings auto-update (pull latest image & restart)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/coinwings upgrade
UNIT

  cat > "${SYSTEMD_DIR}/coinwings-update.timer" <<'UNIT'
[Unit]
Description=Coinwings daily auto-update

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  ok "写入 systemd unit（coinwings.service / coinwings-update.{service,timer}）"
}

install_self_cli() {
  # 把自身安装为管理 CLI。来源依次尝试：
  #   1) 本地脚本文件（bash install.sh 方式，BASH_SOURCE 是真实文件）
  #   2) 从托管地址重新下载（curl | bash 管道方式，无本地文件——这是文档主推方式）
  local src=""
  if [ -f "${BASH_SOURCE[0]:-}" ]; then src="${BASH_SOURCE[0]}"; fi
  if [ -n "$src" ] && [ -f "$src" ]; then
    cp "$src" "$SELF_BIN"
  else
    log "管道安装无本地脚本，从 ${SELF_URL} 下载管理 CLI …"
    curl -fsSL "$SELF_URL" -o "$SELF_BIN" 2>/dev/null || true
  fi
  # 仅在文件确实写入后才 chmod，避免管道下载失败时 chmod 报错触发 set -e 中断整个安装
  if [ -s "$SELF_BIN" ]; then
    chmod 755 "$SELF_BIN"
    ok "安装管理命令：coinwings"
  else
    warn "未能安装 coinwings CLI（不影响服务运行）。可手动：curl -fsSL ${SELF_URL} -o ${SELF_BIN} && chmod 755 ${SELF_BIN}"
  fi
}

# ─────────────────────────── 动作 ───────────────────────────
compose() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

wait_healthy() {
  log "等待服务就绪 …"
  local port; port="$(grep -E '^PORT=' "$ENV_FILE" | cut -d= -f2)"; port="${port:-$PORT_DEFAULT}"
  for _ in $(seq 1 30); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1 \
       || curl -fsS --max-time 2 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
      ok "服务已响应（:${port}）"; return 0
    fi
    sleep 2
  done
  warn "健康检查超时，请稍后用 'coinwings logs' 查看启动日志"
}

print_panel() {
  local ip port token
  ip="$(public_ip)"
  port="$(grep -E '^PORT=' "$ENV_FILE" | cut -d= -f2)"; port="${port:-$PORT_DEFAULT}"
  token="$(grep -E '^CONSOLE_TOKEN=' "$ENV_FILE" | cut -d= -f2)"
  printf '\n'
  printf '%s\n' "${c_grn}${c_bold}╔══════════════════════════════════════════════════════════╗${c_reset}"
  printf '%s\n' "${c_grn}${c_bold}║              Coinwings 部署完成 🎉                        ║${c_reset}"
  printf '%s\n' "${c_grn}${c_bold}╚══════════════════════════════════════════════════════════╝${c_reset}"
  printf '\n'
  printf '  %s  http://%s:%s\n'      "${c_bold}访问地址${c_reset}" "$ip" "$port"
  printf '  %s  %s\n'                "${c_bold}访问令牌${c_reset}" "$token"
  printf '  %s  %s\n'                "${c_bold}配置文件${c_reset}" "$ENV_FILE"
  printf '  %s  %s\n'                "${c_bold}数据目录${c_reset}" "${DATA_DIR}/pgdata"
  printf '\n'
  warn "请立即备份 ${ENV_FILE}（含 ENCRYPTION_KEY，丢失将无法解密已保存的交易所 Key）"
  printf '  常用命令： coinwings status | logs | upgrade | restart | token | uninstall\n\n'
}

do_install() {
  require_root
  log "开始安装 Coinwings 策略后端 …"
  detect_arch
  ensure_docker
  registry_login
  mkdir -p "$CONFIG_DIR" "${DATA_DIR}/pgdata"
  write_compose
  write_env_if_absent
  write_systemd
  install_self_cli
  log "拉取镜像并启动 …"
  systemctl enable coinwings.service >/dev/null 2>&1 || true
  compose pull
  systemctl restart coinwings.service
  wait_healthy
  print_panel
}

do_upgrade() {
  require_root
  log "升级到最新镜像 …"
  registry_login
  compose pull
  systemctl restart coinwings.service
  wait_healthy
  ok "升级完成（数据库迁移已在容器启动时自动执行）"
}

do_status() {
  require_root
  systemctl --no-pager status coinwings.service || true
  printf '\n'
  compose ps
}

do_logs()    { require_root; compose logs -f --tail="${1:-200}" spread-engine; }
do_restart() { require_root; systemctl restart coinwings.service; ok "已重启"; }
do_token()   { require_root; grep -E '^CONSOLE_TOKEN=' "$ENV_FILE" | cut -d= -f2; }

do_autoupdate() {
  require_root
  case "${1:-}" in
    on)  systemctl enable --now coinwings-update.timer; ok "自动更新已开启（每日 04:30±30m）" ;;
    off) systemctl disable --now coinwings-update.timer 2>/dev/null || true; ok "自动更新已关闭" ;;
    *)   die "用法：coinwings autoupdate <on|off>" ;;
  esac
}

do_uninstall() {
  require_root
  warn "即将卸载 Coinwings。"
  read -r -p "是否同时删除数据库数据（${DATA_DIR}）？输入 yes 删除，回车保留：" ans || true
  systemctl disable --now coinwings.service 2>/dev/null || true
  systemctl disable --now coinwings-update.timer 2>/dev/null || true
  [ -f "$COMPOSE_FILE" ] && compose down 2>/dev/null || true
  rm -f "${SYSTEMD_DIR}/coinwings.service" \
        "${SYSTEMD_DIR}/coinwings-update.service" \
        "${SYSTEMD_DIR}/coinwings-update.timer"
  systemctl daemon-reload
  if [ "${ans:-}" = "yes" ]; then
    rm -rf "$DATA_DIR" "$CONFIG_DIR"
    ok "已删除数据与配置"
  else
    rm -f "$COMPOSE_FILE"
    warn "已保留 ${CONFIG_DIR}（含 .env）与 ${DATA_DIR}（数据库）。如需彻底清除请手动删除。"
  fi
  rm -f "$SELF_BIN"
  ok "卸载完成"
}

usage() {
  cat <<TXT
Coinwings 管理命令

  coinwings status            查看服务状态
  coinwings logs [N]          跟踪日志（默认末尾 200 行）
  coinwings upgrade           拉取最新镜像并重启（自动迁移）
  coinwings restart           重启服务
  coinwings token             打印访问令牌
  coinwings autoupdate on|off 开关每日自动更新
  coinwings uninstall         卸载（可选删数据）
TXT
}

# ─────────────────────────── 入口 ───────────────────────────
main() {
  case "${1:-install}" in
    install|"")  do_install ;;
    upgrade)     do_upgrade ;;
    status)      do_status ;;
    logs)        shift; do_logs "${1:-200}" ;;
    restart)     do_restart ;;
    token)       do_token ;;
    autoupdate)  shift; do_autoupdate "${1:-}" ;;
    uninstall)   do_uninstall ;;
    -h|--help|help) usage ;;
    *) die "未知命令：$1（运行 coinwings --help）" ;;
  esac
}
main "$@"

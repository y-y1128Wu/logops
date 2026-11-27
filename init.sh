#!/usr/bin/env bash
# =============================================================================
# init.sh —— logops 初始化（M1）
#
#   1) 依赖检查：bash / docker（含 compose v2）/ awk / sed / grep
#   2) 目录创建：data/logs  out  conf（幂等，已存在不报错）
#   3) 配置生成：.env.example -> .env，首次生成时写入随机 db 密码
#   4) 幂等保护：已存在的 .env 不覆盖；只有 --force 才重建且先备份
#
# 路径/变量名/退出码遵循《表1 接口冻结值》，改动前先发接口变更。
# 退出码：0 成功 | 1 依赖缺失或运行失败 | 2 参数错误
# =============================================================================
set -euo pipefail

SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME SCRIPT_DIR

# ---- 接口冻结值（表1）：目录、模板、变量清单 ----
readonly ENV_FILE=".env"
readonly ENV_TEMPLATE=".env.example"
readonly LOG_DIR="data/logs"
readonly OUT_DIR="out"
readonly CONF_DIR="conf"
readonly ACCESS_LOG="${LOG_DIR}/access.log"
readonly REQUIRED_CMDS=(bash docker awk sed grep)
readonly REQUIRED_KEYS=(WEB_PORT LOG_FILE SAMPLE_LOG OUT_DIR TOP_N \
  DISK_THRESHOLD MEM_THRESHOLD ALERT_LOG)

FORCE=0
QUIET=0

usage() {
  cat <<EOF
用法: ./${SCRIPT_NAME} [选项]

初始化 logops 运行环境：检查依赖、创建目录、由 .env.example 生成 .env。

选项:
  -h, --help    显示本帮助并退出
  -f, --force   重建 .env（旧文件备份为 .env.bak.<时间戳>）
  -q, --quiet   精简输出：只打印致命错误（适合 cron / CI 调用）

说明:
  * 不带参数执行是幂等操作：已存在的 .env 不会被覆盖，可反复执行。
  * 目录: ${LOG_DIR}  ${OUT_DIR}  ${CONF_DIR}
  * 配置: ${ENV_TEMPLATE} -> ${ENV_FILE}（权限 600）
  * 依赖: bash docker(compose v2) awk sed grep

退出码: 0 成功 | 1 依赖缺失或运行失败 | 2 参数错误
EOF
}

# 时间戳先取到变量，避免命令替换的退出码被 printf 掩盖
ts() {
  date +%T
}

log() {
  local now
  now="$(ts)"
  if (( QUIET == 0 )); then
    printf '[%s] %s\n' "$now" "$*"
  fi
}

warn() {
  if (( QUIET == 0 )); then
    local now
    now="$(ts)"
    printf '[%s] 警告: %s\n' "$now" "$*" >&2
  fi
}

die() {
  local now
  now="$(ts)"
  printf '[%s] 错误: %s\n' "$now" "$*" >&2
  exit 1
}

# 参数错误统一出口：打印原因与用法，退出码 2
err() {
  local now
  now="$(ts)"
  printf '[%s] 参数错误: %s\n\n' "$now" "$*" >&2
  usage >&2
}

# 逐条检查外部依赖；缺一个就明确报出名字并 exit 1（验收项 3）
need() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "缺少依赖: ${cmd}，请先安装后重试（Ubuntu: sudo apt-get install -y ${cmd}）"
  fi
}

check_deps() {
  local cmd
  for cmd in "${REQUIRED_CMDS[@]}"; do
    need "$cmd"
  done
  # compose v2 是 docker 子命令，不能只靠 command -v docker 判断
  if ! docker compose version >/dev/null 2>&1; then
    die "缺少 docker compose v2，请安装 docker-compose-plugin 后重试"
  fi
  log "依赖检查通过"
}

# 生成 32 位十六进制随机串：优先 openssl，退化为 /dev/urandom
gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

ensure_dirs() {
  local dir
  for dir in "$LOG_DIR" "$OUT_DIR" "$CONF_DIR"; do
    if [[ -d $dir ]]; then
      log "目录已存在，跳过: ${dir}/"
    else
      mkdir -p -- "$dir"
      log "创建目录: ${dir}/"
    fi
  done
}

# 校验 .env 是否覆盖全部冻结变量（接口对齐、后续 C/D 都读它）
check_env_keys() {
  local key missing=0
  for key in "${REQUIRED_KEYS[@]}"; do
    if ! grep -qE "^[[:space:]]*${key}=" -- "$ENV_FILE"; then
      warn "${ENV_FILE} 缺少变量 ${key}"
      missing=1
    fi
  done
  if (( missing != 0 )); then
    die "${ENV_FILE} 与接口冻结变量清单不一致，请对照 ${ENV_TEMPLATE} 修正，或用 --force 重建"
  fi
}

make_env() {
  [[ -f $ENV_TEMPLATE ]] || die "缺少模板 ${ENV_TEMPLATE}，无法生成 ${ENV_FILE}"

  cp -- "$ENV_TEMPLATE" "$ENV_FILE"

  # 模板里若有空的 DB_PASSWORD= 占位，则填入随机密码（密码不入库）
  if grep -qE '^DB_PASSWORD=$' -- "$ENV_FILE"; then
    local secret tmp
    secret="$(gen_password)"
    tmp="${ENV_FILE}.tmp"
    # 注意：此处不能写 awk -- "$ENV_FILE"，busybox/mawk 会把 -- 当成文件名
    awk -v p="$secret" '/^DB_PASSWORD=$/ { print "DB_PASSWORD=" p; next } { print }' \
      "$ENV_FILE" >"$tmp"
    mv -f -- "$tmp" "$ENV_FILE"
    log "已生成随机 DB_PASSWORD 写入 ${ENV_FILE}"
  fi

  chmod 600 -- "$ENV_FILE"
  log "${ENV_FILE} 已生成（来源 ${ENV_TEMPLATE}）"
  check_env_keys
}

# 保证脚本可执行：从 Windows/压缩包拷来时常丢执行位
chmod_scripts() {
  local script
  for script in init.sh deploy.sh analyze.sh check.sh; do
    if [[ -f $script ]]; then
      chmod +x -- "$script"
    fi
  done
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -f | --force) FORCE=1 ;;
      -q | --quiet) QUIET=1 ;;
      --)
        shift
        break
        ;;
      -*)
        err "未知选项: $1"
        exit 2
        ;;
      *)
        err "不接受位置参数: $1"
        exit 2
        ;;
    esac
    shift
  done
  if (($# > 0)); then
    err "不接受位置参数: $1"
    exit 2
  fi
}

main() {
  parse_args "$@"

  if ! cd -- "$SCRIPT_DIR" 2>/dev/null; then
    die "无法进入脚本目录: ${SCRIPT_DIR}"
  fi

  log "开始初始化 logops（目录: ${SCRIPT_DIR}）"
  check_deps
  ensure_dirs

  if [[ -f $ENV_FILE ]]; then
    if (( FORCE == 1 )); then
      local backup
      backup="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
      cp -- "$ENV_FILE" "$backup"
      log "已备份旧 ${ENV_FILE} -> ${backup}"
      make_env
    else
      log "${ENV_FILE} 已存在，跳过（保持原配置；如需重建请加 --force）"
      check_env_keys
    fi
  else
    make_env
  fi

  chmod_scripts

  # 样例日志由数据与巡检负责人交付，缺失只警告不阻塞
  if [[ ! -f $ACCESS_LOG ]]; then
    warn "未找到 ${ACCESS_LOG}（由数据与巡检负责人交付；analyze.sh 调试可先用 ${LOG_DIR}/sample_access.log）"
  fi

  log "初始化完成"
  log "  日志目录: ${LOG_DIR}/   输出目录: ${OUT_DIR}/   配置目录: ${CONF_DIR}/"
  log "  环境文件: ${ENV_FILE}（含凭据，按约定不入库，需被 .gitignore 忽略）"
  log "  下一步:   ./deploy.sh --dry-run 预览部署流程，或 ./deploy.sh 正式部署"
}

main "$@"

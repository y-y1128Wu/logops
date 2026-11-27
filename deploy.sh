#!/usr/bin/env bash
# =============================================================================
# deploy.sh —— 一键部署流水线（M5）
#
#   阶段顺序：载入配置 -> 前置检查 -> build -> up -d -> 等待 healthy
#             -> 执行 analyze -> 打印访问地址
#
# 第一周交付范围（骨架）：
#   * 已实现：参数校验、.env 载入与变量校验、前置检查、阶段框架、
#             任一阶段失败立即终止并报出阶段名、--dry-run 干跑演示全流程
#   * 待完善（第 3 周）：与 C 联调 compose/健康检查、失败回滚、端口占用自检
#
# 接口遵循《表1 接口冻结值》：
#   service=web、image=logops-web:1.0、network=logops-net、
#   容器内 8080、宿主 ${WEB_PORT}:8080、healthcheck 127.0.0.1:8080。
# 退出码：0 成功 | 1 依赖缺失或运行失败 | 2 参数错误
# =============================================================================
set -euo pipefail

SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME SCRIPT_DIR

# ---- 接口冻结值（表1）----
readonly ENV_FILE=".env"
readonly COMPOSE_FILE="compose.yml"
readonly SERVICE_NAME="web"
readonly IMAGE_NAME="logops-web:1.0"
readonly NETWORK_NAME="logops-net"
readonly CONTAINER_PORT=8080
readonly ANALYZE_SCRIPT="./analyze.sh"
readonly REQUIRED_KEYS=(WEB_PORT LOG_FILE SAMPLE_LOG OUT_DIR TOP_N \
  DISK_THRESHOLD MEM_THRESHOLD ALERT_LOG)
# compose 命令前缀：--env-file 保证 compose 与脚本读同一份 .env
readonly COMPOSE_CMD=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

# 健康等待参数（第 3 周与 C 联调时可调整）
readonly HEALTH_TIMEOUT=120
readonly HEALTH_INTERVAL=3

DRY_RUN=0
CURRENT_STAGE="启动"

usage() {
  cat <<EOF
用法: ./${SCRIPT_NAME} [选项]

一键部署 logops：build -> up -d -> 等待 healthy -> 执行 analyze -> 打印访问地址。

选项:
  -h, --help     显示本帮助并退出
  -n, --dry-run  干跑：只打印将要执行的命令，不调用 docker（用于演示/评审流程）

说明:
  * 必须先执行 ./init.sh 生成 ${ENV_FILE}；端口、日志路径等全部取自 ${ENV_FILE}。
  * 服务约定: service=${SERVICE_NAME}  image=${IMAGE_NAME}  network=${NETWORK_NAME}
  * 容器内端口 ${CONTAINER_PORT}，宿主映射 \${WEB_PORT}:${CONTAINER_PORT}。
  * 任一阶段失败立即终止，打印失败阶段与排查提示，退出码 1。
  * 完整版（失败回滚、健康检查联调）在第 3 周交付。

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
  printf '[%s] %s\n' "$now" "$*"
}

warn() {
  local now
  now="$(ts)"
  printf '[%s] 警告: %s\n' "$now" "$*" >&2
}

die() {
  local now
  now="$(ts)"
  if [[ -n ${CURRENT_STAGE:-} ]]; then
    printf '[%s] 错误: 阶段「%s」失败: %s\n' "$now" "$CURRENT_STAGE" "$*" >&2
  else
    printf '[%s] 错误: %s\n' "$now" "$*" >&2
  fi
  exit 1
}

# 参数错误统一出口：打印原因与用法，退出码 2
err() {
  local now
  now="$(ts)"
  printf '[%s] 参数错误: %s\n\n' "$now" "$*" >&2
  usage >&2
}

# 失败统一出口：报出阶段 + 排查指引（第 3 周在此接入回滚）
on_error() {
  local rc=$? now
  now="$(ts)"
  printf '[%s] 错误: 阶段「%s」失败（退出码 %s）\n' "$now" "$CURRENT_STAGE" "$rc" >&2
  printf '[%s] 排查: docker compose -f %s logs --tail=50 %s\n' \
    "$now" "$COMPOSE_FILE" "$SERVICE_NAME" >&2
  if (( DRY_RUN == 0 )); then
    printf '[%s] 回滚: 待实现（第 3 周：build 失败清理、up 失败 down 并保留现场）\n' \
      "$now" >&2
  fi
  exit "$rc"
}

# 读取 .env：只接受 KEY=VALUE；忽略注释/空行/非法键，兼容 Windows 换行
load_env() {
  local line key value
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%$'\r'}"
    [[ -z ${line//[[:space:]]/} ]] && continue
    [[ $line == \#* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if ((${#value} >= 2)) && [[ $value == \"*\" || $value == \'*\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    printf -v "$key" '%s' "$value"
    export "${key?}"
  done <"$ENV_FILE"
}

# 变量缺失/为空：接口不一致直接失败（保证 C、D 读到同一套配置）
validate_env() {
  local key missing=0
  for key in "${REQUIRED_KEYS[@]}"; do
    if [[ -z ${!key-} ]]; then
      warn "${ENV_FILE} 缺少变量 ${key}"
      missing=1
    fi
  done
  if (( missing != 0 )); then
    die "${ENV_FILE} 与接口冻结变量清单不一致，请对照 .env.example 修正"
  fi
}

# .env 里没有的键用冻结默认值兜底（dry-run、评审演示用）
apply_defaults() {
  WEB_PORT="${WEB_PORT:-8080}"
  LOG_FILE="${LOG_FILE:-data/logs/access.log}"
  SAMPLE_LOG="${SAMPLE_LOG:-data/logs/sample_access.log}"
  OUT_DIR="${OUT_DIR:-out}"
  TOP_N="${TOP_N:-10}"
  DISK_THRESHOLD="${DISK_THRESHOLD:-80}"
  MEM_THRESHOLD="${MEM_THRESHOLD:-90}"
  ALERT_LOG="${ALERT_LOG:-out/alert.log}"
  export WEB_PORT LOG_FILE SAMPLE_LOG OUT_DIR TOP_N \
    DISK_THRESHOLD MEM_THRESHOLD ALERT_LOG
}

# 文件缺失：dry-run 只警告（此时不碰 docker），真实部署直接失败
require_file() {
  local path="$1" hint="${2:-}"
  if [[ -e $path ]]; then
    return 0
  fi
  if (( DRY_RUN == 1 )); then
    warn "缺少 ${path}${hint}（dry-run 继续；正式部署会在此失败）"
    return 0
  fi
  die "缺少 ${path}${hint}"
}

# 统一执行入口：dry-run 只打印命令，不真正执行
run() {
  if (( DRY_RUN == 1 )); then
    log "[dry-run] $*"
    return 0
  fi
  log "执行: $*"
  "$@"
}

# ----------------------------------------------------------------------------
# 阶段 1：载入并校验配置
# ----------------------------------------------------------------------------
stage_env() {
  CURRENT_STAGE="载入配置"
  if [[ -f $ENV_FILE ]]; then
    load_env
    validate_env
  elif (( DRY_RUN == 1 )); then
    warn "缺少 ${ENV_FILE}，请先执行 ./init.sh（dry-run 用冻结默认值继续）"
  else
    die "缺少 ${ENV_FILE}，请先执行 ./init.sh 生成配置"
  fi
  apply_defaults
  log "配置载入完成: WEB_PORT=${WEB_PORT} LOG_FILE=${LOG_FILE} TOP_N=${TOP_N} OUT_DIR=${OUT_DIR}"
}

# ----------------------------------------------------------------------------
# 阶段 2：前置检查（依赖、文件、目录）
# ----------------------------------------------------------------------------
stage_preflight() {
  CURRENT_STAGE="前置检查"

  command -v docker >/dev/null 2>&1 || die "缺少依赖: docker，请先安装并启动 docker"
  if (( DRY_RUN == 0 )); then
    docker compose version >/dev/null 2>&1 || die "缺少 docker compose v2（docker-compose-plugin）"
    docker info >/dev/null 2>&1 || die "docker 守护进程未运行，请启动 docker 后重试"
  fi

  require_file "$COMPOSE_FILE" "（由容器与镜像负责人交付）"
  require_file "$ANALYZE_SCRIPT" "（由脚本开发 B 交付）"
  require_file "$LOG_FILE" "（由数据与巡检负责人交付；调试可先用 ${SAMPLE_LOG}）"

  if [[ ! -d $OUT_DIR ]]; then
    if (( DRY_RUN == 1 )); then
      warn "输出目录 ${OUT_DIR} 不存在（dry-run 继续；正式部署请先执行 ./init.sh）"
    else
      die "输出目录 ${OUT_DIR} 不存在，请先执行 ./init.sh"
    fi
  elif (( DRY_RUN == 0 )) && [[ ! -w $OUT_DIR ]]; then
    die "输出目录 ${OUT_DIR} 不可写，请检查权限"
  fi
  log "前置检查通过"
}

# ----------------------------------------------------------------------------
# 阶段 3：构建镜像
# ----------------------------------------------------------------------------
stage_build() {
  CURRENT_STAGE="构建镜像"
  log "构建镜像 ${IMAGE_NAME}"
  # TODO(第3周): 构建前确认基础镜像已就绪，避免现场拉取超时
  run "${COMPOSE_CMD[@]}" build
}

# ----------------------------------------------------------------------------
# 阶段 4：后台启动
# ----------------------------------------------------------------------------
stage_up() {
  CURRENT_STAGE="启动容器"
  log "启动服务 ${SERVICE_NAME}（宿主 ${WEB_PORT} -> 容器 ${CONTAINER_PORT}）"
  # TODO(第3周): 启动前检测 ${WEB_PORT} 占用情况，占用时提示改 .env
  run "${COMPOSE_CMD[@]}" up -d
}

# ----------------------------------------------------------------------------
# 阶段 5：等待健康检查通过
# ----------------------------------------------------------------------------
stage_wait_healthy() {
  CURRENT_STAGE="等待健康检查"

  if (( DRY_RUN == 1 )); then
    log "[dry-run] 轮询 compose ps --format '{{.Health}}' ${SERVICE_NAME}，最长 ${HEALTH_TIMEOUT}s"
    return 0
  fi

  local waited=0 status="未知"
  log "等待 ${SERVICE_NAME} 进入 healthy（最长 ${HEALTH_TIMEOUT}s，每 ${HEALTH_INTERVAL}s 轮询）"
  while (( waited < HEALTH_TIMEOUT )); do
    # 容器可能还没创建，ps 失败是预期路径，因此忽略返回码（不让 set -e 中断轮询）
    # shellcheck disable=SC2310
    status="$("${COMPOSE_CMD[@]}" ps --format '{{.Health}}' "$SERVICE_NAME" 2>/dev/null || true)"
    if [[ $status == "healthy" ]]; then
      log "${SERVICE_NAME} 已 healthy（耗时 ${waited}s）"
      return 0
    fi
    sleep "$HEALTH_INTERVAL"
    waited=$((waited + HEALTH_INTERVAL))
  done

  # TODO(第3周): 超时后收集容器日志与 healthcheck 输出，便于定位
  die "${SERVICE_NAME} 在 ${HEALTH_TIMEOUT}s 内未进入 healthy（最后状态: ${status}）"
}

# ----------------------------------------------------------------------------
# 阶段 6：调用 analyze.sh 出报告
# ----------------------------------------------------------------------------
stage_analyze() {
  CURRENT_STAGE="生成报告"
  log "执行日志分析: ${ANALYZE_SCRIPT} --log ${LOG_FILE} --top ${TOP_N} --out ${OUT_DIR}"
  if (( DRY_RUN == 0 )) && [[ ! -x $ANALYZE_SCRIPT ]]; then
    die "${ANALYZE_SCRIPT} 不存在或不可执行，请检查 git 执行位（chmod +x ${ANALYZE_SCRIPT}）"
  fi
  run "$ANALYZE_SCRIPT" --log "$LOG_FILE" --top "$TOP_N" --out "$OUT_DIR"
}

# ----------------------------------------------------------------------------
# 阶段 7：打印访问地址
# ----------------------------------------------------------------------------
stage_report() {
  CURRENT_STAGE="打印访问地址"
  local base="http://127.0.0.1:${WEB_PORT}"

  log "部署完成，服务已就绪"
  log "  访问地址: ${base}/"
  log "  报告页面: ${base}/report/report.md（映射路径以 conf/nginx.conf 为准）"
  log "  报告文件: ${OUT_DIR}/report.md  ${OUT_DIR}/summary.csv"
  log "  健康检查: 容器内 http://127.0.0.1:${CONTAINER_PORT}/（宿主端口 ${WEB_PORT}）"
  if (( DRY_RUN == 1 )); then
    warn "以上为 dry-run 结果，未真正启动容器"
  fi
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -n | --dry-run) DRY_RUN=1 ;;
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
  trap on_error ERR

  if (( DRY_RUN == 1 )); then
    log "部署开始（仓库: ${SCRIPT_DIR}，dry-run 模式）"
  else
    log "部署开始（仓库: ${SCRIPT_DIR}）"
  fi

  stage_env
  stage_preflight
  stage_build
  stage_up
  stage_wait_healthy
  stage_analyze
  stage_report
}

main "$@"

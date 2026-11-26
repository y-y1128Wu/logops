#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# 1. 读取环境变量
# 如果 .env 存在则加载，默认值也跟契约保持一致
if [[ -f .env ]]; then
    source .env
fi
LOG_FILE="${LOG_FILE:-data/logs/access.log}"
TOP_N="${TOP_N:-10}"
OUT_DIR="${OUT_DIR:-out}"

# 2. 打印帮助
usage() {
    echo "用法: $0 [--log <日志文件>] [--top <数字>] [--out <输出目录>]"
    echo "兼容: $0 [-log <日志文件>]"
    exit 2  # 契约要求：参数错误 exit 2
}

# 3. 参数解析（契约要求兼容 -log, --log, --top, --out）
while [[ $# -gt 0 ]]; do
    case "$1" in
        --log|-log) LOG_FILE="$2"; shift 2 ;;
        --top) TOP_N="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) echo "错误: 未知参数 $1" >&2; usage ;;
    esac
done

# 4. 检查文件（契约要求：运行失败 exit 1）
if [[ ! -f "$LOG_FILE" ]]; then
    echo "错误: 找不到日志文件 $LOG_FILE" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

# ==========================================
# 5. 核心指标计算（按契约的“指标口径”）
# ==========================================

# 指标1：总请求（非空行数）
total=$(grep -cve '^[[:space:]]*$' "$LOG_FILE" || true)

# 指标2：独立 IP（$1 去重）
ips=$(awk '{print $1}' "$LOG_FILE" | sort -u | wc -l)

# 指标3：5xx 错误数（$9 以 5 开头）
err5xx=$(awk '$9 ~ /^5/' "$LOG_FILE" | wc -l)

# 指标4：TOP N 页面（$7 原样）
# 先把结果存到临时变量里，方便后面写进 Markdown 表格
top_pages=$(awk '{print $7}' "$LOG_FILE" | sort | uniq -c | sort -rn | head -n "$TOP_N" || true)

# 指标5：状态码分布
status_dist=$(awk '{print $9}' "$LOG_FILE" | sort | uniq -c | sort -rn || true)

# 指标6：按小时请求趋势（按冒号切 $4 取第二段）
hour_trend=$(awk -F: '{print $2}' "$LOG_FILE" | sort | uniq -c || true)

# ==========================================
# 6. 生成 summary.csv（契约要求：表头 section,item,value）
# ==========================================
cat << EOF > "$OUT_DIR/summary.csv"
section,item,value
总览,总请求数,$total
总览,独立IP数,$ips
总览,5xx错误数,$err5xx
EOF

# ==========================================
# 7. 生成 report.md（契约要求：六节固定顺序）
# ==========================================
cat << EOF > "$OUT_DIR/report.md"
# 日志分析报告

## 1. 总览
- **总请求数**: $total
- **独立 IP 数**: $ips

## 2. TOP $TOP_N 页面
| 访问次数 | 页面路径 |
|----------|----------|
EOF

# 循环把 TOP 页面追加到 md 里
while read -r count page; do
    echo "| $count | $page |" >> "$OUT_DIR/report.md"
done <<< "$top_pages"

cat << EOF >> "$OUT_DIR/report.md"

## 3. 状态码分布
| 状态码 | 次数 |
|--------|------|
EOF

# 循环把状态码追加到 md 里
while read -r count code; do
    echo "| $code | $count |" >> "$OUT_DIR/report.md"
done <<< "$status_dist"

cat << EOF >> "$OUT_DIR/report.md"

## 4. 5xx 错误明细
共发现 $err5xx 条 5xx 错误。

## 5. 按小时访问趋势
| 小时 | 请求数 |
|------|--------|
EOF

# 循环把时间趋势追加到 md 里
while read -r count hour; do
    # 把小时补零变成两位数，比如 10, 11
    printf "| %02d 点 | %s |\n" "$hour" "$count" >> "$OUT_DIR/report.md"
done <<< "$hour_trend"

# 第六节：生成时间
cat << EOF >> "$OUT_DIR/report.md"

## 6. 生成时间
$(date '+%Y-%m-%d %H:%M:%S')
EOF

echo "分析完成！报告已生成至 $OUT_DIR/"

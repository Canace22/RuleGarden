#!/usr/bin/env bash
# 提交前敏感信息扫描
# 用法: bash .agents/skills/pre-commit-secrets/scripts/scan-secrets.sh [--staged|--working|--all]
set -euo pipefail

MODE="${1:---staged}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
NC='\033[0m'

issues=0
warns=0

section() { echo; echo "== $1 =="; }

fail() { echo -e "${RED}FAIL${NC} $1"; issues=$((issues + 1)); }
warn() { echo -e "${YEL}WARN${NC} $1"; warns=$((warns + 1)); }
ok()   { echo -e "${GRN}OK${NC}   $1"; }

# 获取待扫描文件列表
get_files() {
  case "$MODE" in
    --staged)
      git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true
      ;;
    --all)
      git ls-files
      ;;
    --working)
      {
        git diff --name-only --diff-filter=ACMR 2>/dev/null || true
        git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true
        git ls-files --others --exclude-standard 2>/dev/null || true
      } | sort -u
      ;;
    *)
      echo "Unknown mode: $MODE (use --staged, --working, or --all)" >&2
      exit 2
      ;;
  esac
}

# 不扫描的路径：依赖、构建产物、lockfile；以及本脚本自己（里面的正则会命中自己）
SKIP_PATHS='node_modules/|dist/|build/|release/|coverage/|test-results/|pnpm-lock\.yaml|package-lock\.json|yarn\.lock'
GIT_EXCLUDES=(
  ":(exclude)node_modules/**"
  ":(exclude)dist/**"
  ":(exclude)build/**"
  ":(exclude)release/**"
  ":(exclude)pnpm-lock.yaml"
  ":(exclude)package-lock.json"
  ":(exclude)yarn.lock"
  ":(exclude,glob)**/scan-secrets.sh"
)

filter_files() {
  grep -Ev "$SKIP_PATHS" || true
}

FILES="$(get_files | filter_files)"

section "1. 禁止提交的文件类型"
FORBIDDEN='\.(env|env\.local|env\.production|pem|key|p12|pfx|crt|credentials|secrets)$|(^|/)\.env'
if [ -n "$FILES" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if echo "$f" | grep -Eq "$FORBIDDEN"; then
      fail "敏感文件在变更列表中: $f"
    fi
  done <<< "$FILES"
fi
if [ "$issues" -eq 0 ]; then ok "未发现 .env / 证书 / credentials 类文件"; fi

section "2. 高置信度密钥模式"
PATTERNS=(
  'secret_[a-zA-Z0-9]{20,}'
  'ntn_[a-zA-Z0-9]{20,}'
  'ghp_[a-zA-Z0-9]{36}'
  'github_pat_[a-zA-Z0-9_]{20,}'
  'sk-[a-zA-Z0-9]{20,}'
  'AKIA[0-9A-Z]{16}'
  'xox[baprs]-[a-zA-Z0-9-]{10,}'
  '-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----'
  'mongodb(\+srv)?://[^:]+:[^@]+@'
  'postgres(ql)?://[^:]+:[^@]+@'
  'mysql://[^:]+:[^@]+@'
)
PATTERN_RE="$(IFS='|'; echo "${PATTERNS[*]}")"

scan_content() {
  local scope="$1"
  local content=""
  if [ "$scope" = "staged" ]; then
    content="$(
      git diff --cached -U0 -- . "${GIT_EXCLUDES[@]}" 2>/dev/null \
        | grep -E -e "$PATTERN_RE" \
        || true
    )"
  else
    content="$(git grep -n -E -e "$PATTERN_RE" -- . "${GIT_EXCLUDES[@]}" 2>/dev/null || true)"
  fi
  if [ -n "$content" ]; then
    echo "$content" | while IFS= read -r line; do
      [ -z "$line" ] && continue
      fail "疑似密钥: $line"
    done
    # 管道里的 fail 计数带不出子 shell，这里补记一次
    issues=$((issues + 1))
  else
    ok "未发现高置信度密钥模式"
  fi
}

if [ "$MODE" = "--staged" ]; then
  scan_content staged
else
  scan_content all
fi

section "3. 可疑赋值（需人工确认）"
SUSPICIOUS='(api[_-]?key|secret|password|token|credential)\s*[:=]\s*["'\''`][^"'\'']{8,}["'\''`]'
# 常见误报：UI 占位、设计 token、包名、GitHub OIDC 权限
FALSE_POSITIVES='placeholder|type=.password|design-tokens|js-tokens|id-token: write'
if [ -n "$FILES" ]; then
  hits=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ ! -f "$f" ] && continue
    case "$f" in
      *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.py|*.go|*.rb|*.java|*.json|*.yml|*.yaml|*.toml|*.md|*.env*|*.sh) ;;
      *) continue ;;
    esac
    line="$(grep -nEi "$SUSPICIOUS" "$f" 2>/dev/null | grep -Ev "$FALSE_POSITIVES" || true)"
    if [ -n "$line" ]; then
      hits="${hits}${f}:\n${line}\n"
    fi
  done <<< "$FILES"
  if [ -n "$hits" ]; then
    echo -e "$hits" | while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo -e "${YEL}WARN${NC} 可疑赋值: $line"
    done
    warns=$((warns + 1))
  else
    ok "未发现可疑硬编码赋值"
  fi
else
  ok "无待扫描文件"
fi

section "汇总"
if [ "$issues" -gt 0 ]; then
  echo -e "${RED}发现必须处理的问题，不能提交${NC}"
  exit 1
elif [ "$warns" -gt 0 ]; then
  echo -e "${YEL}无阻断问题，但有警告需人工确认${NC}"
  exit 0
else
  echo -e "${GRN}扫描通过，未发现敏感信息${NC}"
  exit 0
fi

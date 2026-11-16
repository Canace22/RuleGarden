#!/usr/bin/env bash
# RuleGarden：给项目铺规则骨架（init），或更新项目里的共享 skill（sync）
# 用法: bash scripts/garden.sh init|sync <项目目录>
set -euo pipefail

GARDEN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="${1:-}"
TARGET="${2:-}"

usage() {
  echo "用法: bash scripts/garden.sh init|sync <项目目录>" >&2
  exit 2
}

[ -n "$CMD" ] && [ -n "$TARGET" ] || usage
[ -d "$TARGET" ] || { echo "目录不存在: $TARGET" >&2; exit 1; }

TARGET="$(cd "$TARGET" && pwd)"
SKILLS_DIR="$TARGET/.agents/skills"
CLAUDE_LINK="$TARGET/.claude/skills"

report() { printf '%s\t%s\n' "$1" "${2#"$TARGET"/}"; }

# 只在目标不存在时复制，绝不覆盖项目已有的文件
copy_if_missing() {
  local src="$1" dest="$2"
  if [ -e "$dest" ]; then
    report "跳过(已存在)" "$dest"
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  cp -R "$src" "$dest"
  report "新增" "$dest"
}

init() {
  local agents_existed=0
  [ -e "$TARGET/AGENTS.md" ] && agents_existed=1

  copy_if_missing "$GARDEN_ROOT/template/AGENTS.md" "$TARGET/AGENTS.md" || true
  copy_if_missing "$GARDEN_ROOT/template/CLAUDE.md" "$TARGET/CLAUDE.md" || true
  copy_if_missing "$GARDEN_ROOT/template/.agents/skills/README.md" "$SKILLS_DIR/README.md" || true

  local dir
  for dir in "$GARDEN_ROOT"/skills/*/; do
    copy_if_missing "${dir%/}" "$SKILLS_DIR/$(basename "$dir")" || true
  done

  if [ -e "$CLAUDE_LINK" ] || [ -L "$CLAUDE_LINK" ]; then
    report "跳过(已存在)" "$CLAUDE_LINK"
  else
    mkdir -p "$(dirname "$CLAUDE_LINK")"
    ln -s ../.agents/skills "$CLAUDE_LINK"
    report "新增(软链)" "$CLAUDE_LINK"
  fi

  echo
  if [ "$agents_existed" -eq 1 ]; then
    echo "项目已有 AGENTS.md，没有改动它。"
    echo "请把 $GARDEN_ROOT/template/AGENTS.md 里“Skills”一节合并进去，规则才会开始生长。"
  else
    echo "下一步：打开 AGENTS.md，填上项目概述、常用命令和常见入口。"
  fi
}

# 只更新项目里已经有的共享 skill；项目删掉的不会被加回来
sync() {
  [ -d "$SKILLS_DIR" ] || { echo "没有找到 .agents/skills，请先运行 init" >&2; exit 1; }

  local dir name dest
  for dir in "$GARDEN_ROOT"/skills/*/; do
    name="$(basename "$dir")"
    dest="$SKILLS_DIR/$name"
    if [ ! -d "$dest" ]; then
      report "跳过(项目没有)" "$dest"
    elif diff -rq "${dir%/}" "$dest" >/dev/null 2>&1; then
      report "已是最新" "$dest"
    else
      rm -rf "$dest"
      cp -R "${dir%/}" "$dest"
      report "已更新" "$dest"
    fi
  done

  echo
  echo "同步只覆盖共享 skill。提交前用 git diff 看一眼改了什么。"
}

case "$CMD" in
  init) init ;;
  sync) sync ;;
  *) usage ;;
esac

#!/usr/bin/env bash
# 一键安装 skills（macOS / Linux）
# 用法：
#   ./install.sh                     # 安装 own + third-party 到 ~/.agents/skills
#   ./install.sh --stride <工作区路径>  # 追加安装 project-stride 到 <工作区>/.agents/skills
# 重复执行 = 覆盖更新（先删旧目录再拷贝，保证与仓库一致）。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${SKILLS_DIR:-$HOME/.agents/skills}"
STRIDE_DIR=""

usage() { sed -n '2,6p' "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stride)   STRIDE_DIR="${2:-}"; shift 2 ;;
    --stride=*) STRIDE_DIR="${1#*=}"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

install_group() { # $1=来源目录 $2=目标目录
  local src="$1" dest="$2" skill name
  mkdir -p "$dest"
  for skill in "$src"/*/; do
    [[ -f "${skill}SKILL.md" ]] || continue
    name="$(basename "$skill")"
    rm -rf "${dest:?}/$name"
    cp -R "$skill" "${dest:?}/$name"
    echo "  installed $name"
  done
}

echo "→ 用户级 skills → $DEST"
install_group "$REPO_DIR/own" "$DEST"
for src in "$REPO_DIR"/third-party/*/; do
  echo "→ $(basename "$src")"
  install_group "$src" "$DEST"
done

if [[ -n "$STRIDE_DIR" ]]; then
  if [[ ! -d "$STRIDE_DIR" ]]; then
    echo "错误: --stride 路径不存在: $STRIDE_DIR" >&2
    exit 1
  fi
  echo "→ stride 项目级 skills → $STRIDE_DIR/.agents/skills"
  install_group "$REPO_DIR/project-stride" "$STRIDE_DIR/.agents/skills"
fi

echo "完成。重启 ZCode / 新开会话后生效。"

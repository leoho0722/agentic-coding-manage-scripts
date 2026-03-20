#!/usr/bin/env bash
#
# update-flutter-skills.sh
#
# 從 https://github.com/flutter/skills 安裝或更新 Flutter skills。
# 使用 shallow clone 快取 repo，並將每個 skill 以 symlink 連結至 skills/ 資料夾。
#
# 操作流程：
#   1. 若快取不存在，執行 shallow clone
#   2. 若快取已存在，執行 git pull 更新
#   3. 比對 repo 中的 skills 與本地 symlink，新增 / 移除差異項目
#
# 用法：
#   bash scripts/update-flutter-skills.sh
#

set -euo pipefail

# ── 路徑設定 ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILLS_DIR="${ROOT_DIR}/skills"
REPO_CACHE="${ROOT_DIR}/.flutter-skills-repo"
REPO_SKILLS="${REPO_CACHE}/skills"
REPO_URL="https://github.com/flutter/skills.git"
REPO_REF="main"

# ── 顏色輸出 ──
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ── 主邏輯 ──
echo ""
echo -e "${CYAN}── Flutter Skills 更新 ──${NC}"
echo ""

added=0
removed=0
unchanged=0

# 步驟 1：Clone 或 Pull
if [[ -d "${REPO_CACHE}/.git" ]]; then
  info "更新快取：${REPO_CACHE}"
  git -C "${REPO_CACHE}" pull --ff-only origin "${REPO_REF}" 2>&1 | sed 's/^/  /'
else
  if [[ -d "${REPO_CACHE}" ]]; then
    warn "快取資料夾存在但非 git repo，移除後重新 clone"
    rm -rf "${REPO_CACHE}"
  fi
  info "Clone flutter/skills → ${REPO_CACHE}"
  git clone --depth 1 --branch "${REPO_REF}" "${REPO_URL}" "${REPO_CACHE}" 2>&1 | sed 's/^/  /'
fi

echo ""

# 步驟 2：確認 repo 中有 skills
if [[ ! -d "${REPO_SKILLS}" ]]; then
  error "找不到 skills 資料夾：${REPO_SKILLS}"
  exit 1
fi

# 步驟 3：建立新 skill 的 symlink
for skill_dir in "${REPO_SKILLS}"/flutter-*/; do
  [[ -d "${skill_dir}" ]] || continue
  skill_name="$(basename "${skill_dir}")"
  link_target="${SKILLS_DIR}/${skill_name}"

  if [[ -L "${link_target}" ]]; then
    # 已存在 symlink，檢查是否指向正確
    existing="$(readlink -f "${link_target}")"
    expected="$(readlink -f "${skill_dir}")"
    if [[ "${existing}" == "${expected}" ]]; then
      unchanged=$((unchanged + 1))
      continue
    fi
    # 指向錯誤，移除後重建
    warn "修正 symlink：${skill_name}"
    rm "${link_target}"
  elif [[ -e "${link_target}" ]]; then
    warn "已存在非 symlink 項目，跳過：${skill_name}"
    continue
  fi

  ln -s "${skill_dir}" "${link_target}"
  success "新增：${skill_name}"
  added=$((added + 1))
done

# 步驟 4：清除已從 repo 移除的 flutter skill symlink
for link in "${SKILLS_DIR}"/flutter-*; do
  [[ -L "${link}" ]] || continue
  skill_name="$(basename "${link}")"
  if [[ ! -d "${REPO_SKILLS}/${skill_name}" ]]; then
    rm "${link}"
    warn "移除已不存在的 skill：${skill_name}"
    removed=$((removed + 1))
  fi
done

# ── 結果 ──
echo ""
echo -e "  ${GREEN}新增${NC}    ：${added}"
echo -e "  ${YELLOW}移除${NC}    ：${removed}"
echo -e "  ${CYAN}未變更${NC}  ：${unchanged}"
echo ""

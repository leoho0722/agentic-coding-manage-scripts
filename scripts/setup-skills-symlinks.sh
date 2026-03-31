#!/usr/bin/env bash
#
# setup-skills-symlinks.sh
#
# 將共用的 skills/ 資料夾透過 symlink 連結至各 Agentic Coding Tool 的
# global skills 路徑，讓所有工具共享同一套 skills。
#
# 支援的工具：
#   - Claude Code                    (~/.claude/skills/)
#   - OpenCode                        (~/.config/opencode/skills/)
#   - Google Antigravity              (~/.gemini/antigravity/skills/)
#   - OpenAI Codex                    (~/.codex/skills/)
#   - Xcode (Claude Agent, 26.3)     (~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/skills/)
#   - Xcode (Claude Agent, 26.4+)    (~/Library/Developer/Xcode/CodingAssistant/Agents/claude/skills/)
#   - Xcode (Codex, 26.3)            (~/Library/Developer/Xcode/CodingAssistant/codex/skills/)
#   - Xcode (Codex, 26.4+)           (~/Library/Developer/Xcode/CodingAssistant/Agents/codex/skills/)
#

set -euo pipefail

# ── 路徑設定 ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILLS_DIR="${ROOT_DIR}/skills"

# ── 顏色輸出 ──
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# ── Skills 目錄映射表 ──
SKILLS_MAP=(
  "${HOME}/.claude/skills"
  "${HOME}/.config/opencode/skills"
  "${HOME}/.gemini/antigravity/skills"
  "${HOME}/.codex/skills"
  "${HOME}/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/skills"
  "${HOME}/Library/Developer/Xcode/CodingAssistant/codex/skills"
  # Xcode 26.4+（新路徑）
  "${HOME}/Library/Developer/Xcode/CodingAssistant/Agents/claude/skills"
  "${HOME}/Library/Developer/Xcode/CodingAssistant/Agents/codex/skills"
)

# ── 建立 symlink 的共用函式 ──
link_dir() {
  local src_abs="$1"
  local target="$2"
  local label="$3"

  local target_dir
  target_dir="$(dirname "$target")"
  if [[ ! -d "$target_dir" ]]; then
    info "建立目標資料夾：${target_dir}"
    mkdir -p "$target_dir"
  fi

  if [[ -e "$target" || -L "$target" ]]; then
    if [[ -L "$target" ]] && [[ "$(readlink -f "$target")" == "$(readlink -f "$src_abs")" ]]; then
      success "已連結，跳過：${label}"
      skipped=$((skipped + 1))
      return
    fi

    local backup="${target}.backup.$(date +%Y%m%d%H%M%S)"
    warn "目標已存在，備份至：${backup}"

    if [[ -d "$target" && ! -L "$target" ]]; then
      info "合併目錄內容至：${src_abs}"
      cp -rn "$target"/* "$src_abs"/ 2>/dev/null || true
    fi

    mv "$target" "$backup"
    backed_up=$((backed_up + 1))
  fi

  ln -s "$src_abs" "$target"
  success "已連結：${target} → ${label}"
  linked=$((linked + 1))
}

# ── 主邏輯 ──
echo ""
echo -e "${CYAN}── Skills 目錄 Symlink ──${NC}"
echo ""
info "Skills 資料夾：${SKILLS_DIR}"
echo ""

linked=0
skipped=0
backed_up=0

if [[ ! -d "$SKILLS_DIR" ]]; then
  warn "Skills 資料夾不存在：${SKILLS_DIR}"
  warn "請先建立 skills/ 資料夾後再執行此腳本。"
  exit 1
fi

for target in "${SKILLS_MAP[@]}"; do
  link_dir "$SKILLS_DIR" "$target" "skills/"
done

echo ""
echo -e "  ${GREEN}新建連結${NC}：${linked}"
echo -e "  ${YELLOW}已跳過${NC}  ：${skipped}"
echo -e "  ${CYAN}已備份${NC}  ：${backed_up}"
echo ""

if [[ $backed_up -gt 0 ]]; then
  warn "原始 skills 目錄已備份（*.backup.*），確認無誤後可手動刪除。"
fi

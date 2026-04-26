#!/usr/bin/env bash
#
# setup-configs-symlinks.sh
#
# 將各 Agentic Coding Tool 的 global config 收斂至 configs/ 資料夾，
# 並透過 symlink 連結回原始路徑。
#
# 支援的工具：
#   - Claude Code                    (~/.claude/)
#   - OpenCode                        (~/.config/opencode/)
#   - Google Antigravity              (~/.gemini/antigravity/)
#   - OpenAI Codex                    (~/.codex/)
#   - Xcode (Claude Agent, 26.3)     (~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/)
#   - Xcode (Claude Agent, 26.4+)    (~/Library/Developer/Xcode/CodingAssistant/Agents/claude/)
#   - Xcode (Codex, 26.3)            (~/Library/Developer/Xcode/CodingAssistant/codex/)
#   - Xcode (Codex, 26.4+)           (~/Library/Developer/Xcode/CodingAssistant/Agents/codex/)
#

set -euo pipefail

# ── 路徑設定 ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGS_DIR="${ROOT_DIR}/configs"

# ── 顏色輸出 ──
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# ── Config 檔案映射表 ──
# 格式："來源檔案（configs/ 內的相對路徑）|目標路徑（原始位置）"
CONFIG_MAP=(
  # Claude Code
  "claude-code/.claude.json|${HOME}/.claude.json"
  "claude-code/settings.json|${HOME}/.claude/settings.json"
  "claude-code/keybindings.json|${HOME}/.claude/keybindings.json"
  "claude-code/CLAUDE.md|${HOME}/.claude/CLAUDE.md"

  # OpenCode
  "opencode/opencode.json|${HOME}/.config/opencode/opencode.json"

  # Google Antigravity
  "google-antigravity/mcp_config.json|${HOME}/.gemini/antigravity/mcp_config.json"

  # OpenAI Codex
  "openai-codex/config.toml|${HOME}/.codex/config.toml"

  # Xcode (Claude Agent, 26.3)
  "xcode-claude/.claude.json|${HOME}/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/.claude.json"

  # Xcode (Codex, 26.3)
  "xcode-codex/config.toml|${HOME}/Library/Developer/Xcode/CodingAssistant/codex/config.toml"

  # Xcode 26.4+（Claude Agent — 新路徑）
  "xcode-claude/.claude.json|${HOME}/Library/Developer/Xcode/CodingAssistant/Agents/claude/.claude.json"

  # Xcode 26.4+（Codex — 新路徑）
  "xcode-codex/config.toml|${HOME}/Library/Developer/Xcode/CodingAssistant/Agents/codex/config.toml"

  # ── 新增工具範例 ──
  # "tool-name/config.json|${HOME}/.tool-name/config.json"
)

# ── 建立 symlink 的共用函式 ──
link_file() {
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

    if [[ -f "$target" && ! -L "$target" ]]; then
      local original_size our_size
      original_size=$(wc -c < "$target" 2>/dev/null || echo "0")
      our_size=$(wc -c < "$src_abs" 2>/dev/null || echo "0")
      if [[ "$original_size" -gt "$our_size" ]]; then
        info "原始檔案較大（${original_size} bytes），將內容保留至來源"
        cp "$target" "$src_abs"
      fi
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
echo -e "${CYAN}── Config 檔案 Symlink ──${NC}"
echo ""
info "Config 資料夾：${CONFIGS_DIR}"
echo ""

linked=0
skipped=0
backed_up=0

for mapping in "${CONFIG_MAP[@]}"; do
  src_rel="${mapping%%|*}"
  target="${mapping##*|}"
  src_abs="${CONFIGS_DIR}/${src_rel}"

  if [[ ! -f "$src_abs" ]]; then
    warn "來源檔案不存在，跳過：${src_rel}"
    skipped=$((skipped + 1))
    continue
  fi

  link_file "$src_abs" "$target" "$src_rel"
done

echo ""
echo -e "  ${GREEN}新建連結${NC}：${linked}"
echo -e "  ${YELLOW}已跳過${NC}  ：${skipped}"
echo -e "  ${CYAN}已備份${NC}  ：${backed_up}"
echo ""

if [[ $backed_up -gt 0 ]]; then
  warn "原始設定檔已備份（*.backup.*），確認無誤後可手動刪除。"
fi

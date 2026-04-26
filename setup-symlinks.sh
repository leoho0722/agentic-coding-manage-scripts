#!/usr/bin/env bash
#
# setup-symlinks.sh
#
# Agentic Coding Tools 統一管理入口腳本。
# 透過互動式選單選擇要進行的操作。
#
# 支援的工具：
#   Claude Code, OpenCode, Google Antigravity,
#   OpenAI Codex, Xcode (Claude Agent / Codex)
#
# 用法：
#   chmod +x setup-symlinks.sh
#   ./setup-symlinks.sh
#

set -euo pipefail

# ── 路徑設定 ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

# ── 顏色輸出 ──
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── 顯示選單 ──
show_menu() {
  echo ""
  echo -e "${BOLD}========================================"
  echo -e "  Agentic Coding Tools Symlink Manager"
  echo -e "========================================${NC}"
  echo ""
  echo -e "  ${CYAN}1)${NC} Configs        — 設定檔 symlink（settings, keybindings, ...）"
  echo -e "  ${CYAN}2)${NC} Skills         — 共用 skills 目錄 symlink"
  echo -e "  ${CYAN}3)${NC} All Symlinks   — 全部 symlink（Configs + Skills）"
  echo -e "  ${CYAN}4)${NC} Xcode Agents   — 更新 Xcode 內建的 Claude / Codex SDK"
  echo -e "  ${CYAN}5)${NC} Flutter Skills — 安裝／更新 Flutter skills（from github.com/flutter/skills）"
  echo -e "  ${CYAN}6)${NC} MCP Servers    — 從 mcp/servers.json 同步 MCP 設定到所有工具"
  echo -e "  ${CYAN}q)${NC} 離開"
  echo ""
}

# ── 執行子腳本 ──
run_configs() {
  local script="${SCRIPTS_DIR}/setup-configs-symlinks.sh"
  if [[ ! -f "$script" ]]; then
    echo -e "${RED}[ERROR]${NC} 找不到：${script}"
    return 1
  fi
  bash "$script"
}

run_skills() {
  local script="${SCRIPTS_DIR}/setup-skills-symlinks.sh"
  if [[ ! -f "$script" ]]; then
    echo -e "${RED}[ERROR]${NC} 找不到：${script}"
    return 1
  fi
  bash "$script"
}

run_xcode_agents() {
  local script="${SCRIPTS_DIR}/update-xcode-agents.sh"
  if [[ ! -f "$script" ]]; then
    echo -e "${RED}[ERROR]${NC} 找不到：${script}"
    return 1
  fi
  bash "$script" "$@"
}

run_flutter_skills() {
  local script="${SCRIPTS_DIR}/update-flutter-skills.sh"
  if [[ ! -f "$script" ]]; then
    echo -e "${RED}[ERROR]${NC} 找不到：${script}"
    return 1
  fi
  bash "$script"
}

run_mcp_sync() {
  local script="${SCRIPTS_DIR}/sync-mcp-servers.sh"
  if [[ ! -f "$script" ]]; then
    echo -e "${RED}[ERROR]${NC} 找不到：${script}"
    return 1
  fi
  bash "$script" "$@"
}

# ── 主邏輯 ──
show_menu

read -rp "請選擇操作 [1/2/3/4/5/6/q]: " choice

case "$choice" in
  1)
    run_configs
    ;;
  2)
    run_skills
    ;;
  3)
    run_configs
    run_skills
    ;;
  4)
    run_xcode_agents "$@"
    ;;
  5)
    run_flutter_skills
    ;;
  6)
    run_mcp_sync "$@"
    ;;
  q|Q)
    echo ""
    echo -e "${GREEN}已離開。${NC}"
    echo ""
    exit 0
    ;;
  *)
    echo ""
    echo -e "${RED}無效選擇：${choice}${NC}"
    echo ""
    exit 1
    ;;
esac

echo ""
echo -e "${GREEN}${BOLD}全部完成！${NC}"
echo ""

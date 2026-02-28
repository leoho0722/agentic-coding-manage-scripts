#!/usr/bin/env bash
#
# update-xcode-agents.sh
#
# 從官方來源下載最新版本，更新 Xcode 內建的 Claude Agent SDK 與 Codex SDK。
# 自動掃描所有已安裝的 Xcode 版本，逐一更新。
#
# Claude Agent SDK：
#   - 版本查詢：GCS /latest endpoint
#   - 下載來源：storage.googleapis.com（官方 bootstrap.sh 同源）
#
# Codex SDK：
#   - 版本查詢：GitHub Releases API
#   - 下載來源：github.com/openai/codex/releases
#
# 參考：
#   - https://x.com/rudrank/status/2019507820945895529
#   - https://x.com/rudrank/status/2019495335798927610
#

set -euo pipefail

# ── 常數 ──
XCODE_VERSIONS_DIR="${HOME}/Library/Developer/Xcode/CodingAssistant/Agents/Versions"

CLAUDE_GCS_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
CODEX_GITHUB_API="https://api.github.com/repos/openai/codex/releases/latest"

# 平台偵測
detect_platform() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    arm64|aarch64) echo "arm64" ;;
    x86_64)        echo "x64" ;;
    *)             echo "$arch" ;;
  esac
}

ARCH="$(detect_platform)"

# ── 顏色輸出 ──
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ── 前置檢查 ──
preflight_check() {
  if [[ ! -d "$XCODE_VERSIONS_DIR" ]]; then
    error "找不到 Xcode Agents Versions 目錄：${XCODE_VERSIONS_DIR}"
    error "請確認已安裝 Xcode 且已啟用 Coding Intelligence。"
    exit 1
  fi

  if ! command -v curl &>/dev/null; then
    error "需要 curl，請先安裝。"
    exit 1
  fi
}

# ── 掃描所有 Xcode 版本目錄 ──
discover_xcode_versions() {
  local versions=()
  for dir in "${XCODE_VERSIONS_DIR}"/*/; do
    if [[ -d "$dir" ]]; then
      local ver
      ver="$(basename "$dir")"
      versions+=("$ver")
    fi
  done
  echo "${versions[@]}"
}

# ── 取得 binary 的版本（如果可執行）──
get_binary_version() {
  local binary="$1"
  if [[ -x "$binary" ]]; then
    "$binary" --version 2>/dev/null || echo "未知"
  elif [[ -L "$binary" ]]; then
    echo "symlink → $(readlink "$binary")"
  else
    echo "無"
  fi
}

# ── 備份 binary ──
backup_binary() {
  local binary_path="$1"
  local name="$2"

  if [[ -e "$binary_path" && ! -L "$binary_path" ]]; then
    local backup="${binary_path}.backup.$(date +%Y%m%d%H%M%S)"
    info "備份原始 ${name} → ${backup}"
    cp -a "$binary_path" "$backup"
  fi
}

# ══════════════════════════════════════
#  Claude Agent SDK 更新
# ══════════════════════════════════════

update_claude() {
  echo ""
  echo -e "${BOLD}── Claude Agent SDK ──${NC}"
  echo ""

  # 掃描所有版本
  local versions
  read -ra versions <<< "$(discover_xcode_versions)"

  if [[ ${#versions[@]} -eq 0 ]]; then
    error "找不到任何 Xcode 版本目錄。"
    return 1
  fi

  info "偵測到 ${#versions[@]} 個 Xcode 版本："
  for ver in "${versions[@]}"; do
    local bin="${XCODE_VERSIONS_DIR}/${ver}/claude"
    local ver_info
    ver_info="$(get_binary_version "$bin")"
    echo -e "  ${CYAN}${ver}${NC} — ${ver_info}"
  done
  echo ""

  # 從官方 GCS endpoint 取得最新版本號
  info "正在查詢官方最新版本..."
  local latest_version
  latest_version=$(curl -sfS "${CLAUDE_GCS_BASE}/latest" 2>/dev/null || echo "")

  if [[ -z "$latest_version" ]]; then
    error "無法取得最新版本號，請檢查網路連線。"
    return 1
  fi

  info "官方最新版本：${latest_version}"

  # 決定平台路徑
  local platform_dir
  case "$ARCH" in
    arm64) platform_dir="darwin-arm64" ;;
    x64)   platform_dir="darwin-x64" ;;
    *)     error "不支援的架構：${ARCH}"; return 1 ;;
  esac

  local download_url="${CLAUDE_GCS_BASE}/${latest_version}/${platform_dir}/claude"

  echo ""
  info "下載 URL：${download_url}"
  read -rp "確認下載並更新所有版本？[y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    warn "已取消。"
    return 0
  fi

  # 下載一次到暫存
  info "正在下載 Claude ${latest_version}（${platform_dir}）..."
  local tmp_file
  tmp_file="$(mktemp)"
  if ! curl -fSL --progress-bar -o "$tmp_file" "$download_url"; then
    error "下載失敗。"
    rm -f "$tmp_file"
    return 1
  fi
  chmod +x "$tmp_file"

  # 逐版本安裝
  local updated=0
  for ver in "${versions[@]}"; do
    local xcode_claude="${XCODE_VERSIONS_DIR}/${ver}/claude"

    # 跳過不存在 claude binary 且目錄裡也沒有其他 agent 的版本
    if [[ ! -e "$xcode_claude" && ! -L "$xcode_claude" ]]; then
      warn "Xcode ${ver} 無 claude binary，跳過。"
      continue
    fi

    backup_binary "$xcode_claude" "claude (${ver})"
    rm -f "$xcode_claude"
    cp "$tmp_file" "$xcode_claude"
    chmod +x "$xcode_claude"

    local new_ver
    new_ver="$(get_binary_version "$xcode_claude")"
    success "Xcode ${ver}：已更新 → ${new_ver}"
    updated=$((updated + 1))
  done

  rm -f "$tmp_file"

  echo ""
  if [[ $updated -eq 0 ]]; then
    warn "沒有任何版本被更新。"
  else
    success "共更新 ${updated} 個 Xcode 版本的 Claude Agent SDK。"
  fi
}

# ══════════════════════════════════════
#  Codex SDK 更新
# ══════════════════════════════════════

update_codex() {
  echo ""
  echo -e "${BOLD}── Codex SDK ──${NC}"
  echo ""

  # 掃描所有版本
  local versions
  read -ra versions <<< "$(discover_xcode_versions)"

  if [[ ${#versions[@]} -eq 0 ]]; then
    error "找不到任何 Xcode 版本目錄。"
    return 1
  fi

  info "偵測到 ${#versions[@]} 個 Xcode 版本："
  for ver in "${versions[@]}"; do
    local bin="${XCODE_VERSIONS_DIR}/${ver}/codex"
    local ver_info
    ver_info="$(get_binary_version "$bin")"
    echo -e "  ${CYAN}${ver}${NC} — ${ver_info}"
  done
  echo ""

  # 從 GitHub Releases API 取得最新版本
  info "正在查詢 GitHub 最新版本..."
  local release_json
  release_json=$(curl -sfS "$CODEX_GITHUB_API" 2>/dev/null || echo "")

  if [[ -z "$release_json" ]]; then
    error "無法取得 GitHub Release 資訊，請檢查網路連線。"
    return 1
  fi

  local latest_tag
  latest_tag=$(echo "$release_json" | grep '"tag_name"' | head -1 | sed 's/.*: *"//;s/".*//')

  if [[ -z "$latest_tag" ]]; then
    error "無法解析版本號。"
    return 1
  fi

  info "GitHub 最新版本：${latest_tag}"

  # 決定 asset 名稱
  local asset_name
  case "$ARCH" in
    arm64) asset_name="codex-aarch64-apple-darwin.tar.gz" ;;
    x64)   asset_name="codex-x86_64-apple-darwin.tar.gz" ;;
    *)     error "不支援的架構：${ARCH}"; return 1 ;;
  esac

  # 從 release JSON 找到 asset 下載 URL
  local download_url
  download_url=$(echo "$release_json" \
    | grep "browser_download_url" \
    | grep "$asset_name" \
    | head -1 \
    | sed 's/.*: *"//;s/".*//')

  if [[ -z "$download_url" ]]; then
    error "找不到 ${asset_name} 下載連結。"
    return 1
  fi

  echo ""
  info "下載 URL：${download_url}"
  read -rp "確認下載並更新所有版本？[y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    warn "已取消。"
    return 0
  fi

  # 下載一次到暫存
  info "正在下載 Codex ${latest_tag}（${asset_name}）..."
  local tmp_tar
  tmp_tar="$(mktemp)"
  if ! curl -fSL --progress-bar -o "$tmp_tar" "$download_url"; then
    error "下載失敗。"
    rm -f "$tmp_tar"
    return 1
  fi

  # 解壓
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  tar -xzf "$tmp_tar" -C "$tmp_dir"
  rm -f "$tmp_tar"

  # 尋找解壓後的 codex binary
  local codex_bin
  codex_bin=$(find "$tmp_dir" -name "codex" -type f -perm +111 2>/dev/null | head -1)
  if [[ -z "$codex_bin" ]]; then
    codex_bin=$(find "$tmp_dir" -type f -perm +111 2>/dev/null | head -1)
  fi

  if [[ -z "$codex_bin" ]]; then
    error "無法在解壓檔案中找到 codex binary。"
    rm -rf "$tmp_dir"
    return 1
  fi

  chmod +x "$codex_bin"

  # 逐版本安裝
  local updated=0
  for ver in "${versions[@]}"; do
    local xcode_codex="${XCODE_VERSIONS_DIR}/${ver}/codex"

    if [[ ! -e "$xcode_codex" && ! -L "$xcode_codex" ]]; then
      warn "Xcode ${ver} 無 codex binary，跳過。"
      continue
    fi

    backup_binary "$xcode_codex" "codex (${ver})"
    rm -f "$xcode_codex"
    cp "$codex_bin" "$xcode_codex"
    chmod +x "$xcode_codex"
    xattr -d com.apple.quarantine "$xcode_codex" 2>/dev/null || true

    local new_ver
    new_ver="$(get_binary_version "$xcode_codex")"
    success "Xcode ${ver}：已更新 → ${new_ver}"
    updated=$((updated + 1))
  done

  rm -rf "$tmp_dir"

  echo ""
  if [[ $updated -eq 0 ]]; then
    warn "沒有任何版本被更新。"
  else
    success "共更新 ${updated} 個 Xcode 版本的 Codex SDK。"
  fi
}

# ══════════════════════════════════════
#  主邏輯
# ══════════════════════════════════════

preflight_check

echo ""
echo -e "${BOLD}========================================"
echo -e "  Xcode Agents Updater"
echo -e "========================================${NC}"
echo ""
echo -e "  ${CYAN}1)${NC} Claude Agent SDK"
echo -e "  ${CYAN}2)${NC} Codex SDK"
echo -e "  ${CYAN}3)${NC} All（全部更新）"
echo -e "  ${CYAN}q)${NC} 離開"
echo ""

read -rp "請選擇操作 [1/2/3/q]: " choice

case "$choice" in
  1)
    update_claude
    ;;
  2)
    update_codex
    ;;
  3)
    update_claude
    update_codex
    ;;
  q|Q)
    echo ""
    echo -e "${GREEN}已離開。${NC}"
    exit 0
    ;;
  *)
    echo ""
    error "無效選擇：${choice}"
    exit 1
    ;;
esac

echo ""
echo -e "${GREEN}${BOLD}完成！請重新啟動 Xcode 以套用變更。${NC}"
echo ""

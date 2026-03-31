#!/usr/bin/env bash
#
# update-xcode-agents.sh
#
# 從官方來源下載最新版本，更新 Xcode 內建的 Claude Agent SDK 與 Codex SDK。
# 自動偵測並支援新舊兩種目錄結構：
#
#   Xcode 26.3（舊結構）：
#     - Agents/Versions/{XCODE_BUILD}/claude|codex — 獨立 binary
#
#   Xcode 26.4+（新結構）：
#     - Agents/claude/{SEMVER}/claude + Info.plist — 版本化 binary 目錄
#     - Agents/codex/{SEMVER}/codex + Info.plist — 版本化 binary 目錄
#     - Agents/XcodeVersions/{XCODE_BUILD}/claude|codex — symlink 至版本目錄
#
# Claude Agent SDK：
#   - 版本查詢：GCS /latest endpoint
#   - 下載來源：storage.googleapis.com（官方 bootstrap.sh 同源）
#
# Codex SDK：
#   - 版本查詢：GitHub Releases API
#   - 下載來源：github.com/openai/codex/releases
#
# 用法：
#   bash update-xcode-agents.sh                      # 互動式（每次下載前確認）
#   bash update-xcode-agents.sh --allow-autoupdate   # 自動確認所有下載
#   bash update-xcode-agents.sh --clean-backups      # 更新後自動清理 backup 檔案
#   bash update-xcode-agents.sh --clean-stale-builds # 自動清理已解除安裝 Xcode 的遺留目錄
#
# 參考：
#   - https://x.com/rudrank/status/2019507820945895529
#   - https://x.com/rudrank/status/2019495335798927610
#

set -euo pipefail

# ── 參數解析 ──
AUTO_YES=false
CLEAN_BACKUPS=false
CLEAN_STALE=false
for arg in "$@"; do
  case "$arg" in
    --allow-autoupdate)   AUTO_YES=true ;;
    --clean-backups)      CLEAN_BACKUPS=true ;;
    --clean-stale-builds) CLEAN_STALE=true ;;
  esac
done

# ── 常數 ──
XCODE_AGENTS_BASE="${HOME}/Library/Developer/Xcode/CodingAssistant/Agents"

# 舊結構（Xcode 26.3）
XCODE_VERSIONS_DIR="${XCODE_AGENTS_BASE}/Versions"

# 新結構（Xcode 26.4+）
XCODE_XCODE_VERSIONS_DIR="${XCODE_AGENTS_BASE}/XcodeVersions"
XCODE_CLAUDE_AGENTS_DIR="${XCODE_AGENTS_BASE}/claude"
XCODE_CODEX_AGENTS_DIR="${XCODE_AGENTS_BASE}/codex"

CLAUDE_GCS_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
CODEX_RELEASES_URL="https://github.com/openai/codex/releases/latest"

# 結構偵測旗標（preflight_check 設定）
HAS_OLD_STRUCTURE=false
HAS_NEW_STRUCTURE=false

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
  [[ -d "$XCODE_VERSIONS_DIR" ]] && HAS_OLD_STRUCTURE=true
  [[ -d "$XCODE_XCODE_VERSIONS_DIR" || -d "$XCODE_CLAUDE_AGENTS_DIR" || -d "$XCODE_CODEX_AGENTS_DIR" ]] && HAS_NEW_STRUCTURE=true

  if ! $HAS_OLD_STRUCTURE && ! $HAS_NEW_STRUCTURE; then
    error "找不到 Xcode Agents 目錄（舊版或新版皆不存在）。"
    error "請確認已安裝 Xcode 且已啟用 Coding Intelligence。"
    exit 1
  fi

  if ! command -v curl &>/dev/null; then
    error "需要 curl，請先安裝。"
    exit 1
  fi

  info "偵測到的結構："
  $HAS_OLD_STRUCTURE && info "  舊結構（Agents/Versions/）"
  $HAS_NEW_STRUCTURE && info "  新結構（Agents/{claude,codex}/ + XcodeVersions/）"
  echo ""
}

# ══════════════════════════════════════
#  探索函式
# ══════════════════════════════════════

# 掃描舊結構的 Xcode build 目錄（Agents/Versions/*/）
discover_old_xcode_builds() {
  local builds=()
  if [[ -d "$XCODE_VERSIONS_DIR" ]]; then
    for dir in "${XCODE_VERSIONS_DIR}"/*/; do
      [[ -d "$dir" ]] || continue
      local build
      build="$(basename "$dir")"
      [[ "$build" == .* ]] && continue
      builds+=("$build")
    done
  fi
  echo "${builds[@]+"${builds[@]}"}"
}

# 掃描新結構中某個 agent 的已安裝版本（Agents/{agent}/{SEMVER}/）
discover_new_agent_versions() {
  local agent_dir="$1"
  local versions=()
  if [[ -d "$agent_dir" ]]; then
    for dir in "${agent_dir}"/*/; do
      [[ -d "$dir" ]] || continue
      local ver
      ver="$(basename "$dir")"
      [[ "$ver" == .* ]] && continue
      versions+=("$ver")
    done
  fi
  echo "${versions[@]+"${versions[@]}"}"
}

# 掃描新結構的 XcodeVersions build 目錄
discover_new_xcode_builds() {
  local builds=()
  if [[ -d "$XCODE_XCODE_VERSIONS_DIR" ]]; then
    for dir in "${XCODE_XCODE_VERSIONS_DIR}"/*/; do
      [[ -d "$dir" ]] || continue
      local build
      build="$(basename "$dir")"
      [[ "$build" == .* ]] && continue
      builds+=("$build")
    done
  fi
  echo "${builds[@]+"${builds[@]}"}"
}

# 收集所有 Xcode.app 路徑（mdfind + /Applications 直接掃描，去重）
_collect_xcode_apps() {
  local apps=()
  local seen=""

  # 來源 1：mdfind（Spotlight 索引）
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    # 去重
    case "$seen" in *"|${app}|"*) continue ;; esac
    local bid
    bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${app}/Contents/Info.plist" 2>/dev/null) || continue
    [[ "$bid" == "com.apple.dt.Xcode" ]] || continue
    seen="${seen}|${app}|"
    apps+=("$app")
  done < <(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null)

  # 來源 2：直接掃描 /Applications/Xcode*.app
  for app in /Applications/Xcode*.app; do
    [[ -d "$app" ]] || continue
    case "$seen" in *"|${app}|"*) continue ;; esac
    local bid
    bid=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${app}/Contents/Info.plist" 2>/dev/null) || continue
    [[ "$bid" == "com.apple.dt.Xcode" ]] || continue
    seen="${seen}|${app}|"
    apps+=("$app")
  done

  printf '%s\n' "${apps[@]+"${apps[@]}"}"
}

# 偵測系統已安裝的 Xcode，回傳去重後的 build 清單
# 注意：使用 version.plist 的 ProductBuildVersion，而非 Info.plist 的 DTXcodeBuild
discover_installed_xcode_builds() {
  local builds=()
  local seen=""
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    local build
    build=$(/usr/libexec/PlistBuddy -c "Print :ProductBuildVersion" "${app}/Contents/version.plist" 2>/dev/null) || continue
    case "$seen" in *"|${build}|"*) continue ;; esac
    seen="${seen}|${build}|"
    builds+=("$build")
  done < <(_collect_xcode_apps)
  echo "${builds[@]+"${builds[@]}"}"
}

# 顯示已安裝的 Xcode 資訊
show_installed_xcodes() {
  local found=0
  info "系統已安裝的 Xcode："
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    local version build
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${app}/Contents/version.plist" 2>/dev/null) || continue
    build=$(/usr/libexec/PlistBuddy -c "Print :ProductBuildVersion" "${app}/Contents/version.plist" 2>/dev/null) || continue
    echo -e "  ${CYAN}${app}${NC} — ${version} (${build})"
    found=$((found + 1))
  done < <(_collect_xcode_apps)

  if [[ $found -eq 0 ]]; then
    warn "未偵測到任何已安裝的 Xcode。"
  fi
  echo ""
}

# 清理已解除安裝 Xcode 的遺留 build 目錄
cleanup_stale_xcode_builds() {
  local installed
  installed="|$(discover_installed_xcode_builds | tr ' ' '|')|"

  # 收集遺留目錄
  local stale_dirs=()

  if [[ -d "$XCODE_VERSIONS_DIR" ]]; then
    for dir in "${XCODE_VERSIONS_DIR}"/*/; do
      [[ -d "$dir" ]] || continue
      local build
      build="$(basename "$dir")"
      [[ "$build" == .* ]] && continue
      case "$installed" in *"|${build}|"*) continue ;; esac
      stale_dirs+=("$dir")
    done
  fi

  if [[ -d "$XCODE_XCODE_VERSIONS_DIR" ]]; then
    for dir in "${XCODE_XCODE_VERSIONS_DIR}"/*/; do
      [[ -d "$dir" ]] || continue
      local build
      build="$(basename "$dir")"
      [[ "$build" == .* ]] && continue
      case "$installed" in *"|${build}|"*) continue ;; esac
      stale_dirs+=("$dir")
    done
  fi

  if [[ ${#stale_dirs[@]} -eq 0 ]]; then
    info "無已解除安裝 Xcode 的遺留目錄。"
    echo ""
    return
  fi

  warn "偵測到已解除安裝 Xcode 的遺留目錄："
  for dir in ${stale_dirs[@]+"${stale_dirs[@]}"}; do
    local rel
    rel="${dir#"${XCODE_AGENTS_BASE}/"}"
    echo -e "  ${YELLOW}${rel}${NC}"
  done
  echo ""

  local do_clean=false
  if $CLEAN_STALE; then
    do_clean=true
  else
    read -rp "是否刪除上述遺留目錄？[y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && do_clean=true
  fi

  if $do_clean; then
    for dir in ${stale_dirs[@]+"${stale_dirs[@]}"}; do
      rm -rf "$dir"
      local rel
      rel="${dir#"${XCODE_AGENTS_BASE}/"}"
      info "已刪除：${rel}"
    done
    success "遺留目錄清理完成。"

    # 若目錄清空，移除空目錄並更新旗標
    if [[ -d "$XCODE_VERSIONS_DIR" ]] && [[ -z "$(ls -A "$XCODE_VERSIONS_DIR" 2>/dev/null)" ]]; then
      rmdir "$XCODE_VERSIONS_DIR" 2>/dev/null || true
      HAS_OLD_STRUCTURE=false
      info "Agents/Versions/ 已清空並移除。"
    fi
    if [[ -d "$XCODE_XCODE_VERSIONS_DIR" ]] && [[ -z "$(ls -A "$XCODE_XCODE_VERSIONS_DIR" 2>/dev/null)" ]]; then
      rmdir "$XCODE_XCODE_VERSIONS_DIR" 2>/dev/null || true
      info "Agents/XcodeVersions/ 已清空並移除。"
    fi
  else
    info "已跳過遺留目錄清理。"
  fi
  echo ""
}

# ══════════════════════════════════════
#  工具函式
# ══════════════════════════════════════

# 取得 binary 的版本（如果可執行）
get_binary_version() {
  local binary="$1"
  if [[ -x "$binary" && ! -L "$binary" ]]; then
    "$binary" --version 2>/dev/null || echo "未知"
  elif [[ -L "$binary" ]]; then
    local target
    target="$(readlink "$binary")"
    echo "symlink → ${target}"
  else
    echo "無"
  fi
}

# 從 Info.plist 讀取版本號
get_plist_version() {
  local plist="$1"
  if [[ -f "$plist" ]]; then
    /usr/libexec/PlistBuddy -c "Print :version" "$plist" 2>/dev/null || echo "未知"
  else
    echo "無"
  fi
}

# 產生 Info.plist
write_info_plist() {
  local target_dir="$1"
  local name="$2"
  local version="$3"
  local url="$4"
  local checksum="$5"

  cat > "${target_dir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>checksum</key>
	<string>${checksum}</string>
	<key>name</key>
	<string>${name}</string>
	<key>url</key>
	<string>${url}</string>
	<key>version</key>
	<string>${version}</string>
</dict>
</plist>
PLIST
}

# 備份 binary
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

  # ── 顯示舊結構狀態 ──
  if $HAS_OLD_STRUCTURE; then
    local old_builds=()
    read -ra old_builds <<< "$(discover_old_xcode_builds)" || true

    if [[ ${#old_builds[@]} -gt 0 ]]; then
      info "舊結構（Agents/Versions/）— ${#old_builds[@]} 個 Xcode build："
      for build in ${old_builds[@]+"${old_builds[@]}"}; do
        local bin="${XCODE_VERSIONS_DIR}/${build}/claude"
        local ver_info
        ver_info="$(get_binary_version "$bin")"
        echo -e "  ${CYAN}${build}${NC} — ${ver_info}"
      done
      echo ""
    fi
  fi

  # ── 顯示新結構狀態 ──
  if $HAS_NEW_STRUCTURE; then
    local new_versions=()
    read -ra new_versions <<< "$(discover_new_agent_versions "$XCODE_CLAUDE_AGENTS_DIR")" || true

    if [[ ${#new_versions[@]} -gt 0 ]]; then
      info "新結構（Agents/claude/）— ${#new_versions[@]} 個已安裝版本："
      for ver in ${new_versions[@]+"${new_versions[@]}"}; do
        local plist="${XCODE_CLAUDE_AGENTS_DIR}/${ver}/Info.plist"
        local plist_ver
        plist_ver="$(get_plist_version "$plist")"
        echo -e "  ${CYAN}${ver}${NC} — Info.plist 版本：${plist_ver}"
      done
      echo ""
    fi

    local new_builds=()
    read -ra new_builds <<< "$(discover_new_xcode_builds)" || true

    if [[ ${#new_builds[@]} -gt 0 ]]; then
      info "XcodeVersions/ — ${#new_builds[@]} 個 Xcode build："
      for build in ${new_builds[@]+"${new_builds[@]}"}; do
        local link="${XCODE_XCODE_VERSIONS_DIR}/${build}/claude"
        if [[ -L "$link" ]]; then
          echo -e "  ${CYAN}${build}${NC} — $(readlink "$link")"
        else
          echo -e "  ${CYAN}${build}${NC} — 無 claude symlink"
        fi
      done
      echo ""
    fi
  fi

  # ── 查詢最新版本 ──
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
  if ! $AUTO_YES; then
    read -rp "確認下載並更新？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      warn "已取消。"
      return 0
    fi
  fi

  # ── 下載 binary ──
  info "正在下載 Claude ${latest_version}（${platform_dir}）..."
  local tmp_file
  tmp_file="$(mktemp)"
  if ! curl -fSL --progress-bar -o "$tmp_file" "$download_url"; then
    error "下載失敗。"
    rm -f "$tmp_file"
    return 1
  fi
  chmod +x "$tmp_file"

  local updated=0

  # ── 舊結構更新（Agents/Versions/）──
  if $HAS_OLD_STRUCTURE; then
    local old_builds=()
    read -ra old_builds <<< "$(discover_old_xcode_builds)" || true

    for build in ${old_builds[@]+"${old_builds[@]}"}; do
      local xcode_claude="${XCODE_VERSIONS_DIR}/${build}/claude"

      if [[ ! -e "$xcode_claude" && ! -L "$xcode_claude" ]]; then
        warn "Xcode ${build}（舊）無 claude binary，跳過。"
        continue
      fi

      backup_binary "$xcode_claude" "claude (${build}, 舊結構)"
      rm -f "$xcode_claude"
      cp "$tmp_file" "$xcode_claude"
      chmod +x "$xcode_claude"

      local new_ver
      new_ver="$(get_binary_version "$xcode_claude")"
      success "舊結構 ${build}：已更新 → ${new_ver}"
      updated=$((updated + 1))
    done
  fi

  # ── 新結構更新（Agents/claude/{VERSION}/）──
  if $HAS_NEW_STRUCTURE; then
    local new_ver_dir="${XCODE_CLAUDE_AGENTS_DIR}/${latest_version}"

    if [[ ! -d "$XCODE_CLAUDE_AGENTS_DIR" ]]; then
      mkdir -p "$XCODE_CLAUDE_AGENTS_DIR"
    fi

    if [[ -d "$new_ver_dir" ]]; then
      backup_binary "${new_ver_dir}/claude" "claude (${latest_version}, 新結構)"
    else
      mkdir -p "$new_ver_dir"
    fi

    cp "$tmp_file" "${new_ver_dir}/claude"
    chmod +x "${new_ver_dir}/claude"

    # 產生 Info.plist
    local checksum
    checksum=$(shasum -a 512 "${new_ver_dir}/claude" | awk '{print $1}')
    write_info_plist "$new_ver_dir" "claude" "$latest_version" "$download_url" "$checksum"

    success "新結構：已安裝 claude/${latest_version}/"

    # 更新 XcodeVersions 中的 symlink
    local new_builds=()
    read -ra new_builds <<< "$(discover_new_xcode_builds)" || true

    for build in ${new_builds[@]+"${new_builds[@]}"}; do
      local link_path="${XCODE_XCODE_VERSIONS_DIR}/${build}/claude"
      if [[ -L "$link_path" || -e "$link_path" ]]; then
        rm -f "$link_path"
      fi
      ln -s "${new_ver_dir}" "$link_path"
      success "XcodeVersions/${build}/claude → claude/${latest_version}"
    done

    # 清理舊版本目錄，只保留最新版
    for dir in "${XCODE_CLAUDE_AGENTS_DIR}"/*/; do
      [[ -d "$dir" ]] || continue
      local old_ver
      old_ver="$(basename "$dir")"
      [[ "$old_ver" == .* ]] && continue
      if [[ "$old_ver" != "$latest_version" ]]; then
        rm -rf "$dir"
        info "已清理舊版本：claude/${old_ver}/"
      fi
    done

    updated=$((updated + 1))
  fi

  rm -f "$tmp_file"

  echo ""
  if [[ $updated -eq 0 ]]; then
    warn "沒有任何版本被更新。"
  else
    success "Claude Agent SDK 更新完成（共 ${updated} 處）。"
  fi
}

# ══════════════════════════════════════
#  Codex SDK 更新
# ══════════════════════════════════════

update_codex() {
  echo ""
  echo -e "${BOLD}── Codex SDK ──${NC}"
  echo ""

  # ── 顯示舊結構狀態 ──
  if $HAS_OLD_STRUCTURE; then
    local old_builds=()
    read -ra old_builds <<< "$(discover_old_xcode_builds)" || true

    if [[ ${#old_builds[@]} -gt 0 ]]; then
      info "舊結構（Agents/Versions/）— ${#old_builds[@]} 個 Xcode build："
      for build in ${old_builds[@]+"${old_builds[@]}"}; do
        local bin="${XCODE_VERSIONS_DIR}/${build}/codex"
        local ver_info
        ver_info="$(get_binary_version "$bin")"
        echo -e "  ${CYAN}${build}${NC} — ${ver_info}"
      done
      echo ""
    fi
  fi

  # ── 顯示新結構狀態 ──
  if $HAS_NEW_STRUCTURE; then
    local new_versions=()
    read -ra new_versions <<< "$(discover_new_agent_versions "$XCODE_CODEX_AGENTS_DIR")" || true

    if [[ ${#new_versions[@]} -gt 0 ]]; then
      info "新結構（Agents/codex/）— ${#new_versions[@]} 個已安裝版本："
      for ver in ${new_versions[@]+"${new_versions[@]}"}; do
        local plist="${XCODE_CODEX_AGENTS_DIR}/${ver}/Info.plist"
        local plist_ver
        plist_ver="$(get_plist_version "$plist")"
        echo -e "  ${CYAN}${ver}${NC} — Info.plist 版本：${plist_ver}"
      done
      echo ""
    else
      info "新結構（Agents/codex/）— 尚無已安裝版本"
      echo ""
    fi
  fi

  # ── 查詢最新版本 ──
  info "正在查詢 GitHub 最新版本..."
  local redirect_url
  redirect_url=$(curl -sfSI -o /dev/null -w '%{redirect_url}' "$CODEX_RELEASES_URL" 2>/dev/null || echo "")

  if [[ -z "$redirect_url" ]]; then
    error "無法取得 GitHub Release 資訊，請檢查網路連線。"
    return 1
  fi

  local latest_tag
  latest_tag="${redirect_url##*/}"

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

  local download_url="https://github.com/openai/codex/releases/download/${latest_tag}/${asset_name}"

  echo ""
  info "下載 URL：${download_url}"
  if ! $AUTO_YES; then
    read -rp "確認下載並更新？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      warn "已取消。"
      return 0
    fi
  fi

  # ── 下載並解壓 ──
  info "正在下載 Codex ${latest_tag}（${asset_name}）..."
  local tmp_tar
  tmp_tar="$(mktemp)"
  if ! curl -fSL --progress-bar -o "$tmp_tar" "$download_url"; then
    error "下載失敗。"
    rm -f "$tmp_tar"
    return 1
  fi

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

  # 去除 tag 前綴（例如 codex-v0.1.2 → 0.1.2）取得純版本號
  local codex_version
  codex_version="${latest_tag#codex-}"
  codex_version="${codex_version#v}"

  local updated=0

  # ── 舊結構更新（Agents/Versions/）──
  if $HAS_OLD_STRUCTURE; then
    local old_builds=()
    read -ra old_builds <<< "$(discover_old_xcode_builds)" || true

    for build in ${old_builds[@]+"${old_builds[@]}"}; do
      local xcode_codex="${XCODE_VERSIONS_DIR}/${build}/codex"

      if [[ ! -e "$xcode_codex" && ! -L "$xcode_codex" ]]; then
        warn "Xcode ${build}（舊）無 codex binary，跳過。"
        continue
      fi

      backup_binary "$xcode_codex" "codex (${build}, 舊結構)"
      rm -f "$xcode_codex"
      cp "$codex_bin" "$xcode_codex"
      chmod +x "$xcode_codex"
      xattr -d com.apple.quarantine "$xcode_codex" 2>/dev/null || true

      local new_ver
      new_ver="$(get_binary_version "$xcode_codex")"
      success "舊結構 ${build}：已更新 → ${new_ver}"
      updated=$((updated + 1))
    done
  fi

  # ── 新結構更新（Agents/codex/{VERSION}/）──
  if $HAS_NEW_STRUCTURE; then
    local new_ver_dir="${XCODE_CODEX_AGENTS_DIR}/${codex_version}"

    if [[ ! -d "$XCODE_CODEX_AGENTS_DIR" ]]; then
      mkdir -p "$XCODE_CODEX_AGENTS_DIR"
    fi

    if [[ -d "$new_ver_dir" ]]; then
      backup_binary "${new_ver_dir}/codex" "codex (${codex_version}, 新結構)"
    else
      mkdir -p "$new_ver_dir"
    fi

    cp "$codex_bin" "${new_ver_dir}/codex"
    chmod +x "${new_ver_dir}/codex"
    xattr -d com.apple.quarantine "${new_ver_dir}/codex" 2>/dev/null || true

    # 產生 Info.plist
    local checksum
    checksum=$(shasum -a 512 "${new_ver_dir}/codex" | awk '{print $1}')
    write_info_plist "$new_ver_dir" "codex" "$codex_version" "$download_url" "$checksum"

    success "新結構：已安裝 codex/${codex_version}/"

    # 更新 XcodeVersions 中的 symlink（若存在）
    local new_builds=()
    read -ra new_builds <<< "$(discover_new_xcode_builds)" || true

    for build in ${new_builds[@]+"${new_builds[@]}"}; do
      local link_dir="${XCODE_XCODE_VERSIONS_DIR}/${build}"
      local link_path="${link_dir}/codex"

      if [[ ! -d "$link_dir" ]]; then
        continue
      fi

      if [[ -L "$link_path" || -e "$link_path" ]]; then
        rm -f "$link_path"
      fi
      ln -s "${new_ver_dir}" "$link_path"
      success "XcodeVersions/${build}/codex → codex/${codex_version}"
    done

    # 清理舊版本目錄，只保留最新版
    for dir in "${XCODE_CODEX_AGENTS_DIR}"/*/; do
      [[ -d "$dir" ]] || continue
      local old_ver
      old_ver="$(basename "$dir")"
      [[ "$old_ver" == .* ]] && continue
      if [[ "$old_ver" != "$codex_version" ]]; then
        rm -rf "$dir"
        info "已清理舊版本：codex/${old_ver}/"
      fi
    done

    updated=$((updated + 1))
  fi

  rm -rf "$tmp_dir"

  echo ""
  if [[ $updated -eq 0 ]]; then
    warn "沒有任何版本被更新。"
  else
    success "Codex SDK 更新完成（共 ${updated} 處）。"
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

# 先驗證選擇是否有效
case "$choice" in
  1|2|3) ;;
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

# ── 互動式選項（僅在未透過 flag 指定時顯示）──
if ! $AUTO_YES || ! $CLEAN_BACKUPS || ! $CLEAN_STALE; then
  echo ""
  echo -e "${BOLD}── 額外選項 ──${NC}"
  echo ""

  if ! $AUTO_YES; then
    echo -e "  ${CYAN}a)${NC} 允許自動下載並更新（等同 --allow-autoupdate）"
  fi
  if ! $CLEAN_BACKUPS; then
    echo -e "  ${CYAN}b)${NC} 清理所有 backup 檔案（等同 --clean-backups）"
  fi
  if ! $CLEAN_STALE; then
    echo -e "  ${CYAN}c)${NC} 清理已解除安裝 Xcode 的遺留目錄（等同 --clean-stale-builds）"
  fi
  echo ""
  echo -e "  可多選，例如輸入 ${CYAN}abc${NC}；直接按 Enter 跳過。"
  echo ""

  read -rp "請選擇額外選項 [abc/Enter 跳過]: " extra
  [[ "$extra" == *a* ]] && AUTO_YES=true
  [[ "$extra" == *b* ]] && CLEAN_BACKUPS=true
  [[ "$extra" == *c* ]] && CLEAN_STALE=true
fi

# ── 顯示已安裝的 Xcode 與清理遺留目錄 ──
show_installed_xcodes
cleanup_stale_xcode_builds

# ── 執行更新 ──
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
esac

# ── 清理 backup 檔案 ──
if $CLEAN_BACKUPS; then
  echo ""
  info "正在清理 Agents/ 下的 backup 檔案..."
  local_cleaned=0
  while IFS= read -r -d '' bak; do
    rm -rf "$bak"
    info "已刪除：${bak}"
    local_cleaned=$((local_cleaned + 1))
  done < <(find "$XCODE_AGENTS_BASE" -name "*.backup.*" -print0 2>/dev/null)

  if [[ $local_cleaned -eq 0 ]]; then
    info "沒有找到任何 backup 檔案。"
  else
    success "共清理 ${local_cleaned} 個 backup 檔案。"
  fi
fi

echo ""
echo -e "${GREEN}${BOLD}完成！請重新啟動 Xcode 以套用變更。${NC}"
echo ""

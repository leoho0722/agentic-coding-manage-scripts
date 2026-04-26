#!/usr/bin/env bash
#
# sync-mcp-servers.sh
#
# 從 mcp/servers.json 同步 MCP 設定到所有支援工具的 config 檔。
#
# 支援的工具 / target：
#   - claude-code         (configs/claude-code/.claude.json   → .mcpServers)
#   - xcode-claude        (configs/xcode-claude/.claude.json  → .mcpServers)
#   - opencode            (configs/opencode/opencode.json     → .mcp)
#   - google-antigravity  (configs/google-antigravity/mcp_config.json → .mcpServers)
#   - openai-codex        (configs/openai-codex/config.toml   → [mcp_servers.*])
#   - xcode-codex         (configs/xcode-codex/config.toml    → [mcp_servers.*])
#
# 用法：
#   bash scripts/sync-mcp-servers.sh             # 正常同步
#   bash scripts/sync-mcp-servers.sh --dry-run   # 預覽（不寫入）
#   bash scripts/sync-mcp-servers.sh -n          # 同上
#   bash scripts/sync-mcp-servers.sh --dry-run --diff  # 預覽 + 彩色 diff
#
# 註：openai-codex / xcode-codex 不支援 http transport。
#     若 http server 需同步到 codex，請在該 server 加上 codex-fallback 欄位，
#     提供等價的 stdio 設定（transport/command/args/env）。沒有 fallback 者會 warn 並跳過。
#

set -euo pipefail

# ── 路徑設定 ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGS_DIR="${ROOT_DIR}/configs"
MCP_DIR="${ROOT_DIR}/mcp"
SOURCE_FILE="${MCP_DIR}/servers.json"
EXAMPLE_FILE="${MCP_DIR}/servers.example.json"

# ── 顏色輸出 ──
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# 所有 log 一律輸出到 stderr，避免污染 build_section/read_current 等函式的
# stdout（這些 stdout 會被 $(...) 捕獲為 JSON / TOML 資料）。
info()    { echo -e "${CYAN}[INFO]${NC}  $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── 參數解析 ──
DRY_RUN=0
SHOW_DIFF=0

usage() {
  cat <<EOF
用法：
  bash scripts/sync-mcp-servers.sh [options]

Options:
  -n, --dry-run    僅預覽變更，不實際寫入檔案
      --diff       搭配 --dry-run，顯示 unified diff（彩色）
  -h, --help       顯示本說明
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    --diff)       SHOW_DIFF=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) error "未知參數：$1"; usage >&2; exit 2 ;;
  esac
done

if [[ $SHOW_DIFF -eq 1 && $DRY_RUN -eq 0 ]]; then
  warn "--diff 僅在 --dry-run 時生效，已自動忽略"
  SHOW_DIFF=0
fi

# ── 環境檢查 ──
command -v jq      >/dev/null 2>&1 || { error "需要 jq";      exit 1; }
command -v python3 >/dev/null 2>&1 || { error "需要 python3"; exit 1; }
command -v git     >/dev/null 2>&1 || { error "需要 git";     exit 1; }

# Codex TOML 處理依賴 Python 3.11+ 內建的 tomllib
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
  py_ver=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null || echo "unknown")
  error "需要 Python 3.11+（tomllib 為內建模組），目前版本：${py_ver}"
  exit 1
fi

if [[ ! -f "$SOURCE_FILE" ]]; then
  error "找不到來源檔：${SOURCE_FILE}"
  if [[ -f "$EXAMPLE_FILE" ]]; then
    info "請先複製範例：cp '${EXAMPLE_FILE}' '${SOURCE_FILE}'"
  fi
  exit 1
fi

# ── Schema 驗證 ──
SCHEMA_ERR=$(jq -r '
  (.servers // {}) as $servers
  | [
      ($servers | to_entries[]) as $e
      | (
          (if (($e.value.transport // "") | IN("stdio", "http")) | not
           then "[\($e.key)] transport 必須為 stdio 或 http" else empty end),
          (if $e.value.transport == "stdio" and (($e.value.command // "") == "")
           then "[\($e.key)] stdio 必須設定 command" else empty end),
          (if $e.value.transport == "http" and (($e.value.url // "") == "")
           then "[\($e.key)] http 必須設定 url" else empty end),
          (if (($e.value.targets // []) | length) == 0
           then "[\($e.key)] targets 不能為空" else empty end),
          # codex-fallback 驗證
          (($e.value["codex-fallback"]) as $fb
           | if $fb != null then
               (if $e.value.transport != "http"
                then "[\($e.key)] codex-fallback 僅在 transport=http 時有意義" else empty end),
               (if (($fb.transport // "stdio") != "stdio")
                then "[\($e.key)] codex-fallback.transport 必須為 stdio" else empty end),
               (if (($fb.command // "") == "")
                then "[\($e.key)] codex-fallback 必須設定 command" else empty end)
             else empty end)
        )
    ]
  | .[]
' "$SOURCE_FILE")

if [[ -n "$SCHEMA_ERR" ]]; then
  error "Schema 驗證失敗："
  echo "$SCHEMA_ERR" | sed 's/^/  /' >&2
  exit 1
fi

# ── 工具定義（bash 3.2 相容：parallel arrays）──
TOOL_NAMES=(claude-code xcode-claude opencode google-antigravity openai-codex xcode-codex)
TOOL_FILES=(
  "${CONFIGS_DIR}/claude-code/.claude.json"
  "${CONFIGS_DIR}/xcode-claude/.claude.json"
  "${CONFIGS_DIR}/opencode/opencode.json"
  "${CONFIGS_DIR}/google-antigravity/mcp_config.json"
  "${CONFIGS_DIR}/openai-codex/config.toml"
  "${CONFIGS_DIR}/xcode-codex/config.toml"
)
# format: claude | opencode | antigravity | codex
TOOL_FORMATS=(claude claude opencode antigravity codex codex)

# 變更追蹤（哪些工具有實際差異）
CHANGED_TOOLS=()

# 暫存檔清理
TMP_FILES=()
cleanup() {
  for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do
    [[ -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup EXIT

# ── 轉換：universal schema → 各工具 native shape ──
build_section() {
  local tool="$1"
  local format="$2"

  # 先取出歸屬於此 tool 的 servers
  local filtered
  filtered=$(jq --arg tool "$tool" '
    .servers
    | with_entries(select((.value.targets // []) | index($tool)))
  ' "$SOURCE_FILE")

  # Codex 系列：http server 若帶 codex-fallback 則改用 fallback（壓平成 stdio）；
  # 沒 fallback 的 http server 則 warn 並跳過。
  if [[ "$format" == "codex" ]]; then
    local skip_names
    skip_names=$(echo "$filtered" | jq -r '
      to_entries[]
      | select(.value.transport == "http" and (.value["codex-fallback"] // null) == null)
      | .key
    ')
    if [[ -n "$skip_names" ]]; then
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        warn "${tool}: 跳過 ${name}（http transport 不支援，且未設定 codex-fallback）"
      done <<< "$skip_names"
    fi

    # 套用 fallback：把帶 codex-fallback 的 http entry 替換成 fallback 的 stdio 設定，
    # 並保留原本的 targets；其餘 http entry 過濾掉。
    filtered=$(echo "$filtered" | jq '
      with_entries(
        if .value.transport == "http" and (.value["codex-fallback"] // null) != null then
          .value = (.value["codex-fallback"] + {targets: .value.targets})
        else
          .
        end
      )
      | with_entries(select(.value.transport != "http"))
    ')
  fi

  case "$format" in
    claude|antigravity)
      echo "$filtered" | jq '
        with_entries(
          .value |= (
            if .transport == "http" then
              ({type: "http", url: .url}
               + (if (.headers // {}) != {} then {headers: .headers} else {} end))
            else
              {type: "stdio", command: .command, args: (.args // []), env: (.env // {})}
            end
          )
        )
      '
      ;;
    opencode)
      # OpenCode 的 stdio env 欄位名稱為 "environment"（非 env）
      echo "$filtered" | jq '
        with_entries(
          .value |= (
            if .transport == "http" then
              ({type: "remote", url: .url}
               + (if (.headers // {}) != {} then {headers: .headers} else {} end))
            else
              ({type: "local", command: ([.command] + (.args // []))}
               + (if (.env // {}) != {} then {environment: .env} else {} end))
            end
          )
        )
      '
      ;;
    codex)
      echo "$filtered" | jq '
        with_entries(
          .value |= (
            {command: .command}
            + (if (.args // []) != [] then {args: .args} else {} end)
            + (if (.env // {}) != {} then {env: .env} else {} end)
          )
        )
      '
      ;;
  esac
}

# ── 讀取目前各工具的 MCP 區段（轉成同樣 JSON 物件以利比對）──
read_current() {
  local file="$1"
  local format="$2"

  if [[ ! -f "$file" ]]; then
    echo '{}'
    return
  fi

  case "$format" in
    claude|antigravity)
      jq '.mcpServers // {}' "$file"
      ;;
    opencode)
      jq '.mcp // {}' "$file"
      ;;
    codex)
      python3 - "$file" <<'PY'
import sys, json, tomllib
with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)
print(json.dumps(data.get('mcp_servers', {}) or {}))
PY
      ;;
  esac
}

# ── 印出比對摘要；同時更新 has_change 全域變數 ──
HAS_CHANGE=0
print_summary() {
  local tool="$1"
  local file="$2"
  local current_json="$3"
  local new_json="$4"

  HAS_CHANGE=0

  local current_keys new_keys
  current_keys=$(echo "$current_json" | jq -r 'keys_unsorted[]' 2>/dev/null | sort -u || true)
  new_keys=$(echo "$new_json"     | jq -r 'keys_unsorted[]' 2>/dev/null | sort -u || true)

  local added removed both
  added=$(comm -13 <(echo "$current_keys") <(echo "$new_keys") || true)
  removed=$(comm -23 <(echo "$current_keys") <(echo "$new_keys") || true)
  both=$(comm -12 <(echo "$current_keys") <(echo "$new_keys") || true)

  echo -e "  ${BOLD}[${tool}]${NC} ${DIM}${file}${NC}"

  local printed=0

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    echo -e "    ${GREEN}+${NC} ${name}  ${DIM}(新增)${NC}"
    HAS_CHANGE=1
    printed=1
  done <<< "$added"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local cur new
    cur=$(echo "$current_json" | jq --arg k "$name" -S '.[$k]')
    new=$(echo "$new_json"     | jq --arg k "$name" -S '.[$k]')
    if [[ "$cur" != "$new" ]]; then
      echo -e "    ${YELLOW}~${NC} ${name}  ${DIM}(更新)${NC}"
      HAS_CHANGE=1
    else
      echo -e "    ${DIM}= ${name}  (無變化)${NC}"
    fi
    printed=1
  done <<< "$both"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    echo -e "    ${RED}-${NC} ${name}  ${DIM}(移除)${NC}"
    HAS_CHANGE=1
    printed=1
  done <<< "$removed"

  if [[ $printed -eq 0 ]]; then
    echo -e "    ${DIM}(無 server 套用至此工具)${NC}"
  fi
}

# ── 寫入 JSON：把 .key = blob 套用到 input，輸出至 output ──
write_json_section() {
  local input="$1"
  local output="$2"
  local key="$3"
  local blob="$4"

  if [[ ! -f "$input" ]]; then
    error "目標檔不存在，無法寫入：${input}"
    return 1
  fi

  local tmp
  tmp=$(mktemp)
  TMP_FILES+=("$tmp")
  jq --argjson new "$blob" "${key} = \$new" "$input" > "$tmp"
  mv "$tmp" "$output"
}

# ── 寫入 TOML：替換 [mcp_servers.*] 區段 ──
write_toml_section() {
  local input="$1"
  local output="$2"
  local blob="$3"

  if [[ ! -f "$input" ]]; then
    error "目標檔不存在，無法寫入：${input}"
    return 1
  fi

  python3 - "$input" "$output" "$blob" <<'PY'
import sys, json, re, tomllib

input_path, output_path, blob_json = sys.argv[1], sys.argv[2], sys.argv[3]
mcp_servers = json.loads(blob_json)

with open(input_path, 'r', encoding='utf-8') as f:
    content = f.read()

# 先驗證原檔是合法 TOML
with open(input_path, 'rb') as f:
    try:
        tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        sys.stderr.write(f"原檔 TOML 格式錯誤：{e}\n")
        sys.exit(1)

# 移除既有的 [mcp_servers.X] 區段
# 規則：遇到 ^[mcp_servers.NAME] 起算，到下一個頂層 section（^[ 或 ^[[）或檔尾為止
lines = content.split('\n')
result = []
skipping = False
for line in lines:
    stripped = line.lstrip()
    if stripped.startswith('[mcp_servers.') or stripped.startswith('[mcp_servers]'):
        skipping = True
        continue
    if skipping:
        # 任何頂層 section（單括號 table 或雙括號 array-of-tables）皆終止 skip
        if stripped.startswith('['):
            skipping = False
            result.append(line)
        # else 仍在舊區段內 → 跳過
    else:
        result.append(line)

# 收尾：去掉末尾連續空行
while result and result[-1].strip() == '':
    result.pop()

def emit_value(v):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, int) and not isinstance(v, bool):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, str):
        escaped = v.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
        return f'"{escaped}"'
    if isinstance(v, list):
        return '[' + ', '.join(emit_value(x) for x in v) + ']'
    if isinstance(v, dict):
        pairs = ', '.join(f'{emit_key(k)} = {emit_value(val)}' for k, val in v.items())
        return '{ ' + pairs + ' }'
    raise ValueError(f"Unsupported value type: {type(v).__name__}")

def emit_key(k):
    if re.match(r'^[A-Za-z0-9_-]+$', k):
        return k
    escaped = k.replace('\\', '\\\\').replace('"', '\\"')
    return f'"{escaped}"'

new_blocks = []
for name, cfg in mcp_servers.items():
    new_blocks.append('')
    new_blocks.append(f'[mcp_servers.{emit_key(name)}]')
    for key, val in cfg.items():
        new_blocks.append(f'{emit_key(key)} = {emit_value(val)}')

output = '\n'.join(result)
if output and not output.endswith('\n'):
    output += '\n'
if new_blocks:
    output += '\n'.join(new_blocks) + '\n'

with open(output_path, 'w', encoding='utf-8') as f:
    f.write(output)
PY
}

# ── 套用變更（共用 entry：寫到 output_path）──
apply_to() {
  local file="$1"
  local format="$2"
  local blob="$3"
  local output="$4"

  case "$format" in
    claude|antigravity)
      write_json_section "$file" "$output" '.mcpServers' "$blob"
      ;;
    opencode)
      write_json_section "$file" "$output" '.mcp' "$blob"
      ;;
    codex)
      write_toml_section "$file" "$output" "$blob"
      ;;
  esac
}

# ── 顯示 diff（彩色）──
show_diff() {
  local original="$1"
  local modified="$2"
  # git diff 在 dry-run 場景固定要彩色，所以用 --color=always；終端機與 less -R 都能正常顯示
  git --no-pager diff --no-index --color=always "$original" "$modified" || true
}

# ── 備份 ──
backup_file() {
  local file="$1"
  local backup="${file}.backup.$(date +%Y%m%d%H%M%S)"
  cp "$file" "$backup"
  info "已備份：${backup}"
}

# ── 主流程 ──
echo ""
echo -e "${BOLD}========================================"
echo -e "  MCP Servers Sync"
echo -e "========================================${NC}"
echo ""
info "來源：${SOURCE_FILE}"
if [[ $DRY_RUN -eq 1 ]]; then
  warn "DRY-RUN 模式：不會寫入任何檔案"
fi
echo ""

for i in "${!TOOL_NAMES[@]}"; do
  tool="${TOOL_NAMES[$i]}"
  file="${TOOL_FILES[$i]}"
  format="${TOOL_FORMATS[$i]}"

  if [[ ! -f "$file" ]]; then
    warn "[${tool}] 找不到設定檔，跳過：${file}"
    echo ""
    continue
  fi

  blob=$(build_section "$tool" "$format")
  current=$(read_current "$file" "$format")

  print_summary "$tool" "$file" "$current" "$blob"

  if [[ $HAS_CHANGE -eq 1 ]]; then
    CHANGED_TOOLS+=("$tool")
    if [[ $DRY_RUN -eq 1 ]]; then
      if [[ $SHOW_DIFF -eq 1 ]]; then
        tmp=$(mktemp)
        TMP_FILES+=("$tmp")
        apply_to "$file" "$format" "$blob" "$tmp"
        echo ""
        show_diff "$file" "$tmp"
      fi
    else
      backup_file "$file"
      apply_to "$file" "$format" "$blob" "$file"
      success "[${tool}] 已寫入 ${file}"
    fi
  fi
  echo ""
done

# ── Summary ──
echo -e "${BOLD}========================================"
echo -e "  結果"
echo -e "========================================${NC}"
echo ""

if [[ ${#CHANGED_TOOLS[@]} -eq 0 ]]; then
  success "所有工具的 MCP 設定皆與來源一致，無需更動。"
  echo ""
  exit 0
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo -e "${YELLOW}DRY-RUN：未寫入任何檔案。${NC}"
  echo ""
  echo "若實際執行，將會更新下列工具："
  for t in "${CHANGED_TOOLS[@]}"; do
    echo "  • ${t}"
  done
  echo ""
  exit 0
fi

# ── Reload 提示（僅針對實際有變更的工具）──
echo -e "${BOLD}下列工具的 MCP 設定已更新，請重新載入後變更才會生效：${NC}"
echo ""

# 用旗標避免重複印 Xcode 兩行
printed_xcode=0
for t in "${CHANGED_TOOLS[@]}"; do
  case "$t" in
    claude-code)
      echo "  • Claude Code            → 結束目前 session 重啟，或執行 /mcp 重新連線"
      ;;
    opencode)
      echo "  • OpenCode               → 結束 opencode 後重新啟動"
      ;;
    google-antigravity)
      echo "  • Google Antigravity     → 重啟 Antigravity"
      ;;
    openai-codex)
      echo "  • OpenAI Codex (CLI)     → 結束目前 codex session 重啟"
      ;;
    xcode-claude|xcode-codex)
      if [[ $printed_xcode -eq 0 ]]; then
        echo "  • Xcode (Claude / Codex) → 重啟 Xcode 或重新開啟 Coding Assistant 視窗"
        printed_xcode=1
      fi
      ;;
  esac
done

echo ""

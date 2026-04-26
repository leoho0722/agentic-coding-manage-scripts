# Agentic Coding Tools — 集中管理工具

本專案是 Agentic Coding Tools 的設定檔與腳本集中管理中心。透過 symlink 機制，將設定檔（configs）與技能模組（skills）統一管理並分發至各個 AI 編碼工具。

## 專案結構

```text
.
├── setup-symlinks.sh                # 主入口腳本（互動式選單）
├── scripts/
│   ├── setup-configs-symlinks.sh    # 設定檔 symlink 腳本
│   ├── setup-skills-symlinks.sh     # Skills 目錄 symlink 腳本
│   ├── update-xcode-agents.sh       # Xcode 內建 Agent SDK 更新腳本
│   ├── update-flutter-skills.sh     # Flutter Skills 安裝／更新腳本
│   └── sync-mcp-servers.sh          # MCP servers 統一同步腳本
├── configs/                         # 各工具的 native 設定檔（不納入版控）
│   ├── claude-code/
│   ├── opencode/
│   ├── google-antigravity/
│   ├── openai-codex/
│   ├── xcode-claude/
│   └── xcode-codex/
├── mcp/                             # MCP servers 統一來源
│   ├── servers.example.json         # 範例 schema（入版控）
│   └── servers.json                 # 實際設定（不納入版控）
└── skills/                          # 共用的 skills 模組（不納入版控）
```

## 支援的工具

| 工具                       | 設定檔路徑                                                     | Skills 路徑                     |
|----------------------------|----------------------------------------------------------------|---------------------------------|
| Claude Code                | `~/.claude/`                                                   | `~/.claude/skills/`             |
| OpenCode                   | `~/.config/opencode/`                                          | `~/.config/opencode/skills/`    |
| Google Antigravity         | `~/.gemini/antigravity/`                                       | `~/.gemini/antigravity/skills/` |
| OpenAI Codex               | `~/.codex/`                                                    | `~/.codex/skills/`              |
| Xcode Claude Agent (26.3)  | `~/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/` | 同左 `/skills/`                 |
| Xcode Claude Agent (26.4+) | `~/Library/Developer/Xcode/CodingAssistant/Agents/claude/`     | 同左 `/skills/`                 |
| Xcode Codex (26.3)         | `~/Library/Developer/Xcode/CodingAssistant/codex/`             | 同左 `/skills/`                 |
| Xcode Codex (26.4+)        | `~/Library/Developer/Xcode/CodingAssistant/Agents/codex/`      | 同左 `/skills/`                 |

## 腳本使用方式

### 主入口

```bash
chmod +x setup-symlinks.sh
./setup-symlinks.sh
```

透過互動式選單選擇操作：

1. **Configs** — 建立設定檔 symlink
2. **Skills** — 建立共用 skills 目錄 symlink
3. **All Symlinks** — 同時建立 Configs 與 Skills 的 symlink
4. **Xcode Agents** — 從官方來源更新 Xcode 內建的 Claude Agent SDK / Codex SDK
5. **Flutter Skills** — 安裝／更新 Flutter skills（from github.com/flutter/skills）
6. **MCP Servers** — 從 `mcp/servers.json` 同步 MCP 設定到所有工具

### 個別執行

```bash
bash scripts/setup-configs-symlinks.sh
bash scripts/setup-skills-symlinks.sh
bash scripts/update-xcode-agents.sh
bash scripts/update-flutter-skills.sh
bash scripts/sync-mcp-servers.sh
```

### update-xcode-agents.sh Flags

```bash
bash scripts/update-xcode-agents.sh --allow-autoupdate     # 自動確認所有下載
bash scripts/update-xcode-agents.sh --clean-backups        # 更新後自動清理 backup 檔案
bash scripts/update-xcode-agents.sh --clean-stale-builds   # 自動清理已解除安裝 Xcode 的遺留目錄
```

未提供 flag 時，腳本會在選完更新目標後顯示互動式額外選項選單供多選。

### sync-mcp-servers.sh Flags

```bash
bash scripts/sync-mcp-servers.sh                   # 正常同步
bash scripts/sync-mcp-servers.sh --dry-run         # 預覽變更，不寫入
bash scripts/sync-mcp-servers.sh -n                # --dry-run 短旗標
bash scripts/sync-mcp-servers.sh --dry-run --diff  # 預覽 + 彩色 unified diff
```

## MCP 統一設定

所有工具的 MCP servers 集中由 `mcp/servers.json` 管理，透過 `sync-mcp-servers.sh` 分發到各工具的 native 設定格式。`mcp/` 與 `configs/` 分離：前者是「分發來源」，後者是「各工具被分發到的 native 設定」。

### Schema

```jsonc
{
  "servers": {
    "<server-name>": {
      "transport": "stdio" | "http",
      // stdio：
      "command": "npx",
      "args": ["-y", "..."],
      "env": { "KEY": "value" },
      // http：
      "url": "https://...",
      "headers": { "X-Api-Key": "..." },
      // 共用：
      "targets": ["claude-code", "xcode-claude", "opencode",
                  "google-antigravity", "openai-codex", "xcode-codex"]
    }
  }
}
```

- `targets` 列出此 server 要分發到哪些工具；未列入者會在 sync 時從該工具設定中**移除**（保證同步後狀態 = 來源狀態）。
- `openai-codex` / `xcode-codex` 不支援 `http` transport，遇到時會 warn 並跳過。
- 來源檔 `servers.json` 不入版控（含 secrets）；`servers.example.json` 入版控供初始化參考。

### Reload 提示

實際寫入後（非 dry-run），腳本會列出哪些工具有變更並提示如何重新載入：

- Claude Code：結束 session 重啟，或 `/mcp` 重新連線
- Xcode（Claude / Codex）：重啟 Xcode 或重新開啟 Coding Assistant 視窗
- OpenCode：結束 opencode 後重新啟動
- Google Antigravity：重啟 Antigravity
- OpenAI Codex (CLI)：結束 codex session 重啟

## 開發慣例

- **Shell 腳本風格**：所有 bash 腳本開頭加上 `set -euo pipefail`
- **Shebang**：使用 `#!/usr/bin/env bash`
- **註解語言**：使用正體中文撰寫註解與說明
- **腳本檔頭**：包含用途說明、支援工具清單、用法範例
- **備份機制**：建立 symlink 前，若目標已存在會自動備份為 `*.backup.<timestamp>`
- **顏色輸出**：使用統一的 `info()` / `success()` / `warn()` / `error()` 函式
- **Bash 相容性**：須相容 macOS 內建 bash 3.2（不可使用 associative array `declare -A`、空陣列展開需用 `${arr[@]+"${arr[@]}"}` 防止 `set -u` 報錯）

## Commit 風格

使用正體中文撰寫 conventional commits，description（body）使用列點格式，例如：

- `feat(s010): 實作 ApiService（AWS Amplify SDK + 非同步任務模式）`
- `fix: 修正下載進度對話框在 build 期間觸發 setState`

```text
refactor(settings-view): 設定頁面 Cupertino → Material 3 重構

- 移除所有 Cupertino 元件
- 統一採用 Material 3 Card.filled + ListTile 呈現
```

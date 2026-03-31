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
│   └── update-flutter-skills.sh     # Flutter Skills 安裝／更新腳本
├── configs/                         # 各工具的設定檔（不納入版控）
│   ├── claude-code/
│   ├── opencode/
│   ├── google-antigravity/
│   ├── openai-codex/
│   ├── xcode-claude/
│   └── xcode-codex/
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

### 個別執行

```bash
bash scripts/setup-configs-symlinks.sh
bash scripts/setup-skills-symlinks.sh
bash scripts/update-xcode-agents.sh
bash scripts/update-flutter-skills.sh
```

### update-xcode-agents.sh Flags

```bash
bash scripts/update-xcode-agents.sh --allow-autoupdate     # 自動確認所有下載
bash scripts/update-xcode-agents.sh --clean-backups        # 更新後自動清理 backup 檔案
bash scripts/update-xcode-agents.sh --clean-stale-builds   # 自動清理已解除安裝 Xcode 的遺留目錄
```

未提供 flag 時，腳本會在選完更新目標後顯示互動式額外選項選單供多選。

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

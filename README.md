# LLM Usage Bar

Mac 菜单栏小工具，监测 **Codex** 的额度使用情况——不看「消耗了多少 token」，而看**周期内占比**和**距离下次重置还有多久**，免去每次点开客户端查看。

菜单栏长这样：`CX 16%`。占比 ≥75% 变橙、≥90% 变红。展示格式对齐客户端：`占比 % · 重置 2d`。

> **关于 Claude Code**：曾计划一并监测，但 Claude 不把官方额度百分比写到本地（`/usage` 是运行时实时从 API 拉的），而 OAuth token 被 Anthropic 有意限制只能官方客户端用，直连一律 `403 Request not allowed`。本地只能做**估算**，给不了精准值，故移除。详见 [issue 讨论 / 提交历史]。Codex 不同——它把官方额度写进了本地文件，可以读到**精确值**。

## 数据来源（全部本地读取，不联网）

读取 `~/.codex/sessions/YYYY/MM/DD/*.jsonl` 里最新的 `token_count` 事件，取其中的官方 `rate_limits`：

```jsonc
"rate_limits": {
  "primary":   { "used_percent": 16.0, "window_minutes": 43200, "resets_at": 1783148678 },
  "secondary": { ... }
}
```

| 字段 | 含义 | 展示 |
|------|------|------|
| `used_percent` | 官方占比 | `16%` |
| `window_minutes` | 窗口长度 | `43200` → 30天额度 |
| `resets_at` | 重置时间戳 | `重置 21d` |

`primary` / `secondary` 分别对应不同窗口（如 30 天 / 周），都会列出。**全部官方精确值，零估算。**

## 构建 & 运行

标准 **Xcode App 工程**。

```bash
open LLMUsageBar.xcodeproj   # 用 Xcode 打开，⌘R 运行（菜单栏出现 CX 文字）
```

在 Xcode 里：选中 target → **Signing & Capabilities** 选你的 Team（本地运行用默认 "Sign to Run Locally" 即可），⌘R 运行、⌘B 构建，打包分发用 **Product → Archive**。

命令行构建：

```bash
xcodebuild -project LLMUsageBar.xcodeproj -scheme LLMUsageBar -configuration Release build
# 产物在 ~/Library/Developer/Xcode/DerivedData/.../Build/Products/Release/LLMUsageBar.app
```

排查用文本模式（不弹菜单栏，打印后退出）：

```bash
/path/to/LLMUsageBar.app/Contents/MacOS/LLMUsageBar --once
```

> 工程文件由 [XcodeGen](https://github.com/yonsm/XcodeGen) 从 `project.yml` 生成（已 commit，clone 后可直接打开）。增删源文件后用 `xcodegen generate` 重新生成 `.xcodeproj`。

退出：点菜单栏 → 退出（⌘Q）。

## 设置

菜单里「设置…」打开 `~/.config/llm-usage-bar/config.json`：

```json
{ "refreshSeconds": 60 }
```

Codex 读的是官方值，没什么要调的，主要就是刷新频率。

## 开机自启（可选）

```bash
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/local.llmusagebar.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.llmusagebar</string>
  <key>ProgramArguments</key><array><string>/Applications/LLMUsageBar.app/Contents/MacOS/LLMUsageBar</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
launchctl load ~/Library/LaunchAgents/local.llmusagebar.plist
```

## 已知限制

- **必须用官方 OpenAI Codex 套餐**才有官方额度。用自定义/中转供应商（如 aigocode）时，客户端不返回 `rate_limits`（为 null），此时只能显示本会话 token 总量。
- 只在 Codex 客户端写过会话后才有数据；菜单栏显示的是最近一次会话的额度状态。
- 仅读取本地客户端数据，网页版额度本地无数据，不在范围内。

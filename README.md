# LLM Usage Bar

Mac 菜单栏小工具，监测 **Claude Code** 和 **Codex** 的额度使用情况——不看「消耗了多少 token」，而看**周期内占比**和**距离下次重置还有多久**，免去每次点开客户端切 Tab。

菜单栏长这样：`CC 69%  CX 16%`（点开看详情）。占比 ≥75% 变橙、≥90% 变红。

## 数据来源（全部本地读取，不联网）

| 提供方 | 来源 | 占比 | 重置时间 |
|--------|------|------|----------|
| Claude Code | `~/.claude/projects/**/*.jsonl` 每条消息的 `usage` | **估算**（本地加权 token ÷ 可配置额度） | **精确**（5h 滚动窗口） |
| Codex | `~/.codex/sessions/**/*.jsonl` 的 `token_count` 事件 | **官方精确**（`rate_limits.used_percent`） | **官方精确**（`resets_at`） |

> Codex 直接读取客户端落盘的官方 `rate_limits`，零估算。
> Claude 客户端**没有**把官方额度百分比写到本地，所以 Claude 的占比是基于「本地 token 聚合 ÷ 你填的额度上限」的估算——**5h 重置时间是准的，百分比需要校准**。

## 构建 & 运行

这是标准的 **Xcode App 工程**。

```bash
open LLMUsageBar.xcodeproj   # 用 Xcode 打开，点 ▶︎ 构建运行（菜单栏出现仪表盘图标）
```

在 Xcode 里：选中 target → **Signing & Capabilities** 选你的 Team（本地运行用默认的 "Sign to Run Locally" 即可），然后 ⌘R 运行、⌘B 构建。打包分发用 **Product → Archive**。

也可命令行构建：

```bash
xcodebuild -project LLMUsageBar.xcodeproj -scheme LLMUsageBar -configuration Release build
# 产物在 ~/Library/Developer/Xcode/DerivedData/.../Build/Products/Release/LLMUsageBar.app
```

排查数字用文本模式（不弹菜单栏，打印后退出）：

```bash
/path/to/LLMUsageBar.app/Contents/MacOS/LLMUsageBar --once
```

> 工程文件由 [XcodeGen](https://github.com/yonsm/XcodeGen) 从 `project.yml` 生成（已 commit，clone 后可直接打开）。改了源文件增删后用 `xcodegen generate` 重新生成 `.xcodeproj`。

退出：点菜单栏图标 → 退出（⌘Q）。

## 校准 Claude 占比

菜单里「校准额度 / 设置…」会打开 `~/.config/llm-usage-bar/config.json`：

```json
{
  "claudeFiveHourTokenBudget": 20000000,   // 5h 窗口的加权 token 额度（分母）
  "claudeWeeklyTokenBudget": 500000000,    // 7天窗口额度，设 0 隐藏该行
  "claudeWeightInput": 1.0,
  "claudeWeightCacheCreation": 1.0,
  "claudeWeightCacheRead": 0.1,            // 缓存读取量极大、单价低，默认降权
  "claudeWeightOutput": 1.0,
  "refreshSeconds": 60
}
```

**怎么校准**：在 Claude Code 里跑 `/usage` 看官方显示的 5h 占比，对照本工具菜单里显示的「5h 窗口 token 数」，反推出额度填进 `claudeFiveHourTokenBudget`。例：官方显示 50%、此刻菜单显示 10M token，则额度 ≈ 20M。改完保存，下次刷新（≤60s）生效。

`cache_read` 默认按 0.1 权重计入——它的量通常是其它部分的几十倍，全权重会把占比撑爆。

### 可选：给 Claude 周额度一个真实重置倒计时

默认 7 天是「滚动」窗口，没有固定重置点。若你知道账号的周重置时间，加两行即可显示倒计时：

```json
"claudeWeeklyResetWeekday": 3,   // 1=周一 … 7=周日
"claudeWeeklyResetHour": 0        // 本地时间小时
```

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

- Claude 占比是估算，依赖你校准额度；5h 重置时间准确。
- Codex 在使用**自定义/中转供应商**（如本机的 aigocode）时，客户端可能不返回 `rate_limits`（为 null），此时只能显示本会话 token 总量。用官方 OpenAI 账号时会显示官方占比与重置。
- 仅读取本地客户端数据，网页版 ChatGPT / Claude.ai 的订阅额度本地无数据，不在范围内。

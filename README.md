# LLM Usage Bar

Mac 菜单栏小工具，监测 **Claude Code** 和 **Codex** 的额度使用情况——不看「消耗了多少 token」，而看**周期内占比**和**距离下次重置还有多久**，免去每次点开客户端切 Tab。

菜单栏只显示**当下在用的那一个**（自动跟随最近活动），如 `CC 24%`。点开看两边详情。占比 ≥75% 变橙、≥90% 变红。展示格式对齐 Claude Code 的 `/usage`：`占比 % · 重置 2h`。

## 数据来源（全部本地读取，不联网）

| 提供方 | 来源 | 占比 | 重置时间 |
|--------|------|------|----------|
| Claude Code | `~/.claude/projects/**/*.jsonl` 每条消息的 `usage` | **估算**（本地加权 token ÷ 校准额度），标「估算」 | **精确**（5h 滚动窗口） |
| Codex | `~/.codex/sessions/**/*.jsonl` 的 `token_count` 事件 | **官方精确**（`rate_limits.used_percent`） | **官方精确**（`resets_at`） |

> **为什么 Codex 是官方值、Claude 只能估算？**
> Codex 客户端把官方 `rate_limits` 写进了本地会话文件，直接读即可，零估算。
> Claude 客户端**不把**官方额度百分比写到本地——`/usage` 是运行时实时从 API 拉的。试过用 OAuth token 直连 `count_tokens` 读 `anthropic-ratelimit-*` 头，返回 `403 Request not allowed`：Anthropic **有意**只允许官方客户端使用该 token。因此 Claude 的占比只能本地估算，并明确标注「估算」；**5h/周的重置时间仍然准确**。
> 校准后估算已相当接近官方（实测 5h 24% vs 官方 23%，周 3% vs 官方 3%）。

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
  "claudeFiveHourTokenBudget": 94000000,      // 5h 加权 token 额度（分母）
  "claudeWeeklyTokenBudget": 12800000000,     // 周加权 token 额度，设 0 隐藏该行
  "claudeWeightInput": 1.0,
  "claudeWeightCacheCreation": 1.0,
  "claudeWeightCacheRead": 0.1,               // 缓存读取量极大、单价低，默认降权
  "claudeWeightOutput": 1.0,
  "menuBarMode": "auto",                      // auto / claude / codex
  "refreshSeconds": 60
}
```

默认额度已用一组实测 `/usage` 值校准过（官方 5h 23%、周 3%），开箱即大致对齐。若你的套餐不同想重新校准：

> **额度 = 当前加权 token 数 ÷ (官方百分比 / 100)**

在 Claude Code 跑 `/usage` 记下官方 5h %，临时把 `claudeWeightCacheRead` 设回 1 不需要——保持默认权重即可，用 `--once`（见下）看本工具当前的加权 token 数，套上面公式算出额度填回 `claudeFiveHourTokenBudget`。保存后 ≤60s 生效。

`cache_read` 默认按 0.1 权重计入——它的量通常是其它部分的几十倍，全权重会把占比撑爆。这个权重不要随便改，改了上面的校准就得重来。

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

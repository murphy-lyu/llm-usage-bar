# Orb

Orb 是一款 macOS 菜单栏用量监测工具。目前支持 Codex，并为 Claude、Gemini 等提供彼此独立的供应商适配结构。

Orb 展示官方账户用量窗口、已用或剩余百分比及重置时间。菜单栏可以固定显示 5 小时、每周或当前风险最高的额度，避免展示对象在用户不知情时变化。

## Codex 用量口径

使用 ChatGPT 账号登录时，ChatGPT Work 与 Codex 共享用量。当前官方用量通常包含滚动 5 小时窗口，并可能叠加每周限制；Codex-Spark 等模型也可能拥有独立额度。Orb 不预设固定组合，而是按 Codex App Server 实际返回的额度组和窗口展示。

Orb 优先通过本机 Codex App Server 的 `account/rateLimits/read` 接口读取账户级官方数据，因此能够反映其他设备产生的用量，无需在 Orb 内再次登录。App Server 发出 `account/rateLimits/updated` 通知时，Orb 会立即重新读取；60 秒轮询作为兜底。

如果 App Server 暂时不可用，Orb 会回退到 `~/.codex/sessions` 中最新 `token_count` 事件。此时数据只代表本机最近写入的状态，界面会按可获得的字段展示。

## 展示内容

- 官方返回的 5 小时、每周及其他动态窗口
- 已用用量或剩余用量
- 官方重置时间
- 多额度组选择，例如通用额度与模型专属额度
- 用量阈值提醒
- 额外 credits 和额度重置次数，仅在实际可用时显示
- 中英文界面、开机自动启动

Orb 默认在菜单栏显示 5 小时剩余用量。已有用户的手动选择会继续保留。

## 构建与运行

项目是标准 Xcode macOS App 工程，最低支持 macOS 13。

```bash
open LLMUsageBar.xcodeproj
```

命令行构建：

```bash
xcodebuild \
  -project LLMUsageBar.xcodeproj \
  -scheme LLMUsageBar \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  build
```

产物位于：

```text
build/DerivedData/Build/Products/Release/Orb.app
```

读取并打印一次当前数据，不启动菜单栏界面：

```bash
build/DerivedData/Build/Products/Release/Orb.app/Contents/MacOS/Orb --once
```

工程文件由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 根据 `project.yml` 生成。增删源文件后运行：

```bash
xcodegen generate
```

## 配置

设置界面提供：

- 开机自动启动
- 刷新间隔
- 用量提醒及阈值
- 中文、英文切换

配置保存在：

```text
~/.config/llm-usage-bar/config.json
```

## 隐私与数据

Orb 不保存 ChatGPT 密码，也不要求单独登录。账户用量由本机已登录的 Codex App Server 获取；回退数据来自本机 Codex session 文件。Orb 不上传会话内容。

## License

[MIT](LICENSE)

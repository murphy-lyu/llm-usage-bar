import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var config = Config.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.button?.title = "…"  // text-only, no icon — saves menu-bar space
        refresh()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(15, config.refreshSeconds),
                                     repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: - refresh

    private func refresh() {
        config = Config.load()
        let providers = [ClaudeReader.read(config: config), CodexReader.read(config: config)]
        updateTitle(providers)
        statusItem.menu = buildMenu(providers)
    }

    /// The provider shown in the menu bar: pinned one, or (auto) the most
    /// recently used. The dropdown still lists every provider in full.
    private func activeProvider(_ providers: [ProviderUsage]) -> ProviderUsage? {
        let avail = providers.filter { $0.available }
        guard !avail.isEmpty else { return nil }
        switch config.menuBarMode {
        case "claude": return avail.first { $0.short == "CC" } ?? avail.first
        case "codex":  return avail.first { $0.short == "CX" } ?? avail.first
        default:
            return avail.max {
                ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast)
            }
        }
    }

    private func updateTitle(_ providers: [ProviderUsage]) {
        guard let button = statusItem.button else { return }
        guard let active = activeProvider(providers) else {
            button.attributedTitle = NSAttributedString(string: " ⚠︎", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let pct = active.headlinePercent ?? 0
        let color: NSColor = active.headlinePercent == nil ? .labelColor
            : pct >= 90 ? .systemRed : pct >= 75 ? .systemOrange : .labelColor
        button.attributedTitle = NSAttributedString(
            string: "\(active.short) \(active.menuBarValue)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: color])
    }

    // MARK: - menu

    private func buildMenu(_ providers: [ProviderUsage]) -> NSMenu {
        let menu = NSMenu()
        let active = activeProvider(providers)
        for p in providers {
            let isActive = active?.short == p.short
            let mark = isActive ? "  ● 活跃" : ""
            menu.addItem(header(p.name + (p.available ? mark : "  (无数据)"), accent: isActive))
            if let note = p.note { menu.addItem(sub("· \(note)", dim: true)) }
            if p.available {
                for w in p.windows { addWindowRows(menu, w) }
            }
            menu.addItem(.separator())
        }

        // Menu-bar display mode (auto / pin one). Keeps the bar focused on one.
        let modeItem = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for (mode, title) in [("auto", "自动（跟随最近使用）"),
                              ("claude", "仅 Claude Code"),
                              ("codex", "仅 Codex")] {
            let mi = NSMenuItem(title: title, action: #selector(setMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = mode
            mi.state = (config.menuBarMode == mode) ? .on : .off
            modeMenu.addItem(mi)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        menu.addItem(.separator())

        menu.addItem(sub("更新于 \(timeString(Date()))", dim: true))
        let edit = NSMenuItem(title: "校准额度 / 设置…", action: #selector(openConfig), keyEquivalent: ",")
        edit.target = self; menu.addItem(edit)
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(manualRefresh), keyEquivalent: "r")
        refreshItem.target = self; menu.addItem(refreshItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func addWindowRows(_ menu: NSMenu, _ w: UsageWindow) {
        let pctText = w.percent != nil ? String(format: "%.0f%%", w.pct) : "—"
        let bar = w.percent != nil ? w.pct.progressBar() : "··········"
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: "  \(w.label)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)]))
        let barColor: NSColor = w.pct >= 90 ? .systemRed : w.pct >= 75 ? .systemOrange : .systemGreen
        line.append(NSAttributedString(string: "  \(bar) ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: w.percent != nil ? barColor : NSColor.tertiaryLabelColor]))
        line.append(NSAttributedString(string: pctText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)]))

        var tail: [String] = []
        if let d = w.detail { tail.append(d) }
        if w.rolling {
            tail.append("滚动·无固定重置")
        } else if let r = w.resetAt {
            tail.append("重置 \(r.countdownString())")
        }
        if !tail.isEmpty {
            line.append(NSAttributedString(string: "   " + tail.joined(separator: " · "), attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let item = NSMenuItem(); item.attributedTitle = line; item.isEnabled = false
        menu.addItem(item)
    }

    private func header(_ s: String, accent: Bool = false) -> NSMenuItem {
        let i = NSMenuItem()
        i.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: accent ? NSColor.controlAccentColor : NSColor.labelColor])
        i.isEnabled = false
        return i
    }

    private func sub(_ s: String, dim: Bool = false) -> NSMenuItem {
        let i = NSMenuItem()
        i.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: dim ? NSColor.tertiaryLabelColor : NSColor.labelColor])
        i.isEnabled = false
        return i
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
    }

    // MARK: - actions

    @objc private func openConfig() {
        config.save() // ensure file exists
        NSWorkspace.shared.open(Config.path)
    }

    @objc private func manualRefresh() { refresh() }

    @objc private func setMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        config.menuBarMode = mode
        config.save()
        refresh()
    }
}

// Debug/verify mode: print parsed usage as text and exit (no GUI).
if CommandLine.arguments.contains("--once") {
    let cfg = Config.load()
    let provs = [ClaudeReader.read(config: cfg), CodexReader.read(config: cfg)]
    let activeNow = provs.filter { $0.available }
        .max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }
    print(">> menuBarMode=\(cfg.menuBarMode)  auto-active=\(activeNow?.name ?? "none")  bar=\"\(activeNow.map { "\($0.short) \($0.menuBarValue)" } ?? "⚠︎")\"")
    for p in provs {
        print("== \(p.name)  available=\(p.available)  lastActivity=\(p.lastActivity.map { "\($0)" } ?? "nil")  headline=\(p.headlinePercent.map { String(format: "%.1f%%", $0) } ?? "nil")")
        if let n = p.note { print("   note: \(n)") }
        for w in p.windows {
            let pct = w.percent.map { String(format: "%.1f%%", $0) } ?? "nil"
            let reset = w.resetAt.map { "\($0.countdownString()) (\($0))" } ?? (w.rolling ? "rolling" : "n/a")
            print("   - \(w.label): \(pct)  bar=\(w.pct.progressBar())  reset=\(reset)  detail=\(w.detail ?? "-")")
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()

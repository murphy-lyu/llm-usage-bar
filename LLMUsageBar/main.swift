import AppKit
import OSLog

private enum OrbTheme {
    static var accent: NSColor {
        NSColor(named: "AccentColor") ?? .controlAccentColor
    }
}

/// A title/value row for an interactive NSMenuItem (has a submenu), laid out
/// with AutoLayout so the value's right edge is an exact constraint against
/// `width` rather than a guessed NSMenuItem tab-stop position. Draws its own
/// hover highlight and disclosure chevron since a custom `view` on an
/// NSMenuItem replaces AppKit's own row chrome entirely.
private final class MenuValueRowView: NSView {
    override var isFlipped: Bool { true }
    private let highlightView = NSView()
    private let titleLabel: NSTextField
    private let valueLabel: NSTextField
    private let chevron: NSImageView?

    /// `showsChevron` controls whether this renders as a submenu row (title +
    /// value + disclosure arrow) or a plain action row (title + trailing hint,
    /// e.g. a key-equivalent like "⌘R"). Both share the same 14pt left inset
    /// as every other custom row in the panel, so action rows (Refresh Now,
    /// Settings…, Quit) line up flush with everything above them instead of
    /// following AppKit's own (slightly different) native menu item inset.
    init(title: String, value: String, width: CGFloat, showsChevron: Bool = true) {
        titleLabel = NSTextField(labelWithString: title)
        valueLabel = NSTextField(labelWithString: value)
        chevron = showsChevron
            ? NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
            : nil
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))

        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 6
        highlightView.isHidden = true
        addSubview(highlightView)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        valueLabel.font = .systemFont(ofSize: 13, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        if let chevron {
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.translatesAutoresizingMaskIntoConstraints = false
            addSubview(chevron)

            // The value sits flush against the chevron (its actual right
            // neighbor) rather than a fixed edge independent of it — so it
            // reads as "value, then arrow" with no dead gap between them.
            NSLayoutConstraint.activate([
                chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 7),
                chevron.heightAnchor.constraint(equalToConstant: 11),

                valueLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8)
            ])
        } else {
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -27).isActive = true
        }
    }

    required init?(coder: NSCoder) { nil }

    // Claim every click within the row for this view itself, rather than
    // letting the label subviews (NSTextField, an NSControl) intercept it —
    // otherwise mouseUp below never fires.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    // AppKit tracks hover/highlight for custom-view menu items automatically,
    // but it does NOT automatically invoke the item's target/action on click
    // the way it does for standard cell-based items — the custom view has to
    // do that itself. Without this, the row highlights on hover but clicking
    // it does nothing.
    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let action = item.action else {
            super.mouseUp(with: event)
            return
        }
        item.menu?.cancelTracking()
        NSApp.sendAction(action, to: item.target, from: item)
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        highlightView.isHidden = !highlighted
        if highlighted {
            highlightView.frame = bounds.insetBy(dx: 5, dy: 1)
            highlightView.layer?.backgroundColor = OrbTheme.accent.cgColor
        }
        titleLabel.textColor = highlighted ? .white : .labelColor
        valueLabel.textColor = highlighted ? .white : .secondaryLabelColor
        chevron?.contentTintColor = highlighted ? .white : .tertiaryLabelColor
        super.draw(dirtyRect)
    }
}

/// Compact, non-interactive account metadata shown only when it carries useful
/// information, such as a positive credit balance or available limit resets.
private final class AuxiliaryValueRowView: NSView {
    init(title: String, value: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -27),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One complete saved-account summary. Account details stay visible in the
/// Accounts submenu so checking several accounts never requires a third menu.
private struct AccountSummaryWindowLine {
    var label: String
    var percent: String
    var reset: String
}

private final class AccountGroupHeaderView: NSView {
    init(title: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class AccountMetricView: NSView {
    init(window: AccountSummaryWindowLine) {
        super.init(frame: .zero)

        let title = NSTextField(labelWithString: window.label)
        title.font = .systemFont(ofSize: 10, weight: .medium)
        title.textColor = .tertiaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        let percent = NSTextField(labelWithString: window.percent)
        percent.font = .systemFont(ofSize: 12, weight: .semibold)
        percent.textColor = .labelColor
        percent.lineBreakMode = .byTruncatingTail
        percent.translatesAutoresizingMaskIntoConstraints = false
        addSubview(percent)

        let reset = NSTextField(labelWithString: window.reset)
        reset.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        reset.textColor = .secondaryLabelColor
        reset.lineBreakMode = .byTruncatingTail
        reset.translatesAutoresizingMaskIntoConstraints = false
        addSubview(reset)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.topAnchor.constraint(equalTo: topAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            percent.leadingAnchor.constraint(equalTo: leadingAnchor),
            percent.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            percent.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            reset.leadingAnchor.constraint(equalTo: leadingAnchor),
            reset.topAnchor.constraint(equalTo: percent.bottomAnchor, constant: 2),
            reset.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            reset.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class AccountSummaryRowView: NSView {
    init(email: String,
         status: String,
         windows: [AccountSummaryWindowLine],
         updated: String,
         width: CGFloat) {
        let showsUpdated = !updated.isEmpty
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: showsUpdated ? 92 : 76))

        let emailLabel = NSTextField(labelWithString: email)
        emailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        emailLabel.textColor = .labelColor
        emailLabel.lineBreakMode = .byTruncatingMiddle
        emailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emailLabel)

        let statusLabel = NSTextField(labelWithString: status)
        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .right
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            emailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            emailLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            emailLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -10),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            statusLabel.firstBaselineAnchor.constraint(equalTo: emailLabel.firstBaselineAnchor)
        ])

        let metrics = windows.prefix(2).map { window -> AccountMetricView in
            let metric = AccountMetricView(window: window)
            metric.translatesAutoresizingMaskIntoConstraints = false
            addSubview(metric)
            return metric
        }

        if let first = metrics.first {
            NSLayoutConstraint.activate([
                first.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                first.topAnchor.constraint(equalTo: emailLabel.bottomAnchor, constant: 7),
                first.heightAnchor.constraint(equalToConstant: 43)
            ])
            if metrics.count == 2 {
                let second = metrics[1]
                let divider = NSView()
                divider.wantsLayer = true
                divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
                divider.translatesAutoresizingMaskIntoConstraints = false
                addSubview(divider)
                NSLayoutConstraint.activate([
                    first.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -12),
                    second.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 12),
                    second.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                    second.topAnchor.constraint(equalTo: first.topAnchor),
                    second.heightAnchor.constraint(equalTo: first.heightAnchor),
                    first.widthAnchor.constraint(equalTo: second.widthAnchor),
                    divider.centerXAnchor.constraint(equalTo: centerXAnchor),
                    divider.topAnchor.constraint(equalTo: first.topAnchor, constant: 2),
                    divider.bottomAnchor.constraint(equalTo: first.bottomAnchor, constant: -1),
                    divider.widthAnchor.constraint(equalToConstant: 1)
                ])
            } else {
                first.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14).isActive = true
            }
        }

        if showsUpdated {
            let updatedLabel = NSTextField(labelWithString: updated)
            updatedLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            updatedLabel.textColor = .tertiaryLabelColor
            updatedLabel.lineBreakMode = .byTruncatingTail
            updatedLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(updatedLabel)
            NSLayoutConstraint.activate([
                updatedLabel.leadingAnchor.constraint(equalTo: emailLabel.leadingAnchor),
                updatedLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
                updatedLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
            ])
        }
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A compact disclosure row for account metadata. It follows the visual weight
/// of auxiliary rows while still exposing per-credit details in a submenu.
private final class AuxiliaryDisclosureRowView: NSView {
    private let highlightView = NSView()
    private let titleLabel: NSTextField
    private let valueLabel: NSTextField
    private let chevron: NSImageView

    init(title: String, value: String, width: CGFloat) {
        titleLabel = NSTextField(labelWithString: title)
        valueLabel = NSTextField(labelWithString: value)
        chevron = NSImageView(image: NSImage(
            systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))

        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 5
        highlightView.isHidden = true
        addSubview(highlightView)

        titleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)

        chevron.contentTintColor = .tertiaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -7),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 6),
            chevron.heightAnchor.constraint(equalToConstant: 10)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        highlightView.isHidden = !highlighted
        if highlighted {
            highlightView.frame = bounds.insetBy(dx: 5, dy: 1)
            highlightView.layer?.backgroundColor = OrbTheme.accent.cgColor
        }
        titleLabel.textColor = highlighted ? .white : .secondaryLabelColor
        valueLabel.textColor = highlighted ? .white : .secondaryLabelColor
        chevron.contentTintColor = highlighted ? .white : .tertiaryLabelColor
        super.draw(dirtyRect)
    }
}

/// The top title row (e.g. "Codex"), with an optional right-aligned auxiliary
/// value (e.g. the plan name) laid out against a fixed `width` so it lines up
/// with the rest of the panel. Non-interactive: full-color text, no highlight.
private final class HeaderRowView: NSView {
    override var isFlipped: Bool { true }

    init(title: String, plan: String?, width: CGFloat, accent: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = accent ? OrbTheme.accent : .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        guard let plan else { return }

        // The plan badge sits right next to the title, rather than pushed to
        // the row's far right edge, so it reads as "Codex Plus" instead of an
        // unrelated value floating across the row.
        let planBadge = NSView()
        planBadge.wantsLayer = true
        planBadge.layer?.cornerRadius = 4
        planBadge.layer?.backgroundColor = OrbTheme.accent.withAlphaComponent(0.14).cgColor
        planBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(planBadge)

        let planLabel = NSTextField(labelWithString: plan)
        planLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        planLabel.textColor = OrbTheme.accent
        planLabel.lineBreakMode = .byTruncatingTail
        planLabel.translatesAutoresizingMaskIntoConstraints = false
        planBadge.addSubview(planLabel)

        NSLayoutConstraint.activate([
            planBadge.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 7),
            planBadge.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            planBadge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            planBadge.heightAnchor.constraint(equalToConstant: 18),

            planLabel.leadingAnchor.constraint(equalTo: planBadge.leadingAnchor, constant: 6),
            planLabel.trailingAnchor.constraint(equalTo: planBadge.trailingAnchor, constant: -6),
            planLabel.centerYAnchor.constraint(equalTo: planBadge.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class UsageWindowPickerView: NSView {
    private struct Row {
        var kind: UsageWindowKind
        var frame: NSRect
        var field: NSTextField
    }

    private var rows: [Row] = []
    private var selectedKind: UsageWindowKind?
    private let selectionView = NSView()
    private let accentView = NSView()

    override var isFlipped: Bool { true }

    init(items: [(UsageWindowKind, NSAttributedString)],
         selectedKind: UsageWindowKind?,
         width: CGFloat,
         leftPad: CGFloat,
         topPad: CGFloat) {
        self.selectedKind = selectedKind
        super.init(frame: .zero)

        // Selected-row background highlight — disabled for now, kept in case
        // we want it back. `updateSelectionFrame()` still runs harmlessly
        // below (it just positions views that are never added to the
        // hierarchy), so re-enabling is just uncommenting this block.
        // selectionView.wantsLayer = true
        // selectionView.layer?.cornerRadius = 7
        // selectionView.layer?.backgroundColor = OrbTheme.accent.withAlphaComponent(0.08).cgColor
        // addSubview(selectionView)

        // accentView.wantsLayer = true
        // accentView.layer?.cornerRadius = 1.5
        // accentView.layer?.backgroundColor = OrbTheme.accent.cgColor
        // selectionView.addSubview(accentView)

        rebuildRows(items: items, width: width, leftPad: leftPad, topPad: topPad)
        updateSelectionFrame()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(items: [(UsageWindowKind, NSAttributedString)], selectedKind: UsageWindowKind?) {
        self.selectedKind = selectedKind
        rebuildRows(items: items, width: frame.width, leftPad: 14, topPad: 5)
        updateSelectionFrame()
    }

    func setSelectedKind(_ kind: UsageWindowKind?) {
        selectedKind = kind
        updateSelectionFrame()
    }

    private func rebuildRows(items: [(UsageWindowKind, NSAttributedString)],
                             width: CGFloat,
                             leftPad: CGFloat,
                             topPad: CGFloat) {
        for row in rows { row.field.removeFromSuperview() }
        rows.removeAll()

        var y: CGFloat = 0
        for item in items {
            let field = NSTextField(labelWithAttributedString: item.1)
            field.isEditable = false
            field.isSelectable = false
            field.isBezeled = false
            field.drawsBackground = false
            field.usesSingleLineMode = false
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byClipping
            field.sizeToFit()

            let textHeight = ceil(field.fittingSize.height)
            let rowHeight = textHeight + topPad * 2
            let rowFrame = NSRect(x: 0, y: y, width: width, height: rowHeight)
            rows.append(Row(kind: item.0, frame: rowFrame, field: field))

            field.frame = NSRect(x: leftPad, y: y + topPad, width: width - leftPad - 18, height: textHeight)
            addSubview(field)
            y += rowHeight
        }

        frame = NSRect(x: 0, y: 0, width: width, height: y)
    }

    private func updateSelectionFrame() {
        guard let selectedKind,
              let frame = rows.first(where: { $0.kind == selectedKind })?.frame else {
            selectionView.isHidden = true
            return
        }

        selectionView.isHidden = false
        selectionView.frame = frame.insetBy(dx: 4, dy: 1)

        let accentHeight = max(0, selectionView.bounds.height - 16)
        accentView.frame = NSRect(
            x: 3,
            y: (selectionView.bounds.height - accentHeight) / 2,
            width: 3,
            height: accentHeight
        )

        needsLayout = true
        layoutSubtreeIfNeeded()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let logger = Logger(subsystem: "local.llmusagebar",
                                       category: "Refresh")
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var config = Config.load()
    private var settingsOpener: SettingsOpener?
    private var sessionWatcher: DispatchSourceFileSystemObject?
    private var sessionWatcherFD: CInt = -1
    private var watchedSessionPath: URL?
    private var refreshDebounce: DispatchWorkItem?
    private var refreshInFlight = false
    private var refreshPending = false
    private var forceReconnectPending = false
    private var wakeObserver: NSObjectProtocol?
    private var configRevision = 0
    private var hasAlertBaseline = false
    private var lastPercents: [String: Double] = [:]
    private var lastProvider: ProviderUsage?
    /// Serial so overlapping refreshes never race on the readers' file cache.
    private let ioQueue = DispatchQueue(label: "llmusagebar.io", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.button?.title = "…"  // text-only, no icon — saves menu-bar space
        let placeholder = NSMenu(); placeholder.addItem(sub("status.loading".l10n, dim: true))
        placeholder.delegate = self
        statusItem.menu = placeholder
        if config.thresholdAlertsEnabled { NotificationManager.shared.requestIfNeeded() }
        CodexAppServerClient.setRateLimitsUpdateHandler { [weak self] in
            DispatchQueue.main.async {
                self?.debouncedRefresh(after: 0.15)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh(forceReconnect: true)
        }
        refresh(showLocalImmediately: true)
        scheduleTimer()
        scheduleSessionWatcher()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CodexAppServerClient.setRateLimitsUpdateHandler(nil)
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let nextTimer = Timer(timeInterval: max(15, config.refreshSeconds),
                              repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(nextTimer, forMode: .common)
        timer = nextTimer
    }

    // MARK: - refresh

    /// Reads all data on a background queue and only touches the UI on main —
    /// file I/O must never block the main thread, or the menu lags on click.
    private func refresh(forceReconnect: Bool = false,
                         showLocalImmediately: Bool = false) {
        precondition(Thread.isMainThread)
        if forceReconnect { forceReconnectPending = true }
        guard !refreshInFlight else {
            refreshPending = true
            return
        }
        refreshInFlight = true
        let shouldReconnect = forceReconnectPending
        forceReconnectPending = false
        let revision = configRevision
        let refreshStartedAt = Date()
        ioQueue.async { [weak self] in
            if shouldReconnect {
                CodexAppServerClient.invalidateConnection()
            }
            let cfg = Config.load()
            if showLocalImmediately, cfg.providerID == .codex {
                let localProvider = CodexReader.readLocal(config: cfg)
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.lastProvider == nil,
                          revision == self.configRevision else { return }
                    self.config = cfg
                    self.lastProvider = localProvider
                    self.updateTitle(localProvider)
                    let menu = self.buildMenu(localProvider)
                    menu.delegate = self
                    self.statusItem.menu = menu
                    self.scheduleSessionWatcher(for: localProvider.sourceFile)
                    let elapsed = Int(Date().timeIntervalSince(refreshStartedAt) * 1_000)
                    Self.logger.info(
                        "Initial local UI rendered elapsed_ms=\(elapsed, privacy: .public) available=\(localProvider.available, privacy: .public)"
                    )
                }
            }
            let provider = UsageProviderRegistry.adapter(for: cfg.providerID).read(config: cfg)
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                guard revision == self.configRevision else {
                    self.refreshPending = true
                    self.finishRefresh()
                    return
                }
                self.config = cfg
                self.lastProvider = provider
                self.updateTitle(provider)
                self.maybeNotify(provider, config: cfg)
                let menu = self.buildMenu(provider)
                menu.delegate = self
                self.statusItem.menu = menu
                self.scheduleSessionWatcher(for: provider.sourceFile)
                let elapsed = Int(Date().timeIntervalSince(refreshStartedAt) * 1_000)
                let source = provider.sourceFile == nil ? "app_server" : "local_session"
                Self.logger.info(
                    "Refresh completed source=\(source, privacy: .public) elapsed_ms=\(elapsed, privacy: .public) available=\(provider.available, privacy: .public)"
                )
                self.finishRefresh()
            }
        }
    }

    private func finishRefresh() {
        guard refreshPending else { return }
        refreshPending = false
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func updateTitle(_ p: ProviderUsage) {
        guard let button = statusItem.button else { return }
        guard p.available else {
            button.toolTip = nil
            button.attributedTitle = NSAttributedString(string: "\(p.name) ⚠︎", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let quotaID = config.selectedQuotaID(for: p.providerID)
        let mode = p.effectiveDisplayMode(for: config.menuBarDisplayMode, quotaID: quotaID)
        let recovery = p.recoveryWindow(quotaID: quotaID)
        let selected = recovery ?? p.window(for: mode, quotaID: quotaID)
        if let recovery, let reset = recovery.resetAt {
            let formatter = DateFormatter()
            formatter.locale = .autoupdatingCurrent
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            button.toolTip = String(format: "status.recovery".l10n,
                                    recovery.label, formatter.string(from: reset))
        } else {
            button.toolTip = nil
        }
        let pct = selected?.percent ?? p.headlinePercent ?? 0
        let color: NSColor = selected?.percent == nil && p.headlinePercent == nil ? .labelColor
            : pct >= 90 ? .systemRed : pct >= 75 ? .systemOrange : .labelColor
        button.attributedTitle = NSAttributedString(
            string: p.menuBarValue(for: mode,
                                   percentMode: config.percentDisplayMode,
                                   quotaID: quotaID), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: color])
    }

    // MARK: - menu

    private func buildMenu(_ p: ProviderUsage) -> NSMenu {
        let menu = NSMenu()
        let menuWidth = contentWidth()
        menu.addItem(header(p.name + (p.available ? "" : "  \("status.unavailable".l10n)"),
                            plan: p.plan, width: menuWidth))
        if let note = p.note { menu.addItem(sub("· \(note)", dim: true)) }
        if p.available {
            let quotas = p.effectiveQuotas
            let selectedQuotaID = p.selectedQuota(
                preferredID: config.selectedQuotaID(for: p.providerID)).id
            if quotas.count == 1 {
                menu.addItem(usageWindowPickerItem(quotas[0].windows,
                                                   quotaID: quotas[0].id,
                                                   width: menuWidth))
            } else {
                for (index, quota) in quotas.enumerated() {
                    if index > 0 { menu.addItem(.separator()) }
                    menu.addItem(quotaHeaderItem(quota.name, width: menuWidth))
                    menu.addItem(usageWindowPickerItem(quota.windows,
                                                       quotaID: quota.id,
                                                       width: menuWidth))
                }
            }
            let credits = creditsExtra(for: p)
            let resets = p.resetCredits.flatMap { $0.availableCount > 0 ? $0 : nil }
            if credits != nil || resets != nil {
                menu.addItem(.separator())
                if let credits {
                    menu.addItem(auxiliaryRow(credits.title, value: credits.value, width: menuWidth))
                }
                if let resets {
                    menu.addItem(resetCreditsRow(resets, width: menuWidth))
                }
            }
            menu.addItem(.separator())
            if let accounts = accountsRowItem(width: menuWidth, provider: p) {
                menu.addItem(accounts)
            }
            if quotas.count > 1 {
                menu.addItem(quotaRowItem(width: menuWidth,
                                          provider: p,
                                          selectedQuotaID: selectedQuotaID))
            }
            menu.addItem(percentModeRowItem(width: menuWidth))
            menu.addItem(menuBarModeRowItem(width: menuWidth, provider: p))
        } else if let accounts = accountsRowItem(width: menuWidth, provider: p) {
            menu.addItem(.separator())
            menu.addItem(accounts)
        }
        menu.addItem(.separator())

        menu.addItem(actionRow("action.refresh".l10n, keyHint: "⌘R", width: menuWidth,
                               action: #selector(manualRefresh), keyEquivalent: "r", target: self))
        menu.addItem(actionRow("action.settings".l10n, keyHint: "⌘,", width: menuWidth,
                               action: #selector(openConfig), keyEquivalent: ",", target: self))
        menu.addItem(.separator())
        menu.addItem(actionRow("action.quit".l10n, keyHint: "⌘Q", width: menuWidth,
                               action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q", target: nil))
        return menu
    }

    /// A clickable action row (Refresh Now, Settings…, Quit) rendered via the
    /// same custom view as the submenu rows, so its title sits at the exact
    /// same 14pt left inset instead of AppKit's native menu item inset.
    /// `target: nil` (e.g. for `NSApplication.terminate(_:)`) lets the action
    /// travel the normal responder chain instead of being sent straight to
    /// `self`, which doesn't implement it.
    private func actionRow(_ title: String, keyHint: String, width: CGFloat,
                           action: Selector, keyEquivalent: String, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        item.view = MenuValueRowView(title: title, value: keyHint, width: width, showsChevron: false)
        return item
    }

    private func auxiliaryRow(_ title: String, value: String, width: CGFloat) -> NSMenuItem {
        let item = NSMenuItem(title: menuRowTitle(title, value), action: nil, keyEquivalent: "")
        item.view = AuxiliaryValueRowView(title: title, value: value, width: width)
        return item
    }

    private func creditsExtra(for provider: ProviderUsage) -> (title: String, value: String)? {
        if let credits = provider.credits, credits.shouldDisplay {
            let value: String
            if credits.unlimited {
                value = "usage.credits.unlimited".l10n
            } else if let balance = credits.balance, !balance.isEmpty {
                value = balance
            } else {
                value = "usage.credits.available".l10n
            }
            return ("usage.credits.title".l10n, value)
        }
        return nil
    }

    private func accountsRowItem(width: CGFloat, provider: ProviderUsage) -> NSMenuItem? {
        guard provider.providerID == .codex else { return nil }
        var accounts = CodexAccountHistoryStore.accounts()
        guard !accounts.isEmpty else { return nil }
        if let currentID = provider.account?.id,
           let index = accounts.firstIndex(where: { $0.id == currentID }) {
            let current = accounts.remove(at: index)
            accounts.insert(current, at: 0)
        }

        let current = provider.account.flatMap { account in
            accounts.first(where: { $0.id == account.id })
        }
        let value = current.flatMap(\.email)
            ?? String.localizedStringWithFormat("accounts.saved".l10n, accounts.count)
        let title = "menu.accounts.title".l10n
        let item = NSMenuItem(title: menuRowTitle(title, value), action: nil, keyEquivalent: "")
        item.toolTip = current?.email
        item.view = MenuValueRowView(title: title, value: value, width: width)
        item.identifier = NSUserInterfaceItemIdentifier("accounts")
        item.submenu = accountsMenu(accounts, currentID: provider.account?.id, width: width)
        return item
    }

    private func accountsMenu(_ accounts: [CodexAccountRecord],
                              currentID: String?,
                              width: CGFloat) -> NSMenu {
        let menu = NSMenu()
        let summaries = accounts.enumerated().map { index, account in
            let fallback = String.localizedStringWithFormat("accounts.fallback".l10n, index + 1)
            let title = account.email ?? fallback
            let plan = account.planType.flatMap(CodexReader.planName) ?? ""
            return (
                account: account,
                title: title,
                status: plan,
                windows: accountWindowLines(account),
                updated: account.id == currentID ? "" : accountUpdatedText(account.updatedAt)
            )
        }
        let summaryWidth = accountSummaryWidth(summaries: summaries, minimum: width)

        var hasAddedSummary = false
        var hasAddedOtherHeader = false
        for summary in summaries {
            if summary.account.id == currentID {
                menu.addItem(accountGroupHeaderItem("accounts.group.current".l10n, width: summaryWidth))
            } else if !hasAddedOtherHeader {
                if hasAddedSummary { menu.addItem(.separator()) }
                menu.addItem(accountGroupHeaderItem("accounts.group.other".l10n, width: summaryWidth))
                hasAddedOtherHeader = true
            } else {
                menu.addItem(.separator())
            }
            let accessibilityParts = [summary.title, summary.status]
                + summary.windows.map { "\($0.label) \($0.percent) \($0.reset)" }
                + [summary.updated]
            let item = NSMenuItem(
                title: accessibilityParts
                    .filter { !$0.isEmpty }
                    .joined(separator: "\t"),
                action: nil,
                keyEquivalent: ""
            )
            item.toolTip = summary.account.email
            item.view = AccountSummaryRowView(
                email: summary.title,
                status: summary.status,
                windows: summary.windows,
                updated: summary.updated,
                width: summaryWidth
            )
            menu.addItem(item)
            hasAddedSummary = true
        }

        return menu
    }

    private func accountSummaryWidth(
        summaries: [(account: CodexAccountRecord, title: String, status: String, windows: [AccountSummaryWindowLine], updated: String)],
        minimum: CGFloat
    ) -> CGFloat {
        _ = summaries
        return max(250, min(minimum, 260))
    }

    private func accountWindowLines(_ account: CodexAccountRecord) -> [AccountSummaryWindowLine] {
        let sorted = account.windows.sorted { accountWindowOrder($0.kind) < accountWindowOrder($1.kind) }
        guard !sorted.isEmpty else {
            return [AccountSummaryWindowLine(
                label: "accounts.noResetData".l10n,
                percent: "",
                reset: ""
            )]
        }
        return sorted.prefix(2).map { window in
            if let resetAt = window.resetAt, resetAt <= Date() {
                return AccountSummaryWindowLine(
                    label: accountWindowCompactLabel(window),
                    percent: "accounts.dataExpired".l10n,
                    reset: "accounts.switchToRefresh".l10n
                )
            }
            return AccountSummaryWindowLine(
                label: accountWindowCompactLabel(window),
                percent: accountWindowPercent(window),
                reset: "↻ \(accountResetValue(window))"
            )
        }
    }

    private func accountWindowPercent(_ window: CodexAccountWindowRecord) -> String {
        let used = max(0, min(100, window.usedPercent))
        switch config.percentDisplayMode {
        case .remaining:
            return String(format: "status.percentRemaining".l10n, 100 - used)
        case .used:
            return String(format: "status.percentUsed".l10n, used)
        }
    }

    private func accountUpdatedText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        if Calendar.autoupdatingCurrent.isDateInToday(date) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        }
        return "\("accounts.updated".l10n) \(formatter.string(from: date))"
    }

    private func accountGroupHeaderItem(_ title: String, width: CGFloat) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.view = AccountGroupHeaderView(title: title, width: width)
        return item
    }

    private func accountWindowOrder(_ kind: UsageWindowKind) -> Int {
        switch kind {
        case .fiveHour: return 0
        case .daily: return 1
        case .weekly: return 2
        case .monthly: return 3
        case .custom, .session: return 4
        }
    }

    private func accountWindowLabel(_ window: CodexAccountWindowRecord) -> String {
        switch window.kind {
        case .fiveHour: return "limit.fiveHour".l10n
        case .daily: return "limit.daily".l10n
        case .weekly: return "limit.weekly".l10n
        case .monthly: return "limit.monthly".l10n
        case .custom, .session:
            guard let minutes = window.durationMinutes else { return "limit.primary".l10n }
            let rounded = Int(minutes.rounded())
            if rounded >= 1_440 {
                return String.localizedStringWithFormat("limit.days".l10n, rounded / 1_440)
            }
            if rounded >= 60 {
                return String.localizedStringWithFormat("limit.hours".l10n, rounded / 60)
            }
            return String.localizedStringWithFormat("limit.minutes".l10n, rounded)
        }
    }

    private func accountWindowCompactLabel(_ window: CodexAccountWindowRecord) -> String {
        switch window.kind {
        case .fiveHour: return "accounts.window.fiveHour".l10n
        case .weekly: return "accounts.window.weekly".l10n
        default: return accountWindowLabel(window)
        }
    }

    private func accountResetValue(_ window: CodexAccountWindowRecord) -> String {
        guard let resetAt = window.resetAt else { return "status.notReported".l10n }
        guard resetAt > Date() else { return "accounts.needsRefresh".l10n }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(
            window.kind == .fiveHour ? "jm" : "MMM d"
        )
        return formatter.string(from: resetAt)
    }

    private func resetCreditsRow(_ resets: UsageResetCredits, width: CGFloat) -> NSMenuItem {
        guard let credits = resets.credits, !credits.isEmpty else {
            return auxiliaryRow(
                "usage.resetCredits.title".l10n,
                value: String(format: "usage.resetCredits.value".l10n, resets.availableCount),
                width: width)
        }
        let item = NSMenuItem(title: "usage.resetCredits.title".l10n,
                              action: nil, keyEquivalent: "")
        item.view = AuxiliaryDisclosureRowView(
            title: "usage.resetCredits.title".l10n,
            value: String(format: "usage.resetCredits.value".l10n, resets.availableCount),
            width: width)
        let submenu = NSMenu()
        let sorted = credits.sorted {
            ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture)
        }
        for (index, credit) in sorted.enumerated() {
            let title = credit.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rowTitle = title.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(format: "usage.resetCredits.item".l10n, index + 1)
            let value: String
            if let expiry = credit.expiresAt {
                let formatter = DateFormatter()
                formatter.locale = .autoupdatingCurrent
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                value = formatter.string(from: expiry)
            } else {
                value = "usage.resetCredits.noExpiry".l10n
            }
            submenu.addItem(auxiliaryRow(rowTitle, value: value, width: width))
        }
        if resets.availableCount > sorted.count {
            submenu.addItem(auxiliaryRow(
                "usage.resetCredits.detailsUnavailable".l10n,
                value: String(resets.availableCount - sorted.count),
                width: width))
        }
        item.submenu = submenu
        return item
    }

    private func contentWidth() -> CGFloat {
        300
    }

    private func menuBarModeRowItem(width: CGFloat, provider: ProviderUsage? = nil) -> NSMenuItem {
        let title = "menu.menuBarMode.title".l10n
        let value = currentMenuBarWindowLabel(provider: provider)
        let item = NSMenuItem(title: menuRowTitle(title, value), action: nil, keyEquivalent: "")
        item.view = MenuValueRowView(title: title, value: value, width: width)
        item.identifier = NSUserInterfaceItemIdentifier("menuBarMode")
        item.submenu = menuBarModeMenu(provider: provider)
        return item
    }

    private func quotaRowItem(width: CGFloat,
                              provider: ProviderUsage,
                              selectedQuotaID: String) -> NSMenuItem {
        let title = "menu.quota.title".l10n
        let quota = provider.selectedQuota(preferredID: selectedQuotaID)
        let item = NSMenuItem(title: menuRowTitle(title, quota.shortName), action: nil, keyEquivalent: "")
        item.view = MenuValueRowView(title: title, value: quota.shortName, width: width)
        item.identifier = NSUserInterfaceItemIdentifier("quota")
        item.submenu = quotaMenu(provider: provider, selectedQuotaID: selectedQuotaID)
        return item
    }

    private func quotaMenu(provider: ProviderUsage, selectedQuotaID: String) -> NSMenu {
        let submenu = NSMenu()
        for quota in provider.effectiveQuotas {
            let item = NSMenuItem(title: quota.name,
                                  action: #selector(selectQuota(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = quota.id
            item.state = quota.id == selectedQuotaID ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    private func percentModeRowItem(width: CGFloat) -> NSMenuItem {
        let title = "menu.percentMode.title".l10n
        let value = percentModeTitle(config.percentDisplayMode)
        let item = NSMenuItem(title: menuRowTitle(title, value), action: nil, keyEquivalent: "")
        item.view = MenuValueRowView(title: title, value: value, width: width)
        item.identifier = NSUserInterfaceItemIdentifier("percentMode")
        item.submenu = percentModeMenu()
        return item
    }

    private func menuBarModeMenu(provider: ProviderUsage? = nil) -> NSMenu {
        let submenu = NSMenu()
        let quotaID = provider.flatMap { config.selectedQuotaID(for: $0.providerID) }
        let modes = provider?.availableDisplayModes(quotaID: quotaID) ?? Config.MenuBarDisplayMode.settingsCases
        let effectiveMode = provider?.effectiveDisplayMode(for: config.menuBarDisplayMode,
                                                            quotaID: quotaID) ?? config.menuBarDisplayMode
        for mode in modes {
            let item = NSMenuItem(
                title: mode.titleKey.l10n,
                action: selector(for: mode),
                keyEquivalent: ""
            )
            item.target = self
            item.state = effectiveMode == mode ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    private func selector(for mode: Config.MenuBarDisplayMode) -> Selector {
        switch mode {
        case .fiveHour: return #selector(selectMenuBarFiveHour)
        case .weekly: return #selector(selectMenuBarWeekly)
        case .highest: return #selector(selectMenuBarHighest)
        }
    }

    private func percentModeMenu() -> NSMenu {
        let submenu = NSMenu()
        let remaining = NSMenuItem(
            title: Config.PercentDisplayMode.remaining.titleKey.l10n,
            action: #selector(selectPercentRemaining),
            keyEquivalent: ""
        )
        remaining.target = self
        remaining.state = config.percentDisplayMode == .remaining ? .on : .off

        let used = NSMenuItem(
            title: Config.PercentDisplayMode.used.titleKey.l10n,
            action: #selector(selectPercentUsed),
            keyEquivalent: ""
        )
        used.target = self
        used.state = config.percentDisplayMode == .used ? .on : .off

        submenu.addItem(remaining)
        submenu.addItem(used)
        return submenu
    }

    /// Reuses Settings' own titleKey (e.g. "Usage remaining") rather than a
    /// separate, shorter "menu.percentMode.*" string, so the menu shows
    /// exactly the same label the Settings picker does — one source of truth
    /// instead of two strings that can drift out of sync with each other.
    private func percentModeTitle(_ mode: Config.PercentDisplayMode) -> String {
        mode.titleKey.l10n
    }

    private func menuRowTitle(_ title: String, _ value: String) -> String {
        "\(title)\t\(value)"
    }


    private func currentMenuBarWindowLabel(provider: ProviderUsage? = nil) -> String {
        let quotaID = provider.flatMap { config.selectedQuotaID(for: $0.providerID) }
        let mode = provider?.effectiveDisplayMode(for: config.menuBarDisplayMode,
                                                  quotaID: quotaID) ?? config.menuBarDisplayMode
        return mode.titleKey.l10n
    }

    private func usageWindowText(_ w: UsageWindow, fieldWidth: CGFloat) -> NSAttributedString {
        let displayPct = w.displayPercent(for: config.percentDisplayMode)
        let pctText = w.percent != nil ? String(format: displayPercentFormat(), displayPct) : "—"
        let bar = w.percent != nil ? displayPct.progressBar() : "··········"
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: "\(w.label)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)]))
        let barColor: NSColor = w.pct >= 90 ? .systemRed : w.pct >= 75 ? .systemOrange : .systemGreen
        let secondLineStart = line.length
        line.append(NSAttributedString(string: "\(bar)  ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: w.percent != nil ? barColor : NSColor.tertiaryLabelColor]))
        line.append(NSAttributedString(string: pctText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)]))

        // Match Codex's official display: time for 5-hour limits and a date for
        // longer limits, including when a 5-hour reset crosses midnight.
        var tail: [String] = []
        if !w.rolling, let r = w.resetAt {
            if r.timeIntervalSinceNow <= 0 {
                tail.append("time.now".l10n)
            } else if lastProvider?.providerID == .codex {
                tail.append(w.compactResetText(r))
            } else {
                tail.append(String(format: "status.reset".l10n, r.coarseCountdown()))
            }
        }
        if let detail = w.detail { tail.append(detail) }
        if w.estimate { tail.append("status.estimated".l10n) }
        else if w.rolling { tail.append("status.rolling".l10n) }
        if !tail.isEmpty {
            line.append(NSAttributedString(string: "\t" + tail.joined(separator: " · "), attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor]))
        }

        // Pin the tail to the row's right edge with a right tab stop, instead
        // of letting it trail the percentage text at whatever width that text
        // happens to be (which drifted row to row). Leave a few points of
        // margin short of the field's actual edge and align with the custom
        // menu rows' trailing value column.
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: fieldWidth - 9, options: [:])]
        line.addAttribute(.paragraphStyle, value: paragraph,
                          range: NSRange(location: secondLineStart, length: line.length - secondLineStart))
        return line
    }

    private func displayPercentFormat() -> String {
        switch config.percentDisplayMode {
        case .remaining: return "status.percentRemaining".l10n
        case .used: return "status.percentUsed".l10n
        }
    }

    private func header(_ s: String, plan: String? = nil, width: CGFloat, accent: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = HeaderRowView(title: s, plan: plan, width: width, accent: accent)
        return item
    }

    private func sub(_ s: String, dim: Bool = false) -> NSMenuItem {
        displayRow(NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: dim ? NSColor.tertiaryLabelColor : NSColor.labelColor]))
    }

    private func quotaHeaderItem(_ title: String, width: CGFloat) -> NSMenuItem {
        let attr = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        let item = displayRow(attr, leftPad: 14, topPad: 3)
        item.view?.frame.size.width = width
        return item
    }

    private func usageWindowPickerItem(_ windows: [UsageWindow],
                                       quotaID: String,
                                       width: CGFloat,
                                       leftPad: CGFloat = 14,
                                       topPad: CGFloat = 5) -> NSMenuItem {
        // Must match the field frame math in UsageWindowPickerView.rebuildRows.
        let fieldWidth = width - leftPad - 18
        let rows = windows.map { ($0.kind, usageWindowText($0, fieldWidth: fieldWidth)) }
        let picker = UsageWindowPickerView(
            items: rows,
            selectedKind: selectedUsageWindowKind(windows, quotaID: quotaID),
            width: width,
            leftPad: leftPad,
            topPad: topPad
        )
        let item = NSMenuItem()
        item.view = picker
        return item
    }

    /// A non-interactive menu row rendered via a custom view, so its text keeps
    /// full color instead of macOS's greyed-out "disabled" look, and it doesn't
    /// highlight or dismiss the menu on click.
    private func displayRow(_ attr: NSAttributedString, leftPad: CGFloat = 14, topPad: CGFloat = 3) -> NSMenuItem {
        let field = NSTextField(labelWithAttributedString: attr)
        field.isEditable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byClipping
        field.sizeToFit()
        let size = field.fittingSize
        let container = NSView(frame: NSRect(
            x: 0, y: 0, width: ceil(size.width) + leftPad + 16, height: ceil(size.height) + topPad * 2))
        field.frame = NSRect(x: leftPad, y: topPad, width: ceil(size.width), height: ceil(size.height))
        container.addSubview(field)
        let item = NSMenuItem()
        item.view = container
        return item
    }

    // MARK: - actions

    @objc private func openConfig() {
        if settingsOpener == nil {
            settingsOpener = SettingsOpener { [weak self] next in
                guard let self else { return }
                self.config = next
                self.configRevision += 1
                next.save()
                if next.thresholdAlertsEnabled {
                    NotificationManager.shared.requestIfNeeded()
                }
                self.scheduleTimer()
                self.refresh()
            }
        }
        settingsOpener?.open(config: config)
    }

    @objc private func manualRefresh() { refresh(forceReconnect: true) }

    @objc private func selectPercentRemaining() {
        selectPercentMode(.remaining)
    }

    @objc private func selectPercentUsed() {
        selectPercentMode(.used)
    }

    @objc private func selectMenuBarFiveHour() {
        selectMenuBarMode(.fiveHour)
    }

    @objc private func selectMenuBarWeekly() {
        selectMenuBarMode(.weekly)
    }

    @objc private func selectMenuBarHighest() {
        selectMenuBarMode(.highest)
    }

    @objc private func selectQuota(_ sender: NSMenuItem) {
        guard let quotaID = sender.representedObject as? String,
              let provider = lastProvider else { return }
        config.selectQuota(quotaID, for: provider.providerID)
        configRevision += 1
        config.save()
        updateTitle(provider)
        rebuildMenu(provider)
        settingsOpener?.syncIfOpen(config: config)
    }

    private func selectMenuBarMode(_ mode: Config.MenuBarDisplayMode) {
        config.menuBarDisplayMode = mode
        configRevision += 1
        config.save()
        if let provider = lastProvider {
            updateTitle(provider)
            rebuildMenu(provider)
        }
        settingsOpener?.syncIfOpen(config: config)
    }

    private func selectPercentMode(_ mode: Config.PercentDisplayMode) {
        config.percentDisplayMode = mode
        configRevision += 1
        config.save()
        if let provider = lastProvider {
            updateTitle(provider)
            rebuildMenu(provider)
        }
        settingsOpener?.syncIfOpen(config: config)
    }

    private func rebuildMenu(_ provider: ProviderUsage) {
        let menu = buildMenu(provider)
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func selectedUsageWindowKind(_ windows: [UsageWindow], quotaID: String) -> UsageWindowKind? {
        guard let provider = lastProvider,
              provider.selectedQuota(preferredID: config.selectedQuotaID(for: provider.providerID)).id == quotaID else {
            return nil
        }
        let mode = provider.effectiveDisplayMode(for: config.menuBarDisplayMode,
                                                 quotaID: quotaID)
        switch mode {
        case .fiveHour: return .fiveHour
        case .weekly: return .weekly
        case .highest:
            let fixed = windows.filter { !$0.rolling }
            return (fixed.max { $0.pct < $1.pct } ?? windows.max { $0.pct < $1.pct })?.kind
        }
    }

    private func maybeNotify(_ provider: ProviderUsage, config: Config) {
        guard config.thresholdAlertsEnabled, provider.available else {
            hasAlertBaseline = false
            lastPercents.removeAll()
            return
        }

        for quota in provider.effectiveQuotas {
            for window in quota.windows where !window.rolling {
                guard let percent = window.percent else { continue }
                let windowKey = "\(provider.providerID.rawValue)/\(quota.id)/\(window.kind.rawValue)"
                let previous = lastPercents[windowKey] ?? percent
                let levels: [(String, Double)] = [
                    ("warning", config.warningThreshold),
                    ("critical", config.criticalThreshold)
                ]
                for (level, threshold) in levels where percent >= threshold {
                    guard hasAlertBaseline, previous < threshold else { continue }
                    let label = provider.effectiveQuotas.count > 1
                        ? "\(quota.shortName) · \(window.label)"
                        : window.label
                    NotificationManager.shared.notifyLimit(label: label,
                                                           percent: Int(window.displayPercent(for: config.percentDisplayMode).rounded()),
                                                           percentMode: config.percentDisplayMode,
                                                           level: "\(windowKey)-\(level)")
                }
                lastPercents[windowKey] = percent
            }
        }
        hasAlertBaseline = true
    }

    private func scheduleSessionWatcher(for sourceFile: URL? = nil) {
        let target = sourceFile ?? newestSessionFile()
        guard target != watchedSessionPath else { return }

        sessionWatcher?.cancel()
        sessionWatcher = nil
        if sessionWatcherFD >= 0 {
            close(sessionWatcherFD)
            sessionWatcherFD = -1
        }
        watchedSessionPath = target

        guard let target else { return }
        let fd = open(target.path, O_EVTONLY)
        guard fd >= 0 else { return }
        sessionWatcherFD = fd

        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: .main
        )
        watcher.setEventHandler { [weak self] in
            self?.debouncedRefresh()
        }
        watcher.setCancelHandler { [weak self] in
            guard let self, self.sessionWatcherFD >= 0 else { return }
            close(self.sessionWatcherFD)
            self.sessionWatcherFD = -1
        }
        watcher.resume()
        sessionWatcher = watcher
    }

    private func debouncedRefresh(after delay: TimeInterval = 0.5) {
        refreshDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refresh()
            self?.scheduleSessionWatcher()
        }
        refreshDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func newestSessionFile() -> URL? {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let fm = FileManager.default
        func mtime(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true ? url : nil
        }.max { mtime($0) < mtime($1) }
    }
}

// Debug/verify mode: print parsed usage as text and exit (no GUI).
if CommandLine.arguments.contains("--once") {
    let cfg = Config.load()
    // Optional: `--once <session.jsonl>` parses a specific file (for verification).
    let override = CommandLine.arguments.dropFirst().first { $0.hasSuffix(".jsonl") }
        .map { URL(fileURLWithPath: $0) }
    let p = CodexReader.read(config: cfg, overrideFile: override)
    print("== \(p.name)  available=\(p.available)  headline=\(p.headlinePercent.map { String(format: "%.1f%%", $0) } ?? "nil")  plan=\(p.plan ?? "nil")")
    let credits = p.credits
    print("   credits=\(credits?.balance ?? "nil") hasCredits=\(credits?.hasCredits ?? false) unlimited=\(credits?.unlimited ?? false) resets=\(p.resetCredits?.availableCount ?? 0) expiry=\(p.resetCredits?.nextExpiry?.description ?? "unknown")")
    let selectedQuotaID = cfg.selectedQuotaID(for: p.providerID)
    let selectedQuota = p.selectedQuota(preferredID: selectedQuotaID)
    let selectedMode = p.effectiveDisplayMode(for: cfg.menuBarDisplayMode,
                                              quotaID: selectedQuota.id)
    print("   selected=\(selectedQuota.id)/\(selectedMode.rawValue)  menu=\(p.menuBarValue(for: selectedMode, percentMode: cfg.percentDisplayMode, quotaID: selectedQuota.id))")
    if let n = p.note { print("   note: \(n)") }
    for quota in p.effectiveQuotas {
        print("   quota \(quota.id): \(quota.name)")
        for w in quota.windows {
            let pct = w.percent.map { String(format: "%.1f%%", $0) } ?? "nil"
            let reset = w.resetAt.map { "\($0.countdownString()) (\($0))" } ?? (w.rolling ? "rolling" : "n/a")
            print("      - \(w.label): \(pct)  bar=\(w.pct.progressBar())  reset=\(reset)  detail=\(w.detail ?? "-")")
        }
        let modes = p.availableDisplayModes(quotaID: quota.id)
            .map(\.rawValue).joined(separator: ",")
        print("      modes=\(modes)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
app.run()

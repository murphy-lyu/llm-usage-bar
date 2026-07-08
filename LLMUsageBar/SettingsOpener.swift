import AppKit
import SwiftUI

private extension NSToolbarItem.Identifier {
    static let general = NSToolbarItem.Identifier("general")
    static let about = NSToolbarItem.Identifier("about")
}

final class SettingsOpener: NSObject, NSToolbarDelegate {
    private var window: NSWindow?
    private var hosting: NSHostingController<AnyView>?
    private var config = Config()
    /// Bumped every time `config` is replaced, and applied as `.id(...)` on
    /// the hosted view. GeneralSettingsTab keeps its own `@State` copy of the
    /// config it's handed; just reassigning `hosting.rootView` to a new
    /// GeneralSettingsTab value does NOT reset that @State (SwiftUI treats it
    /// as the same view identity and keeps the old state). Changing the id
    /// forces SwiftUI to tear down and recreate the view — and its @State —
    /// so it actually picks up the new config instead of silently ignoring it.
    private var configRevision = 0
    private let onChange: (Config) -> Void

    init(onChange: @escaping (Config) -> Void) {
        self.onChange = onChange
    }

    func open(config: Config) {
        self.config = config
        configRevision += 1
        if window == nil {
            window = makeWindow()
        } else {
            hosting?.rootView = view(for: window?.toolbar?.selectedItemIdentifier ?? .general)
        }

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            self.window?.orderFrontRegardless()
            // AppKit auto-focuses the first key view (the refresh-interval
            // text field) when the window becomes key, showing it selected.
            // Hand focus back to the window itself so nothing starts active.
            self.window?.makeFirstResponder(nil)
        }
    }

    /// Keeps an already-open Settings window in sync with config changes made
    /// elsewhere (e.g. picking Limit/Percentage straight from the menu bar
    /// dropdown), so the two don't show conflicting selections. A no-op if
    /// Settings isn't open — this never creates or brings forward the window.
    func syncIfOpen(config: Config) {
        self.config = config
        configRevision += 1
        guard window != nil else { return }
        hosting?.rootView = view(for: window?.toolbar?.selectedItemIdentifier ?? .general)
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "settings.title".l10n
        win.isReleasedWhenClosed = false

        let toolbar = NSToolbar(identifier: "LLMUsageBarSettings")
        toolbar.delegate = self
        toolbar.selectedItemIdentifier = .general
        toolbar.displayMode = .iconAndLabel
        win.toolbar = toolbar

        let controller = NSHostingController(rootView: view(for: .general))
        controller.sizingOptions = []
        win.contentViewController = controller
        win.setContentSize(NSSize(width: 460, height: 420))
        hosting = controller

        win.center()
        return win
    }

    private func view(for id: NSToolbarItem.Identifier) -> AnyView {
        switch id {
        case .general:
            return AnyView(GeneralSettingsTab(config: config, onChange: onChange)
                .frame(width: 460)
                .padding(.vertical, 12)
                .id(configRevision))
        default:
            return AnyView(AboutTab().frame(width: 460))
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.general, .about]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.general, .about]
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.general, .about]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .general:
            item.label = "settings.general".l10n
            item.image = NSImage(systemSymbolName: "gearshape",
                                 accessibilityDescription: "settings.general".l10n)
            item.action = #selector(selectGeneral)
            item.target = self
        case .about:
            item.label = "settings.about".l10n
            item.image = NSImage(systemSymbolName: "info.circle",
                                 accessibilityDescription: "settings.about".l10n)
            item.action = #selector(selectAbout)
            item.target = self
        default:
            break
        }
        return item
    }

    @objc private func selectGeneral() {
        window?.toolbar?.selectedItemIdentifier = .general
        hosting?.rootView = view(for: .general)
    }

    @objc private func selectAbout() {
        window?.toolbar?.selectedItemIdentifier = .about
        hosting?.rootView = view(for: .about)
    }
}

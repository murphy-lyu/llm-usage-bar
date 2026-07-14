import SwiftUI
import ServiceManagement

struct GeneralSettingsTab: View {
    private let onChange: (Config) -> Void
    @State private var config: Config
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var appLanguage = GeneralSettingsTab.normalizedLanguage(
        (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first)
    @State private var showRestartAlert = false
    @State private var refreshSecondsText: String
    @FocusState private var refreshFieldFocused: Bool

    private let languages: [(code: String, name: String)] = [
        ("en", "English"),
        ("zh-Hans", "简体中文")
    ]

    /// macOS's AppleLanguages entries carry region/script suffixes (e.g.
    /// "zh-Hans-CN", "en-US") that never exactly match our two supported
    /// picker tags ("en", "zh-Hans"), which left the Picker showing no
    /// selection. Match by leading language subtag instead.
    private static func normalizedLanguage(_ raw: String?) -> String {
        guard let raw else { return "en" }
        return raw.hasPrefix("zh") ? "zh-Hans" : "en"
    }

    init(config: Config, onChange: @escaping (Config) -> Void) {
        self.onChange = onChange
        _config = State(initialValue: config)
        _refreshSecondsText = State(initialValue: "\(Int(config.refreshSeconds.rounded()))")
    }

    var body: some View {
        Form {
            Section(header: Text("settings.section.startup")) {
                Toggle("settings.launchAtLogin", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in applyLaunchAtLogin(newValue) }
            }

            Section(header: Text("settings.section.refresh"),
                    footer: Text("settings.refreshDescription")) {
                HStack {
                    Text("settings.refreshInterval")
                    Spacer()
                    TextField("", text: $refreshSecondsText)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                        .focused($refreshFieldFocused)
                        .onChange(of: refreshSecondsText) { newValue in
                            let filtered = newValue.filter { $0.isNumber }
                            if filtered != newValue { refreshSecondsText = filtered }
                        }
                        .onSubmit { commitRefreshSecondsText() }
                        .onChange(of: refreshFieldFocused) { focused in
                            if !focused { commitRefreshSecondsText() }
                        }

                    Stepper("", value: Binding(
                        get: { Int(config.refreshSeconds.rounded()) },
                        set: { applyRefreshSeconds($0) }
                    ), in: 15...3600, step: 15)
                    .labelsHidden()
                    .onChange(of: config.refreshSeconds) { newValue in
                        if !refreshFieldFocused { refreshSecondsText = "\(Int(newValue.rounded()))" }
                    }
                }
            }


            Section(header: Text("settings.section.alerts"),
                    footer: Text("settings.alertsDescription")) {
                Toggle("settings.thresholdAlerts", isOn: Binding(
                    get: { config.thresholdAlertsEnabled },
                    set: { updateConfig(\.thresholdAlertsEnabled, $0) }
                ))

                HStack {
                    Text("settings.warningThreshold")
                    Spacer()
                    Text("\(Int(config.warningThreshold.rounded()))%")
                        .foregroundStyle(.secondary)
                    Stepper("", value: Binding(
                        get: { Int(config.warningThreshold.rounded()) },
                        set: { updateConfig(\.warningThreshold, Double(min($0, Int(config.criticalThreshold)))) }
                    ), in: 50...100, step: 5)
                    .labelsHidden()
                }
                .disabled(!config.thresholdAlertsEnabled)

                HStack {
                    Text("settings.criticalThreshold")
                    Spacer()
                    Text("\(Int(config.criticalThreshold.rounded()))%")
                        .foregroundStyle(.secondary)
                    Stepper("", value: Binding(
                        get: { Int(config.criticalThreshold.rounded()) },
                        set: { updateConfig(\.criticalThreshold, Double(max($0, Int(config.warningThreshold)))) }
                    ), in: 50...100, step: 5)
                    .labelsHidden()
                }
                .disabled(!config.thresholdAlertsEnabled)
            }

            Section(header: Text("settings.section.language"),
                    footer: Text("settings.languageFooter")) {
                Picker("settings.language", selection: $appLanguage) {
                    ForEach(languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: appLanguage) { newValue in
                    UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                    showRestartAlert = true
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .alert(
            LocalizedStringKey("settings.restartTitle"),
            isPresented: $showRestartAlert
        ) {
            Button(LocalizedStringKey("settings.restartButton"), role: .destructive) {
                restartApp()
            }
            Button(LocalizedStringKey("action.cancel"), role: .cancel) {}
        } message: {
            Text("settings.restartMessage")
        }
    }

    private func applyRefreshSeconds(_ value: Int) {
        let clamped = min(3600, max(15, value))
        guard Double(clamped) != config.refreshSeconds else { return }
        config.refreshSeconds = Double(clamped)
        onChange(config)
    }

    /// Parses the typed digits, clamps into range, and snaps the text field
    /// back to whatever value actually got applied (e.g. after clamping, or
    /// after invalid/empty input reverts to the current setting).
    private func commitRefreshSecondsText() {
        if let value = Int(refreshSecondsText) {
            applyRefreshSeconds(value)
        }
        refreshSecondsText = "\(Int(config.refreshSeconds.rounded()))"
    }

    private func updateConfig<Value>(_ keyPath: WritableKeyPath<Config, Value>, _ value: Value) {
        config[keyPath: keyPath] = value
        onChange(config)
    }

    private func applyLaunchAtLogin(_ enable: Bool) {
        do {
            if enable { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"\(bundlePath)\""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        try? proc.run()

        NSApp.terminate(nil)
    }
}

struct AboutTab: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)

            Text("Orb")
                .font(.title2.bold())
            Text(String(format: "about.versionBuild".l10n, version, build))
                .foregroundStyle(.secondary)
                .font(.subheadline)

            Divider()
                .frame(width: 150)
                .padding(.vertical, 2)

            HStack(spacing: 8) {
                Link("Twitter / X", destination: URL(string: "https://x.com/murphy_latte")!)
                Text("·")
                    .foregroundStyle(.tertiary)
                Link("GitHub", destination: URL(string: "https://github.com/murphy-lyu/llm-usage-bar")!)
            }
            .font(.caption)

            Text("@Murphy")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

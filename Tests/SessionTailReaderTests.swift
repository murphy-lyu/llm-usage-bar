import Foundation

@main
struct SessionTailReaderTests {
    static func main() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("orb-large-session-\(UUID().uuidString).jsonl")
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
        }

        // Invalid UTF-8 in the old part proves the reader only decodes the
        // bounded tail. Loading the entire file as String would fail.
        try handle.write(contentsOf: Data(repeating: 0xFF, count: 5 * 1024 * 1024))
        try handle.write(contentsOf: Data("\n".utf8))
        let event = """
        {"timestamp":"2026-10-12T10:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":42,"window_minutes":300,"resets_at":2000000000}}}}

        """
        try handle.write(contentsOf: Data(event.utf8))
        try handle.synchronize()

        var config = Config()
        config.percentDisplayMode = .remaining
        let provider = CodexReader.read(config: config, overrideFile: file)
        assert(provider.available)
        assert(provider.windows.first?.percent == 42)
        assert(provider.menuBarValue(for: .fiveHour, percentMode: .remaining) == "5h · 58%")
        print("Session tail reader tests passed.")
    }
}

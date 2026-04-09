import Foundation

enum BinaryLocator {

    /// 按优先级查找 claude CLI 二进制。
    /// 优先级：环境变量 > ~/.local/bin > /usr/local/bin > which
    static func locate() -> String? {
        if let envPath = ProcessInfo.processInfo.environment["CLAUDE_BINARY_PATH"],
           FileManager.default.isExecutableFile(atPath: envPath) {
            return envPath
        }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(homeDir)/.local/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return whichClaude()
    }

    private static func whichClaude() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return path
    }
}

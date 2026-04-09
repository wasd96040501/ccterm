import Foundation

enum ShellEnvironment {

    /// 从登录 shell 加载完整环境变量。每次调用都重新执行，确保拿到最新的 shell 配置。
    static func loginEnvironment() -> [String: String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-li", "-c", "env"]
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
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        var env: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eqIndex])
            let value = String(line[line.index(after: eqIndex)...])
            env[key] = value
        }
        return env.isEmpty ? nil : env
    }
}

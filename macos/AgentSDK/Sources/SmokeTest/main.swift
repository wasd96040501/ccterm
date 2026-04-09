import Foundation
import AgentSDK

let config = SessionConfiguration(
    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    permissionMode: .plan,
    systemPrompt: .custom("You are a helpful assistant. Reply briefly."),
    maxTurns: 1
)

let session = Session(configuration: config)
let done = DispatchSemaphore(value: 0)

session.onMessage = { (message: Message2) in
    switch message {
    case .assistant(let msg):
        for block in msg.message?.content ?? [] {
            if case .text(let t) = block {
                print("[assistant] \(t.text ?? "")")
            }
        }
    case .result(let resultMsg):
        switch resultMsg {
        case .success(let s):
            print("[result] success=true, turns=\(s.numTurns ?? 0), sessionId=\(s.sessionId ?? "unknown")")
            if let cost = s.totalCostUsd {
                print("[result] cost=$\(String(format: "%.4f", cost))")
            }
        case .errorDuringExecution(let e):
            print("[result] success=false, errors=\(e.errors ?? [])")
        default:
            break
        }
        done.signal()
    default:
        break
    }
}

session.onStderr = { (text: String) in
    print("[stderr] \(text)")
}

session.onProcessExit = { (code: Int32) in
    print("[exit] code=\(code)")
    if code != 0 { done.signal() }
}

session.onPermissionRequest = { (request: PermissionRequest, completion: @escaping (PermissionDecision) -> Void) in
    print("[permission] tool=\(request.toolName)")
    completion(.deny(reason: "SmokeTest: auto-deny all tools"))
}

do {
    try await session.start()
    print("[info] Session started, sending message...")
    session.sendMessage("Say hello in one sentence.")
    done.wait()
} catch {
    print("[error] \(error)")
    exit(1)
}

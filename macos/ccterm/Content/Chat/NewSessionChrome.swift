import SwiftUI

/// 悬浮在 ChatHistoryView 顶部的 z-overlay,在**所有** session(draft + history)
/// 上常驻。其作用是双重的:
///
/// 1. 功能:draft 状态(`!handle.hasRecord`)下提供一个"从 ~/dev 启动"的入口。
/// 2. 视觉证据:overlay 在 Start 前后**不消失**,只切换自身形态(big card → small pill);
///    底下 ChatHistoryView 的 `.id` 不变 — 如果 NSView 真的没被 SwiftUI 拆重建,
///    这段 chrome 自身的 spring 动画就会平滑;一旦底层重建,chrome 也会跟着闪。
///
/// 形态切换由 observable `handle.hasRecord` 驱动,wrap 在 `withAnimation` 里。
struct NewSessionChrome: View {
    let handle: SessionHandle2
    let onStarted: (String) -> Void

    var body: some View {
        Group {
            if handle.hasRecord {
                statusPill
            } else {
                startCard
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.78),
                   value: handle.hasRecord)
    }

    /// draft 形态:大卡片 + Start 按钮。
    private var startCard: some View {
        VStack(spacing: 12) {
            Text("New Session")
                .font(.title2.bold())
            Text("Hardcoded cwd: ~/dev")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(action: start) {
                Label("Start from ~/dev", systemImage: "play.fill")
                    .frame(minWidth: 160)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .shadow(radius: 8, y: 2)
        .padding(20)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 0.55, anchor: .top).combined(with: .opacity)
        ))
    }

    /// 已 persist 形态:顶部小药丸状态指示,证明 chrome 没被销毁。
    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusLabel)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(radius: 3, y: 1)
        .padding(.top, 10)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.6, anchor: .top).combined(with: .opacity),
            removal: .scale(scale: 0.9).combined(with: .opacity)
        ))
    }

    private var statusLabel: String {
        switch handle.status {
        case .notStarted: return "idle"
        case .starting: return "starting…"
        case .idle: return "ready"
        case .responding: return "responding"
        case .interrupting: return "interrupting…"
        case .stopped: return "stopped"
        }
    }

    private var statusColor: Color {
        switch handle.status {
        case .notStarted, .stopped: return .secondary
        case .starting, .interrupting: return .orange
        case .idle: return .green
        case .responding: return .blue
        }
    }

    private func start() {
        let dev = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("dev")
            .path
        handle.setCwd(dev)
        // activate() 同步走 ensureStarted → persistConfiguration → hasRecord=true。
        // wrap 在 withAnimation 里让 chrome 形态切换走 spring 动画。
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
            handle.activate()
        }
        onStarted(handle.sessionId)
    }
}

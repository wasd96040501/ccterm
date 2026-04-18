import SwiftUI

/// Fallback tool block for tools without a dedicated renderer (and for
/// `Skill(name)` — where we just show "Skill(<name>)" in the header). Only
/// the error state produces expandable content.
struct GenericToolBlock: View {
    let name: String
    let status: ToolBlockStatus

    var body: some View {
        ToolBlock(status: status) {
            Label(name, systemImage: "wrench.and.screwdriver")
        }
    }
}

// MARK: - Previews

#Preview("Idle") {
    GenericToolBlock(name: "CronCreate", status: .idle)
        .padding()
        .frame(width: 400)
}

#Preview("Running") {
    GenericToolBlock(name: "CronList", status: .running)
        .padding()
        .frame(width: 400)
}

#Preview("Error") {
    GenericToolBlock(
        name: "Skill(pdf)",
        status: .error("skill not installed")
    )
    .padding()
    .frame(width: 400)
}

#Preview("Stacked") {
    VStack(spacing: 8) {
        GenericToolBlock(name: "CronCreate", status: .idle)
        GenericToolBlock(name: "CronList", status: .running)
        GenericToolBlock(name: "Skill(pdf)", status: .error("not installed"))
    }
    .padding()
    .frame(width: 400)
}

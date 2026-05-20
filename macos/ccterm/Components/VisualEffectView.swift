import AppKit
import SwiftUI

/// SwiftUI wrapper around `NSVisualEffectView`. Drop it behind content
/// (typically via `.background { … }` or as the bottom layer of a
/// `ZStack`) when the surface needs vibrancy — i.e. the desktop wallpaper
/// and any windows behind ours should faintly bleed through — rather than
/// the flat opaque `Color(nsColor: .windowBackgroundColor)` SwiftUI
/// applies by default.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State

    init(
        material: NSVisualEffectView.Material = .windowBackground,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .followsWindowActiveState
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

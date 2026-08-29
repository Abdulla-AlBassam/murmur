import AppKit
import SwiftUI

/// The floating capsule shown at the bottom of the screen while dictating,
/// hosted in a borderless, non-activating panel so it never steals focus
/// from the app the user is dictating into.
@MainActor
final class RecordingPill {
    enum Mode { case listening, working }

    private var panel: NSPanel?

    func show(_ mode: Mode) {
        if panel == nil { panel = Self.makePanel() }
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: PillView(mode: mode))
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 28))
    }
}

private struct PillView: View {
    let mode: RecordingPill.Mode
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            switch mode {
            case .listening:
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                    .scaleEffect(pulsing ? 1.0 : 0.6)
                    .opacity(pulsing ? 1.0 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                        value: pulsing
                    )
                    .onAppear { pulsing = true }
                Text("Listening…")
            case .working:
                ProgressView()
                    .controlSize(.small)
                Text("Polishing…")
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

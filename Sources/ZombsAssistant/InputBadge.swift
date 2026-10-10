import AppKit
import SwiftUI

/// A small click-through label at the top of the game showing whether the assistant is sending input
/// and what it is doing. It never takes focus, and the capture records only the game window, so the
/// label is not part of what the assistant sees.
@MainActor
final class InputBadge {
    /// Where the label sits: the top of the game area, or above your character where you are looking.
    enum Placement { case top, aboveCharacter }
    final class Content: ObservableObject {
        @Published var title = ""
        @Published var detail = ""
        @Published var color = Color.gray
    }
    private var panel: NSPanel?
    private let content = Content()
    private var placed = CGRect.null
    private let placement: Placement
    static let size = CGSize(width: 360, height: 46)
    init(placement: Placement = .top) { self.placement = placement }

    /// - Parameters:
    ///   - windowBounds: the game window in global display points, top-left origin.
    ///   - contentRect: the captured game area inside that window.
    func show(title: String, detail: String, color: Color, windowBounds: CGRect, contentRect: CGRect) {
        content.title = title; content.detail = detail; content.color = color
        let panel = self.panel ?? makePanel()
        // Display coordinates start at the top left of the primary screen; AppKit's start at its bottom left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let top = windowBounds.minY + contentRect.minY + (placement == .top ? 8 : contentRect.height * 0.3 - Self.size.height / 2)
        let frame = CGRect(x: windowBounds.minX + contentRect.midX - Self.size.width / 2,
                           y: primaryHeight - top - Self.size.height, width: Self.size.width, height: Self.size.height)
        if frame != placed { panel.setFrame(frame, display: true); placed = frame }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: BadgeView(content: content))
        self.panel = panel
        return panel
    }
}

private struct BadgeView: View {
    @ObservedObject var content: InputBadge.Content
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(content.color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(content.title).font(.system(size: 13, weight: .bold))
                if !content.detail.isEmpty { Text(content.detail).font(.system(size: 11)).lineLimit(1).opacity(0.85) }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(content.color.opacity(0.9), lineWidth: 1.5))
        .frame(width: InputBadge.size.width, height: InputBadge.size.height)
    }
}

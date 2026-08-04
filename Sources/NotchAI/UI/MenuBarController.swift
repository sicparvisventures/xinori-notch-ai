import AppKit
import SwiftUI

/// The app's presence in the menu bar.
///
/// Until now NotchAI was invisible when it ran and unreachable when it wedged —
/// `pkill` was the only way to stop it, which is not something you can ask of
/// the people this is aimed at. The status item fixes that and gives the state
/// that previously only existed in the log file a place to live.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let app: AppModel
    private let notch: NotchModel

    init(app: AppModel, notch: NotchModel) {
        self.app = app
        self.notch = notch
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = Self.icon()
            button.image?.isTemplate = true      // follows light/dark menu bars
            button.action = #selector(toggle)
            button.target = self
        }

        popover.behavior = .transient            // click away to dismiss
        popover.animates = true

        // Let the SwiftUI content own the size rather than guessing a
        // `contentSize` here. (The guess was mostly harmless — the hosting
        // controller's intrinsic size won anyway — but stating a wrong number
        // and relying on it being ignored is not a plan.)
        let controller = NSHostingController(
            rootView: MenuBarMenu(app: app, chat: app.chat, ollama: app.ollama,
                                  notch: notch, dismiss: { [weak self] in self?.popover.close() })
        )
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.close()
        } else if let button = statusItem.button {
            // Refresh before showing: the status line is the point of this menu.
            Task { await app.ollama.refresh() }
            // This is the one that mattered: `.maxY` puts the popover *above*
            // the status item, and the status item is already at the top of the
            // screen — so it landed off-screen and read as the menu jumping up
            // into nothing. `.minY` hangs it below, where a menu belongs.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// A 16pt notch drawn in code, as a template image so macOS tints it.
    private static func icon() -> NSImage {
        let size = NSSize(width: 17, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let notchWidth: CGFloat = 7
            let notch = NSRect(x: rect.midX - notchWidth / 2, y: rect.maxY - 4,
                               width: notchWidth, height: 4)
            NSBezierPath(roundedRect: notch, xRadius: 1.5, yRadius: 1.5).fill()

            let panel = NSRect(x: rect.minX + 1.5, y: rect.minY + 2,
                               width: rect.width - 3, height: rect.height - 7)
            let path = NSBezierPath(roundedRect: panel, xRadius: 3, yRadius: 3)
            path.lineWidth = 1.4
            path.stroke()
            return true
        }
        return image
    }
}

private struct MenuBarMenu: View {
    @ObservedObject var app: AppModel
    @ObservedObject var chat: ChatModel
    @ObservedObject var ollama: OllamaSetup
    let notch: NotchModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            group {
                item("Open paneel", icon: "rectangle.topthird.inset.filled") {
                    notch.open(); dismiss()
                }
                item("Nieuw gesprek", icon: "square.and.pencil") {
                    chat.reset(); notch.open(); dismiss()
                }
            }
            Divider()
            group {
                item("Instellingen…", icon: "gearshape") {
                    app.route = .settings; notch.open(); dismiss()
                }
            }
            Divider()
            group {
                item("Afsluiten", icon: "power") {
                    NSApp.terminate(nil)
                }
            }
        }
        .frame(width: 260)
        .padding(.vertical, 6)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text("Xinori Notch AI")
                    .font(.system(size: 12.5, weight: .bold))
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Circle()
                        .fill(ready ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                    Text(statusText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ready ? .green : .orange)
                }
            }
            Text("\(chat.providerID.displayName) · \(chat.model) · \(toolCount) tools")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 13)
        .padding(.bottom, 8)
    }

    private var ready: Bool {
        chat.providerID.isLocal ? ollama.step.isReady : true
    }

    private var statusText: String {
        if chat.isStreaming { return "Bezig" }
        return ready ? "Gereed" : "Ollama uit"
    }

    private var toolCount: Int {
        guard chat.toolsEnabled else { return 0 }
        return chat.orchestrationEnabled
            ? ToolDomain.allCases.count
            : ToolRegistry.shared.tools.count
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }.padding(.vertical, 3)
    }

    private func item(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 15)
                    .foregroundStyle(.secondary)
                Text(title).font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }
}

/// Hover highlight, the way a real menu behaves.
private struct MenuRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering ? Color.primary.opacity(0.08) : .clear)
            .onHover { hovering = $0 }
    }
}

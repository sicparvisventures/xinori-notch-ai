import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var app: AppModel

    private var size: CGSize { model.currentSize }

    private var topRadius: CGFloat { model.state == .open ? 14 : 10 }

    private var bottomRadius: CGFloat {
        switch model.state {
        case .closed: return 11   // matches the hardware corner closely enough to disappear
        case .hover:  return 14
        case .open:   return 26
        }
    }

    /// A notch blends into hardware and needs the concave shoulders; a pill has
    /// nothing to blend into, so it is rounded all round.
    private var shape: AnyShape {
        switch model.placement.style {
        case .notch:
            return AnyShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
        case .pill:
            return AnyShape(RoundedRectangle(cornerRadius: model.state == .open ? 18 : 13,
                                             style: .continuous))
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .overlay { shape.stroke(Color.white.opacity(model.state == .open ? 0.09 : 0), lineWidth: 1) }
                .shadow(color: .black.opacity(model.state == .open ? 0.5 : 0), radius: 24, y: 8)
                .frame(width: size.width, height: size.height)
                .overlay {
                    if model.state == .open {
                        openContent
                            .frame(width: size.width, height: size.height)
                            .transition(.opacity)
                    } else if model.state == .hover {
                        listeningHint
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Animate on the state itself so shape, size and content morph as one.
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.state)
    }

    /// Settings and onboarding live in the same panel as the chat rather than
    /// in a separate window — a floating preferences window would break the
    /// illusion that this is part of the hardware.
    @ViewBuilder
    private var openContent: some View {
        switch app.route {
        case .onboarding:
            OnboardingView(app: app, ollama: app.ollama, chat: app.chat)
        case .chat:
            ChatPanel(app: app, chat: app.chat, transcriber: app.transcriber)
        case .settings:
            SettingsView(app: app, chat: app.chat, ollama: app.ollama)
        }
    }

    /// The hover state is 38pt tall — room for a hairline, nothing more.
    private var listeningHint: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 4, height: 4)
            Circle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 4, height: 4)
        }
        .offset(y: 10)
    }
}

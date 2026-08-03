import SwiftUI

/// Shared building blocks for the panel's screens, so settings and onboarding
/// feel like the same object as the chat rather than three different dialogs.
enum Panel {
    static let ink = Color.white
    static let inkSoft = Color.white.opacity(0.62)
    static let inkFaint = Color.white.opacity(0.38)
    static let surface = Color.white.opacity(0.07)
    static let hairline = Color.white.opacity(0.09)
}

/// Small uppercase group head — the one element that marks every section.
struct GroupHead: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.9)
            .foregroundStyle(Panel.inkFaint)
    }
}

/// The bar at the top of settings and onboarding: a title, an optional back
/// arrow, and an optional close.
struct PanelHeader: View {
    let title: String
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Panel.inkSoft)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text(title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(Panel.ink)

            Spacer(minLength: 0)

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Panel.inkSoft)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// A filled primary action.
struct PanelButton: View {
    let title: String
    var icon: String?
    var prominent = true
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.black.opacity(0.88) : Panel.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(prominent ? Color.white.opacity(enabled ? 0.92 : 0.3)
                                    : Color.white.opacity(0.10))
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A labelled row with a trailing control, used throughout settings.
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Panel.ink.opacity(0.9))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Panel.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 7)
    }
}

/// A compact switch that reads on a dark surface.
struct PanelToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 999)
                .fill(isOn ? Color.white.opacity(0.85) : Color.white.opacity(0.14))
                .frame(width: 32, height: 18)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(isOn ? Color.black.opacity(0.8) : Color.white.opacity(0.7))
                        .frame(width: 13, height: 13)
                        .padding(2.5)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

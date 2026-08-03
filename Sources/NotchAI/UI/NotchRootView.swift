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

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                .fill(.black)
                .overlay {
                    NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                        .stroke(Color.white.opacity(model.state == .open ? 0.09 : 0), lineWidth: 1)
                }
                .shadow(color: .black.opacity(model.state == .open ? 0.5 : 0), radius: 24, y: 8)
                .frame(width: size.width, height: size.height)
                .overlay {
                    if model.state == .open {
                        ChatPanel(app: app)
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

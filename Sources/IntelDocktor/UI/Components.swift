import SwiftUI

struct DrawerTab: Identifiable, Hashable {
    var id: String
    var symbol: String
    var label: String
}

/// The icon row at the top of every drawer: the selected tab expands into
/// an icon + label pill, the others stay as bare icons.
struct DrawerTabBar<Trailing: View>: View {
    var tabs: [DrawerTab]
    @Binding var selection: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                TabButton(tab: tab, selected: tab.id == selection) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = tab.id }
                }
            }
            Spacer(minLength: 4)
            trailing()
        }
        .frame(height: 34)
    }
}

extension DrawerTabBar where Trailing == EmptyView {
    init(tabs: [DrawerTab], selection: Binding<String>) {
        self.init(tabs: tabs, selection: selection) { EmptyView() }
    }
}

private struct TabButton: View {
    var tab: DrawerTab
    var selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                if selected {
                    Text(tab.label)
                        .font(Theme.font(14, .bold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(selected ? Theme.primary : Theme.secondary)
            .padding(.horizontal, selected ? 11 : 9)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.12) : (hover ? Color.white.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tab.label)
    }
}

struct IconButton: View {
    var symbol: String
    var size: CGFloat = 15
    var tint: Color = Theme.secondary
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(hover ? Theme.primary : tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hover ? Color.white.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Capsule text button ("Next", "Remind 5m").
struct PillButton: View {
    var title: String
    var prominent: Bool = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(14, .bold))
                .foregroundStyle(prominent ? Theme.primary : Theme.secondary)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(Color.black.opacity(hover ? 0.42 : 0.3)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Row that lights up on hover, used by lists inside drawers.
struct HoverRow<Content: View>: View {
    var radius: CGFloat = 12
    var action: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hover ? Theme.tileHover : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { action?() }
    }
}

/// Small square rounded tile holding a symbol (weather icon, CPU badge…).
struct SymbolTile: View {
    var symbol: String
    var size: CGFloat
    var symbolSize: CGFloat? = nil
    var tint: Color = .white
    var background: Color = Theme.tile

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: symbolSize ?? size * 0.48, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(background))
    }
}

/// Faint placeholder used when a widget needs a permission or has no data.
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String? = nil
    var buttonTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
            Text(title)
                .font(Theme.font(14, .bold))
                .foregroundStyle(Theme.secondary)
            if let message {
                Text(message)
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
            }
            if let buttonTitle, let action {
                PillButton(title: buttonTitle, prominent: true, action: action)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat? = nil

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(hex: 0xF25C8A), Color(hex: 0x8E44FF)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius ?? size * 0.2, style: .continuous))
    }
}

extension View {
    @ViewBuilder func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

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
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                // The highlight slides from tab to tab rather than fading.
                TabButton(tab: tab, selected: tab.id == selection, pill: pill) {
                    withAnimation(Motion.snappy) { selection = tab.id }
                }
            }
            Spacer(minLength: 4)
            trailing()
        }
        .frame(height: 28)
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
    var pill: Namespace.ID
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .symbolVariant(selected ? .fill : .none)
                    .frame(width: 15)
                if selected {
                    Text(tab.label)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
            }
            .foregroundStyle(selected ? Theme.primary : (hover ? Theme.primary.opacity(0.85) : Theme.secondary))
            .padding(.horizontal, selected ? 10 : 7)
            .frame(height: 26)
            .background {
                if selected {
                    Capsule().fill(Color.white.opacity(0.14))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                        .matchedGeometryEffect(id: "pill", in: pill)
                } else if hover {
                    Capsule().fill(Color.white.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .onHover { h in withAnimation(Motion.snappy) { hover = h } }
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
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(hover ? Theme.primary : tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hover ? Color.white.opacity(0.1) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.88))
        .onHover { h in withAnimation(Motion.snappy) { hover = h } }
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primary.opacity(prominent ? 1 : 0.85))
                .padding(.horizontal, 14)
                .frame(height: 28)
                // Prominent buttons take the accent color, like Apple's.
                .background(Capsule().fill(prominent ? AnyShapeStyle(Theme.accent.opacity(hover ? 1 : 0.9))
                                                     : AnyShapeStyle(Color.white.opacity(hover ? 0.18 : 0.12))))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.95))
        .onHover { h in withAnimation(Motion.snappy) { hover = h } }
    }
}

/// Row that lights up on hover, used by lists inside drawers.
struct HoverRow<Content: View>: View {
    var radius: CGFloat = 10
    var action: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hover ? Theme.tileHover : .clear)
            )
            .contentShape(Rectangle())
            .onHover { h in withAnimation(Motion.snappy) { hover = h } }
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
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            if let message {
                Text(message)
                    .font(.system(size: 11, weight: .regular))
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

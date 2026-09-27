import SwiftUI

enum Theme {
    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 10
    static let radiusLarge: CGFloat = 20

    static let cornerRadius: CGFloat = radiusLarge
    static let innerPadding: CGFloat = 22
    /// Codex-like neutral surfaces with one restrained blue accent. Recording
    /// status keeps its own red so the action remains immediately legible.
    static let accent = Color(red: 0.10, green: 0.42, blue: 0.95)
    static let recordingAccent: Color = .red
    static let panelFill = Color.primary.opacity(0.045)
    static let panelBorder = Color.primary.opacity(0.11)
    static let subtle: Color = .primary.opacity(0.65)

    static let space2: CGFloat = 4   // 4 pt
    static let space3: CGFloat = 6   // 6 pt
    static let space4: CGFloat = 8   // 8 pt
    static let space6: CGFloat = 12  // 12 pt
    static let space8: CGFloat = 16  // 16 pt
    static let space12: CGFloat = 24 // 24 pt

    static let monoFont = Font.system(.body, design: .monospaced)
    static let titleFont = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let sectionTitleFont = Font.system(size: 15, weight: .medium, design: .rounded)

    static func speakerColor(for index: Int) -> Color {
        TagColor.allCases[index % TagColor.allCases.count].swiftUIColor
    }
}

struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .opacity(reduceMotion && configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { .init() }
}

struct ChipHoverModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func chipHover() -> some View {
        modifier(ChipHoverModifier())
    }
}

/// A quiet Codex-style panel. Keep the name for existing callers, but avoid
/// translucent Liquid Glass chrome in the main app surface.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.cornerRadius
    var padding: CGFloat = Theme.innerPadding
    let content: () -> Content

    init(cornerRadius: CGFloat = Theme.cornerRadius,
         padding: CGFloat = Theme.innerPadding,
         @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .background(
                Theme.panelFill,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.panelBorder, lineWidth: 0.7)
            }
    }
}

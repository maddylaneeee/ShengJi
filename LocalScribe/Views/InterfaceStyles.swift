import SwiftUI

private struct PrimaryActionStyleModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    func primaryActionStyle() -> some View {
        modifier(PrimaryActionStyleModifier())
    }
}

import SwiftUI

extension Color {
    static let neonGreen = Color(red: 0.22, green: 1.0, blue: 0.08)
    static let electricOrange = Color(red: 1.0, green: 0.45, blue: 0.0)
    static let glassBackground = Color(white: 1.0, opacity: 0.05)
}

struct GlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
    }
}

extension View {
    func glassCard() -> some View {
        self.modifier(GlassCardModifier())
    }
    
    func premiumRounded() -> some View {
        self.fontDesign(.rounded)
    }
}

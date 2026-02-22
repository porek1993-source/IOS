import SwiftUI

struct ShimmerEffect: View {
    @State private var phase: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.15)
                
                LinearGradient(
                    gradient: Gradient(colors: [.clear, .white.opacity(0.1), .clear]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geometry.size.width)
                .offset(x: -geometry.size.width + (phase * geometry.size.width * 2))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
        .clipped()
    }
}

extension View {
    func shimmer() -> some View {
        self.overlay(ShimmerEffect())
    }
}

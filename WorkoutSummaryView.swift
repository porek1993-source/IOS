import SwiftUI

struct WorkoutSummaryView: View {
    @Environment(WorkoutViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var animate = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Confetti Layer
            ConfettiCannon(trigger: $animate)
            
            VStack(spacing: 30) {
                Spacer()
                
                // Trophy/Checkmark Icon
                ZStack {
                    Circle()
                        .fill(Color.neonGreen.opacity(0.1))
                        .frame(width: 120, height: 120)
                    
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.neonGreen)
                        .scaleEffect(animate ? 1.0 : 0.5)
                        .opacity(animate ? 1.0 : 0.0)
                }
                
                VStack(spacing: 8) {
                    Text("WORKOUT COMPLETE")
                        .font(.caption)
                        .fontWeight(.black)
                        .foregroundColor(.neonGreen)
                        .tracking(4)
                    
                    Text("Crushed it!")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                
                // Statistics
                HStack(spacing: 20) {
                    StatBox(title: "TOTAL WEIGHT", value: String(format: "%.0f", viewModel.summaryWeight), unit: "kg")
                    StatBox(title: "DURATION", value: "\(viewModel.summaryDuration)", unit: "min")
                }
                .padding(.horizontal)
                
                Spacer()
                
                Button {
                    viewModel.showSummary = false
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.neonGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                animate = true
            }
        }
    }
}

struct StatBox: View {
    let title: String
    let value: String
    let unit: String
    
    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.white.opacity(0.5))
            
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(unit)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .glassCard()
    }
}

// MARK: - Confetti Logic
struct ConfettiCannon: View {
    @Binding var trigger: Bool
    @State private var particles: [ConfettiParticle] = []
    
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                for index in particles.indices {
                    let particle = particles[index]
                    let elapsed = timeline.date.timeIntervalSince(particle.createdAt)
                    
                    if elapsed < 3 {
                        let x = particle.x * size.width
                        let y = particle.y * size.height + (elapsed * 300)
                        let rotation = particle.rotation * elapsed * 2
                        
                        var path = Path()
                        path.addRect(CGRect(x: -5, y: -5, width: 10, height: 10))
                        
                        context.concatenate(CGAffineTransform(translationX: x, y: y))
                        context.concatenate(CGAffineTransform(rotationAngle: rotation))
                        context.fill(path, with: .color(particle.color))
                        context.concatenate(CGAffineTransform(rotationAngle: -rotation))
                        context.concatenate(CGAffineTransform(translationX: -x, y: -y))
                    }
                }
            }
        }
        .onChange(of: trigger) { oldValue, newValue in
            if newValue {
                generateParticles()
            }
        }
    }
    
    private func generateParticles() {
        let colors: [Color] = [.neonGreen, .electricOrange, .blue, .purple, .pink]
        for _ in 0..<80 {
            particles.append(ConfettiParticle(
                x: Double.random(in: 0...1),
                y: Double.random(in: -0.5...0),
                color: colors.randomElement()!,
                rotation: Double.random(in: 0...Double.pi * 2)
            ))
        }
    }
}

struct ConfettiParticle: Identifiable {
    let id = UUID()
    let x: Double
    let y: Double
    let color: Color
    let rotation: Double
    let createdAt = Date()
}

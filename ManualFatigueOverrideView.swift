import SwiftUI
import SwiftData

struct ManualFatigueOverrideView: View {
    @Environment(WorkoutViewModel.self) private var viewModel
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Manually mark muscles as exhausted if you've done activities outside of HealthKit (e.g., helping a friend move).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("All Muscle Groups") {
                    ForEach(MuscleGroup.allCases) { muscle in
                        let fatigue = viewModel.fatigueProfile?.currentFatigue() ?? [:]
                        let isHigh = (fatigue[muscle] ?? .none) >= .medium
                        
                        Button {
                            viewModel.toggleManualFatigue(for: muscle)
                        } label: {
                            HStack {
                                Text(muscle.rawValue)
                                    .foregroundColor(.primary)
                                Spacer()
                                if isHigh {
                                    Text("Exhausted")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.red)
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                } else {
                                    Text("Rested")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Manual Override")
            .background(Color(white: 0.05))
            .scrollContentBackground(.hidden)
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ManualFatigueOverrideView()
        .environment(WorkoutViewModel.preview)
}

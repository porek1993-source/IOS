import SwiftUI
import SwiftData

struct ActiveWorkoutView: View {
    @Environment(WorkoutViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if viewModel.activeWorkoutSlots.isEmpty {
                        ContentUnavailableView("No active workout", systemImage: "bolt.slash.fill", description: Text("Generate a workout from the dashboard to start."))
                    } else {
                        ForEach(Array(viewModel.activeWorkoutSlots.enumerated()), id: \.offset) { index, slot in
                            ExerciseCard(index: index, slot: slot)
                        }
                    }
                    
                    if !viewModel.activeWorkoutSlots.isEmpty {
                        Button {
                            HapticManager.success()
                            viewModel.finishWorkout()
                        } label: {
                            Text("Complete Session")
                                .fontWeight(.bold)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.neonGreen)
                                .foregroundColor(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .padding(.top, 20)
                        .shadow(color: .neonGreen.opacity(0.2), radius: 10)
                    }
                }
                .padding()
            }
            .background(Color(white: 0.05))
            .navigationTitle("Active Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("End Early") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $viewModel.showSummary) {
            WorkoutSummaryView()
                .environment(viewModel)
        }
    }
}

struct ExerciseCard: View {
    let index: Int
    let slot: WorkoutSlot
    @Environment(WorkoutViewModel.self) private var viewModel
    
    @State private var weight: String = ""
    @State private var reps: String = ""
    @State private var imageURL: URL? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // MARK: - Illustration
            Group {
                if let url = imageURL {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 180)
                            .cornerRadius(12)
                    } placeholder: {
                        ShimmerEffect()
                            .frame(height: 180)
                            .cornerRadius(12)
                    }
                } else {
                    Rectangle()
                        .fill(Color(white: 0.15))
                        .frame(height: 180)
                        .cornerRadius(12)
                        .overlay(
                            Image(systemName: "figure.strengthtraining.functional")
                                .font(.largeTitle)
                                .foregroundColor(.white.opacity(0.2))
                        )
                }
            }
            .task {
                imageURL = await WgerManager.shared.fetchIllustration(for: slot.exercise.name)
            }
            // MARK: - Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(slot.exercise.name)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.neonGreen)
                    
                    Text("\(slot.recommendedSets) sets × \(slot.recommendedReps.lowerBound)-\(slot.recommendedReps.upperBound) reps")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                }
                
                Spacer()
                
                Button {
                    HapticManager.light()
                    viewModel.swapExercise(at: index)
                    Task {
                        imageURL = await WgerManager.shared.fetchIllustration(for: activeSlot.exercise.name)
                    }
                } label: {
                    Label("Swap", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.1))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }
            
            // MARK: - Progression Info
            if let target = slot.progressionTarget {
                HStack {
                    VStack(alignment: .leading) {
                        Text("LAST TIME")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", target.lastWeightKg))kg × \(target.lastReps)")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing) {
                        Text("TARGET")
                            .font(.caption2)
                            .foregroundColor(.electricOrange)
                        Text(target.strategy.rawValue)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.electricOrange)
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)
            }
            
            // MARK: - Input/Logging
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Weight (kg)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("0", text: $weight)
                        .keyboardType(.decimalPad)
                        .padding(10)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reps")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("0", text: $reps)
                        .keyboardType(.numberPad)
                        .padding(10)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                }
                
                Button {
                    if let w = Double(weight), let r = Int(reps) {
                        HapticManager.medium()
                        viewModel.logSetForExercise(exercise: slot.exercise, weight: w, reps: r)
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.neonGreen)
                }
                .padding(.top, 18)
            }
        }
        .padding()
        .glassCard()
    }
    
    private var activeSlot: WorkoutSlot {
        viewModel.activeWorkoutSlots[index]
    }
}

#Preview {
    ActiveWorkoutView()
        .environment(WorkoutViewModel.preview)
}

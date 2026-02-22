import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(WorkoutViewModel.self) private var viewModel
    @State private var showingSetup = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ready for a workout?")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.neonGreen)
                    
                    Text("Your engine is optimized based on your recent activity.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.top)
                
                // MARK: - Recent Activity (HealthKit)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent Sports")
                        .font(.headline)
                        .padding(.horizontal)
                    
                    if viewModel.healthKitManager.zpracovanéTréninky.isEmpty {
                        ContentUnavailableView("No recent sports", systemImage: "figure.run", description: Text("Sync with HealthKit to see your activity."))
                            .frame(height: 120)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(viewModel.healthKitManager.zpracovanéTréninky, id: \.source.uuid) { processed in
                                    RecentActivityCard(workout: processed)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                
                // MARK: - Body Map
                VStack(alignment: .leading, spacing: 12) {
                    Text("Muscle Status")
                        .font(.headline)
                        .padding(.horizontal)
                    
                    BodyMapGrid(fatigue: viewModel.fatigueProfile?.currentFatigue() ?? [:])
                        .padding(.horizontal)
                }
                
                Spacer(minLength: 40)
                
                // MARK: - Generate Button
                Button {
                    showingSetup = true
                } label: {
                    HStack {
                        Image(systemName: "bolt.fill")
                        Text("Generate Workout")
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.neonGreen)
                    .foregroundColor(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Color.neonGreen.opacity(0.3), radius: 10, x: 0, y: 5)
                }
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
        }
        .background(Color(white: 0.05)) // Deep dark mode
        .sheet(isPresented: $showingSetup) {
            WorkoutSetupView()
                .environment(viewModel)
        }
    }
}

struct RecentActivityCard: View {
    let workout: ProcessedWorkout
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "figure.run")
                    .foregroundColor(.blue)
                Spacer()
                Text(workout.source.startDate, style: .date)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Text(ActivityFatigueMapper.lokalizovanyNazev(pro: workout.source.workoutActivityType))
                .font(.subheadline)
                .fontWeight(.semibold)
            
            Text("\(Int(workout.source.duration / 60)) min")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 140)
        .glassCard()
    }
}

struct BodyMapGrid: View {
    let fatigue: [MuscleGroup: FatigueLevel]
    
    let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 12)
    ]
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(MuscleGroup.allCases) { group in
                let level = fatigue[group] ?? .none
                MuscleStatusChip(group: group, level: level)
            }
        }
    }
}

struct MuscleStatusChip: View {
    let group: MuscleGroup
    let level: FatigueLevel
    
    var color: Color {
        switch level {
        case .none, .low: return .neonGreen
        case .medium: return .electricOrange
        case .high, .severe: return .red
        }
    }
    
    var iconName: String {
        // Mapping muscle groups to SF Symbols
        switch group {
        case .chest: return "m.square.fill"
        case .back: return "figure.walk"
        case .quads, .hamstrings, .glutes, .calves: return "figure.run"
        case .shoulders: return "hand.raised.fill"
        case .core: return "circle.grid.cross.fill"
        case .biceps, .triceps, .forearms: return "hand.thumbsup.fill"
        default: return "circle.fill"
        }
    }
    
    var body: some View {
        HStack {
            Image(systemName: iconName)
                .font(.caption)
            Text(group.rawValue)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassCard()
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(color.opacity(0.5), lineWidth: 1)
        )
    }
}

// MARK: - Workout Setup View
struct WorkoutSetupView: View {
    @Environment(WorkoutViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Settings") {
                    Stepper("Time: \(viewModel.availableMinutes) min", value: $viewModel.availableMinutes, in: 15...120, step: 5)
                    
                    Picker("Goal", selection: $viewModel.selectedGoal) {
                        ForEach(WorkoutGoal.allCases) { goal in
                            Text(goal.rawValue).tag(goal)
                        }
                    }
                }
                
                Section("Equipment") {
                    ForEach(Equipment.allCases) { equipment in
                        Toggle(equipment.rawValue, isOn: Binding(
                            get: { viewModel.selectedEquipment.contains(equipment) },
                            set: { newValue in
                                if newValue {
                                    viewModel.selectedEquipment.append(equipment)
                                } else {
                                    viewModel.selectedEquipment.removeAll { $0 == equipment }
                                }
                            }
                        ))
                    }
                }
                
                Button {
                    viewModel.generateWorkout()
                    dismiss()
                } label: {
                    Text("Build My Program")
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.blue)
                }
            }
            .navigationTitle("New Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

#Preview {
    DashboardView()
        .environment(WorkoutViewModel.preview)
        .preferredColorScheme(.dark)
}

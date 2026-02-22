import Foundation
import SwiftData

#if DEBUG
extension WorkoutViewModel {
    static var preview: WorkoutViewModel {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: FatigueProfile.self, FatigueEvent.self, WorkoutSession.self, Exercise.self, ExerciseSet.self, configurations: config)
        let context = container.mainContext
        
        let vm = WorkoutViewModel(modelContext: context, healthKitManager: HealthKitManager())
        
        // Add some mock fatigue
        let profile = FatigueProfile()
        context.insert(profile)
        vm.fatigueProfile = profile
        
        let event1 = FatigueEvent(
            timestamp: Date().addingTimeInterval(-3600),
            sourceKind: .sport,
            sourceName: "Florbal",
            muscleFatigueLevels: [.quads: .high, .calves: .medium]
        )
        context.insert(event1)
        profile.events.append(event1)
        
        // Add mock exercises
        let bench = Exercise(name: "Bench Press", primaryMuscleGroup: .chest, requiredEquipment: [.barbell], isCompound: true)
        let squat = Exercise(name: "Squat", primaryMuscleGroup: .quads, requiredEquipment: [.barbell], isCompound: true)
        context.insert(bench)
        context.insert(squat)
        
        return vm
    }
}

struct MockData {
    static let workouts: [ProcessedWorkout] = [
        // This is tricky because HKWorkout is not easily mockable without real objects
        // In real app, we'd use a protocol or a wrapper. 
        // For preview purposes, we might just use strings or simplified structs.
    ]
}
#endif

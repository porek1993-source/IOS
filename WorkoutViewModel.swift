import Foundation
import SwiftData
import Observation

@Observable
@MainActor
final class WorkoutViewModel {
    var modelContext: ModelContext
    var healthKitManager: HealthKitManager
    var engine: WorkoutEngine
    
    // MARK: - State
    var fatigueProfile: FatigueProfile?
    var currentSession: WorkoutSession?
    var activeWorkoutSlots: [WorkoutSlot] = []
    
    // MARK: - Summary State
    var showSummary: Bool = false
    var summaryWeight: Double = 0
    var summaryDuration: Int = 0
    
    // MARK: - Setup State
    var availableMinutes: Int = 45
    var selectedGoal: WorkoutGoal = .hypertrophy
    var selectedEquipment: [Equipment] = Equipment.allCases
    
    init(modelContext: ModelContext, healthKitManager: HealthKitManager) {
        self.modelContext = modelContext
        self.healthKitManager = healthKitManager
        
        // Initialize engine with repository
        let repository = SwiftDataExerciseRepository(modelContext: modelContext)
        self.engine = WorkoutEngine(repository: repository)
        
        loadOrCreateFatigueProfile()
    }
    
    // MARK: - Persistence
    
    private func loadOrCreateFatigueProfile() {
        let descriptor = FetchDescriptor<FatigueProfile>()
        if let profile = (try? modelContext.fetch(descriptor))?.first {
            self.fatigueProfile = profile
        } else {
            let newProfile = FatigueProfile()
            modelContext.insert(newProfile)
            self.fatigueProfile = newProfile
            try? modelContext.save()
        }
    }
    
    // MARK: - Actions
    
    func refreshHealthData() async {
        guard let fatigueProfile = fatigueProfile else { return }
        await healthKitManager.synchronizovatSHealthKit(dní: 2)
        healthKitManager.persistovat(
            zpracované: healthKitManager.zpracovanéTréninky,
            do: modelContext,
            profil: fatigueProfile
        )
    }
    
    func generateWorkout() {
        guard let fatigueProfile = fatigueProfile else { return }
        
        activeWorkoutSlots = engine.generateWorkout(
            availableMinutes: availableMinutes,
            targetGoal: selectedGoal,
            availableEquipment: selectedEquipment,
            currentFatigue: fatigueProfile
        )
        
        // Start a new session
        let session = WorkoutSession(
            name: "\(selectedGoal.rawValue) Session",
            availableEquipment: selectedEquipment,
            targetDurationMinutes: availableMinutes
        )
        modelContext.insert(session)
        self.currentSession = session
    }
    
    func swapExercise(at index: Int) {
        guard let fatigueProfile = fatigueProfile, 
              index < activeWorkoutSlots.count else { return }
        
        let oldSlot = activeWorkoutSlots[index]
        if let alternative = engine.findAlternative(
            for: oldSlot.exercise,
            availableEquipment: selectedEquipment,
            currentFatigue: fatigueProfile
        ) {
            let newSlot = WorkoutSlot(
                exercise: alternative,
                recommendedSets: oldSlot.recommendedSets,
                recommendedReps: oldSlot.recommendedReps,
                progressionTarget: engine.progressionTarget(for: alternative, goal: selectedGoal)
            )
            activeWorkoutSlots[index] = newSlot
        }
    }
    
    func logSetForExercise(exercise: Exercise, weight: Double, reps: Int) {
        guard let session = currentSession else { return }
        
        let orderIndex = session.exerciseSets.count
        let newSet = ExerciseSet(
            orderIndex: orderIndex,
            exercise: exercise,
            weightKg: weight,
            reps: reps
        )
        newSet.workoutSession = session
        session.exerciseSets.append(newSet)
        
        try? modelContext.save()
    }
    
    func finishWorkout() {
        guard let session = currentSession else { return }
        session.completedAt = .now
        let duration = Int(Date().timeIntervalSince(session.startedAt))
        session.durationSeconds = duration
        
        // Calculate statistics for summary
        self.summaryWeight = session.exerciseSets.reduce(0) { $0 + ($1.weightKg * Double($1.reps)) }
        self.summaryDuration = duration / 60
        self.showSummary = true
        
        // Create a fatigue event from this session
        if let fatigueProfile = fatigueProfile {
            // Very simplified: gym workout causes medium fatigue to primary muscles
            var levels: [MuscleGroup: FatigueLevel] = [:]
            let uniqueExercises = Set(session.exerciseSets.compactMap { $0.exercise })
            for exercise in uniqueExercises {
                levels[exercise.primaryMuscleGroup] = .medium
            }
            
            let event = FatigueEvent(
                sourceKind: .gym,
                sourceName: session.name ?? "Gym Workout",
                muscleFatigueLevels: levels
            )
            modelContext.insert(event)
            fatigueProfile.events.append(event)
        }
        
        self.currentSession = nil
        self.activeWorkoutSlots = []
        try? modelContext.save()
    }
    
    func toggleManualFatigue(for muscle: MuscleGroup) {
        guard let fatigueProfile = fatigueProfile else { return }
        
        // If current fatigue is high, we "reset" it by doing nothing or we could add a "recovery" event.
        // For simplicity, this just adds a "high fatigue" event if not already fatigued.
        let current = fatigueProfile.currentFatigue()
        let isFatigued = (current[muscle] ?? .none) >= .medium
        
        if !isFatigued {
            let event = FatigueEvent(
                sourceKind: .sport, // Manual override
                sourceName: "Manual Override: \(muscle.rawValue)",
                muscleFatigueLevels: [muscle: .high]
            )
            modelContext.insert(event)
            fatigueProfile.events.append(event)
        }
        
    try? modelContext.save()
    }
}

// MARK: - Preview Mock
#if DEBUG
extension WorkoutViewModel {
    static var preview: WorkoutViewModel {
        let schema = Schema([
            FatigueProfile.self,
            WorkoutSession.self,
            FatigueEvent.self,
            ExerciseSet.self,
            Exercise.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: config)
        
        let healthKitManager = HealthKitManager()
        let viewModel = WorkoutViewModel(modelContext: container.mainContext, healthKitManager: healthKitManager)
        
        // Add some mock exercises
        let e1 = Exercise(name: "Bench Press", primaryMuscleGroup: .chest, isCompound: true)
        let e2 = Exercise(name: "Squat", primaryMuscleGroup: .quads, isCompound: true)
        container.mainContext.insert(e1)
        container.mainContext.insert(e2)
        
        return viewModel
    }
}
#endif

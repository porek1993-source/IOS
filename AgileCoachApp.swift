import SwiftUI
import SwiftData

@main
struct AgileCoachApp: App {
    var body: some Scene {
        WindowGroup {
            let container = try! ModelContainer(for: FatigueProfile.self, WorkoutSession.self, FatigueEvent.self, ExerciseSet.self)
            let healthKitManager = HealthKitManager()
            
            MainView(modelContext: container.mainContext, healthKitManager: healthKitManager)
                .modelContainer(container)
        }
    }
}

import SwiftUI
import SwiftData

struct MainView: View {
    @State private var viewModel: WorkoutViewModel
    
    init(modelContext: ModelContext, healthKitManager: HealthKitManager) {
        _viewModel = State(initialValue: WorkoutViewModel(modelContext: modelContext, healthKitManager: healthKitManager))
    }
    
    var body: some View {
        TabView {
            DashboardView()
                .environment(viewModel)
                .tabItem {
                    Label("Dashboard", systemImage: "house.fill")
                }
            
            ActiveWorkoutView()
                .environment(viewModel)
                .tabItem {
                    Label("Active", systemImage: "bolt.fill")
                }
            
            ManualFatigueOverrideView()
                .environment(viewModel)
                .tabItem {
                    Label("Fatigue", systemImage: "figure.walk.motion")
                }
        }
        .accentColor(.neonGreen)
        .premiumRounded()
        .preferredColorScheme(.dark)
        .task {
            await viewModel.refreshHealthData()
        }
    }
}

}

import Foundation

@MainActor
final class WgerManager {
    static let shared = WgerManager()
    private init() {}
    
    private var imageCache: [String: URL] = [:]
    
    func fetchIllustration(for exerciseName: String) async -> URL? {
        if let cached = imageCache[exerciseName] {
            return cached
        }
        
        // Step 1: Search for exercise
        let query = exerciseName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let searchURL = URL(string: "https://wger.de/api/v2/exercise/search/?term=\(query)")!
        
        do {
            let (data, _) = try await URLSession.shared.data(from: searchURL)
            let searchResult = try JSONDecoder().decode(WgerSearchResponse.self, from: data)
            
            guard let exerciseId = searchResult.suggestions.first?.data.id else { return nil }
            
            // Step 2: Get image URL
            let imageURL = URL(string: "https://wger.de/api/v2/exerciseimage/?exercise=\(exerciseId)")!
            let (imageData, _) = try await URLSession.shared.data(from: imageURL)
            let imageResult = try JSONDecoder().decode(WgerImageResponse.self, from: imageData)
            
            if let result = imageResult.results.first, let url = URL(string: result.image) {
                imageCache[exerciseName] = url
                return url
            }
        } catch {
            print("Wger Error for \(exerciseName): \(error)")
        }
        
        return nil
    }
}

// MARK: - API Models
struct WgerSearchResponse: Codable {
    let suggestions: [WgerSuggestion]
}

struct WgerSuggestion: Codable {
    let value: String
    let data: WgerExerciseData
}

struct WgerExerciseData: Codable {
    let id: Int
}

struct WgerImageResponse: Codable {
    let results: [WgerImageResult]
}

struct WgerImageResult: Codable {
    let image: String
}

// WorkoutEngine.swift
// AgileCoach — Engine pro generování tréninků
//
// Architektura:
//   • WorkoutEngine závisí pouze na injektovaných protokolech, nikdy na konkrétních SwiftData dotazech.
//     To znamená, že veškerá logika je unit-testovatelná bez živého ModelContext.
//   • Tenký protokol ExerciseRepository vlastní veškeré persistence obavy.
//   • WorkoutEngine je třída s čistou logikou; přijímá data, zpracovává je, vrací výsledky.
//   • WorkoutGoal řídí schéma sérií/opakování (je zde, aby byl engine soběstačný).

import Foundation

// MARK: - Podpůrné typy

enum WorkoutGoal: String, Codable, CaseIterable, Identifiable {
    case strength       = "Síla"            // 3–5 opakování, těžší váha
    case hypertrophy    = "Hypertrofie"     // 8–12 opakování, střední váha
    case endurance      = "Vytrvalost"      // 15–20 opakování, lehčí váha
    case generalFitness = "Obecná kondice"  // mix, dobrý výchozí stav

    var id: String { rawValue }

    /// Rozsah opakování pro daný cíl.
    var repRange: ClosedRange<Int> {
        switch self {
        case .strength:       return 3...5
        case .hypertrophy:    return 8...12
        case .endurance:      return 15...20
        case .generalFitness: return 8...15
        }
    }

    /// Doporučený počet sérií pro daný cíl.
    var recommendedSets: Int {
        switch self {
        case .strength:       return 5
        case .hypertrophy:    return 4
        case .endurance:      return 3
        case .generalFitness: return 3
        }
    }
}

/// Plně vyřešený plán pro jeden slot cviku ve vygenerovaném tréninku.
struct WorkoutSlot {
    let exercise: Exercise
    let recommendedSets: Int
    let recommendedReps: ClosedRange<Int>

    /// Cíl progresivního přetížení odvozený z posledního výkonu uživatele.
    let progressionTarget: ProgressionTarget?
}

/// Říká UI / vrstvě logování přesně, na co se v této sessině zaměřit.
struct ProgressionTarget {
    let lastWeightKg: Double        // váha z posledního tréninku
    let lastReps: Int               // opakování z posledního tréninku
    let suggestedWeightKg: Double   // doporučená váha = poslední + přírůstek
    let suggestedReps: Int          // doporučená opakování
    let strategy: OverloadStrategy
}

/// Strategie progresivního přetížení — zobrazuje se uživateli jako instrukce.
enum OverloadStrategy: String {
    case addWeight  = "Přidej váhu"
    case addRep     = "Přidej opakování"
    case maintain   = "Udržuj — deload týden"
    case firstTime  = "První pokus — vyber příjemnou startovací váhu"
}

/// Historický snímek vrácený repozitářem.
struct ExerciseHistory {
    let exerciseID: UUID
    let lastWeightKg: Double    // váha z posledního setu
    let lastReps: Int           // počet opakování z posledního setu
    let sessionDate: Date       // datum tréninku
}

// MARK: - Protokoly (body pro dependency injection a testování)

/// Abstrahuje veškerý čtecí přístup ke katalogu cviků a historickým datům sessiny.
protocol ExerciseRepositoryProtocol {
    /// Vrátí kompletní katalog cviků, již filtrovaný podle `equipment`.
    func fetchExercises(availableEquipment: [Equipment]) -> [Exercise]

    /// Vrátí všechny zalogované sety pro `exercise`, od nejnovějšího.
    func fetchHistory(for exercise: Exercise) -> [ExerciseHistory]
}

/// Abstrahuje logiku přírůstků progresivního přetížení — lze zaměnit podle preference uživatele.
protocol ProgressionPolicyProtocol {
    func suggestedWeight(lastWeightKg: Double, lastReps: Int, goal: WorkoutGoal) -> Double
    func suggestedReps(lastReps: Int, goal: WorkoutGoal) -> Int
    func strategy(lastWeightKg: Double, lastReps: Int, goal: WorkoutGoal) -> OverloadStrategy
}

// MARK: - Výchozí strategie progrese

/// Dvojitá progrese: přidávej opakování každou sessinu, dokud nedosáhneš stropu rozsahu,
/// pak zvyš váhu o nejmenší smysluplný přírůstek a resetuj opakování na spodní hranici.
struct DoubleProgressionPolicy: ProgressionPolicyProtocol {

    /// Přírůstky váhy podle cíle (v kg)
    private let weightIncrement: [WorkoutGoal: Double] = [
        .strength:       2.5,
        .hypertrophy:    2.5,
        .endurance:      1.25,
        .generalFitness: 2.5,
    ]

    func suggestedWeight(lastWeightKg: Double, lastReps: Int, goal: WorkoutGoal) -> Double {
        // Váhu zvyšuj pouze poté, co uživatel dosáhl stropu rozsahu opakování.
        if lastReps >= goal.repRange.upperBound {
            return lastWeightKg + (weightIncrement[goal] ?? 2.5)
        }
        return lastWeightKg
    }

    func suggestedReps(lastReps: Int, goal: WorkoutGoal) -> Int {
        if lastReps >= goal.repRange.upperBound {
            return goal.repRange.lowerBound  // reset po zvýšení váhy
        }
        return min(lastReps + 1, goal.repRange.upperBound)
    }

    func strategy(lastWeightKg: Double, lastReps: Int, goal: WorkoutGoal) -> OverloadStrategy {
        if lastReps >= goal.repRange.upperBound { return .addWeight }
        if lastReps < goal.repRange.lowerBound  { return .maintain }
        return .addRep
    }
}

// MARK: - Skórování únavy

/// Interní skórovací konstanty — izolované zde pro snadné ladění nebo A/B testování.
private enum FatigueScore {
    /// Únava primárního svalu na nebo nad touto úrovní způsobuje úplné vyloučení cviku.
    static let primaryBlockThreshold: FatigueLevel = .high

    /// Penalizace odečtená od skóre cviku, pokud je unavený sekundární sval.
    static func secondaryPenalty(for level: FatigueLevel) -> Double {
        switch level {
        case .none:   return 0
        case .low:    return 5
        case .medium: return 15
        case .high:   return 40
        case .severe: return 80
        }
    }

    /// Bonus pro vícekloubové cviky (efektivnější z hlediska času).
    static let compoundBonus: Double = 10

    /// Bonus za zásah svalové skupiny, která ještě není v aktuálním výběru.
    static let muscleVarietyBonus: Double = 20
}

// MARK: - WorkoutEngine

final class WorkoutEngine {

    // MARK: Závislosti

    private let repository: ExerciseRepositoryProtocol
    private let progressionPolicy: ProgressionPolicyProtocol

    /// Odhadovaný čas na jeden slot cviku (série + odpočinek + přesun).
    private let minutesPerExercise: Double = 3.5

    // MARK: Inicializátor

    init(
        repository: ExerciseRepositoryProtocol,
        progressionPolicy: ProgressionPolicyProtocol = DoubleProgressionPolicy()
    ) {
        self.repository = repository
        self.progressionPolicy = progressionPolicy
    }

    // MARK: - Hlavní API

    /// Vygeneruje seřazený seznam WorkoutSlotů přizpůsobených aktuálnímu stavu uživatele.
    ///
    /// - Parameters:
    ///   - availableMinutes: Požadovaná délka sessiny.
    ///   - targetGoal: Řídí schéma opakování/sérií a přírůstky progrese.
    ///   - availableEquipment: Vybavení dostupné v dnešní posilovně nebo doma.
    ///   - currentFatigue: Živý FatigueProfile model ze SwiftData.
    /// - Returns: Seřazený `[WorkoutSlot]` připravený pro zobrazení sessiny.
    func generateWorkout(
        availableMinutes: Int,
        targetGoal: WorkoutGoal,
        availableEquipment: [Equipment],
        currentFatigue: FatigueProfile
    ) -> [WorkoutSlot] {

        let exerciseCount = maxExercises(for: availableMinutes)
        let fatigue = currentFatigue.currentFatigue()

        // 1. Načti katalog filtrovaný podle dostupného vybavení.
        let catalogue = repository.fetchExercises(availableEquipment: availableEquipment)

        // 2. Tvrdě vyloučit cviky, jejichž primární sval je příliš unavený.
        let eligible = catalogue.filter { !isPrimaryBlocked($0, fatigue: fatigue) }

        // 3. Ohodnotit zbývající kandidáty.
        var selectedMuscles: Set<MuscleGroup> = []
        let scored = eligible.map { exercise -> (exercise: Exercise, score: Double) in
            (exercise, desirabilityScore(exercise, fatigue: fatigue, alreadySelectedMuscles: selectedMuscles))
        }.sorted { $0.score > $1.score }

        // 4. Chamtivý výběr — nejprve vícekloubové cviky pro časovou efektivitu, pak izolace.
        var selected: [Exercise] = []
        var remaining = exerciseCount

        for pass in [true, false] {  // true = průchod vícekloubovými, false = průchod izolací
            for candidate in scored where candidate.exercise.isCompound == pass {
                guard remaining > 0 else { break }
                // Při průchodu izolací přeskočit svaly již pokryté vícekloubovým cvikem.
                if !pass, selectedMuscles.contains(candidate.exercise.primaryMuscleGroup) { continue }
                selected.append(candidate.exercise)
                selectedMuscles.insert(candidate.exercise.primaryMuscleGroup)
                remaining -= 1
            }
            guard remaining > 0 else { break }
        }

        // 5. Převést každý výběr na WorkoutSlot s cílem progrese.
        return selected.map { buildSlot(exercise: $0, goal: targetGoal) }
    }

    // MARK: - Chytré nahrazení cviku

    /// Vrátí nejlepší alternativu pro `exercise`: stejná primární svalová skupina,
    /// ale jiné vybavení nebo mechanika pohybu. Vrátí nil, pokud žádná vhodná náhrada neexistuje.
    ///
    /// Použití: vybavení náhle nedostupné, uživatel nemá cvik rád,
    /// nebo únava vzrostla v průběhu sessiny od okamžiku, kdy byl plán vygenerován.
    func findAlternative(
        for exercise: Exercise,
        availableEquipment: [Equipment],
        currentFatigue: FatigueProfile
    ) -> Exercise? {
        let fatigue = currentFatigue.currentFatigue()
        let catalogue = repository.fetchExercises(availableEquipment: availableEquipment)

        return catalogue
            .filter { candidate in
                candidate.primaryMuscleGroup == exercise.primaryMuscleGroup
                && candidate.id != exercise.id
                && !isPrimaryBlocked(candidate, fatigue: fatigue)
            }
            .map { candidate -> (exercise: Exercise, score: Double) in
                var score = desirabilityScore(candidate, fatigue: fatigue, alreadySelectedMuscles: [])

                // Preferovat skutečně jiné vybavení — to je hlavní důvod pro swap.
                let differentEquipment = Set(candidate.requiredEquipment)
                    .isDisjoint(with: Set(exercise.requiredEquipment))
                if differentEquipment { score += 25 }

                // Bonus za rozmanitost pohybového vzoru (vícekloubový vs. izolace).
                if candidate.isCompound != exercise.isCompound { score += 10 }

                return (candidate, score)
            }
            .sorted { $0.score > $1.score }
            .first?.exercise
    }

    // MARK: - Načítání progresivního přetížení

    /// Vrátí ProgressionTarget pro `exercise` na základě zalogované historie uživatele.
    /// Vždy vrátí hodnotu — strategie `.firstTime` je použita, pokud žádná historie neexistuje.
    func progressionTarget(for exercise: Exercise, goal: WorkoutGoal) -> ProgressionTarget {
        guard let last = repository.fetchHistory(for: exercise).first else {
            // Uživatel tento cvik nikdy nedělal — první pokus.
            return ProgressionTarget(
                lastWeightKg: 0,
                lastReps: 0,
                suggestedWeightKg: 0,
                suggestedReps: goal.repRange.lowerBound,
                strategy: .firstTime
            )
        }

        return ProgressionTarget(
            lastWeightKg: last.lastWeightKg,
            lastReps: last.lastReps,
            suggestedWeightKg: progressionPolicy.suggestedWeight(
                lastWeightKg: last.lastWeightKg, lastReps: last.lastReps, goal: goal),
            suggestedReps: progressionPolicy.suggestedReps(
                lastReps: last.lastReps, goal: goal),
            strategy: progressionPolicy.strategy(
                lastWeightKg: last.lastWeightKg, lastReps: last.lastReps, goal: goal)
        )
    }

    // MARK: - Privátní pomocné funkce

    /// Maximální počet slotů cviků pro daný dostupný čas.
    private func maxExercises(for availableMinutes: Int) -> Int {
        let workingMinutes = max(0, Double(availableMinutes) - 5)  // rezervovat 5 min na rozcvičku
        let raw = Int(workingMinutes / minutesPerExercise)
        return min(max(raw, 1), 8)  // minimum 1, maximum 8
    }

    /// Vrátí true, pokud musí být cvik vyloučen, protože jeho PRIMÁRNÍ sval
    /// dosáhl nebo překročil práh blokování únavy.
    private func isPrimaryBlocked(_ exercise: Exercise, fatigue: [MuscleGroup: FatigueLevel]) -> Bool {
        (fatigue[exercise.primaryMuscleGroup] ?? .none) >= FatigueScore.primaryBlockThreshold
    }

    /// Ohodnotí žádanost cviku. Vyšší = více preferován.
    /// Neblokuje — blokování se provádí před tímto voláním.
    private func desirabilityScore(
        _ exercise: Exercise,
        fatigue: [MuscleGroup: FatigueLevel],
        alreadySelectedMuscles: Set<MuscleGroup>
    ) -> Double {
        var score: Double = 100  // základní skóre

        // Silně penalizovat únavu sekundárního svalu.
        for muscle in exercise.secondaryMuscleGroups {
            score -= FatigueScore.secondaryPenalty(for: fatigue[muscle] ?? .none)
        }

        // Mírnější penalizace pro únavu primárního svalu pod prahem blokování
        // (např. střední únava ramen stále odklání od OHP, ale nezakazuje ho).
        let primaryFatigue = fatigue[exercise.primaryMuscleGroup] ?? .none
        score -= FatigueScore.secondaryPenalty(for: primaryFatigue) * 0.5

        // Vícekloubové cviky jsou časově efektivnější.
        if exercise.isCompound { score += FatigueScore.compoundBonus }

        // Odměnit rozmanitost svalových skupin v aktuálním výběru.
        if !alreadySelectedMuscles.contains(exercise.primaryMuscleGroup) {
            score += FatigueScore.muscleVarietyBonus
        }

        return max(score, 0)
    }

    /// Sestaví plně vyřešený WorkoutSlot pro cvik.
    private func buildSlot(exercise: Exercise, goal: WorkoutGoal) -> WorkoutSlot {
        WorkoutSlot(
            exercise: exercise,
            recommendedSets: goal.recommendedSets,
            recommendedReps: goal.repRange,
            progressionTarget: progressionTarget(for: exercise, goal: goal)
        )
    }
}

// MARK: - Repozitář napojený na SwiftData

/// Skutečná implementace komunikující se SwiftData.
/// Oddělená od enginu, aby testy mohly injektovat mock místo ní.
final class SwiftDataExerciseRepository: ExerciseRepositoryProtocol {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func fetchExercises(availableEquipment: [Equipment]) -> [Exercise] {
        let descriptor = FetchDescriptor<Exercise>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        // Cvik je způsobilý pouze pokud je veškeré jeho požadované vybavení dostupné.
        return all.filter { exercise in
            exercise.requiredEquipment.allSatisfy { availableEquipment.contains($0) }
        }
    }

    func fetchHistory(for exercise: Exercise) -> [ExerciseHistory] {
        var descriptor = FetchDescriptor<ExerciseSet>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        // Omezit na 50 záznamů — dostatečná historie pro jakýkoliv algoritmus progrese.
        descriptor.fetchLimit = 50

        let sets = (try? modelContext.fetch(descriptor)) ?? []
        return sets
            .filter { $0.exercise?.id == exercise.id && !$0.isWarmupSet }
            .map { ExerciseHistory(
                exerciseID: exercise.id,
                lastWeightKg: $0.weightKg,
                lastReps: $0.reps,
                sessionDate: $0.completedAt
            )}
    }
}

// MARK: - Mock repozitář (unit testy + SwiftUI preview)

#if DEBUG
/// Falešný repozitář pro unit testy a SwiftUI preview.
/// Injektovat místo SwiftDataExerciseRepository — bez disku, bez kontejneru, okamžitý.
final class MockExerciseRepository: ExerciseRepositoryProtocol {
    var exercises: [Exercise] = []
    var historyByExerciseID: [UUID: [ExerciseHistory]] = [:]

    func fetchExercises(availableEquipment: [Equipment]) -> [Exercise] { exercises }
    func fetchHistory(for exercise: Exercise) -> [ExerciseHistory] {
        historyByExerciseID[exercise.id] ?? []
    }
}
#endif

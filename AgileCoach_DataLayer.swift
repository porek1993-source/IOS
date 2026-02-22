// AgileCoach — Datová vrstva
// Architektura: SwiftData + local-first, žádné síťové modely zde.
// Všechny typy jsou Codable pro JSON export a připravenost na CloudKit sync.

import Foundation
import SwiftData

// MARK: - Výčtové typy

/// Svalové skupiny používané v celé aplikaci pro sledování únavy, štítkování cviků a UI.
enum MuscleGroup: String, Codable, CaseIterable, Identifiable {
    case chest       = "Hrudník"
    case back        = "Záda"
    case quads       = "Čtyřhlavý sval"
    case hamstrings  = "Hamstringy"
    case glutes      = "Hýžďové svaly"
    case shoulders   = "Ramena"
    case core        = "Střed těla"
    case calves      = "Lýtka"
    case biceps      = "Biceps"
    case triceps     = "Triceps"
    case forearms    = "Předloktí"
    case hipFlexors  = "Flexory kyčle"   // relevantní pro kopací sporty (florbal, Krav Maga)
    case neck        = "Krk"

    var id: String { rawValue }
}

/// Závažnost únavy — používá se jak v penalizacích ExternalSport, tak ve stavu FatigueProfile.
enum FatigueLevel: Int, Codable, CaseIterable, Comparable {
    case none   = 0  // žádná únava
    case low    = 1  // mírná únava
    case medium = 2  // střední únava
    case high   = 3  // vysoká únava
    case severe = 4  // silná únava, např. DOMS den po těžkém tréninku nohou

    static func < (lhs: FatigueLevel, rhs: FatigueLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Sloučí dvě úrovně únavy, maximálně do hodnoty .severe.
    func combined(with other: FatigueLevel) -> FatigueLevel {
        FatigueLevel(rawValue: min(Self.severe.rawValue, self.rawValue + other.rawValue)) ?? .severe
    }
}

/// Dostupné vybavení na daném tréninku.
enum Equipment: String, Codable, CaseIterable, Identifiable {
    case barbell        = "Činka dlouhá"
    case dumbbell       = "Činka krátká"
    case cables         = "Kladky"
    case machine        = "Stroj"
    case bodyweight     = "Vlastní váha"
    case kettlebell     = "Kettlebell"
    case resistanceBand = "Odporová guma"

    var id: String { rawValue }
}

// MARK: - Cvik

/// Znovupoužitelná definice cviku. Neměnná během tréninku; sdílená napříč všemi WorkoutSessions.
/// Vztah: jeden Exercise → mnoho ExerciseSets (inverzní vztah na ExerciseSet.exercise).
@Model
final class Exercise {

    // SwiftData vyžaduje stabilní identifikátor napříč zařízeními pro CloudKit.
    @Attribute(.unique) var id: UUID

    var name: String

    // Uloženo jako raw stringy, protože SwiftData neumí persistovat enums přímo.
    // Typované computed properties níže obnovují správné enum hodnoty.
    var primaryMuscleGroupRaw: String           // MuscleGroup.rawValue
    var secondaryMuscleGroupsRaw: [String]      // [MuscleGroup.rawValue]
    var requiredEquipmentRaw: [String]          // [Equipment.rawValue]

    var isCompound: Bool

    /// Volitelné poznámky nebo koučovací instrukce ke cviku.
    var notes: String?

    // Inverzní vztah — SwiftData spravuje spojovací tabulku automaticky.
    @Relationship(deleteRule: .nullify, inverse: \ExerciseSet.exercise)
    var sets: [ExerciseSet] = []

    // MARK: Typované computed přístupy

    var primaryMuscleGroup: MuscleGroup {
        get { MuscleGroup(rawValue: primaryMuscleGroupRaw) ?? .core }
        set { primaryMuscleGroupRaw = newValue.rawValue }
    }

    var secondaryMuscleGroups: [MuscleGroup] {
        get { secondaryMuscleGroupsRaw.compactMap { MuscleGroup(rawValue: $0) } }
        set { secondaryMuscleGroupsRaw = newValue.map(\.rawValue) }
    }

    var requiredEquipment: [Equipment] {
        get { requiredEquipmentRaw.compactMap { Equipment(rawValue: $0) } }
        set { requiredEquipmentRaw = newValue.map(\.rawValue) }
    }

    // MARK: Inicializátor

    init(
        name: String,
        primaryMuscleGroup: MuscleGroup,
        secondaryMuscleGroups: [MuscleGroup] = [],
        requiredEquipment: [Equipment],
        isCompound: Bool,
        notes: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.primaryMuscleGroupRaw = primaryMuscleGroup.rawValue
        self.secondaryMuscleGroupsRaw = secondaryMuscleGroups.map(\.rawValue)
        self.requiredEquipmentRaw = requiredEquipment.map(\.rawValue)
        self.isCompound = isCompound
        self.notes = notes
    }
}

// MARK: - Externí sport

/// Popisuje sport (např. "Florbal") a únavu svalů, kterou způsobuje.
/// Slovník je serializován přes JSON transformer, protože SwiftData nativně
/// nepodporuje slovníky s enum klíči ani hodnotami.
///
/// Architektonické rozhodnutí: ExternalSport je konfigurační objekt, nikoli záznam události.
/// Skutečné odehrané sessiony se zaznamenávají jako FatigueEvent (viz FatigueProfile).
@Model
final class ExternalSport {

    @Attribute(.unique) var id: UUID
    var name: String        // např. "Florbal", "Krav Maga", "Basketbal"
    var iconName: String?   // název SF Symbol nebo assetu pro UI

    /// Serializováno jako JSON: {"Ramena": 2, "Čtyřhlavý sval": 2, "Lýtka": 1, ...}
    /// Pro čtení/zápis používejte typovaný accessor `fatiguePenalties`.
    @Attribute(.transformable(by: MuscleGroupFatigueDictionaryTransformer.self))
    var fatiguePenaltiesData: [String: Int]

    var fatiguePenalties: [MuscleGroup: FatigueLevel] {
        get {
            Dictionary(
                uniqueKeysWithValues: fatiguePenaltiesData.compactMap { key, value in
                    guard let group = MuscleGroup(rawValue: key),
                          let level = FatigueLevel(rawValue: value) else { return nil }
                    return (group, level)
                }
            )
        }
        set {
            fatiguePenaltiesData = Dictionary(
                uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value.rawValue) }
            )
        }
    }

    /// Typická délka účinku únavy po sessonu tohoto sportu (v hodinách).
    var fatigueDecayHours: Double

    init(
        name: String,
        iconName: String? = nil,
        fatiguePenalties: [MuscleGroup: FatigueLevel],
        fatigueDecayHours: Double = 36
    ) {
        self.id = UUID()
        self.name = name
        self.iconName = iconName
        self.fatiguePenaltiesData = Dictionary(
            uniqueKeysWithValues: fatiguePenalties.map { ($0.key.rawValue, $0.value.rawValue) }
        )
        self.fatigueDecayHours = fatigueDecayHours
    }
}

// MARK: - Událost únavy (podpůrný záznam pro FatigueProfile)

/// Jedna událost způsobující únavu: buď dokončený trénink v posilovně, nebo session externího sportu.
/// FatigueProfile tyto události agreguje v rámci pohyblivého 48hodinového okna.
@Model
final class FatigueEvent {

    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var sourceKind: FatigueSourceKind   // .gym nebo .sport

    /// Název sportu (pokud .sport) nebo tréninku (pokud .gym). Denormalizováno pro rychlost.
    var sourceName: String

    /// Serializovaný snímek [MuscleGroup: FatigueLevel] v době události.
    @Attribute(.transformable(by: MuscleGroupFatigueDictionaryTransformer.self))
    var muscleFatigueLevelsData: [String: Int]

    var muscleFatigueLevels: [MuscleGroup: FatigueLevel] {
        get {
            Dictionary(uniqueKeysWithValues: muscleFatigueLevelsData.compactMap { key, value in
                guard let group = MuscleGroup(rawValue: key),
                      let level = FatigueLevel(rawValue: value) else { return nil }
                return (group, level)
            })
        }
        set {
            muscleFatigueLevelsData = Dictionary(
                uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value.rawValue) }
            )
        }
    }

    @Relationship(deleteRule: .nullify)
    var fatigueProfile: FatigueProfile?

    init(
        timestamp: Date = .now,
        sourceKind: FatigueSourceKind,
        sourceName: String,
        muscleFatigueLevels: [MuscleGroup: FatigueLevel]
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.sourceKind = sourceKind
        self.sourceName = sourceName
        self.muscleFatigueLevelsData = Dictionary(
            uniqueKeysWithValues: muscleFatigueLevels.map { ($0.key.rawValue, $0.value.rawValue) }
        )
    }
}

/// Zdroj události únavy.
enum FatigueSourceKind: String, Codable {
    case gym        // trénink v posilovně
    case sport      // externí sport zadaný ručně
    case healthKit  // importováno z HKWorkout
}

// MARK: - Profil únavy

/// Singleton model (jeden na uživatele). Agreguje FatigueEvents v rámci pohyblivého
/// 48hodinového okna a poskytuje aktuální stav únavy pro každou svalovou skupinu.
///
/// Architektonické rozhodnutí: Ukládáme surové události a agregát počítáme lazy,
/// takže nikdy neztrácíme historickou přesnost — pohyblivé okno je jen predikát dotazu.
@Model
final class FatigueProfile {

    @Attribute(.unique) var id: UUID

    /// Délka pohyblivého okna v hodinách. Výchozí 48; uživatel může upravit v nastavení.
    var rollingWindowHours: Double

    @Relationship(deleteRule: .cascade, inverse: \FatigueEvent.fatigueProfile)
    var events: [FatigueEvent] = []

    // MARK: Výpočet agregátu (volat z doménové/servisní vrstvy, ne přímo ze SwiftUI)

    /// Vrátí kombinovanou úroveň únavy pro každou svalovou skupinu napříč všemi událostmi
    /// v rámci pohyblivého okna. Události se lineárně rozpadají v čase.
    func currentFatigue(at now: Date = .now) -> [MuscleGroup: FatigueLevel] {
        let cutoff = now.addingTimeInterval(-rollingWindowHours * 3600)
        let recentEvents = events.filter { $0.timestamp >= cutoff }

        var totals: [MuscleGroup: Int] = [:]
        for event in recentEvents {
            // Lineární rozpad: události blížící se hranici okna přispívají méně.
            let age = now.timeIntervalSince(event.timestamp)
            let windowSeconds = rollingWindowHours * 3600
            let decayFactor = max(0, 1 - (age / windowSeconds))  // 1.0 → 0.0

            for (muscle, level) in event.muscleFatigueLevels {
                let decayedValue = Int((Double(level.rawValue) * decayFactor).rounded())
                totals[muscle, default: 0] += decayedValue
            }
        }

        // Zastropovat na .severe
        return totals.mapValues {
            FatigueLevel(rawValue: min($0, FatigueLevel.severe.rawValue)) ?? .severe
        }
    }

    init(rollingWindowHours: Double = 48) {
        self.id = UUID()
        self.rollingWindowHours = rollingWindowHours
    }
}

// MARK: - Tréninková session

/// Dokončená (nebo probíhající) session v posilovně. Obsahuje seřazené ExerciseSety.
@Model
final class WorkoutSession {

    @Attribute(.unique) var id: UUID
    var name: String?               // např. "Push Day A", automaticky generováno pokud nil
    var startedAt: Date
    var completedAt: Date?          // nil = session probíhá
    var durationSeconds: Int?

    /// Dostupné vybavení pro tuto session (ovlivňuje výběr cviků).
    var availableEquipmentRaw: [String]
    var availableEquipment: [Equipment] {
        get { availableEquipmentRaw.compactMap { Equipment(rawValue: $0) } }
        set { availableEquipmentRaw = newValue.map(\.rawValue) }
    }

    /// Cílová délka, kterou uživatel zadal (v minutách).
    var targetDurationMinutes: Int?

    /// Volné poznámky (např. "byl jsem unavený, snížil jsem váhu").
    var notes: String?

    @Relationship(deleteRule: .cascade, inverse: \ExerciseSet.workoutSession)
    var exerciseSets: [ExerciseSet] = []

    // MARK: Pomocné funkce pro progresivní přetížení (volá je doporučovací engine)

    /// Seskupí sety podle cviku a vrátí nejlepší set (nejvyšší objem = váha × opakování) pro každý cvik.
    func bestSetPerExercise() -> [UUID: ExerciseSet] {
        var best: [UUID: ExerciseSet] = [:]
        for set in exerciseSets {
            guard let exercise = set.exercise else { continue }
            if let existing = best[exercise.id] {
                if set.volume > existing.volume { best[exercise.id] = set }
            } else {
                best[exercise.id] = set
            }
        }
        return best
    }

    /// Celkový objem sessiony (součet všech setů).
    var totalVolume: Double {
        exerciseSets.reduce(0) { $0 + $1.volume }
    }

    init(
        name: String? = nil,
        startedAt: Date = .now,
        availableEquipment: [Equipment] = Equipment.allCases,
        targetDurationMinutes: Int? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.startedAt = startedAt
        self.availableEquipmentRaw = availableEquipment.map(\.rawValue)
        self.targetDurationMinutes = targetDurationMinutes
    }
}

// MARK: - Set cviku

/// Jeden set v rámci WorkoutSession. Atomická jednotka pro sledování progresivního přetížení.
@Model
final class ExerciseSet {

    @Attribute(.unique) var id: UUID
    var orderIndex: Int             // pořadí v rámci sessiony pro zobrazení

    // Vztahy
    @Relationship(deleteRule: .nullify)
    var exercise: Exercise?

    @Relationship(deleteRule: .nullify)
    var workoutSession: WorkoutSession?

    // Výkonnostní data
    var weightKg: Double            // 0 pro cviky s vlastní vahou
    var reps: Int
    var repsInReserve: Int?         // RIR pro autoregulaci (nil = nesledováno)
    var rpe: Double?                // Subjektivní náročnost (RPE) 1–10

    /// Tempo uloženo jako "excentrická-pauza-koncentrická-pauza", např. "3-1-1-0"
    var tempo: String?

    var isWarmupSet: Bool
    var completedAt: Date

    // MARK: Objem a přetížení

    /// Jednoduchá metrika objemu: váha × opakování.
    /// Pro cviky s vlastní vahou je weightKg tělesná hmotnost uživatele (nastavuje volající kód).
    var volume: Double { weightKg * Double(reps) }

    /// Odhad maximální váhy na jedno opakování (1RM) pomocí Epleyho vzorce.
    var estimatedOneRepMax: Double {
        guard reps > 1 else { return weightKg }
        return weightKg * (1 + Double(reps) / 30)
    }

    init(
        orderIndex: Int,
        exercise: Exercise? = nil,
        weightKg: Double,
        reps: Int,
        repsInReserve: Int? = nil,
        rpe: Double? = nil,
        tempo: String? = nil,
        isWarmupSet: Bool = false,
        completedAt: Date = .now
    ) {
        self.id = UUID()
        self.orderIndex = orderIndex
        self.exercise = exercise
        self.weightKg = weightKg
        self.reps = reps
        self.repsInReserve = repsInReserve
        self.rpe = rpe
        self.tempo = tempo
        self.isWarmupSet = isWarmupSet
        self.completedAt = completedAt
    }
}

// MARK: - SwiftData Value Transformer

/// Umožňuje SwiftData persistovat slovníky [String: Int] (naše raw mapy únavy)
/// bez externího sloupce databáze pro každý klíč. Registrovat při spuštění aplikace.
@objc(MuscleGroupFatigueDictionaryTransformer)
final class MuscleGroupFatigueDictionaryTransformer: ValueTransformer {

    static let name = NSValueTransformerName("MuscleGroupFatigueDictionaryTransformer")

    static func register() {
        ValueTransformer.setValueTransformer(
            MuscleGroupFatigueDictionaryTransformer(),
            forName: name
        )
    }

    override class func transformedValueClass() -> AnyClass { NSData.self }
    override class func allowsReverseTransformation() -> Bool { true }

    override func transformedValue(_ value: Any?) -> Any? {
        guard let dict = value as? [String: Int] else { return nil }
        return try? JSONEncoder().encode(dict)
    }

    override func reverseTransformedValue(_ value: Any?) -> Any? {
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode([String: Int].self, from: data)
    }
}

// MARK: - Továrna ModelContainer (volat jednou při spuštění aplikace)

extension ModelContainer {
    /// Vytvoří a nakonfiguruje SwiftData kontejner pro celou aplikaci AgileCoach.
    static func agileCoachContainer() throws -> ModelContainer {
        // Transformer musí být registrován před vytvořením kontejneru.
        MuscleGroupFatigueDictionaryTransformer.register()

        let schema = Schema([
            Exercise.self,
            ExternalSport.self,
            FatigueEvent.self,
            FatigueProfile.self,
            WorkoutSession.self,
            ExerciseSet.self,
        ])

        let config = ModelConfiguration(
            "AgileCoach",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        return try ModelContainer(for: schema, configurations: config)
    }
}

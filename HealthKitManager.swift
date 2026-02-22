// HealthKitManager.swift
// AgileCoach — Integrace s HealthKit
//
// Architektura:
//   • @Observable (Swift 5.9) místo ObservableObject — méně boilerplate, lepší výkon.
//   • Veškerá komunikace s HealthKit probíhá na background threadu přes async/await.
//   • Výsledky jsou vždy doručeny na hlavní vlákno přes @MainActor.
//   • Mapování HKWorkoutActivityType → FatigueEvent je odděleno do samostatné
//     struktury `ActivityFatigueMapper`, aby bylo nezávisle testovatelné.
//   • HealthKitManager NEZAPISUJE přímo do SwiftData — vrací [FatigueEvent]
//     a nechává volající vrstvu (ViewModel / AppState), aby je persistovala.
//     Tím udržujeme čistou separaci odpovědností.

import Foundation
import HealthKit
import Observation

// MARK: - Chybové stavy

/// Typované chyby HealthKit managera — lépe než generické Error pro UI vrstvu.
enum HealthKitError: LocalizedError {
    case nedostupne             // HealthKit na tomto zařízení není dostupný (iPad bez páru)
    case autorizaceZamítnuta    // uživatel odmítl přístup
    case dotazSelhal(Error)     // chyba při samotném dotazu
    case žádnáData              // dotaz uspěl, ale nevrátil žádné záznamy

    var errorDescription: String? {
        switch self {
        case .nedostupne:
            return "HealthKit není na tomto zařízení dostupný."
        case .autorizaceZamítnuta:
            return "Přístup k datům o zdraví byl zamítnut. Povolte ho v Nastavení → Zdraví → Sdílení dat."
        case .dotazSelhal(let chyba):
            return "Dotaz na HealthKit selhal: \(chyba.localizedDescription)"
        case .žádnáData:
            return "Za zvolené období nebyla nalezena žádná tréninková data."
        }
    }
}

// MARK: - Výsledek zpracování tréninku

/// Výsledek překladu jednoho HKWorkout do naší domény.
/// Obsahuje jak surový HKWorkout (pro debugging/zobrazení), tak přeložené FatigueEvents.
struct ProcessedWorkout {
    let source: HKWorkout
    let fatigueEvents: [FatigueEvent]  // může jich být více (např. kombinovaný sport)

    /// Stručný popis pro UI (název aktivity + datum)
    var displayTitle: String {
        let nazevAktivity = ActivityFatigueMapper.lokalizovanyNazev(pro: source.workoutActivityType)
        let formatovacDatu = DateFormatter()
        formatovacDatu.dateStyle = .medium
        formatovacDatu.timeStyle = .short
        return "\(nazevAktivity) – \(formatovacDatu.string(from: source.startDate))"
    }
}

// MARK: - HealthKitManager

/// Hlavní třída pro komunikaci s HealthKit.
/// Používá @Observable (Swift 5.9) — vhodné pro SwiftUI bez nutnosti @Published.
@Observable
@MainActor
final class HealthKitManager {

    // MARK: Publikovaný stav (automaticky sledovaný SwiftUI díky @Observable)

    /// Aktuálně probíhá dotaz nebo autorizace.
    var nacitaSe: Bool = false

    /// Poslední chyba — nil pokud vše proběhlo v pořádku.
    var poslednáChyba: HealthKitError?

    /// Naposledy načtené zpracované tréninky.
    var zpracovanéTréninky: [ProcessedWorkout] = []

    /// Stav autorizace — pro zobrazení správné UI (banner "Připojit zdraví").
    var stavAutorizace: HKAuthorizationStatus = .notDetermined

    // MARK: Privátní

    private let healthStore = HKHealthStore()

    /// Typy, ke kterým žádáme přístup — rozšiřitelné pro budoucí metriky (TF, spánek...).
    private let čtecíTypy: Set<HKObjectType> = [
        HKObjectType.workoutType(),
        // Budoucí rozšíření:
        // HKObjectType.quantityType(forIdentifier: .heartRate)!,
        // HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
    ]

    // MARK: - Autorizace

    /// Vyžádá autorizaci ke čtení tréninkových dat.
    /// Volat při prvním spuštění nebo ze Settings obrazovky.
    func vyžádatAutorizaci() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            poslednáChyba = .nedostupne
            return
        }

        nacitaSe = true
        defer { nacitaSe = false }

        do {
            // iOS 17+: requestAuthorization je nativně async
            try await healthStore.requestAuthorization(toShare: [], read: čtecíTypy)
            stavAutorizace = healthStore.authorizationStatus(for: HKObjectType.workoutType())
        } catch {
            poslednáChyba = .dotazSelhal(error)
        }
    }

    /// Zkontroluje aktuální stav autorizace bez zobrazení dialogu.
    func zkontrolovatAutorizaci() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        stavAutorizace = healthStore.authorizationStatus(for: HKObjectType.workoutType())
    }

    // MARK: - Načítání tréninkových dat

    /// Načte všechny tréninky z posledních `dní` dnů a přeloží je do FatigueEvents.
    ///
    /// - Parameter dní: Kolik dní zpět hledat (typicky 2–7 pro okno únavy).
    /// - Returns: Pole `ProcessedWorkout` seřazené od nejnovějšího.
    /// - Throws: `HealthKitError` při jakémkoliv selhání.
    func načístRecentníTréninky(dní: Int) async throws -> [ProcessedWorkout] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.nedostupne
        }

        guard stavAutorizace == .sharingAuthorized || stavAutorizace == .notDetermined else {
            throw HealthKitError.autorizaceZamítnuta
        }

        nacitaSe = true
        defer { nacitaSe = false }
        poslednáChyba = nil

        // Sestavit časový predikát
        let hraniceOkna = Calendar.current.date(
            byAdding: .day,
            value: -dní,
            to: .now
        ) ?? .now

        let predikát = HKQuery.predicateForSamples(
            withStart: hraniceOkna,
            end: .now,
            options: .strictStartDate
        )

        let třídicíDescriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: false  // nejnovější první
        )

        // Spustit dotaz na background threadu, výsledek přinést zpět
        let surováData: [HKWorkout] = try await withCheckedThrowingContinuation { pokračování in
            let dotaz = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predikát,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [třídicíDescriptor]
            ) { _, výsledky, chyba in
                if let chyba {
                    pokračování.resume(throwing: HealthKitError.dotazSelhal(chyba))
                    return
                }
                pokračování.resume(returning: (výsledky as? [HKWorkout]) ?? [])
            }
            healthStore.execute(dotaz)
        }

        guard !surováData.isEmpty else {
            throw HealthKitError.žádnáData
        }

        // Přeložit na ProcessedWorkout — CPU práce, ale rychlá → OK na main threadu
        let zpracované = surováData.compactMap { trénink -> ProcessedWorkout? in
            let události = ActivityFatigueMapper.přeložit(trénink: trénink)
            // Ignorovat aktivity bez mapování (neznámé sporty, meditace atd.)
            guard !události.isEmpty else { return nil }
            return ProcessedWorkout(source: trénink, fatigueEvents: události)
        }

        // Uložit do publikovaného stavu pro přímé sledování SwiftUI
        zpracovanéTréninky = zpracované
        return zpracované
    }

    /// Kombinovaná funkce: autorizuj (pokud je třeba) + načti tréninky.
    /// Vhodná pro volání z .task { } modifieru.
    func synchronizovatSHealthKit(dní: Int = 2) async {
        await vyžádatAutorizaci()

        do {
            _ = try await načístRecentníTréninky(dní: dní)
        } catch let chyba as HealthKitError {
            poslednáChyba = chyba
        } catch {
            poslednáChyba = .dotazSelhal(error)
        }
    }
}

// MARK: - Mapper aktivit na únavu

/// Čistá (pure) struktura bez stavu — překlad HKWorkoutActivityType → [FatigueEvent].
/// Oddělena od HealthKitManager pro snadné unit testování bez HealthKit frameworku.
struct ActivityFatigueMapper {

    // MARK: - Hlavní vstupní bod

    /// Přeloží jeden HKWorkout do pole FatigueEvents.
    /// Vrátí prázdné pole pro aktivity bez definovaného mapování (neznámé, meditace atd.)
    static func přeložit(trénink: HKWorkout) -> [FatigueEvent] {
        let mapování = mapujAktivitu(trénink.workoutActivityType)
        guard !mapování.isEmpty else { return [] }

        // Intenzitu škálovat podle délky tréninku:
        // < 20 min → o jeden stupeň méně | > 90 min → o jeden stupeň více
        let délkaMinut = trénink.duration / 60
        let škálovanéMapování = škálovat(mapování: mapování, délkaMinut: délkaMinut)

        let událost = FatigueEvent(
            timestamp: trénink.startDate,
            sourceKind: .healthKit,
            sourceName: lokalizovanyNazev(pro: trénink.workoutActivityType),
            muscleFatigueLevels: škálovanéMapování
        )

        return [událost]
    }

    // MARK: - Mapování aktivit

    /// Centrální lookup tabulka: HKWorkoutActivityType → [MuscleGroup: FatigueLevel]
    ///
    /// Principy:
    ///   • Bojové sporty (Krav Maga, MMA, box) → silná únava ramen + středu těla + kyčelní flexory
    ///   • Míčové sporty s během (hokej, fotbal, florbal) → silná únava nohou
    ///   • Rakety (tenis, squash, badminton) → ramena + nohy + střed těla
    ///   • Silový trénink → záda + hrudník (hrubý odhad bez znalosti konkrétního tréninku)
    ///   • Kardio (běh, kolo, veslování) → nohy nebo kombinace dle aktivity
    static func mapujAktivitu(_ typ: HKWorkoutActivityType) -> [MuscleGroup: FatigueLevel] {
        switch typ {

        // ── Bojové sporty ──────────────────────────────────────────────────────
        case .martialArts, .boxing, .kickboxing:
            // Krav Maga, MMA, box: výrazné zapojení ramen, středu těla a kyčelních flexorů
            return [
                .shoulders: .high,
                .core:      .high,
                .hipFlexors: .medium,
                .forearms:  .medium,
                .back:      .low,
            ]

        case .wrestling:
            // Zápas: celotělová aktivita, dominantní záda a střed těla
            return [
                .back:      .high,
                .core:      .high,
                .shoulders: .medium,
                .quads:     .medium,
                .forearms:  .medium,
            ]

        // ── Hokej a bruslení ───────────────────────────────────────────────────
        case .hockey:
            // Florbal/hokej: silné nohy (střelba, bruslení) + ramena (hůl)
            return [
                .quads:      .high,
                .hamstrings: .high,
                .glutes:     .medium,
                .calves:     .medium,
                .shoulders:  .medium,
                .core:       .low,
            ]

        case .skating:
            return [
                .quads:      .high,
                .glutes:     .high,
                .hamstrings: .medium,
                .calves:     .medium,
                .core:       .low,
            ]

        // ── Míčové sporty sběhem ──────────────────────────────────────────────
        case .soccer:
            return [
                .quads:      .high,
                .hamstrings: .high,
                .calves:     .medium,
                .hipFlexors: .medium,
                .core:       .low,
            ]

        case .basketball, .volleyball, .handball:
            // Výbušné pohyby: skoky + změny směru + hody
            return [
                .quads:      .high,
                .hamstrings: .medium,
                .calves:     .medium,
                .shoulders:  .medium,
                .core:       .medium,
            ]

        case .baseball, .softball:
            // Dominantní hod → ramena a předloktí
            return [
                .shoulders:  .high,
                .forearms:   .medium,
                .core:       .medium,
                .back:       .low,
            ]

        // ── Rakety ────────────────────────────────────────────────────────────
        case .tennis:
            // Tenis: asymetrické zatížení ramene + dynamické nohy + rotace středu
            return [
                .shoulders:  .high,
                .quads:      .high,
                .core:       .medium,
                .forearms:   .medium,
                .calves:     .low,
            ]

        case .squash, .racquetball, .badminton, .tableTennis:
            // Rakety obecně: podobné tenisu, ale trochu méně intenzivní nohy
            return [
                .shoulders:  .high,
                .core:       .medium,
                .quads:      .medium,
                .forearms:   .medium,
            ]

        // ── Běh a chůze ───────────────────────────────────────────────────────
        case .running:
            return [
                .quads:      .high,
                .hamstrings: .high,
                .calves:     .medium,
                .hipFlexors: .medium,
                .core:       .low,
            ]

        case .walking, .hiking:
            // Chůze/turistika: mírná únava, ale reálná při delší aktivitě
            return [
                .quads:      .low,
                .hamstrings: .low,
                .calves:     .medium,
                .hipFlexors: .low,
            ]

        case .stairs:
            return [
                .quads:      .high,
                .glutes:     .medium,
                .calves:     .medium,
                .hamstrings: .low,
            ]

        // ── Cyklistika ────────────────────────────────────────────────────────
        case .cycling:
            return [
                .quads:      .high,
                .hamstrings: .medium,
                .glutes:     .medium,
                .calves:     .low,
                .core:       .low,
            ]

        // ── Vodní sporty ──────────────────────────────────────────────────────
        case .swimming:
            // Plavání: celotělová aktivita, dominantní záda a ramena
            return [
                .back:       .high,
                .shoulders:  .high,
                .core:       .medium,
                .triceps:    .medium,
            ]

        case .rowing:
            return [
                .back:       .high,
                .biceps:     .high,
                .core:       .medium,
                .quads:      .medium,
                .shoulders:  .low,
            ]

        // ── Silový trénink ────────────────────────────────────────────────────
        case .traditionalStrengthTraining, .functionalStrengthTraining:
            // Hrubý odhad bez detailů — engine to zpřesní vlastními daty sessiny
            return [
                .back:       .medium,
                .chest:      .medium,
                .shoulders:  .medium,
                .quads:      .medium,
                .core:       .low,
            ]

        case .crossTraining, .highIntensityIntervalTraining:
            return [
                .quads:      .high,
                .shoulders:  .medium,
                .core:       .high,
                .hamstrings: .medium,
            ]

        // ── Gymnastika a lezení ───────────────────────────────────────────────
        case .gymnastics:
            return [
                .core:       .high,
                .shoulders:  .high,
                .back:       .medium,
                .triceps:    .medium,
            ]

        case .climbing:
            return [
                .back:       .high,
                .forearms:   .high,
                .biceps:     .high,
                .core:       .medium,
                .shoulders:  .medium,
            ]

        // ── Jóga a pilates ────────────────────────────────────────────────────
        case .yoga:
            return [
                .core:       .low,
                .shoulders:  .low,
                .back:       .low,
            ]

        case .pilates:
            return [
                .core:       .medium,
                .back:       .low,
                .shoulders:  .low,
            ]

        // ── Skupinové fitness ─────────────────────────────────────────────────
        case .dance, .danceInspiredTraining:
            return [
                .quads:      .medium,
                .calves:     .medium,
                .core:       .medium,
                .hipFlexors: .low,
            ]

        case .jumpRope:
            return [
                .calves:     .high,
                .shoulders:  .medium,
                .core:       .low,
            ]

        // ── Ostatní / neznámé ─────────────────────────────────────────────────
        default:
            // Pro neznámé aktivity vrátíme prázdné mapování.
            // Caller (přeložit:) tuto aktivitu přeskočí.
            return [:]
        }
    }

    // MARK: - Škálování podle délky tréninku

    /// Upraví intenzitu únavy podle délky aktivity.
    /// Krátký trénink (< 20 min) → snížit o jeden stupeň.
    /// Dlouhý trénink (> 90 min) → zvýšit o jeden stupeň.
    static func škálovat(
        mapování: [MuscleGroup: FatigueLevel],
        délkaMinut: Double
    ) -> [MuscleGroup: FatigueLevel] {
        mapování.mapValues { úroveň in
            if délkaMinut < 20 {
                return FatigueLevel(rawValue: max(úroveň.rawValue - 1, FatigueLevel.none.rawValue)) ?? .none
            } else if délkaMinut > 90 {
                return FatigueLevel(rawValue: min(úroveň.rawValue + 1, FatigueLevel.severe.rawValue)) ?? .severe
            }
            return úroveň
        }
    }

    // MARK: - Lokalizované názvy aktivit

    /// Vrátí česky lokalizovaný název aktivity pro zobrazení v UI.
    static func lokalizovanyNazev(pro typ: HKWorkoutActivityType) -> String {
        switch typ {
        case .martialArts:                  return "Bojové sporty"
        case .boxing:                       return "Box"
        case .kickboxing:                   return "Kickbox"
        case .wrestling:                    return "Zápas"
        case .hockey:                       return "Hokej / Florbal"
        case .skating:                      return "Bruslení"
        case .soccer:                       return "Fotbal"
        case .basketball:                   return "Basketbal"
        case .volleyball:                   return "Volejbal"
        case .handball:                     return "Házená"
        case .baseball:                     return "Baseball"
        case .softball:                     return "Softball"
        case .tennis:                       return "Tenis"
        case .squash:                       return "Squash"
        case .racquetball:                  return "Raketa"
        case .badminton:                    return "Badminton"
        case .tableTennis:                  return "Stolní tenis"
        case .running:                      return "Běh"
        case .walking:                      return "Chůze"
        case .hiking:                       return "Turistika"
        case .stairs:                       return "Schody"
        case .cycling:                      return "Cyklistika"
        case .swimming:                     return "Plavání"
        case .rowing:                       return "Veslování"
        case .traditionalStrengthTraining:  return "Silový trénink"
        case .functionalStrengthTraining:   return "Funkční trénink"
        case .crossTraining:                return "Cross trénink"
        case .highIntensityIntervalTraining: return "HIIT"
        case .gymnastics:                   return "Gymnastika"
        case .climbing:                     return "Lezení"
        case .yoga:                         return "Jóga"
        case .pilates:                      return "Pilates"
        case .dance:                        return "Tanec"
        case .danceInspiredTraining:        return "Tanec (trénink)"
        case .jumpRope:                     return "Švihadlo"
        default:                            return "Jiná aktivita"
        }
    }
}

// MARK: - Rozšíření pro persistenci (volat z ViewModelu / AppState)

extension HealthKitManager {

    /// Synchronizuje HealthKit data do SwiftData ModelContext.
    ///
    /// Odděleno od načítání, protože HealthKitManager nesmí znát ModelContext —
    /// to by porušilo single responsibility a znemožnilo testování.
    ///
    /// Použití z ViewModelu:
    /// ```swift
    /// let události = try await healthKitManager.načístRecentníTréninky(dní: 2)
    /// await healthKitManager.persistovat(zpracované: události, do: modelContext, profil: fatigueProfile)
    /// ```
    func persistovat(
        zpracované: [ProcessedWorkout],
        do modelContext: ModelContext,
        profil: FatigueProfile
    ) {
        // Deduplikovat: nevkládat události, které již v profilu existují
        // (identifikace přes timestamp + sourceName jako kompozitní klíč)
        let existujícíKlíče = Set(
            profil.events.map { "\($0.timestamp.timeIntervalSince1970)_\($0.sourceName)" }
        )

        for zpracovaný in zpracované {
            for událost in zpracovaný.fatigueEvents {
                let klíč = "\(událost.timestamp.timeIntervalSince1970)_\(událost.sourceName)"
                guard !existujícíKlíče.contains(klíč) else { continue }

                modelContext.insert(událost)
                profil.events.append(událost)
            }
        }

        // Uložit kontext — zachytit chybu bez pádu aplikace
        do {
            try modelContext.save()
        } catch {
            poslednáChyba = .dotazSelhal(error)
        }
    }
}

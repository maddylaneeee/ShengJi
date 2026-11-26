import Foundation
import Observation

@MainActor
@Observable
final class AIPromptPreferences {
    static let maximumCustomInstructionLength = 500
    static let maximumOneTimeInstructionLength = 500
    /// Posted across processes when the CLI changes the saved prompts.
    nonisolated static let externalChangeNotification = Notification.Name("ca.lixinchen.localscribe.AIPromptsChanged")

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let appVersion: String

    private static let proofreadKey = "AIPromptPreferences.ProofreadInstructions"
    private static let summaryKey = "AIPromptPreferences.SummaryInstructions"
    private static let preserveKey = "AIPromptPreferences.PreserveAcrossUpdates"
    private static let recordedVersionKey = "AIPromptPreferences.RecordedVersion"

    private var proofreadValue: String
    private var summaryValue: String
    private var preserveValue: Bool
    /// True when a saved prompt was longer than the current limit and was cut.
    private(set) var wasTruncated = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var proofreadInstructions: String {
        get { proofreadValue }
        set {
            proofreadValue = Self.normalized(newValue)
            persist(proofreadValue, key: Self.proofreadKey)
        }
    }

    var summaryInstructions: String {
        get { summaryValue }
        set {
            summaryValue = Self.normalized(newValue)
            persist(summaryValue, key: Self.summaryKey)
        }
    }

    var preservesAcrossUpdates: Bool {
        get { preserveValue }
        set {
            preserveValue = newValue
            defaults.set(newValue, forKey: Self.preserveKey)
        }
    }

    init(defaults: UserDefaults = .standard, appVersion: String = AppInfo.version) {
        self.defaults = defaults
        self.appVersion = appVersion
        let loadedPreserveValue = defaults.object(forKey: Self.preserveKey) as? Bool ?? false
        let recordedVersion = defaults.string(forKey: Self.recordedVersionKey)
        let shouldAdoptNewDefaults = recordedVersion != nil
            && recordedVersion != appVersion
            && !loadedPreserveValue
        preserveValue = loadedPreserveValue
        if shouldAdoptNewDefaults {
            proofreadValue = ""
            summaryValue = ""
            defaults.removeObject(forKey: Self.proofreadKey)
            defaults.removeObject(forKey: Self.summaryKey)
        } else {
            let storedProofread = defaults.string(forKey: Self.proofreadKey) ?? ""
            let storedSummary = defaults.string(forKey: Self.summaryKey) ?? ""
            proofreadValue = Self.normalized(storedProofread)
            summaryValue = Self.normalized(storedSummary)
            if storedProofread.count > Self.maximumCustomInstructionLength
                || storedSummary.count > Self.maximumCustomInstructionLength {
                wasTruncated = true
                persist(proofreadValue, key: Self.proofreadKey)
                persist(summaryValue, key: Self.summaryKey)
            }
        }
        defaults.set(appVersion, forKey: Self.recordedVersionKey)
    }

    /// Re-reads values written by another process, such as `--cli prompts edit`.
    func reload() {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        let proofread = Self.normalized(defaults.string(forKey: Self.proofreadKey) ?? "")
        let summary = Self.normalized(defaults.string(forKey: Self.summaryKey) ?? "")
        let preserve = defaults.object(forKey: Self.preserveKey) as? Bool ?? false
        if proofread != proofreadValue { proofreadValue = proofread }
        if summary != summaryValue { summaryValue = summary }
        if preserve != preserveValue { preserveValue = preserve }
    }

    /// Keeps a running GUI in sync with CLI edits.
    func observeExternalChanges() {
        guard observers.isEmpty else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Self.externalChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
    }

    nonisolated static func postExternalChange() {
        DistributedNotificationCenter.default().postNotificationName(
            externalChangeNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    func instructions(for kind: GemmaOptimizationKind, oneTimeInstructions: String = "") -> String {
        let persistent = switch kind {
        case .proofread: proofreadInstructions
        case .summarize: summaryInstructions
        }
        return [persistent, oneTimeInstructions]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    func reset(_ kind: GemmaOptimizationKind) {
        switch kind {
        case .proofread: proofreadInstructions = ""
        case .summarize: summaryInstructions = ""
        }
    }

    private func persist(_ value: String, key: String) {
        if value.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value, forKey: key)
        }
        defaults.set(appVersion, forKey: Self.recordedVersionKey)
    }

    private static func normalized(_ value: String) -> String {
        String(value.prefix(maximumCustomInstructionLength))
    }
}

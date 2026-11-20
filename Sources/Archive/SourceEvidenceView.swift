import SwiftUI

private struct SourceAvailabilityServiceKey: EnvironmentKey {
    static let defaultValue = SourceAvailabilityService.shared
}

extension EnvironmentValues {
    var sourceAvailabilityService: SourceAvailabilityService {
        get { self[SourceAvailabilityServiceKey.self] }
        set { self[SourceAvailabilityServiceKey.self] = newValue }
    }
}

/// Content for an already selected source. Embed in an existing source/relationship
/// sheet or push it from a source list; never create one per unselected list row.
/// This view does not create another sheet, navigation stack, or dismissal button.
struct SourceEvidenceView: View {
    let source: Source
    var claim: String? = nil
    var service: SourceAvailabilityService? = nil

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sourceAvailabilityService) private var environmentService
    @State private var observation: SourceAvailabilityObservation?
    @State private var isChecking = false
    @State private var retry = 0
    @State private var handledRetry = 0
    @State private var activeRequest: UUID?

    private var currentObservation: SourceAvailabilityObservation? {
        observation?.sourceURL == source.url ? observation : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let claim, !claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(claim).font(.body).lineSpacing(4).textSelection(.enabled)
                    .accessibilityIdentifier("source-claim")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(source.title).font(.subheadline.weight(.semibold)).textSelection(.enabled)
                    .accessibilityIdentifier("source-title")
                if !source.detail.isEmpty {
                    Text(source.detail).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("source-detail")
                }
            }
            HStack(spacing: 16) {
                if let url = SourceAvailabilityService.openableURL(source.url) {
                    // Link hands off the exact original URL immediately. Its
                    // system acceptance is not used as a page-access signal.
                    Link(destination: url) {
                        Label("打开原文", systemImage: "arrow.up.right")
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("source-open-original")
                }
                Spacer(minLength: 0)
                if isChecking {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("正在检查来源链接")
                } else if currentObservation?.outcome.message != nil,
                          SourceAvailabilityService.openableURL(source.url) != nil {
                    Button("重试") { retry += 1 }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("source-retry")
                }
            }
            .font(.subheadline)
            if let observation = currentObservation, let message = observation.outcome.message {
                VStack(alignment: .leading, spacing: 3) {
                    Text(message).font(.footnote)
                    Text(observation.checkedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("source-access-observation")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: CheckKey(url: source.url, active: scenePhase == .active, retry: retry)) {
            guard scenePhase == .active else { return }
            await check()
        }
    }

    @MainActor private func check() async {
        let token = UUID()
        activeRequest = token
        isChecking = true
        let forceRefresh = retry != handledRetry
        handledRetry = retry
        defer {
            if activeRequest == token { isChecking = false }
        }
        do {
            let result = try await (service ?? environmentService).observe(source, forceRefresh: forceRefresh)
            try Task.checkCancellation()
            guard activeRequest == token else { return }
            observation = result
        } catch {
            // Cancellation keeps the last dated observation and original text.
            // Network failures are represented by the service, never thrown.
        }
    }

    private struct CheckKey: Hashable {
        let url: String
        let active: Bool
        let retry: Int
    }
}

import SwiftUI

/// Native sheet and Liquid Glass controls use the same palette as the shop.
/// The draft is immutable: live playback and research cannot change its subject.
struct ResultFeedbackSheet: View {
    let draft: ResultFeedbackDraft
    var onFinish: (ResultFeedbackOutbox.Outcome) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reasons: Set<ResultFeedbackReason> = []
    @State private var note = ""
    @State private var submitting = false
    @State private var failure: String?
    @FocusState private var writing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 12) {
                        ShopCover(artwork: draft.snapshot.subject.artworkURL, title: draft.snapshot.subject.title)
                            .frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(draft.snapshot.subject.title).font(.headline).foregroundStyle(ShopStyle.ink)
                                .accessibilityIdentifier("feedback-subject")
                            if !draft.snapshot.subject.creator.isEmpty {
                                Text(draft.snapshot.subject.creator).font(.caption).foregroundStyle(ShopStyle.secondary)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("原因（选填，可多选）").font(.subheadline).foregroundStyle(ShopStyle.secondary)
                        GlassEffectContainer(spacing: 12) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                                ForEach(ResultFeedbackReason.allCases) { reason in
                                    Button {
                                        if !reasons.insert(reason).inserted { reasons.remove(reason) }
                                    } label: {
                                        HStack(spacing: 6) {
                                            if reasons.contains(reason) { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                                            Text(reason.title).font(.subheadline)
                                        }.frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 8)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(reasons.contains(reason) ? ShopStyle.base : ShopStyle.ink)
                                    .glassEffect(.regular.tint(reasons.contains(reason) ? ShopStyle.accent : nil).interactive(), in: .capsule)
                                    .accessibilityAddTraits(reasons.contains(reason) ? .isSelected : [])
                                    .accessibilityIdentifier("feedback-reason-" + reason.rawValue)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("补充一句（选填）").font(.subheadline).foregroundStyle(ShopStyle.secondary)
                        TextField("哪里不对，或你原本想找什么", text: $note, axis: .vertical)
                            .font(.body).lineLimit(3...5).focused($writing)
                            .padding(14).background(ShopStyle.ink.opacity(0.055), in: .rect(cornerRadius: 14))
                            .foregroundStyle(ShopStyle.ink).accessibilityIdentifier("feedback-note")
                            .onChange(of: note) { _, value in if value.count > 500 { note = String(value.prefix(500)) } }
                    }
                    Text("会附上这首歌和当前结果").font(.footnote).foregroundStyle(ShopStyle.secondary)
                    if let failure { Text(failure).font(.footnote).foregroundStyle(ShopStyle.secondary).accessibilityIdentifier("feedback-error") }
                    Button {
                        writing = false; submitting = true; failure = nil
                        Task { @MainActor in
                            do {
                                let outcome = try await ResultFeedbackOutbox.shared.submit(draft,
                                    reasons: ResultFeedbackReason.allCases.filter(reasons.contains), note: note)
                                onFinish(outcome); dismiss()
                            } catch { failure = error.localizedDescription }
                            submitting = false
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if submitting { ProgressView().tint(ShopStyle.base) }
                            Text(submitting ? "正在提交" : "提交反馈").font(.body.weight(.semibold)).foregroundStyle(ShopStyle.base)
                        }.frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glassProminent).tint(ShopStyle.accent)
                    .accessibilityIdentifier("feedback-submit")
                }
                .padding(24).padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(ShopStyle.base)
            .navigationTitle("这次哪里不对？").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                        .tint(ShopStyle.ink).disabled(submitting).accessibilityIdentifier("feedback-close")
                }
            }
            .disabled(submitting)
        }
        .tint(ShopStyle.accent).preferredColorScheme(.dark)
        .presentationDetents([.fraction(0.78), .large]).presentationDragIndicator(.visible)
        .interactiveDismissDisabled(submitting)
        .accessibilityIdentifier("feedback-sheet")
    }
}

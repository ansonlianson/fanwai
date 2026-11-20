import SwiftUI

struct VideoCueRow: View {
    let workID: WorkID
    let cue: VideoCue
    let open: () -> Void
    @Environment(Library.self) private var library
    @State private var sourcePresented = false
    private var isSaved: Bool { library.watchLaterEntry(for: workID)?.cue == cue }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(spacing: 16) {
                    Text(cue.timeLabel).font(.subheadline.monospacedDigit()).frame(width: 50, alignment: .leading)
                    Text(cue.title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "play.fill").font(.caption)
                }.frame(minHeight: 54).contentShape(.rect)
            }.buttonStyle(.plain)
                .accessibilityLabel("\(cue.timeLabel)，\(cue.title)，观看")
                .accessibilityIdentifier("video-cue-\(cue.seconds)")
            Menu {
                Button(isSaved ? "已留到稍后看" : "稍后从这里看", systemImage: isSaved ? "checkmark" : "clock") {
                    library.saveForLater(workID, cue: cue)
                }.disabled(isSaved)
                    .accessibilityIdentifier("video-cue-save-\(cue.seconds)")
                Button("时间点出处", systemImage: "text.quote") { sourcePresented = true }
            } label: {
                Image(systemName: isSaved ? "checkmark.circle" : "ellipsis")
                    .font(.subheadline).frame(width: 44, height: 54)
                    .foregroundStyle(library.visualDirection.accent)
            }
            .accessibilityLabel("\(cue.timeLabel) 更多选项")
            .accessibilityIdentifier("video-cue-menu-\(cue.seconds)")
        }
        .id(cue.id)
        .sheet(isPresented: $sourcePresented) {
            NavigationStack {
                ScrollView { SourceEvidenceView(source: cue.source, claim: cue.timeLabel + " · " + cue.title).padding(22) }
                    .navigationTitle("出处").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sourcePresented = false } } }
            }.presentationDetents([.medium, .large])
        }
    }
}

/// Used only when a saved upload differs from the work's current destination.
/// It opens the saved URL and cue explicitly, without rewriting either version.
struct SavedVideoIntentView: View {
    let entry: WatchLaterEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(Library.self) private var library
    @State private var openFailed = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(entry.workID.displayTitle).font(.title2.bold())
                    if let video = entry.video {
                        Text(video.providerName).font(.subheadline).foregroundStyle(.secondary)
                        if let cue = entry.cue {
                            Text(cue.timeLabel + " · " + cue.title).font(.headline)
                        }
                        Button(entry.cue.map { "从 \($0.timeLabel) 观看" } ?? "观看视频", systemImage: "play.fill") {
                            guard let url = video.destination(seconds: entry.cue?.seconds) else { return }
                            library.persist()
                            openURL(url) { accepted in openFailed = !accepted }
                        }.buttonStyle(.glassProminent).controlSize(.large)
                        if openFailed { Text("暂时无法打开，请重试。").font(.footnote).foregroundStyle(.secondary) }
                        Text("保存的视频链接").font(.caption).foregroundStyle(.secondary)
                        Text(video.canonicalURL).font(.footnote).textSelection(.enabled)
                    }
                }.padding(22)
            }.navigationTitle("稍后看").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

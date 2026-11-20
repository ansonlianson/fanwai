import SwiftUI

struct RootView: View {
    var body: some View { NowRootView() }
}

/// A two-destination navigation surface. Its geometry is independent of the
/// selected page and playback; each destination still owns its NavigationStack.
struct CompactLibraryTabs: View {
    @Binding var selection: AppTab
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            item(.now, title: "此刻", symbol: "play.circle.fill")
            item(.collection, title: "收藏", symbol: "star.fill")
        }
        .padding(5)
        .frame(maxWidth: typeSize.isAccessibilitySize ? 320 : 224)
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主导航")
        .accessibilityIdentifier("compact-main-tabs")
    }

    private func item(_ tab: AppTab, title: String, symbol: String) -> some View {
        Button { selection = tab } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 8)
            .foregroundStyle(selection == tab ? VisualDirection.orbit.foreground : VisualDirection.orbit.secondary)
            .background {
                Capsule().fill(.white.opacity(selection == tab ? 0.12 : 0))
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selection == tab ? "已选择" : "")
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
        .accessibilityIdentifier("tab-" + tab.rawValue)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selection)
    }
}

struct Atmosphere: View {
    let art: String
    @Environment(Library.self) private var library
    var body: some View {
        VisualAtmosphere(art: art, style: library.visualDirection)
    }
}

struct MiniPlayer: View {
    @Environment(Library.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing: 12) {
            Button { library.playerPresented = true } label: {
                HStack(spacing: 10) {
                    RecordStoreArtwork(id: library.playing, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(library.playing.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if !typeSize.isAccessibilitySize {
                            Text(library.playing.work.creator).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    // The native tab accessory has a compact fixed height.
                    // Full-size metadata remains in the expanded player.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("正在播放，\(library.playing.displayTitle)，\(library.playing.work.creator)")
            .accessibilityHint("打开播放器")
            .accessibilityIdentifier("mini-player-open")
            .accessibilityShowsLargeContentViewer {
                Label(library.playing.displayTitle, systemImage: "music.note")
            }
            Button(library.isPlaying ? "暂停" : "播放", systemImage: library.isPlaying ? "pause.fill" : "play.fill") {
                library.togglePlayback()
            }.labelStyle(.iconOnly).font(.system(size: 19, weight: .semibold)).frame(minWidth: 44, minHeight: 44)
                .disabled(library.playbackBusy)
            Button("下一首", systemImage: "forward.end.fill") { library.skip() }
                .labelStyle(.iconOnly).font(.system(size: 19, weight: .semibold)).frame(minWidth: 44, minHeight: 44)
                .disabled(library.playbackBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct UnidentifiedPlaybackAccessory: View {
    @Environment(Library.self) private var library
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").foregroundStyle(.secondary)
            Text("播放信息暂未同步").font(.subheadline).lineLimit(2)
                .accessibilityIdentifier("playback-unidentified")
            Spacer(minLength: 4)
            Button("搜索", systemImage: "magnifyingglass") { library.searchPresented = true }
                .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                .accessibilityLabel("搜索作品")
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
}

struct NewTrackPrompt: View {
    @Environment(Library.self) private var library
    var body: some View {
        HStack(spacing: 12) {
            Button { library.followPlayback() } label: {
                HStack(spacing: 10) {
                    RecordStoreArtwork(id: library.playing, size: 32)
                    Text("正在播放 \(library.playing.displayTitle)").font(.subheadline).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
            }.buttonStyle(.plain)
            Button("关闭", systemImage: "xmark") { library.showNewTrack = false }
                .labelStyle(.iconOnly).frame(width: 44, height: 44)
        }
        .padding(.leading, 12)
        .glassEffect(in: .rect(cornerRadius: 18))
        .padding(.horizontal, 20).padding(.bottom, 8)
    }
}

struct SongActions: View {
    let id: WorkID
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmPlay = false
    @State var outcome: ExperienceScenario = .ready
    private var hasCatalogVersion: Bool { id.work.hasCatalogRecording }
    var body: some View {
        ScrollView {
        VStack(spacing: 22) {
            HStack(spacing: 14) {
                if library.visualDirection == .orbit {
                    RecordStoreArtwork(id: id, size: 64)
                } else {
                    Image(id.work.art).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(id.displayTitle).font(.title3.bold())
                    Text(id.work.creator).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if outcome.isQueueCase {
                QueueOutcomeActions(outcome: $outcome, id: id)
            } else {
            VStack(spacing: 10) {
                if library.playbackPlatform == .apple, !hasCatalogVersion {
                    Button { library.findRecording(for: id) } label: {
                        Label("查找录音版本", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                    }.buttonStyle(.glassProminent).controlSize(.large)
                }
                if library.canQueueNext && hasCatalogVersion {
                Button { library.queueNext(id) } label: {
                    Label(library.pendingSong == id ? "正在加入" : "下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                }.buttonStyle(.glassProminent).controlSize(.large).disabled(library.playbackBusy || library.isPlaybackUncertain(for: id, command: .insertNext))
                }
                Button {
                    library.toggleListenLater(id)
                    let text = library.listenLater.contains(id) ? "已加入稍后听" : "已移出稍后听"
                    dismiss(); library.flash(text)
                } label: {
                    Label(library.listenLater.contains(id) ? "移出稍后听" : "加入稍后听", systemImage: library.listenLater.contains(id) ? "checkmark" : "plus")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.glass).controlSize(.large)
                HStack {
                    Button { library.toggleSaved(id) } label: {
                        Label(library.saved.contains(id) ? "已收藏" : "收藏作品", systemImage: library.saved.contains(id) ? "star.fill" : "star")
                    }
                    Spacer(minLength: 16)
                    if library.listenLater.contains(id) {
                        Button("已听", systemImage: "checkmark") {
                            library.toggleListenLater(id)
                            dismiss(); library.flash("已从稍后听移出")
                        }
                    }
                }.font(.subheadline).padding(.vertical, 5)
                if library.playbackPlatform != .apple {
                    Button(library.playbackPlatform.listenTitle) { dismiss(); library.listen(id) }
                        .font(.subheadline).padding(.top, 5)
                } else if library.canPlayCatalog && hasCatalogVersion {
                    Button("现在播放") { confirmPlay = true }
                        .font(.subheadline).padding(.top, 5)
                        .disabled(library.playbackBusy || library.isPlaybackUncertain(for: id, command: .playNow))
                } else if let raw = id.work.url, let url = URL(string: raw) {
                    Link(id.work.externalLinkTitle, destination: url).font(.subheadline).padding(.top, 5)
                }
            }
            }
            if let error = library.playbackError {
                Text(error).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if library.isPlaybackUncertain(for: id, command: .insertNext) || library.isPlaybackUncertain(for: id, command: .playNow) {
                if let raw = id.work.url, let url = URL(string: raw) {
                    Link("打开 Apple Music 检查", destination: url).font(.subheadline)
                }
                Button("我已检查播放队列") {
                    library.acknowledgePlaybackCheck(for: id, command: .insertNext)
                    library.acknowledgePlaybackCheck(for: id, command: .playNow)
                }.font(.footnote)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background {
            if library.visualDirection == .orbit {
                VisualAtmosphere(art: id.work.art, style: .orbit)
            }
        }
        .confirmationDialog("切换到 \(id.displayTitle)？", isPresented: $confirmPlay, titleVisibility: .visible) {
            Button("现在播放") { library.startNow(id) }
        } message: { Text("当前歌曲会停止播放。") }
    }
}

struct PlayerSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        ScrollView {
        VStack(spacing: 28) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                : AnyLayout(HStackLayout(spacing: 16))
            layout {
                if library.visualDirection == .orbit {
                    RecordStoreArtwork(id: library.playing, size: 76, showsDisc: true)
                } else {
                    Image(library.playing.work.art).resizable().frame(width: 76, height: 76).clipShape(.rect(cornerRadius: 14))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(library.playing.displayTitle).font(.title2.bold())
                    Text(library.playing.work.creator).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                if !typeSize.isAccessibilitySize { Spacer() }
            }
            HStack(spacing: 40) {
                Button(library.isPlaying ? "暂停" : "播放", systemImage: library.isPlaying ? "pause.fill" : "play.fill") {
                library.togglePlayback()
                }.labelStyle(.iconOnly)
                Button("下一首", systemImage: "forward.end.fill") { library.skip() }.labelStyle(.iconOnly)
            }.font(.title).buttonStyle(.glass).controlSize(.large).disabled(library.playbackBusy)
            if let next = library.next {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("已设为下一首")
                            if let receipt = library.playbackOperations.first(where: {
                                $0.command == .insertNext && $0.outcome == .succeeded && $0.targetWorkID == next
                            }) {
                                Text(receipt.completedAt, style: .time)
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(next.displayTitle).font(.headline)
                    }
                    Spacer()
                    RecordStoreArtwork(id: next, size: 44)
                }
            }
        }.padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
            .accessibilityIdentifier("player-sheet")
            .background {
                if library.visualDirection == .orbit {
                    VisualAtmosphere(art: library.playing.work.art, style: .orbit)
                }
            }
    }
}

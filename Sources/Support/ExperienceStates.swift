import SwiftUI

enum ExperienceScenario: String {
    case ready, consent, denied, idle, loading, partial, empty, offline, ambiguous
    case queuePending = "queue-pending", queueFailed = "queue-failed", queueUncertain = "queue-uncertain"
    case unavailable, searchEmpty = "search-empty", unidentified
    static var initial: Self {
        let arg = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--experience=") }
        return arg.flatMap { Self(rawValue: String($0.dropFirst(13))) } ?? .ready
    }
    var isQueueCase: Bool { [.queuePending, .queueFailed, .queueUncertain, .unavailable].contains(self) }
    var hasPlayback: Bool { ![.consent, .denied, .idle, .unidentified].contains(self) }
}

struct ExperienceRoot: View {
    @Binding var scenario: ExperienceScenario
    @Environment(Library.self) private var library
    var body: some View {
        Group {
            if scenario == .ready || scenario.isQueueCase { WorkPage(id: library.focus, isRoot: true).id(library.focus) }
            else { statePage }
        }
    }
    private var statePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                switch scenario {
                case .consent:
                    intro("music.note", "连接 Apple Music", "从正在播放的歌曲，继续发现作品和创作者。")
                    Button("连接 Apple Music") { scenario = .ready }.buttonStyle(.glass).controlSize(.large)
                    searchButton
                case .denied:
                    intro("music.note", "还不能读取正在播放", "你可以在设置中允许访问音乐，也可以直接搜索作品。")
                    Link("前往设置", destination: URL(string: UIApplication.openSettingsURLString)!).buttonStyle(.glass).controlSize(.large)
                    searchButton
                case .idle:
                    intro("pause.circle", "此刻没有播放", "接着上次的作品逛逛。")
                    entity(.pool, "上次浏览")
                    entity(.animenz, "钢琴改编")
                    searchButton
                case .unidentified:
                    intro("waveform", "这首歌还没对上", "现有信息不足以确认版本。用歌名或创作者找一找。")
                    searchButton
                case .loading:
                    compactWork(.pool)
                    HStack { ProgressView(); Text("正在查找关联").foregroundStyle(.secondary) }
                    ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 16).fill(.quaternary).frame(height: 72).accessibilityHidden(true) }
                case .partial:
                    compactWork(.pool)
                    Text("关联").font(.title2.bold())
                    entity(.film, "配乐来自")
                    entity(.ushio, "作曲")
                    HStack { ProgressView(); Text("故事还在整理").font(.subheadline).foregroundStyle(.secondary) }
                case .empty:
                    compactWork(.distance)
                    Text("还没有更多资料").font(.title2.bold())
                    Text("先从作品和创作者继续。找到可靠的故事后，会补在这里。")
                        .foregroundStyle(.secondary)
                    entity(.utada, "演唱")
                    entity(.distanceAlbum, "所属专辑")
                case .offline:
                    compactWork(.pool)
                    Label("离线，显示已保存的内容", systemImage: "wifi.slash").font(.subheadline).foregroundStyle(.secondary)
                    entity(.film, "配乐来自")
                    entity(.animenz, "钢琴改编")
                    Button("重新连接") { scenario = .ready }.buttonStyle(.glass)
                case .ambiguous:
                    Text("你找的是哪个版本？").font(.title2.bold())
                    Text("in the pool").font(.subheadline).foregroundStyle(.secondary)
                    entity(.pool, "牛尾宪辅 · 原声录音 · 2025")
                    entity(.animenz, "Animenz · 钢琴改编视频 · 5:24")
                case .searchEmpty:
                    intro("magnifyingglass", "没有找到作品", "试试原名、创作者或作品链接。")
                    searchButton
                case .queuePending, .queueFailed, .queueUncertain, .unavailable:
                    compactWork(.jane)
                    queueState
                case .ready: EmptyView()
                }
            }.padding(24).padding(.top, 12)
        }.background { Atmosphere(art: scenario.hasPlayback ? "pool" : "") }
    }
    private func intro(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: symbol).font(.system(size: 48, weight: .light)).foregroundStyle(.secondary).padding(.top, 54)
            Text(title).font(.largeTitle.bold())
            Text(detail).font(.body).foregroundStyle(.secondary).lineSpacing(5)
        }.padding(.bottom, 8)
    }
    private var searchButton: some View {
        Button("搜索作品", systemImage: "magnifyingglass") { library.searchPresented = true }.buttonStyle(.glass).controlSize(.large)
    }
    private func compactWork(_ id: WorkID) -> some View {
        HStack(spacing: 18) {
            Image(id.work.art).resizable().scaledToFill().frame(width: 90, height: 90).clipShape(.rect(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 8) {
                Text(id.work.title).font(.title2.bold())
                Text(id.work.creator).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 14)
    }
    private func entity(_ id: WorkID, _ relation: String) -> some View {
        NavigationLink(value: Route.work(id)) { EntityRow(id: id, relation: relation, showsChevron: true) }.buttonStyle(.plain)
    }
    @ViewBuilder private var queueState: some View {
        switch scenario {
        case .queuePending:
            HStack { ProgressView(); Text("正在加入下一首") }.font(.headline)
            Text("当前歌曲继续播放。").foregroundStyle(.secondary)
        case .queueUncertain:
            Text("尚未确认是否加入").font(.title2.bold())
            Text("Apple Music 没有返回结果。先查看播放列表，避免重复添加。").foregroundStyle(.secondary)
            musicLink
            saveLater
        case .queueFailed:
            Text("没有加入下一首").font(.title2.bold())
            Text("请求未提交成功，当前歌曲不受影响。").foregroundStyle(.secondary)
            Button("重试") { scenario = .queuePending }.buttonStyle(.glass)
            saveLater
        case .unavailable:
            Text("暂时无法在这里播放").font(.title2.bold())
            Text("可以先加入稍后听，或在 Apple Music 中查看可用版本。").foregroundStyle(.secondary)
            musicLink
            saveLater
        default: EmptyView()
        }
    }
    private var musicLink: some View { Link("在 Apple Music 中查看", destination: URL(string: WorkID.jane.work.url!)!).buttonStyle(.glass).controlSize(.large) }
    private var saveLater: some View {
        Button(library.listenLater.contains(.jane) ? "已加入稍后听" : "加入稍后听", systemImage: library.listenLater.contains(.jane) ? "checkmark" : "plus") {
            library.toggleListenLater(.jane)
        }.buttonStyle(.glass).controlSize(.large)
    }
}


struct QueueOutcomeActions: View {
    @Binding var outcome: ExperienceScenario
    let id: WorkID
    @Environment(Library.self) private var library
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if outcome == .queuePending {
                HStack { ProgressView(); Text("正在加入下一首").font(.headline) }
                Text("当前歌曲继续播放。").foregroundStyle(.secondary)
            } else {
                Text(outcome == .queueFailed ? "没有加入下一首" : outcome == .queueUncertain ? "尚未确认是否加入" : "暂时无法在这里播放").font(.title3.bold())
                Text(outcome == .queueFailed ? "请求未提交成功，当前歌曲不受影响。" : outcome == .queueUncertain ? "Apple Music 没有返回结果。先查看播放列表，避免重复添加。" : "可以先加入稍后听，或在 Apple Music 中查看可用版本。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if outcome == .queueFailed {
                    Button("重试") { outcome = .queuePending }.buttonStyle(.glass).controlSize(.large)
                } else if let url = id.work.url.flatMap(URL.init(string:)) {
                    Link("在 Apple Music 中查看", destination: url).buttonStyle(.glass).controlSize(.large)
                }
                Button(library.listenLater.contains(id) ? "已加入稍后听" : "加入稍后听", systemImage: library.listenLater.contains(id) ? "checkmark" : "plus") { library.toggleListenLater(id) }
                    .buttonStyle(.glass).controlSize(.large)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

import MusicKit
import SwiftUI
import UIKit

/// 设置: reached from the gear on 收藏 only. It holds what is useful now — the Apple Music
/// connection and region, history, version, and editable story writing
/// (2026-11-16 anson 经 Codex). Provider credentials stay separate.
struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false
    @State private var cleared = false
    @State private var writing = StoryWritingStore.runtime.load().style
    @AppStorage(NextWorkPrefetch.paidKey) private var prefetchPaid = false
    @AppStorage(ConfiguredResearchTransport.widerStoryKey) private var widerStory = true
    @Environment(StoryModelSettings.self) private var model
    @State private var trial = TrialAccess.shared
    @State private var enteringCode = false
    /// 「按现在的模型约 ¥0.03 一首。」, from the chosen model's price; any service, not only DeepSeek.
    static func extra(_ cost: Double?, per unit: String) -> String {
        guard let cost else { return "花费按「模型」里填的单价估算。" }
        return String(format: "按现在的模型每%@约多花 ¥%.2f。", unit, cost)
    }

    private var connected: Bool { library.musicConnected }
    private static var monthStart: Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
    }
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short)（\(build)）"
    }

    var body: some View {
        @Bindable var library = library
        NavigationStack {
            Form {
                Section {
                    Picker("默认播放平台", selection: $library.playbackPlatform) {
                        ForEach(PlaybackPlatform.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .accessibilityIdentifier("settings-playback-platform")
                } header: { Text("默认播放平台") }
                Section {
                    LabeledContent("状态") {
                        if connected { Text("已连接") }
                        else {
                            Button("连接") { Task { await library.connectMusic(); await AccountStorefront.sync(library) } }
                                .disabled(library.playbackBusy)
                        }
                    }
                    if connected {
                        LabeledContent("地区", value: AccountStorefront.name(library.country) + " · 跟随账号")
                    } else {
                        Picker("地区", selection: $library.country) {
                            ForEach(AccountStorefront.choices, id: \.self) { Text(AccountStorefront.name($0)).tag($0) }
                        }
                    }
                } header: { Text("Apple Music") } footer: {
                    Text("已连接时，搜索、版本和链接都用你账号所在的地区；没连接时才可以在这里选。")
                }
                Section {
                    Button(cleared ? "已清除" : "清除浏览记录", role: .destructive) { confirmingClear = true }
                        .disabled(cleared)
                        .confirmationDialog("清除浏览记录？", isPresented: $confirmingClear, titleVisibility: .visible) {
                            Button("清除", role: .destructive) {
                                library.clearBrowsingHistory(); SearchHistory.shared.clear()
                                library.clearRelationTrails()
                                cleared = true
                            }
                        }
                } header: { Text("记录") } footer: {
                    Text("清除「最近搜索」「最近探索」和每首歌关系图的展开状态。收藏的歌和它们的关系图不受影响。")
                }
                Section {
                    Picker("故事写法", selection: $writing) {
                        ForEach(StoryWritingPreferences.Style.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: writing) { _, style in try? StoryWritingStore.runtime.save(.init(style: style)) }
                    .accessibilityIdentifier("settings-story-writing")
                    NavigationLink("模型") { StoryModelSettingsView() }
                        .accessibilityIdentifier("settings-model")
                    // 体验码: what is left on it, and where another one goes in.
                    if trial.hasPass || trial.offered {
                        Button { enteringCode = true } label: {
                            LabeledContent("体验码", value: trial.hasPass ? "还剩 \(trial.remaining) / \(trial.total) 首" : "未填").foregroundStyle(.primary)
                        }.accessibilityIdentifier("settings-trial-code")
                    }
                    NavigationLink { UsageView() } label: {
                        LabeledContent("用量", value: UsageLedger.shared.total(since: Self.monthStart).text)
                    }.accessibilityIdentifier("settings-usage")
                } footer: { Text("写法对之后新查的故事生效。用量显示的是本月。") }
                Section {
                    Toggle("放宽故事范围", isOn: $widerStory).accessibilityIdentifier("settings-wider-story")
                } footer: {
                    Text("这首歌自己查不到幕后时，改讲它所属的动画、电影、游戏或专辑的幕后，开头标「关于《…》」。故事会多一些，但讲的不一定是这首歌本身。只在没查到时多查一次，" + Self.extra(ConfiguredResearchTransport.widerStoryCost(model.price), per: "首"))
                }
                Section {
                    Toggle("提前查卡片的关联", isOn: $prefetchPaid).accessibilityIdentifier("settings-prefetch")
                } footer: {
                    Text("卡片出来后接着查它们各自的关联，在关系图里点开就有。每首歌最多多查 3 张卡，" + Self.extra(NextWorkPrefetch.cardCost(model.price), per: "张") + "关着时只用免费数据库预查。")
                }
                Section("关于") {
                    LabeledContent("版本", value: Self.version)
                        .contextMenu {
                            Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = "番外 " + Self.version }
                        }
                        .accessibilityIdentifier("settings-version")
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") { dismiss() }.accessibilityIdentifier("settings-done")
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await AccountStorefront.sync(library) }
        .task { await trial.refresh() }
        .fullScreenCover(isPresented: $enteringCode) {
            NavigationStack {
                OnboardingTrialCode { enteringCode = false }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { enteringCode = false } } }
            }.preferredColorScheme(.dark).tint(ShopStyle.accent)
        }
    }
}

/// One region for every catalogue lookup: the Apple Music account's own storefront when
/// connected; the region chosen in 设置 otherwise (MAP-COLLECTION-DESIGN §7).
@MainActor enum AccountStorefront {
    static let choices = ["jp", "us", "cn", "hk", "tw", "gb"]
    static func name(_ code: String) -> String {
        switch code.lowercased() {
        case "jp": "日本"
        case "us": "美国"
        case "cn": "中国大陆"
        case "hk": "中国香港"
        case "tw": "中国台湾"
        case "gb": "英国"
        default: code.uppercased()
        }
    }
    static func sync(_ library: Library) async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-isolate-data") { return }
        #endif
        guard library.music.snapshot.authorization == .authorized,
              let code = try? await MusicDataRequest.currentCountryCode else { return }
        let value = code.lowercased()
        guard value.count == 2, value.allSatisfy({ $0.isASCII && $0.isLetter }), library.country != value else { return }
        library.country = value
    }
}

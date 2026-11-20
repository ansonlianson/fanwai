import MusicKit
import SwiftUI
import UniformTypeIdentifiers

extension PlaybackPlatform {
    /// The platform's own app icon (App Store artwork), for places that name it.
    var iconAsset: String {
        switch self { case .apple: "PlatformAppleMusic"; case .qq: "PlatformQQ"; case .netease: "PlatformNetease" }
    }
    var openTitle: String { "在\(title)中打开" }
    /// Opens the app itself (to find a song and copy its link); falls back to its website.
    var appURL: URL { URL(string: self == .qq ? "qqmusic://" : self == .netease ? "orpheus://" : "music://")! }
    var webURL: URL { URL(string: self == .qq ? "https://y.qq.com" : self == .netease ? "https://music.163.com" : "https://music.apple.com")! }
}

struct PlatformIcon: View {
    let platform: PlaybackPlatform
    var size: CGFloat = 28
    var body: some View {
        Image(platform.iconAsset).resizable().interpolation(.high).frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// 此刻 for a QQ 音乐 / 网易云 user with no song yet (DOMESTIC-STORY-ART, revised 11-17):
/// the same ledge as 此刻 with the lamp off and nothing on it; the copy sits where a
/// song's title would; the bin stays away until there is a song to dig from.
struct DomesticCounterView: View {
    let platform: PlaybackPlatform
    var onPaste: @MainActor (String) -> Void
    var onSearch: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, k = W / ShopPlates.plateWidth, r = W / 402
            ZStack(alignment: .topLeading) {
                ShopStyle.base
                if let m = ShopPlates.shared.main("lp_paused") {
                    if let bg = m.bg {
                        ShopLayerImage(image: ShopPlates.shared.image("lp_paused", bg), frame: CGRect(x: 0, y: 0, width: m.size[0], height: m.size[1]), k: k)
                    }
                    if let f = m.front {
                        ShopLayerImage(image: ShopPlates.shared.image("lp_paused", f.over), frame: f.frame.rect, k: k)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    // ONBOARDING (2026-11-18): an Apple Music reader who has not played anything yet
                    // gets the same empty ledge, not the bundled demo record labelled 「上次停在这里」.
                    Text(platform == .apple ? "放一首歌" : "复制一首歌的链接").font(.system(size: 30, weight: .semibold)).tracking(-0.4)
                        .accessibilityIdentifier("now-title")
                    Text(platform == .apple ? "在 Apple Music 里播放，回到这里就能看到它背后的故事。" : "在\(platform.title)点「分享」›「复制链接」，回来粘贴。")
                        .font(.system(size: 13.5)).foregroundStyle(ShopStyle.secondary).padding(.top, 4)
                    HStack(spacing: 10) {
                        if platform != .apple {
                            ClipboardPasteButton(onPaste: onPaste)
                            .labelStyle(.titleAndIcon).buttonBorderShape(.capsule).controlSize(.large).tint(ShopStyle.accent)
                            .accessibilityIdentifier("counter-paste")
                        }
                        Button(action: onSearch) {
                            Label("搜索歌曲", systemImage: "magnifyingglass").font(.system(size: 13.5, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 38)
                        }
                        .buttonStyle(.plain).foregroundStyle(ShopStyle.ink).glassEffect(.regular.interactive(), in: .capsule)
                        .accessibilityIdentifier("counter-search")
                    }.padding(.top, 14)
                    Button {
                        openURL(platform.appURL) { opened in if !opened { openURL(platform.webURL) } }
                    } label: {
                        HStack(spacing: 8) {
                            PlatformIcon(platform: platform, size: 22)
                            Text("打开\(platform.title)").font(.system(size: 13.5, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(ShopStyle.accent).padding(.top, 18)
                    .accessibilityIdentifier("counter-open-platform")
                }
                .foregroundStyle(ShopStyle.ink)
                .padding(.horizontal, 26).padding(.top, 333 * r)
                .frame(width: W, alignment: .leading)
            }
            .frame(width: W, height: geo.size.height, alignment: .topLeading).clipped()
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("domestic-counter")
    }
}

/// First run: one question, shown once and only to people not connected to Apple Music.
struct PlatformChoiceSheet: View {
    var onChoose: (PlaybackPlatform) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("用什么听歌？").font(.system(size: 24, weight: .semibold))
            Text("「去听」会直接打开那首歌。以后可以在设置里改。")
                .font(.system(size: 14)).foregroundStyle(.secondary).padding(.bottom, 6)
            option(.apple, "跟着正在播放的歌")
            option(.qq, "粘贴链接或搜索歌曲")
            option(.netease, "粘贴链接或搜索歌曲")
        }
        .padding(22)
        .accessibilityIdentifier("platform-choice")
    }
    private func option(_ platform: PlaybackPlatform, _ detail: String) -> some View {
        Button { onChoose(platform) } label: {
            HStack(spacing: 12) {
                PlatformIcon(platform: platform, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(platform.title).font(.system(size: 16, weight: .semibold))
                    Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12).contentShape(.rect)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain).accessibilityIdentifier("platform-choice-" + platform.rawValue)
    }
}

/// The QQ 音乐 / 网易云 hooks on the root view, kept out of its long modifier chain. Since the
/// first-run flow (ONBOARDING, 2026-11-18) they also present it: the old 用什么听歌 sheet is its first page.
struct DomesticHooks: ViewModifier {
    @Binding var askPlatform: Bool
    @Binding var platformAsked: Bool
    @Binding var toast: String?
    let previewing: Bool
    let checkClipboard: () -> Void
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content
            .task {
                checkClipboard()
                let forced = ProcessInfo.processInfo.arguments.contains("--ui-onboarding")
                // Readers from before the first-run flow have already chosen; they never see it.
                if !library.onboardingDone, !forced,
                   platformAsked || MusicAuthorization.currentStatus == .authorized || StoryModelSettings.shared.hasKey {
                    library.onboardingDone = true
                }
                if !library.onboardingDone && (!previewing || forced) { askPlatform = true }
            }
            .onChange(of: library.playbackPlatform) { _, _ in checkClipboard() }
            // 体验码: what the relay says is left, and its switch; asked on launch and on coming forward.
            .task { await TrialAccess.shared.loadConfiguration(); await TrialAccess.shared.refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await TrialAccess.shared.refresh() } } }
            // The last few free lookups are counted down, once each.
            .onChange(of: TrialAccess.shared.remaining) { old, left in
                if TrialAccess.shared.hasPass, left < old, left <= 3 { toast = left == 0 ? "体验码的次数用完了" : "体验码还剩 \(left) 首" }
            }
            .onChange(of: library.listening.lastReceipt?.id) { _, _ in
                guard let receipt = library.listening.lastReceipt, receipt.platform != .apple else { return }
                toast = receipt.accepted ? "已在\(receipt.platform.title)打开" : "没能打开\(receipt.platform.title)"
            }
            .fullScreenCover(isPresented: $askPlatform) {
                OnboardingFlow { outcome in
                    library.onboardingDone = true; platformAsked = true; askPlatform = false
                    if outcome == .trial { toast = "可以免费查 \(TrialAccess.shared.remaining) 首了" }
                    checkClipboard()
                }
                .environment(library).environment(StoryModelSettings.shared)
            }
    }
}

/// 粘贴 for a copied share: the system's own paste button, so iOS shows no permission prompt.
/// It takes the link whether the other app put it on the clipboard as text or as a URL
/// (anson 11-18 15:03: a link copied in 网易云 had to be pasted into the search field by hand).
struct ClipboardPasteButton: View {
    let onPaste: @MainActor (String) -> Void
    var body: some View {
        PasteButton(supportedContentTypes: [.utf8PlainText, .plainText, .url]) { providers in
            guard let provider = providers.first else { return }
            if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, !text.isEmpty else { return }
                    Task { @MainActor in onPaste(text) }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in onPaste(url.absoluteString) }
                }
            }
        }
    }
}

/// Back from QQ 音乐 / 网易云 with a link on the clipboard: the offer to look it up comes down
/// from the top, where a newly playing song offers itself, on whichever tab is open. Only
/// the presence of a link is known until 粘贴 is tapped: reading the clipboard without that tap
/// would make iOS ask for permission every time.
struct ClipboardPrompt: View {
    let platform: PlaybackPlatform
    let onPaste: @MainActor (String) -> Void
    var onDismiss: () -> Void
    var body: some View {
        HStack(spacing: 11) {
            PlatformIcon(platform: platform, size: 30).padding(.leading, 4)
            Text("查刚复制的链接").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(ArtworkPalette.tx)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            ClipboardPasteButton(onPaste: onPaste)
                .labelStyle(.titleAndIcon).buttonBorderShape(.capsule).tint(ShopStyle.accent)
                .accessibilityIdentifier("now-domestic-clipboard-paste")
            Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 34, height: 40) }
                .buttonStyle(.plain).foregroundStyle(ArtworkPalette.tx2).accessibilityLabel("不用")
                .accessibilityIdentifier("clipboard-prompt-dismiss")
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
        .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { if $0.translation.height < -24 { onDismiss() } })
        .accessibilityElement(children: .contain).accessibilityIdentifier("clipboard-prompt")
    }
}

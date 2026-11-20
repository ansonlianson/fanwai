import SwiftUI
import UIKit

/// First run (Design/review/ONBOARDING/PLAN.md, 2026-11-18). It happens on the 此刻 ledge with
/// the lamp off: which app the songs come from, then the model that finds the stories. The
/// lamp comes on once the model answers. Shop look throughout: no system sheets, real app icons.
struct OnboardingFlow: View {
    enum Start { case platform, model, code }
    enum Outcome { case connected, trial, later }
    enum Step: Hashable { case model, deepseek, ownKey, check, code }
    var start: Start = .platform
    var onFinish: (Outcome) -> Void
    @State private var path: [Step] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch start {
                case .platform: OnboardingPlatformPage { path.append(.model) }
                case .model: modelPage
                case .code: OnboardingTrialCode { onFinish(.trial) }
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .model: modelPage
                case .deepseek: OnboardingDeepSeekGuide { path.append(.check) }
                case .ownKey: OnboardingOwnKey { path.append(.check) }
                case .check: OnboardingKeyCheck(onDone: { onFinish(.connected) }, onBack: { path.removeLast() })
                case .code: OnboardingTrialCode { onFinish(.trial) }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(ShopStyle.accent)
    }
    private var modelPage: some View {
        OnboardingModelPage(onCode: { path.append(.code) },
                            onDeepSeek: { path.append(.deepseek) },
                            onOwnKey: { path.append(.ownKey) },
                            onLater: { onFinish(.later) })
    }
}

// MARK: - The ledge every step stands on

/// The 此刻 ledge (DomesticCounterView's plate), copy where a song's title sits; `lit` turns the lamp on.
struct OnboardingLedge<Content: View>: View {
    var lit = false
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, k = W / ShopPlates.plateWidth, r = W / 402
            ZStack(alignment: .topLeading) {
                ShopStyle.base
                Self.plate("lp_paused", k: k)
                Self.plate("lp", k: k).opacity(lit ? 1 : 0)
                ScrollView {
                    content
                        .foregroundStyle(ShopStyle.ink)
                        .padding(.horizontal, 26).padding(.top, 333 * r).padding(.bottom, 48)
                        .frame(width: W, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize).scrollIndicators(.hidden)
            }
            .frame(width: W, height: geo.size.height, alignment: .topLeading).clipped()
        }
        .ignoresSafeArea(.container)
        .animation(.easeInOut(duration: 0.9), value: lit)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
    @ViewBuilder static func plate(_ name: String, k: CGFloat) -> some View {
        if let m = ShopPlates.shared.main(name) {
            ZStack(alignment: .topLeading) {
                if let bg = m.bg {
                    ShopLayerImage(image: ShopPlates.shared.image(name, bg), frame: CGRect(x: 0, y: 0, width: m.size[0], height: m.size[1]), k: k)
                }
                if let f = m.front { ShopLayerImage(image: ShopPlates.shared.image(name, f.over), frame: f.frame.rect, k: k) }
            }
        }
    }
}

/// Title and one line under it, as a song's title and identity line sit on 此刻.
struct OnboardingHeading: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 30, weight: .semibold)).tracking(-0.4)
                .accessibilityIdentifier("onboarding-title")
            if let detail {
                Text(detail).font(.system(size: 13.5)).foregroundStyle(ShopStyle.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
        }
    }
}

/// One answer: the real app icon, its name, what it means. The same glass row the old sheet had.
struct OnboardingChoice<Icon: View>: View {
    let title: String
    let detail: String
    let id: String
    let action: () -> Void
    @ViewBuilder var icon: Icon
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(ShopStyle.ink)
                    Text(detail).font(.system(size: 13)).foregroundStyle(ShopStyle.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .accessibilityIdentifier(id)
    }
}

struct AppIconImage: View {
    let name: String
    var size: CGFloat = 40
    var body: some View {
        Image(name).resizable().interpolation(.high).frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// The accent capsule used for the one thing to do next (the same look as the system 粘贴 button).
struct OnboardingPrimary: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large).tint(ShopStyle.accent)
            .foregroundStyle(ShopStyle.base).fontWeight(.semibold)
    }
}
/// A second choice beside it: glass, ink text.
struct OnboardingSecondary: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.plain).font(.system(size: 15, weight: .medium)).foregroundStyle(ShopStyle.ink)
            .frame(minHeight: 50).padding(.horizontal, 20).glassEffect(.regular.interactive(), in: .capsule)
    }
}

// MARK: - ① 用什么听歌

struct OnboardingPlatformPage: View {
    var onNext: () -> Void
    @Environment(Library.self) private var library
    @Environment(\.openURL) private var openURL
    @State private var refused: String?
    var body: some View {
        OnboardingLedge {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeading(title: "用什么听歌？")
                VStack(spacing: 10) {
                    choice(.apple, "自动跟着正在播放的歌")
                    choice(.qq, "复制分享链接，或者搜歌名")
                    choice(.netease, "复制分享链接，或者搜歌名")
                }.padding(.top, 20)
                if let refused {
                    HStack(spacing: 4) {
                        Text(refused + " ·").foregroundStyle(ShopStyle.tertiary)
                        Button("去设置") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                            .buttonStyle(.plain).foregroundStyle(ShopStyle.accent)
                    }.font(.system(size: 13)).padding(.top, 14).accessibilityIdentifier("onboarding-music-refused")
                }
            }
        }
    }
    private func choice(_ platform: PlaybackPlatform, _ detail: String) -> some View {
        OnboardingChoice(title: platform.title, detail: detail, id: "onboarding-platform-" + platform.rawValue) {
            choose(platform)
        } icon: { PlatformIcon(platform: platform, size: 40) }
    }
    /// Apple Music asks for the system permission right away; the other two need nothing.
    private func choose(_ platform: PlaybackPlatform) {
        library.playbackPlatform = platform
        guard platform == .apple, !library.musicConnected else { refused = nil; onNext(); return }
        Task {
            await library.connectMusic()
            if library.musicConnected { refused = nil; onNext() } else { refused = "没拿到 Apple Music 的权限" }
        }
    }
}

// MARK: - ② 接一个大模型

struct OnboardingModelPage: View {
    var onCode: () -> Void
    var onDeepSeek: () -> Void
    var onOwnKey: () -> Void
    var onLater: () -> Void
    @State private var trial = TrialAccess.shared
    var body: some View {
        OnboardingLedge {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeading(title: "接一个大模型", detail: "番外用它上网查歌背后的故事。每查一首约 ¥0.1，从你自己的账户扣。")
                VStack(spacing: 10) {
                    // 体验码: handed out by the developer during the beta. Free lookups without a code wait
                    // for the device check (BETA-TRIAL.md) and are not offered here.
                    if trial.offered && !trial.usable {
                        OnboardingChoice(title: "填体验码", detail: "有码就能免费查，不用注册", id: "onboarding-code", action: onCode) {
                            AppIconImage(name: "AppMark")
                        }
                    }
                    OnboardingChoice(title: "开通 DeepSeek", detail: "没有 API Key，跟着做", id: "onboarding-deepseek", action: onDeepSeek) {
                        AppIconImage(name: "PlatformDeepSeek")
                    }
                    OnboardingChoice(title: "填我的 API Key", detail: "DeepSeek、OpenAI 或其他服务", id: "onboarding-own-key", action: onOwnKey) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.1))
                            .overlay(Image(systemName: "key.horizontal.fill").font(.system(size: 17, weight: .medium)).foregroundStyle(ShopStyle.accent))
                    }
                }.padding(.top, 20)
                Button("以后再说", action: onLater).buttonStyle(.plain)
                    .font(.system(size: 13.5)).foregroundStyle(ShopStyle.secondary).padding(.top, 18)
                    .accessibilityIdentifier("onboarding-later")
            }
        }
    }
}

// MARK: - ②' 填体验码

/// One field. A pasted code goes straight in; a wrong one says which kind of wrong.
struct OnboardingTrialCode: View {
    var onRedeemed: () -> Void
    @State private var trial = TrialAccess.shared
    @State private var code = ""
    @State private var checking = false
    @State private var problem: String?
    @FocusState private var focused: Bool
    private var plausible: Bool { code.filter { $0.isLetter || $0.isNumber }.count >= 8 }
    var body: some View {
        OnboardingLedge {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeading(title: "填体验码")
                HStack(spacing: 10) {
                    TextField("FW-XXXX-XXXX", text: $code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled().focused($focused)
                        .submitLabel(.done).onSubmit { redeem() }
                        .font(.system(size: 17, weight: .medium).monospaced()).padding(.horizontal, 18).frame(height: 50)
                        .glassEffect(.regular, in: .capsule)
                        .accessibilityIdentifier("onboarding-code-field")
                    ClipboardPasteButton { text in code = text.trimmingCharacters(in: .whitespacesAndNewlines); redeem() }
                        .labelStyle(.iconOnly).modifier(OnboardingPrimary())
                        .accessibilityIdentifier("onboarding-code-paste")
                }.padding(.top, 20)
                if let problem {
                    Text(problem).font(.system(size: 13)).foregroundStyle(ShopStyle.accent).padding(.top, 10)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("onboarding-code-problem")
                }
                Button { redeem() } label: {
                    ZStack {
                        Text("确定").opacity(checking ? 0 : 1)
                        if checking { ProgressView().tint(ShopStyle.base) }
                    }.frame(maxWidth: .infinity)
                }
                .modifier(OnboardingPrimary()).disabled(!plausible || checking).padding(.top, 18)
                .accessibilityIdentifier("onboarding-code-confirm")
            }
        }
        .task { await trial.loadConfiguration() }
    }
    private func redeem() {
        guard plausible, !checking else { return }
        checking = true; problem = nil; focused = false
        Task {
            let result = await trial.redeem(code)
            checking = false
            switch result {
            case .ok: onRedeemed()
            case .notFound: problem = "没有这个体验码，看看有没有输错。"
            case .tooManyDevices: problem = "这个体验码用过的设备已经到上限了。"
            case .disabled: problem = "这个体验码已停用。"
            case .tooManyAttempts: problem = "试的次数太多，过一小时再来。"
            case .unreachable: problem = "连不上番外的服务器，检查网络后再试。"
            }
        }
    }
}

// MARK: - ③ 开通 DeepSeek

/// The four things to do, all visible at once: the reader goes back and forth to Safari, and
/// whatever step they are on is still on screen when they return. 粘贴 becomes the main button
/// once the site has been opened.
struct OnboardingDeepSeekGuide: View {
    static let site = URL(string: "https://platform.deepseek.com/")!
    var onPasted: () -> Void
    @Environment(StoryModelSettings.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var visited = ProcessInfo.processInfo.arguments.contains("--ui-guide-visited")
    @State private var rejected = false
    var body: some View {
        OnboardingLedge {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeading(title: "开通 DeepSeek", detail: "在 DeepSeek 开放平台做完前三步，回到这里粘贴。")
                VStack(alignment: .leading, spacing: 16) {
                    step(1, "登录", "用手机号收验证码，新号码会自动注册。")
                    step(2, "实名认证，准备余额", "按开放平台的提示完成实名认证。账户里有一定余额就能用。")
                    step(3, "创建 API Key", "在「API keys」页点「创建 API key」，名字随便填。创建后点「复制」，这串字只显示一次。")
                    step(4, "回来粘贴", nil)
                }.padding(.top, 22)
                if rejected {
                    Text("刚才粘贴的不是 API Key。它以 sk- 开头，是一长串字母和数字。")
                        .font(.system(size: 13)).foregroundStyle(ShopStyle.accent).padding(.top, 14)
                        .accessibilityIdentifier("onboarding-not-a-key")
                }
                HStack(spacing: 10) {
                    if visited {
                        paste.modifier(OnboardingPrimary())
                        Button("再打开") { open() }.modifier(OnboardingSecondary())
                    } else {
                        Button { open() } label: { Label("打开 DeepSeek 开放平台", systemImage: "arrow.up.right").frame(maxWidth: .infinity) }
                            .modifier(OnboardingPrimary()).accessibilityIdentifier("onboarding-open-deepseek")
                        paste.labelStyle(.iconOnly).modifier(OnboardingPrimary())
                    }
                }.padding(.top, 22)
                Text("手机上不好操作，也可以在电脑上打开 platform.deepseek.com，把 Key 发到手机上再粘贴。")
                    .font(.system(size: 12)).foregroundStyle(ShopStyle.tertiary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            }
        }
    }
    private var paste: some View {
        ClipboardPasteButton { text in
            guard let key = OnboardingKeyFormat.key(in: text) else { rejected = true; return }
            rejected = false
            settings.selectProvider("deepseek")
            settings.saveKey(key)
            onPasted()
        }
        .accessibilityIdentifier("onboarding-paste-key")
    }
    private func open() { visited = true; openURL(Self.site) }
    private func step(_ number: Int, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(String(number)).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(ShopStyle.accent)
                .frame(width: 22, height: 22).background(Circle().strokeBorder(ShopStyle.accent.opacity(0.6), lineWidth: 1))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15.5, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 13)).foregroundStyle(ShopStyle.secondary).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What a pasted key must look like before it is saved: one token, no spaces. A share text or a
/// sentence pasted by mistake is turned away here, not by the service a moment later.
enum OnboardingKeyFormat {
    static func key(in text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 20, value.count <= 300, !value.contains(where: { $0.isWhitespace }),
              value.allSatisfy({ $0.isASCII }) else { return nil }
        return value
    }
}

// MARK: - ③' 填我的 API Key

struct OnboardingOwnKey: View {
    var onEntered: () -> Void
    @Environment(StoryModelSettings.self) private var settings
    @State private var provider = ProcessInfo.processInfo.arguments.contains("--ui-own-key-custom") ? "custom" : "deepseek"
    @State private var address = ""
    @State private var key = ""
    @State private var rejected = false
    private var ready: Bool { OnboardingKeyFormat.key(in: key) != nil && (provider != "custom" || URL(string: address)?.scheme == "https") }
    var body: some View {
        OnboardingLedge {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeading(title: "填你的 API Key")
                Picker("服务", selection: $provider) {
                    Text("DeepSeek").tag("deepseek"); Text("OpenAI").tag("openai"); Text("其他").tag("custom")
                }
                .pickerStyle(.segmented).padding(.top, 20).accessibilityIdentifier("onboarding-provider")
                if provider == "custom" {
                    field { TextField("服务地址，https:// 开头", text: $address).keyboardType(.URL) }.padding(.top, 12)
                    Text("要支持 OpenAI Responses 接口和联网搜索。").font(.system(size: 12)).foregroundStyle(ShopStyle.tertiary).padding(.top, 8)
                }
                HStack(spacing: 10) {
                    field { SecureField("API Key", text: $key).accessibilityIdentifier("onboarding-key-field") }
                    ClipboardPasteButton { text in key = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .labelStyle(.iconOnly).modifier(OnboardingPrimary())
                }.padding(.top, 12)
                if rejected {
                    Text("这串不像 API Key：中间不能有空格，至少 20 位。").font(.system(size: 13)).foregroundStyle(ShopStyle.accent).padding(.top, 10)
                }
                Button { connect() } label: { Text("连接").frame(maxWidth: .infinity) }
                    .modifier(OnboardingPrimary()).disabled(!ready).padding(.top, 18)
                    .accessibilityIdentifier("onboarding-connect")
            }
        }
    }
    private func field<F: View>(@ViewBuilder _ content: () -> F) -> some View {
        content().textInputAutocapitalization(.never).autocorrectionDisabled()
            .font(.system(size: 15)).padding(.horizontal, 18).frame(height: 50)
            .glassEffect(.regular, in: .capsule)
    }
    private func connect() {
        guard let value = OnboardingKeyFormat.key(in: key) else { rejected = true; return }
        settings.selectProvider(provider)
        if provider == "custom" { settings.setAddress(address) }
        settings.saveKey(value)
        onEntered()
    }
}

// MARK: - ④ 连好了

/// One real request with the key (the same check as 设置 › 模型 › 测试连接), then DeepSeek's balance.
/// Every failure says which of the four things went wrong and offers the one way to fix it.
struct OnboardingKeyCheck: View {
    var onDone: () -> Void
    var onBack: () -> Void
    @Environment(StoryModelSettings.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var balance: Double?
    @State private var finished = false
    private enum Phase { case checking, ready, empty, refused, noSearch, offline }
    private var state: Phase {
        guard finished else { return .checking }
        if settings.connectionError == .insufficientBalance || balance == 0 { return .empty }
        if settings.connectionError == .invalidKey { return .refused }
        if settings.connectionError != nil { return .offline }
        return settings.probeResult == .available ? .ready : .noSearch
    }
    private var service: String { settings.preset?.name ?? "" }
    var body: some View {
        OnboardingLedge(lit: state == .ready) {
            VStack(alignment: .leading, spacing: 0) {
                switch state {
                case .checking:
                    OnboardingHeading(title: "正在连接", detail: "用这个 Key 让 \(service) 查一次网页。")
                    ProgressView().tint(ShopStyle.secondary).padding(.top, 18)
                case .ready:
                    OnboardingHeading(title: "连好了")
                    summary.padding(.top, 18)
                    Button { onDone() } label: { Text("开始").frame(maxWidth: .infinity) }
                        .modifier(OnboardingPrimary()).padding(.top, 20).accessibilityIdentifier("onboarding-start")
                case .empty:
                    OnboardingHeading(title: "账户里还没有余额", detail: "\(service) 账户里要有一定余额才能查。在开放平台处理好，回来点「重试」。")
                    HStack(spacing: 10) {
                        Button { Task { await check() } } label: { Text("重试").frame(maxWidth: .infinity) }.modifier(OnboardingPrimary())
                        Button("打开开放平台") { openURL(OnboardingDeepSeekGuide.site) }.modifier(OnboardingSecondary())
                    }.padding(.top, 20)
                case .refused:
                    OnboardingHeading(title: "这个 Key 用不了", detail: "可能复制少了几位，或者已经在开放平台删掉了。Key 只显示一次，找不回来就新建一把，复制后再粘贴。")
                    HStack(spacing: 10) {
                        ClipboardPasteButton { text in
                            guard let key = OnboardingKeyFormat.key(in: text) else { return }
                            settings.saveKey(key); Task { await check() }
                        }.modifier(OnboardingPrimary())
                        if settings.preferences.providerID == "deepseek" {
                            Button("打开开放平台") { openURL(OnboardingDeepSeekGuide.site) }.modifier(OnboardingSecondary())
                        }
                    }.padding(.top, 20)
                case .noSearch:
                    OnboardingHeading(title: "连上了，但查不了网页", detail: settings.connectionResult ?? "")
                    Button("换一个服务", action: onBack).modifier(OnboardingSecondary()).padding(.top, 20)
                case .offline:
                    OnboardingHeading(title: "连不上 \(service)", detail: "检查网络后重试。")
                    Button { Task { await check() } } label: { Text("重试").frame(maxWidth: .infinity) }
                        .modifier(OnboardingPrimary()).padding(.top, 20)
                }
            }
        }
        .navigationBarBackButtonHidden(state == .ready || state == .checking)
        .task { await check() }
    }
    private var summary: some View {
        VStack(spacing: 0) {
            row("服务", service)
            Divider().overlay(ShopStyle.line)
            row("模型", settings.model)
            if let balance {
                Divider().overlay(ShopStyle.line)
                row("余额", String(format: "¥%.2f", balance) + (balance >= 1 ? "，约能查 \(Int(balance / 0.1)) 首" : ""))
            }
        }
        .padding(.horizontal, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(ShopStyle.secondary)
            Spacer()
            Text(value).foregroundStyle(ShopStyle.ink).lineLimit(1)
        }
        .font(.system(size: 15)).frame(minHeight: 46)
    }
    private func check() async {
        finished = false; balance = nil
        await settings.testConnection()
        balance = await settings.deepSeekBalance()
        finished = true
    }
}

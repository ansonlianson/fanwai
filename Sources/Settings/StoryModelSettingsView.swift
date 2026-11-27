import SwiftUI

struct StoryModelSettingsView: View {
    @Environment(StoryModelSettings.self) private var settings
    @State private var input = ""
    @State private var priceIn = ""
    @State private var priceOut = ""
    @State private var editingKey = false
    @State private var showingDeepSeekGuide = false
    private var published: ModelPrice? { ModelPrice.published(model: settings.model) }
    private static func plain(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
    private func loadPrice() {
        priceIn = settings.enteredPrice.map { Self.plain($0.input) } ?? ""
        priceOut = settings.enteredPrice.map { Self.plain($0.output) } ?? ""
    }
    private func storePrice() {
        let entered = (Double(priceIn), Double(priceOut))
        if entered.0 != settings.enteredPrice?.input || entered.1 != settings.enteredPrice?.output { settings.setPrice(input: entered.0, output: entered.1) }
    }
    @FocusState private var keyFocused: Bool

    var body: some View {
        Form {
            Section {
                Button("开通 DeepSeek") { commitKey(); keyFocused = false; showingDeepSeekGuide = true }
                    .accessibilityIdentifier("story-model-deepseek-guide")
                Link("DeepSeek 开放平台", destination: OnboardingDeepSeekGuide.site)
                    .accessibilityIdentifier("story-model-deepseek-platform")
            }
            Section {
                Picker("服务商", selection: Binding(get: { settings.preferences.providerID }, set: {
                    commitKey(); settings.selectProvider($0); editingKey = false
                })) {
                    // Only while nothing is chosen: an empty row in the list read as broken (anson 11-18).
                    if settings.preferences.providerID.isEmpty { Text("未选择").tag("") }
                    ForEach(settings.presets) { Text($0.name).tag($0.id) }
                }.accessibilityIdentifier("story-model-provider")
                if settings.preferences.providerID == "custom" {
                    LabeledContent("地址") {
                        TextField("地址", text: Binding(get: { settings.preferences.customAddress }, set: settings.setAddress))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { settings.refreshModels() }
                    }
                }
            } footer: {
                if settings.preferences.providerID == "custom" { Text("需要支持 OpenAI Responses 接口和联网查找的服务。") }
            }
            Section {
                if settings.hasKey && !editingKey {
                    Button { editingKey = true; keyFocused = true } label: {
                        HStack { Text("密钥"); Spacer(); Text(settings.maskedKey).foregroundStyle(.secondary) }
                            .foregroundStyle(.primary)
                    }.accessibilityIdentifier("story-model-masked-key")
                } else {
                    SecureField("密钥", text: $input)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($keyFocused)
                        .submitLabel(.done).onSubmit { commitKey(); keyFocused = false }
                        .accessibilityIdentifier("story-model-key")
                }
            } footer: { Text("按服务商的价格从你的账户计费。") }
            Section {
                if !settings.hasKey {
                    LabeledContent("模型") { Text("填好密钥后获取").foregroundStyle(.secondary) }
                        .accessibilityIdentifier("story-model-model-waiting")
                } else if settings.modelsLoading {
                    LabeledContent("模型") { ProgressView() }
                } else if settings.usesManualModel {
                    LabeledContent("模型") {
                        TextField("模型", text: Binding(get: { settings.model }, set: settings.selectModel))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("story-model-model-input")
                    }
                } else {
                    Picker("模型", selection: Binding(get: { settings.model }, set: settings.selectModel)) {
                        ForEach(settings.availableModels, id: \.self) { Text($0).tag($0) }
                    }.accessibilityIdentifier("story-model-model")
                }
            } footer: {
                if settings.hasKey, !settings.modelsLoading, !settings.hasRemoteModelList { Text("这个服务没有给出模型列表，请填写模型名。") }
            }
            if settings.hasKey, !settings.model.isEmpty {
                Section {
                    LabeledContent("输入") {
                        TextField(published.map { Self.plain($0.input) } ?? "未填", text: $priceIn)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityIdentifier("story-model-price-in")
                    }
                    LabeledContent("输出") {
                        TextField(published.map { Self.plain($0.output) } ?? "未填", text: $priceOut)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).accessibilityIdentifier("story-model-price-out")
                    }
                } header: { Text("单价（元 / 百万 token）") } footer: {
                    Text(settings.enteredPrice == nil && published != nil ? "已按官方白天价估算花费，也可以自己填。"
                         : settings.price == nil ? "填了才能估算花费；不填只记用量。" : "用来估算花费，以服务商账单为准。")
                }
            }
            Section {
                Button("测试连接") {
                    commitKey(); keyFocused = false
                    Task { await settings.testConnection() }
                }.disabled(settings.testing).accessibilityIdentifier("story-model-test")
                if let result = settings.connectionResult { Text(result).accessibilityIdentifier("story-model-result") }
            }
            Section {
                Button("移除密钥", role: .destructive) { input = ""; editingKey = false; settings.removeKey() }
                    .disabled(!settings.hasKey).accessibilityIdentifier("story-model-remove")
            }
        }
        .navigationTitle("模型").navigationBarTitleDisplayMode(.inline)
        .onChange(of: keyFocused) { _, focused in if !focused { commitKey() } }
        .onDisappear { commitKey() }
        .task { settings.refreshModels(); loadPrice() }
        .onChange(of: settings.preferences.providerID + "|" + settings.model) { _, _ in loadPrice() }
        .onChange(of: priceIn) { _, _ in storePrice() }
        .onChange(of: priceOut) { _, _ in storePrice() }
        .scrollDismissesKeyboard(.interactively)
        .fullScreenCover(isPresented: $showingDeepSeekGuide) {
            OnboardingFlow(start: .deepseek) { _ in showingDeepSeekGuide = false }
        }
    }
    private func commitKey() {
        if !input.isEmpty { settings.saveKey(input); input = "" }
        editingKey = false
    }
}

import SwiftUI

/// 设置 › 用量 (anson 2026-11-18): what each lookup cost, and the totals for today and this month.
/// Amounts are estimates from the price of the chosen model; the service's own bill is the truth.
struct UsageView: View {
    @State private var ledger = UsageLedger.shared
    private static let time: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "M-d HH:mm"; return formatter
    }()

    var body: some View {
        let calendar = Calendar.current, now = Date()
        let today = ledger.total(since: calendar.startOfDay(for: now))
        let month = ledger.total(since: calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now)
        Form {
            Section {
                LabeledContent("今天", value: today.text).accessibilityIdentifier("usage-today")
                LabeledContent("本月", value: month.text).accessibilityIdentifier("usage-month")
            } footer: {
                if month.count > 0, month.unpriced == month.count { Text("在「模型」里填上单价，就能估算花费。") }
                else if month.unpriced > 0 { Text("本月有 \(month.unpriced) 次没有单价，只记了用量。金额按单价估算，以服务商账单为准。") }
                else { Text("金额按单价估算，以服务商账单为准。") }
            }
            if !ledger.entries.isEmpty {
                Section("最近") {
                    ForEach(ledger.entries.prefix(100)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title).lineLimit(1)
                                Text([Self.time.string(from: entry.date), entry.kind.label].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(UsageLedger.amount(entry)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle("用量").navigationBarTitleDisplayMode(.inline)
    }
}

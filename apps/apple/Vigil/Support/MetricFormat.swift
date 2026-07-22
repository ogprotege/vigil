import SwiftUI
import VigilKit

/// Scalar metric formatting shared by dashboard surfaces, so every row states
/// amounts identically. Values remain amounts, never invented percentages
/// (see WindowRows.swift).
enum MetricFormat {
    static func value(_ metric: UsageMetric, locale: Locale = .current) -> String {
        if let unit = metric.unit, unit.count == 3 {
            return metric.value.formatted(
                .currency(code: unit)
                    .precision(.fractionLength(0...4))
                    .locale(locale)
            )
        }
        let number = metric.value.formatted(
            .number.precision(.fractionLength(0...4)).locale(locale)
        )
        return metric.unit.map { "\(number) \($0)" } ?? number
    }

    static func symbol(for kind: UsageMetricKind) -> String {
        switch kind {
        case .balance: return "wallet.pass"
        case .spend: return "creditcard"
        case .limit: return "gauge.with.needle"
        case .remaining: return "banknote"
        }
    }

    static func tint(for kind: UsageMetricKind) -> Color {
        switch kind {
        case .remaining, .balance: return .green
        case .spend: return .orange
        case .limit: return .secondary
        }
    }
}

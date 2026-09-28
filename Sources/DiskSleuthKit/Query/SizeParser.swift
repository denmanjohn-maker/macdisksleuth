import Foundation

extension ByteCount {
    /// Parses human sizes: "100MB", "1.5GiB", "4k", "123". Decimal units by
    /// default (matching `format`), binary for the `Ki`/`Mi`/`Gi`… forms.
    /// Case-insensitive; the trailing "B" is optional. Returns nil when invalid.
    public static func parse(_ text: String) -> Int64? {
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        let numberPart = lowered.prefix { $0.isNumber || $0 == "." }
        guard !numberPart.isEmpty, let value = Double(numberPart), value >= 0 else { return nil }

        var unit = lowered.dropFirst(numberPart.count).trimmingCharacters(in: .whitespaces)
        if unit.hasSuffix("b") { unit.removeLast() }
        let binary = unit.hasSuffix("i")
        if binary { unit.removeLast() }

        let exponents: [String: Int] = ["": 0, "k": 1, "m": 2, "g": 3, "t": 4, "p": 5]
        guard let exponent = exponents[unit], !(binary && exponent == 0) else { return nil }

        let bytes = value * pow(binary ? 1024 : 1000, Double(exponent))
        guard bytes.isFinite, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes.rounded())
    }
}

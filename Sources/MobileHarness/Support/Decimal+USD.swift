import Foundation

/// Decimal construction helpers for USD money values received from remote APIs.
///
/// OpenRouter reports per-token prices as decimal *strings* (exact) and
/// per-request costs as binary doubles (approximate). Both are converted to
/// `Decimal` without binary floating-point drift so cost statistics can be
/// summed and displayed exactly.
extension Decimal {
    /// Creates a decimal from a decimal string such as `"0.0000015"`, `"1e-07"`, or `"-2.5E-3"`.
    ///
    /// Falls back to zero for strings that are not decimal numbers.
    init(usdString: String) {
        let lowered = usdString.lowercased()
        if let plain = Decimal(string: lowered) {
            self = plain
        } else if let scientific = Decimal.parsingExponentNotation(lowered) {
            self = scientific
        } else {
            self = 0
        }
    }

    /// Creates a decimal from a double carrying a USD amount.
    ///
    /// The double is round-tripped through its shortest decimal representation
    /// (`String(describing:)`) so values like `0.0012` stay `0.0012` instead of
    /// drifting to `0.0011999999…`.
    init(usdDouble: Double) {
        if usdDouble.isFinite {
            self = Decimal(usdString: String(describing: usdDouble))
        } else {
            self = 0
        }
    }

    /// Parses `mantissa e exponent` notation via `Decimal(sign:exponent:significand:)`,
    /// which `Decimal(string:)` does not reliably accept.
    private static func parsingExponentNotation(_ text: String) -> Decimal? {
        let parts = text.split(separator: "e")
        guard parts.count == 2,
              let significand = Decimal(string: String(parts[0])),
              let exponent = Int(parts[1])
        else { return nil }
        let sign: FloatingPointSign = text.hasPrefix("-") ? .minus : .plus
        return Decimal(sign: sign, exponent: exponent, significand: significand)
    }
}

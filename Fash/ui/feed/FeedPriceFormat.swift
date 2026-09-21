import Foundation

enum FeedPriceFormat {
    /// One formatter per language tag. `NumberFormatter` allocation is expensive (ICU state) and this runs in
    /// every listing card body — twice per card (price row + accessibility label) — so building one per call
    /// dominated cell creation cost during feed scrolling. Formatting on a configured instance is thread-safe.
    private static var formatters: [String: NumberFormatter] = [:]
    private static let formattersLock = NSLock()

    private static func formatter(for tag: String) -> NumberFormatter {
        formattersLock.lock()
        defer { formattersLock.unlock() }
        if let cached = formatters[tag] { return cached }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = AppLocale.locale
        formatter.groupingSeparator = tag == AppLocale.tagEN ? "," : "."
        formatters[tag] = formatter
        return formatter
    }

    static func format(_ price: Int64) -> String {
        let formatter = formatter(for: AppLocale.currentTag)
        let n = formatter.string(from: NSNumber(value: price)) ?? "\(price)"
        return "₫\(n)"
    }
}

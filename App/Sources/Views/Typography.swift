import SwiftUI

/// App-wide scaled type. Every view derives its fonts from this, so the
/// single user-set scale (Settings, or ⌘+ / ⌘−) resizes all text together.
struct Typography {
    var scale: Double

    func size(_ base: CGFloat) -> CGFloat { base * scale }
    func font(_ base: CGFloat) -> Font { .system(size: base * scale) }

    var largeTitle: Font { font(26) }
    var title2: Font { font(17) }
    var title3: Font { font(15) }
    var headline: Font { font(13).weight(.semibold) }
    var body: Font { font(13) }
    var callout: Font { font(12) }
    var subheadline: Font { font(11) }
    var caption: Font { font(10.5) }
    var caption2: Font { font(10) }
}

private struct TypographyKey: EnvironmentKey {
    static let defaultValue = Typography(scale: 1.0)
}

extension EnvironmentValues {
    var typography: Typography {
        get { self[TypographyKey.self] }
        set { self[TypographyKey.self] = newValue }
    }
}

import Foundation

/// Centralized feature flag for controlling whether ads are enabled.
/// Defaults to `false` and can be enabled in a few local-only ways.
public enum AdsFeature {
    /// Returns true if ads should be active in this build/runtime.
    public static var isEnabled: Bool {
        // 1) Compile-time flag (can be set in a local xcconfig): OTHER_SWIFT_FLAGS = -DENABLE_ADS
        #if ENABLE_ADS
        return true
        #else
        // 2) Environment variable at runtime (Scheme -> Arguments): ENABLE_ADS=1
        if ProcessInfo.processInfo.environment["ENABLE_ADS"] == "1" { return true }
        // 3) Local user defaults override (e.g., via launch argument -enable_ads YES)
        if UserDefaults.standard.bool(forKey: "enable_ads") { return true }
        // 4) Private override hook via an optional type you can define locally and keep gitignored
        if let override = AdsLocalOverridesShim.adsEnabledOverride { return override }
        return false
        #endif
    }
}

// MARK: - Private override hook shim

/// Define this in a local, gitignored file as:
///
///     enum AdsLocalOverridesShim {
///         static var adsEnabledOverride: Bool? { true }
///     }
///
/// If not defined, this fallback keeps the symbol available without enabling ads.
public enum AdsLocalOverridesShim {
    public static var adsEnabledOverride: Bool? { nil }
}

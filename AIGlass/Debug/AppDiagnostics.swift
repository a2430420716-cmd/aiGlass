import Foundation

/// Packaging adds AIGLASS_DIAGNOSTICS only to internal testing builds.
nonisolated enum AppDiagnostics {
    #if !AIGLASS_PRODUCTION && (DEBUG || AIGLASS_DIAGNOSTICS)
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif
}

/// Keep existing console calls lazy and silent in production.
nonisolated func print(_ message: @autoclosure () -> String) {
    guard AppDiagnostics.isEnabled else { return }
    Swift.print(message())
}

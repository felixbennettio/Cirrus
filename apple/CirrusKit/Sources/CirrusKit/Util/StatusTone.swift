import Foundation

/// How a status reads at a glance (the colour of its badge).
public enum StatusTone: Sendable {
    case good, warn, bad, neutral

    public static func of(_ status: String?) -> StatusTone {
        let s = (status ?? "").lowercased()
        if goodWords.contains(s) { return .good }
        if warnWords.contains(s) { return .warn }
        if badWords.contains(s) { return .bad }
        return .neutral
    }

    private static let goodWords: Set<String> = [
        "active", "healthy", "success", "enabled", "on", "deployed", "verified", "ready", "connected", "valid",
        "running", "complete", "completed", "ok", "up",
    ]
    private static let warnWords: Set<String> = [
        "pending", "initializing", "pending_validation", "pending_deployment", "pending_issuance", "queued",
        "building", "degraded", "moved", "paused", "inactive", "idle", "waiting", "unverified", "staging",
    ]
    private static let badWords: Set<String> = [
        "failed", "failure", "error", "deleted", "down", "disabled", "off", "expired", "revoked", "unhealthy",
        "blocked", "canceled", "cancelled", "inactive_deleted",
    ]
}

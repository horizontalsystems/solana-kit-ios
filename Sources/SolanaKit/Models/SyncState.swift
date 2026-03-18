/// The sync state of a single subsystem (balance, token accounts, transactions).
///
/// Mirrors EvmKit's `SyncState` exactly, replacing the Kotlin `sealed class` with a Swift enum.
public enum SyncState {
    /// Sync has completed successfully and data is up to date.
    case synced
    /// Sync is in progress. `progress` is `nil` when indeterminate, or 0.0–1.0 otherwise.
    case syncing(progress: Double?)
    /// Sync has failed. `error` describes why.
    case notSynced(error: Error)

    // MARK: - Convenience booleans

    /// `true` when this state is `.synced`.
    public var synced: Bool {
        self == .synced
    }

    /// `true` when this state is `.syncing`.
    public var syncing: Bool {
        if case .syncing = self { return true } else { return false }
    }

    /// `true` when this state is `.notSynced`.
    public var notSynced: Bool {
        if case .notSynced = self { return true } else { return false }
    }
}

// MARK: - Equatable

extension SyncState: Equatable {
    public static func == (lhs: SyncState, rhs: SyncState) -> Bool {
        switch (lhs, rhs) {
        case (.synced, .synced):
            return true
        case let (.syncing(lhsProgress), .syncing(rhsProgress)):
            return lhsProgress == rhsProgress
        case let (.notSynced(lhsError), .notSynced(rhsError)):
            // Error is not Equatable; compare via string description
            return "\(lhsError)" == "\(rhsError)"
        default:
            return false
        }
    }
}

// MARK: - CustomStringConvertible

extension SyncState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .synced:
            return "synced"
        case let .syncing(progress):
            return "syncing \(progress.map { String($0) } ?? "?")"
        case let .notSynced(error):
            return "not synced: \(error)"
        }
    }
}

// MARK: - SyncError

/// Well-known errors that can appear in `.notSynced(error:)`.
///
/// Mirrors the Android `SolanaKit.SyncError` sealed class hierarchy.
public enum SyncError: Error {
    /// Sync has not been started yet (e.g., `kit.start()` was never called).
    case notStarted
    /// The device has no network connection.
    case noNetworkConnection
}

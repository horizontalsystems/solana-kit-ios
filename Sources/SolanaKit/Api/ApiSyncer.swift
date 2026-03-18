import Combine
import Foundation
import HsExtensions
import UIKit

/// Timer-based block height polling loop that drives all downstream sync subsystems.
///
/// `ApiSyncer` polls `getBlockHeight` via `IRpcApiProvider` on a configurable interval
/// (from `RpcSource.syncInterval`), reacts to network reachability changes via
/// `IConnectionManager`, and notifies its delegate on every tick.
///
/// Follows the EvmKit `ApiRpcSyncer` pattern, adapted for Solana-specific RPC
/// and Android `ApiSyncer.kt` behaviour (including `pause()`/`resume()` support).
class ApiSyncer {

    // MARK: - Delegate

    weak var delegate: IApiSyncerDelegate?

    // MARK: - Dependencies

    private let rpcApiProvider: IRpcApiProvider
    private let connectionManager: IConnectionManager
    private let storage: IMainStorage
    private let syncInterval: TimeInterval

    // MARK: - State

    /// Current readiness state of the poller. Fires delegate only on distinct transitions.
    private(set) var state: SyncerState = .notReady(error: SyncError.notStarted) {
        didSet {
            if state != oldValue {
                delegate?.didUpdateSyncerState(state)
            }
        }
    }

    /// Last known block height (slot), pre-populated from storage at init time.
    private(set) var lastBlockHeight: Int64?

    // MARK: - Private state

    private var isStarted: Bool = false
    private var isPaused: Bool = false
    private var timer: Timer?
    private var tasks = Set<AnyTask>()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed

    var source: String {
        "API \(rpcApiProvider.source)"
    }

    // MARK: - Init

    init(
        rpcApiProvider: IRpcApiProvider,
        connectionManager: IConnectionManager,
        storage: IMainStorage,
        syncInterval: TimeInterval
    ) {
        self.rpcApiProvider = rpcApiProvider
        self.connectionManager = connectionManager
        self.storage = storage
        self.syncInterval = syncInterval

        // Pre-populate from persisted value so callers see the last known height
        // before the first RPC response arrives (mirrors Android ApiSyncer line 60).
        lastBlockHeight = storage.lastBlockHeight()

        // React to reachability changes (mirrors EvmKit ApiRpcSyncer lines 33-37).
        connectionManager.isConnectedPublisher
            .sink { [weak self] connected in
                self?.handleUpdate(reachable: connected)
            }
            .store(in: &cancellables)

        // Pause the timer when entering background; resume on foreground.
        // Mirrors EvmKit ApiRpcSyncer lines 39-40.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    deinit {
        stop()
    }

    // MARK: - Notification handlers

    @objc private func onEnterBackground() {
        stopTimer()
    }

    @objc private func onEnterForeground() {
        guard isStarted, !isPaused else { return }
        startTimer()
    }

    // MARK: - Private timer helpers

    private func startTimer() {
        stopTimer()

        // Schedule on main RunLoop — matches EvmKit ApiRpcSyncer lines 66-75.
        DispatchQueue.main.async { [weak self, syncInterval] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
                self?.onFireTimer()
            }
            self?.timer?.tolerance = 0.5

            // Fire immediately so the first sync doesn't wait for the full interval.
            // Mirrors Android ApiSyncer's `emit(Unit)` before the delay loop (lines 131-132).
            self?.onFireTimer()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func onFireTimer() {
        Task { [weak self, rpcApiProvider] in
            do {
                let blockHeight = try await rpcApiProvider.getBlockHeight()
                self?.handleBlockHeight(blockHeight)
            } catch {
                guard !(error is CancellationError) else { return }
                self?.state = .notReady(error: error)
            }
        }.store(in: &tasks)
    }

    // MARK: - Private logic

    private func handleBlockHeight(_ blockHeight: Int64) {
        // Persist only when the value changes (Android lines 104-108).
        if lastBlockHeight != blockHeight {
            lastBlockHeight = blockHeight
            try? storage.save(lastBlockHeight: blockHeight)
        }
        // Always notify the delegate — this heartbeat drives downstream syncs.
        delegate?.didUpdateLastBlockHeight(blockHeight)
    }

    private func handleUpdate(reachable: Bool) {
        guard isStarted else { return }

        if reachable {
            state = .ready
            // Respect pause state — don't restart the timer if paused (Android line 118).
            if !isPaused {
                startTimer()
            }
        } else {
            state = .notReady(error: SyncError.noNetworkConnection)
            stopTimer()
        }
    }

    // MARK: - Lifecycle

    func start() {
        isStarted = true
        // Kick off based on current reachability (Android lines 63-68, EvmKit lines 97-100).
        handleUpdate(reachable: connectionManager.isConnected)
    }

    func stop() {
        isStarted = false
        isPaused = false
        tasks = Set()
        state = .notReady(error: SyncError.notStarted)
        stopTimer()
    }

    /// Temporarily suspends polling without resetting `isStarted`.
    /// Mirrors Android `ApiSyncer.pause()` (lines 83-86).
    func pause() {
        isPaused = true
        stopTimer()
    }

    /// Resumes polling after a `pause()` call.
    /// Mirrors Android `ApiSyncer.resume()` (lines 87-91).
    func resume() {
        isPaused = false
        if isStarted && connectionManager.isConnected {
            startTimer()
        }
    }
}

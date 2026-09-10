import Foundation

/// Conservative per-stage budgets. QoS is a scheduling hint, not CPU affinity.
struct ScanResourcePolicy: Equatable, Sendable {
    let workers: Int

    init(cores: Int, lowPower: Bool, thermalState: ProcessInfo.ThermalState) {
        // A bounded two-worker default also avoids assuming every volume is an NVMe SSD.
        workers = cores <= 2 || lowPower || thermalState != .nominal ? 1 : 2
    }

    var backendLimits: (traversal: Int, classification: Int, atomic: Int) {
        // Classification is per directory; keep it serial to avoid multiplying the budget.
        (traversal: workers, classification: 1, atomic: workers)
    }

    static var current: Self {
        let info = ProcessInfo.processInfo
        return Self(cores: info.activeProcessorCount, lowPower: info.isLowPowerModeEnabled,
                    thermalState: info.thermalState)
    }
}

/// The legacy scanner shares one queue across all stages and monitor instances.
/// Changes throttle admission; already running synchronous filesystem calls must finish.
final class ScanOperationScheduler: @unchecked Sendable {
    static let shared = ScanOperationScheduler()
    let queue = OperationQueue()
    private var observers: [NSObjectProtocol] = []

    private init() {
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = ScanResourcePolicy.current.workers
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.maxConcurrentOperationCount = ScanResourcePolicy.current.workers
            })
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

/// Keep result storage synchronized without capturing a mutable array in @Sendable closures.
final class ScanResults<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Element] = []

    func append(_ value: Element) { append(contentsOf: [value]) }

    func append(contentsOf additions: [Element]) {
        lock.lock()
        defer { lock.unlock() }
        values.append(contentsOf: additions)
    }

    func snapshot() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

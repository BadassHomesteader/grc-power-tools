import Cocoa

/// Countdown and stopwatch for the notch.
///
/// The clock lives HERE, not in the module view: the notch builds a module's
/// view when it opens and destroys it when it folds, so a timer kept on the
/// view would die the moment you looked away from it. This is the one piece of
/// notch state that has to outlive its panel.
@MainActor final class TimerCenter {
    static let shared = TimerCenter()

    enum Mode { case idle, running, paused, stopwatch }

    private(set) var mode: Mode = .idle
    /// Countdown: when it fires. Stopwatch: when it started.
    private(set) var mark = Date()
    private(set) var total: TimeInterval = 0
    private var pausedRemaining: TimeInterval = 0
    private var ticker: Timer?

    /// Fired once when a countdown reaches zero.
    var onFinish: ((TimeInterval) -> Void)?
    /// Anything drawing the timer asks to be nudged.
    var onTick: (() -> Void)?

    private init() {}

    var remaining: TimeInterval {
        switch mode {
        case .running: return max(0, mark.timeIntervalSinceNow)
        case .paused: return pausedRemaining
        default: return 0
        }
    }
    var elapsed: TimeInterval { mode == .stopwatch ? max(0, -mark.timeIntervalSinceNow) : 0 }
    var isActive: Bool { mode == .running || mode == .paused || mode == .stopwatch }

    func start(minutes: Double) {
        total = minutes * 60
        mark = Date().addingTimeInterval(total)
        mode = .running
        run()
    }

    func startStopwatch() {
        mark = Date()
        total = 0
        mode = .stopwatch
        run()
    }

    func pause() {
        guard mode == .running else { return }
        pausedRemaining = remaining
        mode = .paused
        ticker?.invalidate()
        ticker = nil
        onTick?()
    }

    func resume() {
        guard mode == .paused else { return }
        mark = Date().addingTimeInterval(pausedRemaining)
        mode = .running
        run()
    }

    func reset() {
        ticker?.invalidate()
        ticker = nil
        mode = .idle
        total = 0
        pausedRemaining = 0
        onTick?()
    }

    private func run() {
        ticker?.invalidate()
        // 0.5s so the seconds never appear to skip one.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.mode == .running, self.remaining <= 0 {
                    let ran = self.total
                    self.reset()
                    self.onFinish?(ran)
                    return
                }
                self.onTick?()
            }
        }
        onTick?()
    }

    /// mm:ss, or h:mm:ss once it has earned the hour.
    static func clock(_ t: TimeInterval) -> String {
        let n = Int(t.rounded())
        let h = n / 3600, m = (n % 3600) / 60, s = n % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

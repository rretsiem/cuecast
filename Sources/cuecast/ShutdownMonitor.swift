import Dispatch
import Darwin
import Foundation

final class ShutdownMonitor {
    private let signals: [Int32]
    private let queue = DispatchQueue(label: "cuecast.shutdown-monitor")
    private let onFirstSignal: @Sendable (Int32) -> Void
    private let onSecondSignal: @Sendable (Int32) -> Void
    private var dispatchSources: [DispatchSourceSignal] = []
    private var didRequestShutdown = false

    init(
        signals: [Int32] = [SIGINT, SIGTERM],
        onFirstSignal: @escaping @Sendable (Int32) -> Void,
        onSecondSignal: @escaping @Sendable (Int32) -> Void
    ) {
        self.signals = signals
        self.onFirstSignal = onFirstSignal
        self.onSecondSignal = onSecondSignal
    }

    func start() {
        guard dispatchSources.isEmpty else {
            return
        }

        for signalNumber in signals {
            signal(signalNumber, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in
                self?.handleSignal(signalNumber)
            }
            source.resume()
            dispatchSources.append(source)
        }
    }

    func stop() {
        dispatchSources.removeAll()
    }

    private func handleSignal(_ signalNumber: Int32) {
        if didRequestShutdown {
            onSecondSignal(signalNumber)
            return
        }

        didRequestShutdown = true
        onFirstSignal(signalNumber)
    }
}

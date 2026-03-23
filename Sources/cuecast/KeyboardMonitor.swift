import Darwin
import Dispatch
import Foundation

final class KeyboardMonitor {
    private let onKey: @Sendable (UInt8) -> Void
    private let queue = DispatchQueue(label: "cuecast.keyboard-monitor")
    private var originalTermios = termios()
    private var didCaptureTermios = false
    private var readSource: DispatchSourceRead?
    private var isStarted = false

    init(onKey: @escaping @Sendable (UInt8) -> Void) {
        self.onKey = onKey
    }

    var isAvailable: Bool {
        isatty(STDIN_FILENO) != 0
    }

    func start() {
        guard !isStarted, isAvailable else {
            return
        }

        guard tcgetattr(STDIN_FILENO, &originalTermios) == 0 else {
            return
        }
        didCaptureTermios = true

        var raw = originalTermios
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        raw.c_cc.16 = 1
        raw.c_cc.17 = 0
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)

        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainInput()
        }
        source.setCancelHandler { [weak self] in
            self?.restoreTerminal()
        }
        source.resume()

        readSource = source
        isStarted = true
    }

    func stop() {
        guard isStarted else {
            return
        }

        readSource?.cancel()
        readSource = nil
        restoreTerminal()
        isStarted = false
    }

    private func drainInput() {
        var buffer = [UInt8](repeating: 0, count: 32)

        while true {
            let bytesRead = read(STDIN_FILENO, &buffer, buffer.count)
            if bytesRead <= 0 {
                break
            }

            for byte in buffer.prefix(bytesRead) {
                onKey(byte)
            }

            if bytesRead < buffer.count {
                break
            }
        }
    }

    private func restoreTerminal() {
        guard didCaptureTermios else {
            return
        }

        var original = originalTermios
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        didCaptureTermios = false
    }
}

import Foundation

final class Logger {
    let isQuiet: Bool
    private var terminalUI: TerminalUI?

    init(isQuiet: Bool) {
        self.isQuiet = isQuiet
    }

    func attach(terminalUI: TerminalUI) {
        self.terminalUI = terminalUI
    }

    func info(_ message: String) {
        guard !isQuiet else {
            return
        }
        if let terminalUI {
            terminalUI.log(message)
            return
        }
        fputs("[cuecast] \(message)\n", stderr)
    }
}

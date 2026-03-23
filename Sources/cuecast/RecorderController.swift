import Foundation

final class RecorderController: @unchecked Sendable {
    private let terminalUI: TerminalUI

    init(terminalUI: TerminalUI) {
        self.terminalUI = terminalUI
    }

    func beginShutdown(reason: String) {
        terminalUI.setStatus(reason)
    }

    func toggleDisplayMode() {
        terminalUI.toggleDisplayMode()
    }

    func toggleHotkeys() {
        terminalUI.toggleHotkeys()
    }
}

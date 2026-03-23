import Foundation

final class TaskBox: @unchecked Sendable {
    var task: Task<Void, Error>?
}

final class RecorderControlBox: @unchecked Sendable {
    var quitHandler: (@Sendable () -> Void)?
    var toggleDisplayMode: (@Sendable () -> Void)?
    var toggleHotkeys: (@Sendable () -> Void)?
}

@main
struct cuecast {
    static func main() async {
        do {
            let command = try CLI.parse(arguments: Array(CommandLine.arguments.dropFirst()))
            switch command {
            case .help:
                print(CLI.helpText)
            case .record(let options):
                let taskBox = TaskBox()
                let controlBox = RecorderControlBox()
                let shutdownMonitor = ShutdownMonitor(
                    onFirstSignal: { signal in
                        fputs("\n[cuecast] received \(Self.signalName(signal)), shutting down...\n", stderr)
                        controlBox.quitHandler?()
                        taskBox.task?.cancel()
                    },
                    onSecondSignal: { signal in
                        fputs("\n[cuecast] force exiting after repeated \(Self.signalName(signal))\n", stderr)
                        _exit(EXIT_FAILURE)
                    }
                )

                shutdownMonitor.start()
                defer {
                    shutdownMonitor.stop()
                }

                let keyboardMonitor = KeyboardMonitor { byte in
                    switch byte {
                    case UInt8(ascii: "q"), UInt8(ascii: "Q"):
                        fputs("\n[cuecast] hotkey Q pressed, shutting down...\n", stderr)
                        controlBox.quitHandler?()
                        taskBox.task?.cancel()
                    case UInt8(ascii: "c"), UInt8(ascii: "C"):
                        controlBox.toggleDisplayMode?()
                    case UInt8(ascii: "?"), UInt8(ascii: "h"), UInt8(ascii: "H"):
                        controlBox.toggleHotkeys?()
                    default:
                        break
                    }
                }
                keyboardMonitor.start()
                defer {
                    keyboardMonitor.stop()
                }

                let recorderTask = Task {
                    let recorder = StreamRecorder(logger: Logger(isQuiet: options.isQuiet))
                    let controls = recorder.controls
                    controlBox.quitHandler = {
                        controls.beginShutdown(reason: "Shutting down")
                    }
                    controlBox.toggleDisplayMode = {
                        controls.toggleDisplayMode()
                    }
                    controlBox.toggleHotkeys = {
                        controls.toggleHotkeys()
                    }
                    try await recorder.record(options)
                }
                taskBox.task = recorderTask

                switch await recorderTask.result {
                case .success:
                    break
                case .failure(let error):
                    if error is CancellationError || error.localizedDescription == "cancelled" {
                        return
                    }
                    fputs("error: \(error.localizedDescription)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            case .retag(let options):
                var retagger = Retagger(logger: Logger(isQuiet: options.isQuiet))
                try await retagger.retag(options)
            }
        } catch let error as CLIError {
            if case .helpRequested = error {
                print(CLI.helpText)
                return
            }

            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        } catch is CancellationError {
            return
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGINT:
            return "SIGINT"
        case SIGTERM:
            return "SIGTERM"
        default:
            return "signal \(signal)"
        }
    }
}

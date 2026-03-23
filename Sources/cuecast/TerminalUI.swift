import Darwin
import Foundation

final class TerminalUI: @unchecked Sendable {
    enum DisplayMode: String {
        case detail
        case compact

        mutating func toggle() {
            self = self == .detail ? .compact : .detail
        }
    }

    private struct Palette {
        let border: String
        let header: String
        let label: String
        let primary: String
        let secondary: String
        let accent: String
        let success: String
        let warning: String
        let subtle: String
        let reset: String
        let bold: String
        let dim: String
    }

    private struct State {
        let launchedAt = Date()
        var stationName: String?
        var streamURL: String?
        var codecLabel: String = "Unknown"
        var bitrateKbps: Int?
        var sampleRateHz: Int?
        var contentType: String?
        var availableDiskBytes: Int64?
        var diskWarningThresholdBytes: Int64?
        var diskStopThresholdBytes: Int64?
        var totalAudioBytes: Int64 = 0
        var currentTitle: String?
        var currentMetadata: String?
        var currentFileName: String?
        var currentTitleStartedAt: Date?
        var splitCount = 0
        var lastLog = "Starting..."
        var displayMode: DisplayMode = .detail
        var showHotkeys = true
        var statusText = "Recording"
    }

    private let queue = DispatchQueue(label: "cuecast.terminal-ui")
    private let isEnabled: Bool
    private let palette: Palette
    private var state = State()
    private var timer: DispatchSourceTimer?

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled && isatty(STDERR_FILENO) != 0
        self.palette = Self.makePalette(isEnabled: self.isEnabled)
    }

    func attach(to logger: Logger) {
        guard isEnabled else {
            return
        }
        logger.attach(terminalUI: self)
    }

    func start() {
        guard isEnabled else {
            return
        }

        write("\u{001B}[?25l")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.render()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        guard isEnabled else {
            return
        }

        queue.sync {
            render()
            write("\u{001B}[0m\n\u{001B}[?25h")
            timer?.cancel()
            timer = nil
        }
    }

    func log(_ message: String) {
        guard isEnabled else {
            return
        }

        queue.async {
            self.state.lastLog = message
            self.render()
        }
    }

    func connected(to url: URL, descriptor: StreamDescriptor) {
        guard isEnabled else {
            return
        }

        queue.async {
            self.state.streamURL = url.absoluteString
            self.state.stationName = descriptor.stationName
            self.state.codecLabel = descriptor.codecLabel
            self.state.bitrateKbps = descriptor.bitrateKbps
            self.state.sampleRateHz = descriptor.sampleRateHz
            self.state.contentType = descriptor.contentType
            self.render()
        }
    }

    func noteAudioBytes(_ count: Int) {
        guard isEnabled else {
            return
        }

        queue.async {
            self.state.totalAudioBytes += Int64(count)
        }
    }

    func noteDiskSpace(_ snapshot: DiskSpaceSnapshot) {
        guard isEnabled else {
            return
        }

        queue.async {
            self.state.availableDiskBytes = snapshot.availableBytes
            self.state.diskWarningThresholdBytes = snapshot.warningThresholdBytes
            self.state.diskStopThresholdBytes = snapshot.stopThresholdBytes
            self.render()
        }
    }

    func noteMetadata(_ metadata: StreamMetadata) {
        guard isEnabled else {
            return
        }

        queue.async {
            self.state.currentMetadata = metadata.displaySummary
            if let streamTitle = metadata.streamTitle, !streamTitle.isEmpty {
                self.state.currentTitle = streamTitle
            }
            self.render()
        }
    }

    func noteFileChange(_ snapshot: RecordingFileSnapshot) {
        guard isEnabled else {
            return
        }

        queue.async {
            self.state.currentFileName = snapshot.fileURL.lastPathComponent
            self.state.currentTitle = snapshot.title ?? self.state.currentTitle
            self.state.currentTitleStartedAt = snapshot.startedAt
            self.state.splitCount = snapshot.splitCount
            self.render()
        }
    }

    func toggleDisplayMode() {
        guard isEnabled else {
            return
        }

        queue.async {
            self.state.displayMode.toggle()
            self.state.lastLog = "Switched to \(self.state.displayMode.rawValue) mode"
            self.render()
        }
    }

    func toggleHotkeys() {
        guard isEnabled else {
            return
        }

        queue.async {
            self.state.showHotkeys.toggle()
            self.state.lastLog = self.state.showHotkeys ? "Hotkeys shown" : "Hotkeys hidden"
            self.render()
        }
    }

    func setStatus(_ status: String) {
        guard isEnabled else {
            return
        }

        queue.async {
            self.state.statusText = status
            self.render()
        }
    }

    private func render() {
        guard isEnabled else {
            return
        }

        let snapshot = state
        let width = max(72, terminalWidth())
        let innerWidth = width - 4
        let totalRuntime = Date().timeIntervalSince(snapshot.launchedAt)
        let segmentRuntime = snapshot.currentTitleStartedAt.map { Date().timeIntervalSince($0) } ?? totalRuntime
        let segmentScale = Self.segmentScale(for: segmentRuntime)
        let progressBar = styledProgressBar(
            width: max(20, min(48, innerWidth - 12)),
            elapsed: segmentRuntime,
            scale: segmentScale
        )

        var lines: [String] = []
        lines.append(border(width))
        lines.append(row(styledTitle("STREAMER  " + styledStatus(snapshot.statusText)), width: width))
        lines.append(border(width))
        lines.append(infoRow(label: "Station", value: snapshot.stationName ?? "Unknown", width: width, valueStyle: palette.primary))

        let bitrateText = snapshot.bitrateKbps.map { "\($0) kbps" } ?? "unknown bitrate"
        let sampleRateText = snapshot.sampleRateHz.map(Self.formatSampleRate)
        let formatLine = [snapshot.codecLabel, bitrateText, sampleRateText].compactMap { $0 }.joined(separator: " | ")
        lines.append(infoRow(label: "Mode", value: snapshot.displayMode.rawValue, width: width, valueStyle: palette.accent))
        lines.append(
            infoRow(
                label: "Title",
                value: snapshot.currentTitle ?? "Waiting for metadata",
                width: width,
                valueStyle: snapshot.currentTitle == nil ? palette.warning : palette.success
            )
        )

        let startedAtText = snapshot.currentTitleStartedAt.map(Self.clockTime) ?? "--:--:--"

        if snapshot.displayMode == .detail {
            lines.append(infoRow(label: "Format", value: formatLine, width: width, valueStyle: palette.accent))
            lines.append(
                infoRow(
                    label: "Runtime",
                    value: "\(Self.formatClock(totalRuntime)) total | \(snapshot.splitCount) split(s) | \(Self.formatBytes(snapshot.totalAudioBytes))",
                    width: width,
                    valueStyle: palette.secondary
                )
            )
            if let diskLine = diskLine(snapshot: snapshot, includeThresholds: true) {
                lines.append(infoRow(label: "Disk", value: diskLine.value, width: width, valueStyle: diskLine.style))
            }
        } else {
            lines.append(
                infoRow(
                    label: "Runtime",
                    value: "\(Self.formatClock(totalRuntime)) total | \(Self.formatClock(segmentRuntime)) segment",
                    width: width,
                    valueStyle: palette.secondary
                )
            )
            if let diskLine = diskLine(snapshot: snapshot, includeThresholds: false) {
                lines.append(infoRow(label: "Disk", value: diskLine.value, width: width, valueStyle: diskLine.style))
            }
        }

        lines.append(
            infoRow(
                label: "Started",
                value: "\(startedAtText) | segment elapsed \(Self.formatClock(segmentRuntime))",
                width: width,
                valueStyle: palette.secondary
            )
        )
        lines.append(
            infoRow(
                label: "File",
                value: snapshot.currentFileName ?? "Pending...",
                width: width,
                valueStyle: palette.primary
            )
        )
        lines.append(infoRow(label: "Progress", value: progressBar, width: width, valueStyle: nil))

        if snapshot.displayMode == .detail {
            lines.append(
                infoRow(
                    label: "Scale",
                    value: "Dashboard scale \(Self.formatClock(segmentScale)) (display only, no auto-cut)",
                    width: width,
                    valueStyle: palette.subtle
                )
            )

            if let metadata = snapshot.currentMetadata {
                lines.append(infoRow(label: "Meta", value: metadata, width: width, valueStyle: palette.subtle))
            }

            if let streamURL = snapshot.streamURL {
                lines.append(infoRow(label: "Stream", value: streamURL, width: width, valueStyle: palette.dim))
            }
        }

        lines.append(border(width))
        lines.append(infoRow(label: "Last", value: snapshot.lastLog, width: width, valueStyle: palette.warning))
        if snapshot.showHotkeys {
            lines.append(
                infoRow(
                    label: "Keys",
                    value: "[Q] Quit  [C] Compact/Detail  [?] Toggle help",
                    width: width,
                    valueStyle: palette.secondary
                )
            )
        }
        lines.append(border(width))

        write("\u{001B}[2J\u{001B}[H" + lines.joined(separator: "\n"))
    }

    private func terminalWidth() -> Int {
        var window = winsize()
        if ioctl(STDERR_FILENO, TIOCGWINSZ, &window) == 0, window.ws_col > 0 {
            return Int(window.ws_col)
        }
        return 100
    }

    private func border(_ width: Int) -> String {
        palette.border + "+" + String(repeating: "-", count: width - 2) + "+" + palette.reset
    }

    private func row(_ value: String, width: Int) -> String {
        let clamped = Self.clampStyled(value, to: width - 4)
        let visibleLength = Self.visibleLength(of: clamped)
        let padding = max(0, width - 4 - visibleLength)
        return palette.border + "| " + palette.reset + clamped + String(repeating: " ", count: padding) + palette.border + " |" + palette.reset
    }

    private func write(_ string: String) {
        guard let data = string.data(using: .utf8) else {
            return
        }
        try? FileHandle.standardError.write(contentsOf: data)
    }

    private func infoRow(label: String, value: String, width: Int, valueStyle: String?) -> String {
        let plain = "\(label): \(value)"
        let clampedPlain = Self.clampPlain(plain, to: width - 4)
        let separatorIndex = clampedPlain.firstIndex(of: ":") ?? clampedPlain.endIndex
        let labelPart = String(clampedPlain[..<separatorIndex])
        let remainderPart = separatorIndex == clampedPlain.endIndex ? "" : String(clampedPlain[separatorIndex...])

        let styledLabel = palette.bold + palette.label + labelPart + palette.reset
        let styledValue = (valueStyle ?? "") + remainderPart + palette.reset
        return row(styledLabel + styledValue, width: width)
    }

    private func styledTitle(_ value: String) -> String {
        palette.bold + palette.header + value + palette.reset
    }

    private func styledStatus(_ value: String) -> String {
        let lowercased = value.lowercased()
        let color = lowercased.contains("shutting") || lowercased.contains("disk")
            ? palette.warning
            : palette.success
        return color + "[" + value.uppercased() + "]" + palette.reset
    }

    private func diskLine(snapshot: State, includeThresholds: Bool) -> (value: String, style: String)? {
        guard let availableDiskBytes = snapshot.availableDiskBytes else {
            return nil
        }

        let style: String
        if let stopThreshold = snapshot.diskStopThresholdBytes, availableDiskBytes <= stopThreshold {
            style = palette.warning
        } else if let warningThreshold = snapshot.diskWarningThresholdBytes, availableDiskBytes <= warningThreshold {
            style = palette.warning
        } else {
            style = palette.secondary
        }

        var value = "\(Self.formatBytes(availableDiskBytes)) free"
        if includeThresholds {
            if let warningThreshold = snapshot.diskWarningThresholdBytes, let stopThreshold = snapshot.diskStopThresholdBytes {
                value += " | warn \(Self.formatBytes(warningThreshold)) | stop \(Self.formatBytes(stopThreshold))"
            }
        }

        return (value, style)
    }

    private func styledProgressBar(width: Int, elapsed: TimeInterval, scale: TimeInterval) -> String {
        let ratio = min(1.0, max(0.0, elapsed / max(scale, 1)))
        let filled = Int((Double(width) * ratio).rounded(.down))
        let fillColor = ratio < 0.5 ? palette.success : (ratio < 0.85 ? palette.accent : palette.warning)
        let filledBar = fillColor + String(repeating: "#", count: filled) + palette.reset
        let emptyBar = palette.subtle + String(repeating: "-", count: max(0, width - filled)) + palette.reset
        let timing = palette.secondary + " " + Self.formatClock(elapsed) + " / " + Self.formatClock(scale) + palette.reset
        return "[" + filledBar + emptyBar + "]" + timing
    }

    private static func clampStyled(_ value: String, to width: Int) -> String {
        let plain = stripANSI(from: value)
        guard plain.count > width else {
            return value
        }
        return clampPlain(plain, to: width)
    }

    private static func clampPlain(_ value: String, to width: Int) -> String {
        guard value.count > width else {
            return value
        }
        let endIndex = value.index(value.startIndex, offsetBy: max(0, width - 1))
        return String(value[..<endIndex]) + "..."
    }

    private static func visibleLength(of value: String) -> Int {
        stripANSI(from: value).count
    }

    private static func stripANSI(from value: String) -> String {
        let pattern = #"\u001B\[[0-9;]*m"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: "")
    }

    private static func formatClock(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func formatSampleRate(_ sampleRateHz: Int) -> String {
        String(format: "%.1f kHz", Double(sampleRateHz) / 1000.0)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    private static func segmentScale(for runtime: TimeInterval) -> TimeInterval {
        let candidates: [TimeInterval] = [
            15 * 60, 30 * 60, 45 * 60, 60 * 60,
            90 * 60, 120 * 60, 180 * 60, 240 * 60
        ]

        for candidate in candidates where runtime <= candidate {
            return candidate
        }

        let hour = 60.0 * 60.0
        return ceil(runtime / hour) * hour
    }

    private static func makePalette(isEnabled: Bool) -> Palette {
        guard isEnabled else {
            return Palette(
                border: "",
                header: "",
                label: "",
                primary: "",
                secondary: "",
                accent: "",
                success: "",
                warning: "",
                subtle: "",
                reset: "",
                bold: "",
                dim: ""
            )
        }

        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil {
            return makePalette(isEnabled: false)
        }

        if supportsTrueColor() {
            return Palette(
                border: "\u{001B}[38;2;78;98;121m",
                header: "\u{001B}[38;2;123;211;255m",
                label: "\u{001B}[38;2;255;214;102m",
                primary: "\u{001B}[38;2;238;241;245m",
                secondary: "\u{001B}[38;2;165;180;196m",
                accent: "\u{001B}[38;2;147;197;253m",
                success: "\u{001B}[38;2;134;239;172m",
                warning: "\u{001B}[38;2;251;191;36m",
                subtle: "\u{001B}[38;2;148;163;184m",
                reset: "\u{001B}[0m",
                bold: "\u{001B}[1m",
                dim: "\u{001B}[2m"
            )
        }

        return Palette(
            border: "\u{001B}[38;5;60m",
            header: "\u{001B}[38;5;81m",
            label: "\u{001B}[38;5;221m",
            primary: "\u{001B}[38;5;255m",
            secondary: "\u{001B}[38;5;250m",
            accent: "\u{001B}[38;5;117m",
            success: "\u{001B}[38;5;114m",
            warning: "\u{001B}[38;5;220m",
            subtle: "\u{001B}[38;5;246m",
            reset: "\u{001B}[0m",
            bold: "\u{001B}[1m",
            dim: "\u{001B}[2m"
        )
    }

    private static func supportsTrueColor() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let colorTerm = environment["COLORTERM"]?.lowercased() ?? ""
        let termProgram = environment["TERM_PROGRAM"]?.lowercased() ?? ""
        return colorTerm.contains("truecolor")
            || colorTerm.contains("24bit")
            || termProgram == "ghostty"
    }
}

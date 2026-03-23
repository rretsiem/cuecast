import Foundation

enum StreamRecorderError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case playlistResolutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "server did not return an HTTP response"
        case .httpStatus(let statusCode):
            return "server returned HTTP \(statusCode)"
        case .playlistResolutionFailed(let url):
            return "failed to resolve playlist URL: \(url)"
        }
    }
}

struct StreamRecorder {
    private let session: URLSession
    private let logger: Logger
    private let terminalUI: TerminalUI
    private let controller: RecorderController

    init(session: URLSession = .shared, logger: Logger) {
        self.session = session
        self.logger = logger
        self.terminalUI = TerminalUI(isEnabled: !logger.isQuiet)
        self.terminalUI.attach(to: logger)
        self.controller = RecorderController(terminalUI: terminalUI)
    }

    var controls: RecorderController {
        controller
    }

    func record(_ options: RecordOptions) async throws {
        let recordingStartedAt = Date()
        terminalUI.start()
        defer {
            terminalUI.stop()
        }

        let diskMonitor = DiskSpaceMonitor(recordsDirectory: options.recordsDirectory)
        let initialDiskSnapshot = try diskMonitor.initialCheck()
        terminalUI.noteDiskSpace(initialDiskSnapshot)
        if initialDiskSnapshot.isLow {
            logger.info("Low disk warning: \(Self.formatBytes(initialDiskSnapshot.availableBytes)) free")
        }

        let streamURL = try await PlaylistResolver.resolve(url: options.sourceURL, session: session, logger: logger)

        logger.info("Connecting to \(streamURL.absoluteString)")

        var request = URLRequest(url: streamURL)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("cuecast/0.1", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StreamRecorderError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw StreamRecorderError.httpStatus(httpResponse.statusCode)
        }

        let descriptor = ContentType.descriptor(from: httpResponse, sourceURL: streamURL)
        terminalUI.connected(to: streamURL, descriptor: descriptor)

        logger.info(
            "Connected codec=\(descriptor.codecLabel) bitrate=\(descriptor.bitrateKbps.map { "\($0) kbps" } ?? "unknown") metadata=\(descriptor.metaInterval.map(String.init) ?? "off")"
        )

        let artwork = await ArtworkResolver.resolve(sourceURL: options.sourceURL, session: session, logger: logger)
        let tagContext = MP3TagContext(
            stationName: descriptor.stationName,
            stationGenre: descriptor.genre,
            stationWebsiteURL: descriptor.websiteURL,
            sourceURL: options.sourceURL,
            resolvedURL: streamURL,
            artwork: artwork
        )

        let manifest = try SegmentManifest(
            recordsDirectory: options.recordsDirectory,
            sourceURL: options.sourceURL,
            resolvedURL: streamURL,
            descriptor: descriptor,
            startedAt: recordingStartedAt,
            logger: logger
        )
        defer {
            try? manifest.finish()
        }

        let sink = try RecordingSink(
            recordsDirectory: options.recordsDirectory,
            stationName: descriptor.stationName,
            sourceURL: streamURL,
            fileExtension: descriptor.fileExtension,
            logger: logger,
            onFileChange: { snapshot in
                terminalUI.noteFileChange(snapshot)
                try manifest.noteFileChange(snapshot)
            },
            onFileFinalized: { segment in
                try MP3TagWriter.embedTagsIfSupported(for: segment, context: tagContext, logger: logger)
            }
        )

        var parser: IcyStreamParser?
        var bufferedAudio = Data()
        var shouldFlushPendingAudioOnCleanup = true

        defer {
            do {
                if shouldFlushPendingAudioOnCleanup, var parser {
                    try parser.finish { data in
                        try sink.appendAudio(data)
                        terminalUI.noteAudioBytes(data.count)
                    }
                }

                if shouldFlushPendingAudioOnCleanup, !bufferedAudio.isEmpty {
                    try sink.appendAudio(bufferedAudio)
                    terminalUI.noteAudioBytes(bufferedAudio.count)
                    bufferedAudio.removeAll(keepingCapacity: true)
                }

                try sink.finish()
            } catch {
                logger.info("cleanup after shutdown encountered: \(error.localizedDescription)")
            }
        }

        if let metaInterval = descriptor.metaInterval, metaInterval > 0 {
            parser = IcyStreamParser(metaInterval: metaInterval)

            do {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    try parser?.process(
                        byte: byte,
                        onAudio: { data in
                            let diskSnapshot = try diskMonitor.validateWrite(incomingBytes: data.count)
                            terminalUI.noteDiskSpace(diskSnapshot)
                            try sink.appendAudio(data)
                            terminalUI.noteAudioBytes(data.count)
                        },
                        onMetadata: { metadata in
                            terminalUI.noteMetadata(metadata)
                            manifest.noteMetadata(metadata)
                            try sink.updateMetadata(metadata)
                        }
                    )
                }
            } catch let error as DiskSpaceMonitorError {
                shouldFlushPendingAudioOnCleanup = false
                terminalUI.setStatus("Low disk")
                logger.info(error.localizedDescription)
                throw error
            }
        } else {
            try sink.ensurePlaceholderFileIfNeeded()

            bufferedAudio.reserveCapacity(64 * 1024)

            do {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    bufferedAudio.append(byte)
                    if bufferedAudio.count >= 64 * 1024 {
                        let diskSnapshot = try diskMonitor.validateWrite(incomingBytes: bufferedAudio.count)
                        terminalUI.noteDiskSpace(diskSnapshot)
                        try sink.appendAudio(bufferedAudio)
                        terminalUI.noteAudioBytes(bufferedAudio.count)
                        bufferedAudio.removeAll(keepingCapacity: true)
                    }
                }

                if !bufferedAudio.isEmpty {
                    let diskSnapshot = try diskMonitor.validateWrite(incomingBytes: bufferedAudio.count)
                    terminalUI.noteDiskSpace(diskSnapshot)
                }
            } catch let error as DiskSpaceMonitorError {
                shouldFlushPendingAudioOnCleanup = false
                bufferedAudio.removeAll(keepingCapacity: true)
                terminalUI.setStatus("Low disk")
                logger.info(error.localizedDescription)
                throw error
            }
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }
}

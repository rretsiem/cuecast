import Foundation

struct RecordingFileSnapshot {
    let fileURL: URL
    let title: String?
    let startedAt: Date
    let splitCount: Int
    let isPlaceholder: Bool
}

typealias RecordingFinalizer = (RecordingFinalizedSegment) throws -> Void

private enum SegmentCompletion {
    case metadataBoundary
    case interrupted
}

final class RecordingSink {
    private struct CurrentFile {
        let url: URL
        let cleanURL: URL
        let handle: FileHandle
        let title: String?
        let titleSlug: String?
        let startedAt: Date
        let isPlaceholder: Bool
        let metadata: StreamMetadata?
    }

    private let recordsDirectory: URL
    private let stationSlug: String
    private let fileExtension: String
    private let logger: Logger
    private let maxPendingBytes = 2 * 1024 * 1024
    private let onFileChange: ((RecordingFileSnapshot) throws -> Void)?
    private let onFileFinalized: RecordingFinalizer?

    private var pendingAudio = Data()
    private var pendingAudioStartedAt: Date?
    private var currentFile: CurrentFile?
    private var splitCount = 0

    init(
        recordsDirectory: URL,
        stationName: String?,
        sourceURL: URL,
        fileExtension: String,
        logger: Logger,
        onFileChange: ((RecordingFileSnapshot) throws -> Void)? = nil,
        onFileFinalized: RecordingFinalizer? = nil
    ) throws {
        self.recordsDirectory = recordsDirectory.standardizedFileURL
        self.stationSlug = Slugifier.slugify(stationName ?? sourceURL.host ?? "Stream")
        self.fileExtension = fileExtension
        self.logger = logger
        self.onFileChange = onFileChange
        self.onFileFinalized = onFileFinalized

        try FileManager.default.createDirectory(
            at: self.recordsDirectory,
            withIntermediateDirectories: true
        )
    }

    func appendAudio(_ data: Data) throws {
        if currentFile == nil, pendingAudio.isEmpty {
            pendingAudioStartedAt = Date()
        }

        if let currentFile {
            try currentFile.handle.write(contentsOf: data)
            return
        }

        pendingAudio.append(data)
        if pendingAudio.count >= maxPendingBytes {
            try openFile(title: nil, titleSlug: nil, metadata: nil)
        }
    }

    func updateMetadata(_ metadata: StreamMetadata) throws {
        guard let titleSlug = metadata.titleSlug else {
            return
        }
        let title = metadata.streamTitle

        if let currentFile {
            if currentFile.isPlaceholder {
                try renameCurrentFile(title: title, titleSlug: titleSlug, metadata: metadata)
                return
            }

            if currentFile.titleSlug != titleSlug {
                try rotateFile(title: title, titleSlug: titleSlug, metadata: metadata)
            }
            return
        }

        try openFile(title: title, titleSlug: titleSlug, metadata: metadata)
    }

    func ensurePlaceholderFileIfNeeded() throws {
        if currentFile == nil {
            try openFile(title: nil, titleSlug: nil, metadata: nil)
        }
    }

    func finish() throws {
        if currentFile == nil, !pendingAudio.isEmpty {
            try openFile(title: nil, titleSlug: nil, metadata: nil)
        }

        try finalizeCurrentFile(completion: .interrupted)
        currentFile = nil
    }

    private func rotateFile(title: String?, titleSlug: String, metadata: StreamMetadata) throws {
        try finalizeCurrentFile(completion: .metadataBoundary)
        currentFile = nil
        try openFile(title: title, titleSlug: titleSlug, metadata: metadata)
    }

    private func renameCurrentFile(title: String?, titleSlug: String, metadata: StreamMetadata) throws {
        guard let currentFile else {
            try openFile(title: title, titleSlug: titleSlug, metadata: metadata)
            return
        }

        try currentFile.handle.close()

        let cleanURL = FileNamer.uniqueFileURL(
            in: recordsDirectory,
            date: currentFile.startedAt,
            stationSlug: stationSlug,
            titleSlug: titleSlug,
            fileExtension: fileExtension
        )
        let destination = try SecurityPolicy.validatedOutputURL(
            Self.marking(cleanURL, suffix: "recording"),
            within: recordsDirectory
        )

        try FileManager.default.moveItem(at: currentFile.url, to: destination)

        let handle = try FileHandle(forWritingTo: destination)
        try handle.seekToEnd()

        logger.info("Renamed placeholder to \(destination.lastPathComponent)")
        self.currentFile = CurrentFile(
            url: destination,
            cleanURL: cleanURL,
            handle: handle,
            title: title,
            titleSlug: titleSlug,
            startedAt: currentFile.startedAt,
            isPlaceholder: false,
            metadata: metadata
        )
        try notifyFileChange()
    }

    private func openFile(title: String?, titleSlug: String?, metadata: StreamMetadata?) throws {
        let startedAt = pendingAudioStartedAt ?? Date()
        let cleanURL = FileNamer.uniqueFileURL(
            in: recordsDirectory,
            date: startedAt,
            stationSlug: stationSlug,
            titleSlug: titleSlug,
            fileExtension: fileExtension
        )
        let safeCleanURL = try SecurityPolicy.validatedOutputURL(cleanURL, within: recordsDirectory)
        let fileURL = try SecurityPolicy.validatedOutputURL(
            Self.marking(safeCleanURL, suffix: "recording"),
            within: recordsDirectory
        )

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)

        if !pendingAudio.isEmpty {
            try handle.write(contentsOf: pendingAudio)
            pendingAudio.removeAll(keepingCapacity: true)
        }

        logger.info("Recording to \(fileURL.path)")
        splitCount += 1
        currentFile = CurrentFile(
            url: fileURL,
            cleanURL: cleanURL,
            handle: handle,
            title: title,
            titleSlug: titleSlug,
            startedAt: startedAt,
            isPlaceholder: titleSlug == nil,
            metadata: metadata
        )
        pendingAudioStartedAt = nil
        try notifyFileChange()
    }

    private func finalizeCurrentFile(completion: SegmentCompletion) throws {
        guard let currentFile else {
            return
        }

        try currentFile.handle.close()
        let finalURL: URL
        switch completion {
        case .metadataBoundary:
            finalURL = try SecurityPolicy.validatedOutputURL(currentFile.cleanURL, within: recordsDirectory)
        case .interrupted:
            finalURL = try SecurityPolicy.validatedOutputURL(
                Self.marking(currentFile.cleanURL, suffix: "partial"),
                within: recordsDirectory
            )
        }

        if currentFile.url != finalURL {
            try FileManager.default.moveItem(at: currentFile.url, to: finalURL)
        }

        try onFileChange?(
            RecordingFileSnapshot(
                fileURL: finalURL,
                title: currentFile.title,
                startedAt: currentFile.startedAt,
                splitCount: splitCount,
                isPlaceholder: currentFile.isPlaceholder
            )
        )

        try onFileFinalized?(
            RecordingFinalizedSegment(
                fileURL: finalURL,
                title: currentFile.title,
                startedAt: currentFile.startedAt,
                endedAt: Date(),
                isPlaceholder: currentFile.isPlaceholder,
                metadata: currentFile.metadata
            )
        )
    }

    private static func marking(_ url: URL, suffix: String) -> URL {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return directory.appendingPathComponent("\(stem)_\(suffix).\(ext)")
    }

    private func notifyFileChange() throws {
        guard let currentFile else {
            return
        }

        try onFileChange?(
            RecordingFileSnapshot(
                fileURL: currentFile.url,
                title: currentFile.title,
                startedAt: currentFile.startedAt,
                splitCount: splitCount,
                isPlaceholder: currentFile.isPlaceholder
            )
        )
    }
}

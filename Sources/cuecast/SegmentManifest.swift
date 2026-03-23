import Foundation

struct SegmentManifestEntry: Codable {
    let recordedAt: Date
    let sourceURL: String
    let resolvedURL: String
    let stationName: String?
    let stationGenre: String?
    let stationWebsiteURL: String?
    let codec: String
    let bitrateKbps: Int?
    let sampleRateHz: Int?
    let contentType: String?
    let splitCount: Int
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Int
    let fileName: String
    let title: String?
    let isPlaceholder: Bool
    let metadata: [String: String]
}

final class SegmentManifest {
    private struct PendingSegment {
        var snapshot: RecordingFileSnapshot
        var metadata: [String: String]
    }

    private let manifestURL: URL
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private let sessionStartedAt: Date
    private let sourceURL: URL
    private let resolvedURL: URL
    private let descriptor: StreamDescriptor

    private var pendingMetadata: [String: String] = [:]
    private var currentSegment: PendingSegment?

    init(
        recordsDirectory: URL,
        sourceURL: URL,
        resolvedURL: URL,
        descriptor: StreamDescriptor,
        startedAt: Date,
        logger: Logger
    ) throws {
        self.sessionStartedAt = startedAt
        self.sourceURL = sourceURL
        self.resolvedURL = resolvedURL
        self.descriptor = descriptor

        try FileManager.default.createDirectory(
            at: recordsDirectory,
            withIntermediateDirectories: true
        )

        let stationSlug = Slugifier.slugify(descriptor.stationName ?? resolvedURL.host ?? "Stream")
        self.manifestURL = FileNamer.uniqueFileURL(
            in: recordsDirectory,
            date: startedAt,
            stationSlug: stationSlug,
            titleSlug: "session-manifest",
            fileExtension: "jsonl"
        )

        FileManager.default.createFile(atPath: manifestURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: manifestURL)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        logger.info("Writing segment manifest to \(manifestURL.lastPathComponent)")
    }

    func noteMetadata(_ metadata: StreamMetadata) {
        pendingMetadata = metadata.fields

        guard var currentSegment else {
            return
        }

        if currentSegment.snapshot.isPlaceholder || currentSegment.snapshot.title == metadata.streamTitle {
            currentSegment.metadata = metadata.fields
            self.currentSegment = currentSegment
        }
    }

    func noteFileChange(_ snapshot: RecordingFileSnapshot) throws {
        if var currentSegment {
            if currentSegment.snapshot.splitCount == snapshot.splitCount {
                currentSegment.snapshot = snapshot
                if !pendingMetadata.isEmpty {
                    currentSegment.metadata = pendingMetadata
                }
                self.currentSegment = currentSegment
                return
            }

            try writeEntry(for: currentSegment, endedAt: snapshot.startedAt)
        }

        currentSegment = PendingSegment(
            snapshot: snapshot,
            metadata: pendingMetadata
        )
    }

    func finish(at endedAt: Date = Date()) throws {
        guard let currentSegment else {
            return
        }

        try writeEntry(for: currentSegment, endedAt: endedAt)
        self.currentSegment = nil
        try handle.close()
    }

    private func writeEntry(for segment: PendingSegment, endedAt: Date) throws {
        let durationSeconds = max(0, Int(endedAt.timeIntervalSince(segment.snapshot.startedAt).rounded()))
        let entry = SegmentManifestEntry(
            recordedAt: sessionStartedAt,
            sourceURL: sourceURL.absoluteString,
            resolvedURL: resolvedURL.absoluteString,
            stationName: descriptor.stationName,
            stationGenre: descriptor.genre,
            stationWebsiteURL: descriptor.websiteURL,
            codec: descriptor.codecLabel,
            bitrateKbps: descriptor.bitrateKbps,
            sampleRateHz: descriptor.sampleRateHz,
            contentType: descriptor.contentType,
            splitCount: segment.snapshot.splitCount,
            startedAt: segment.snapshot.startedAt,
            endedAt: endedAt,
            durationSeconds: durationSeconds,
            fileName: segment.snapshot.fileURL.lastPathComponent,
            title: segment.snapshot.title,
            isPlaceholder: segment.snapshot.isPlaceholder,
            metadata: segment.metadata
        )

        let data = try encoder.encode(entry)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data("\n".utf8))
    }
}

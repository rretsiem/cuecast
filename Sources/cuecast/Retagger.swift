import Foundation

enum RetaggerError: LocalizedError {
    case targetNotFound(URL)
    case manifestNotFound(URL)
    case noManifestFoundForFile(URL)
    case manifestEntryNotFound(fileURL: URL, manifestURL: URL)
    case noManifestFilesInDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .targetNotFound(let url):
            return "retag target not found: \(url.path)"
        case .manifestNotFound(let url):
            return "manifest not found: \(url.path)"
        case .noManifestFoundForFile(let url):
            return "no manifest found for MP3 file: \(url.path)"
        case .manifestEntryNotFound(let fileURL, let manifestURL):
            return "no manifest entry for \(fileURL.lastPathComponent) in \(manifestURL.lastPathComponent)"
        case .noManifestFilesInDirectory(let url):
            return "no manifest files found in \(url.path)"
        }
    }
}

struct Retagger {
    private let session: URLSession
    private let logger: Logger

    init(session: URLSession = .shared, logger: Logger) {
        self.session = session
        self.logger = logger
    }

    mutating func retag(_ options: RetagOptions) async throws {
        let targetURL = options.targetURL
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw RetaggerError.targetNotFound(targetURL)
        }

        var artworkCache: [String: ArtworkAsset?] = [:]
        let values = try targetURL.resourceValues(forKeys: [.isDirectoryKey])

        if values.isDirectory == true {
            let manifests = try manifestFiles(in: targetURL)
            guard !manifests.isEmpty else {
                throw RetaggerError.noManifestFilesInDirectory(targetURL)
            }
            for manifestURL in manifests {
                try await retagManifest(at: manifestURL, artworkCache: &artworkCache)
            }
            return
        }

        if targetURL.pathExtension.lowercased() == "jsonl" {
            try await retagManifest(at: targetURL, artworkCache: &artworkCache)
            return
        }

        guard targetURL.pathExtension.lowercased() == "mp3" else {
            throw RetaggerError.noManifestFoundForFile(targetURL)
        }

        let manifestURL = try resolveManifest(for: targetURL, preferredManifestURL: options.manifestURL)
        let entry = try manifestEntry(for: targetURL, in: manifestURL)
        try await retagEntry(entry, from: manifestURL, artworkCache: &artworkCache)
    }

    private func manifestFiles(in directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return contents
            .filter { $0.pathExtension.lowercased() == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func resolveManifest(for fileURL: URL, preferredManifestURL: URL?) throws -> URL {
        if let preferredManifestURL {
            guard FileManager.default.fileExists(atPath: preferredManifestURL.path) else {
                throw RetaggerError.manifestNotFound(preferredManifestURL)
            }
            return preferredManifestURL
        }

        let directory = fileURL.deletingLastPathComponent()
        let manifests = try manifestFiles(in: directory)

        for manifestURL in manifests {
            if (try? manifestEntry(for: fileURL, in: manifestURL)) != nil {
                return manifestURL
            }
        }

        throw RetaggerError.noManifestFoundForFile(fileURL)
    }

    private func manifestEntry(for fileURL: URL, in manifestURL: URL) throws -> SegmentManifestEntry {
        for entry in try loadManifestEntries(at: manifestURL) where entry.fileName == fileURL.lastPathComponent {
            return entry
        }
        throw RetaggerError.manifestEntryNotFound(fileURL: fileURL, manifestURL: manifestURL)
    }

    private func loadManifestEntries(at manifestURL: URL) throws -> [SegmentManifestEntry] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw RetaggerError.manifestNotFound(manifestURL)
        }

        let data = try Data(contentsOf: manifestURL)
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try text
            .split(whereSeparator: \.isNewline)
            .map { line in
                try decoder.decode(SegmentManifestEntry.self, from: Data(line.utf8))
            }
    }

    private mutating func retagManifest(at manifestURL: URL, artworkCache: inout [String: ArtworkAsset?]) async throws {
        let entries = try loadManifestEntries(at: manifestURL)
        logger.info("Retagging from \(manifestURL.lastPathComponent)")

        for entry in entries {
            try await retagEntry(entry, from: manifestURL, artworkCache: &artworkCache)
        }
    }

    private mutating func retagEntry(
        _ entry: SegmentManifestEntry,
        from manifestURL: URL,
        artworkCache: inout [String: ArtworkAsset?]
    ) async throws {
        let fileURL = manifestURL.deletingLastPathComponent().appendingPathComponent(entry.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.info("Skipping missing file \(entry.fileName)")
            return
        }
        guard fileURL.pathExtension.lowercased() == "mp3" else {
            logger.info("Skipping non-MP3 file \(entry.fileName)")
            return
        }

        let sourceURL = URL(string: entry.sourceURL) ?? fileURL
        let resolvedURL = URL(string: entry.resolvedURL) ?? fileURL
        let artwork = await cachedArtwork(for: sourceURL, artworkCache: &artworkCache)
        let context = MP3TagContext(
            stationName: entry.stationName,
            stationGenre: entry.stationGenre,
            stationWebsiteURL: entry.stationWebsiteURL,
            sourceURL: sourceURL,
            resolvedURL: resolvedURL,
            artwork: artwork
        )
        let segment = RecordingFinalizedSegment(
            fileURL: fileURL,
            title: entry.title,
            startedAt: entry.startedAt,
            endedAt: entry.endedAt,
            isPlaceholder: entry.isPlaceholder,
            metadata: StreamMetadata(fields: entry.metadata)
        )

        try MP3TagWriter.embedTagsIfSupported(for: segment, context: context, logger: logger)
    }

    private mutating func cachedArtwork(
        for sourceURL: URL,
        artworkCache: inout [String: ArtworkAsset?]
    ) async -> ArtworkAsset? {
        let key = sourceURL.absoluteString
        if let cached = artworkCache[key] {
            return cached
        }
        let artwork = await ArtworkResolver.resolve(sourceURL: sourceURL, session: session, logger: logger)
        artworkCache[key] = artwork
        return artwork
    }
}

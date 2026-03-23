import Foundation

struct MP3TagContext {
    let stationName: String?
    let stationGenre: String?
    let stationWebsiteURL: String?
    let sourceURL: URL
    let resolvedURL: URL
    let artwork: ArtworkAsset?
}

struct RecordingFinalizedSegment {
    let fileURL: URL
    let title: String?
    let startedAt: Date
    let endedAt: Date
    let isPlaceholder: Bool
    let metadata: StreamMetadata?
}

enum MP3TagWriter {
    static func embedTagsIfSupported(
        for segment: RecordingFinalizedSegment,
        context: MP3TagContext,
        logger: Logger
    ) throws {
        guard segment.fileURL.pathExtension.lowercased() == "mp3" else {
            return
        }

        let parsed = ParsedTrackTitle(from: segment.title)
        let title = parsed.title ?? segment.title ?? "Live"

        var frames: [Data] = []
        frames.append(textFrame(id: "TIT2", value: title))
        if let artist = parsed.artist {
            frames.append(textFrame(id: "TPE1", value: artist))
        }
        if let stationName = context.stationName {
            frames.append(textFrame(id: "TALB", value: stationName))
        }
        if let genre = context.stationGenre {
            frames.append(textFrame(id: "TCON", value: genre))
        }
        if let stationWebsiteURL = context.stationWebsiteURL {
            frames.append(urlFrame(id: "WOAS", value: stationWebsiteURL))
        }

        let commentValue = [
            "Recorded by cuecast",
            "Source: \(context.sourceURL.absoluteString)",
            "Resolved: \(context.resolvedURL.absoluteString)",
            "Started: \(ISO8601DateFormatter().string(from: segment.startedAt))"
        ].joined(separator: " | ")
        frames.append(commentFrame(value: commentValue))

        if let artwork = context.artwork {
            frames.append(artworkFrame(asset: artwork))
        }

        let tagData = id3Tag(from: frames)
        let originalData = try Data(contentsOf: segment.fileURL)
        let audioData = stripExistingID3Tag(from: originalData)

        var output = Data()
        output.reserveCapacity(tagData.count + audioData.count)
        output.append(tagData)
        output.append(audioData)

        try output.write(to: segment.fileURL, options: .atomic)
        logger.info("Embedded ID3 tags into \(segment.fileURL.lastPathComponent)")
    }

    private static func id3Tag(from frames: [Data]) -> Data {
        let payload = frames.reduce(into: Data(), { $0.append($1) })
        var data = Data("ID3".utf8)
        data.append(contentsOf: [0x03, 0x00, 0x00])
        data.append(synchsafe(payload.count))
        data.append(payload)
        return data
    }

    private static func textFrame(id: String, value: String) -> Data {
        var payload = Data([0x01])
        payload.append(utf16(value))
        return frame(id: id, payload: payload)
    }

    private static func urlFrame(id: String, value: String) -> Data {
        frame(id: id, payload: Data(value.utf8))
    }

    private static func commentFrame(value: String) -> Data {
        var payload = Data([0x01])
        payload.append(Data("eng".utf8))
        payload.append(contentsOf: [0xFF, 0xFE, 0x00, 0x00])
        payload.append(utf16(value))
        return frame(id: "COMM", payload: payload)
    }

    private static func artworkFrame(asset: ArtworkAsset) -> Data {
        var payload = Data([0x00])
        payload.append(Data(asset.mimeType.utf8))
        payload.append(0x00)
        payload.append(0x03)
        payload.append(0x00)
        payload.append(asset.data)
        return frame(id: "APIC", payload: payload)
    }

    private static func frame(id: String, payload: Data) -> Data {
        var data = Data(id.utf8)
        data.append(bigEndian32(payload.count))
        data.append(contentsOf: [0x00, 0x00])
        data.append(payload)
        return data
    }

    private static func utf16(_ value: String) -> Data {
        var data = Data([0xFF, 0xFE])
        data.append(value.data(using: .utf16LittleEndian) ?? Data())
        return data
    }

    private static func bigEndian32(_ value: Int) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private static func synchsafe(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ])
    }

    private static func stripExistingID3Tag(from data: Data) -> Data {
        guard data.count >= 10, String(data: data.prefix(3), encoding: .ascii) == "ID3" else {
            return data
        }

        let size = data[6...9].reduce(0) { partialResult, byte in
            (partialResult << 7) | Int(byte & 0x7F)
        }
        let tagLength = 10 + size
        guard tagLength < data.count else {
            return data
        }
        return data.dropFirst(tagLength)
    }
}

private struct ParsedTrackTitle {
    let artist: String?
    let title: String?

    init(from streamTitle: String?) {
        guard let streamTitle, !streamTitle.isEmpty else {
            artist = nil
            title = nil
            return
        }

        for separator in [" - ", " – ", " — "] where streamTitle.contains(separator) {
            let parts = streamTitle.components(separatedBy: separator)
            if parts.count >= 2 {
                let artistPart = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let titlePart = parts.dropFirst().joined(separator: separator)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                artist = artistPart.isEmpty ? nil : artistPart
                title = titlePart.isEmpty ? streamTitle : titlePart
                return
            }
        }

        artist = nil
        title = streamTitle
    }
}

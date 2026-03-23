import Foundation

struct StreamDescriptor {
    let stationName: String?
    let genre: String?
    let websiteURL: String?
    let metaInterval: Int?
    let fileExtension: String
    let codecLabel: String
    let bitrateKbps: Int?
    let sampleRateHz: Int?
    let contentType: String?
}

enum ContentType {
    static func descriptor(from response: HTTPURLResponse, sourceURL: URL) -> StreamDescriptor {
        let stationName = response.value(forHTTPHeaderField: "icy-name")?.nilIfEmpty(maxLength: 160)
        let genre = response.value(forHTTPHeaderField: "icy-genre")?.nilIfEmpty(maxLength: 120)
        let websiteURL = response.value(forHTTPHeaderField: "icy-url")?.nilIfEmpty(maxLength: 300)
        let metaInterval = response.value(forHTTPHeaderField: "icy-metaint").flatMap(Int.init)
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        let bitrateKbps = response.value(forHTTPHeaderField: "icy-br").flatMap(Int.init)
            ?? response.value(forHTTPHeaderField: "ice-bitrate").flatMap(Int.init)
        let sampleRateHz = response.value(forHTTPHeaderField: "icy-sr").flatMap(Int.init)
        let fileExtension = fileExtension(for: contentType, sourceURL: sourceURL)
        let codecLabel = codecLabel(for: contentType, fileExtension: fileExtension)

        return StreamDescriptor(
            stationName: stationName,
            genre: genre,
            websiteURL: websiteURL,
            metaInterval: metaInterval,
            fileExtension: fileExtension,
            codecLabel: codecLabel,
            bitrateKbps: bitrateKbps,
            sampleRateHz: sampleRateHz,
            contentType: contentType
        )
    }

    static func fileExtension(for contentType: String?, sourceURL: URL) -> String {
        let normalized = contentType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "audio/mpeg", "audio/mp3":
            return "mp3"
        case "audio/aac", "audio/aacp", "audio/x-aac":
            return "aac"
        case "audio/mp4", "video/mp4", "application/mp4", "audio/x-m4a":
            return "mp4"
        case "audio/ogg", "application/ogg":
            return "ogg"
        case "audio/flac":
            return "flac"
        default:
            let candidate = sourceURL.pathExtension.lowercased()
            if ["mp3", "aac", "mp4", "m4a", "ogg", "flac"].contains(candidate) {
                return candidate == "m4a" ? "mp4" : candidate
            }
            return "mp3"
        }
    }

    static func codecLabel(for contentType: String?, fileExtension: String) -> String {
        let normalized = contentType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "audio/mpeg", "audio/mp3":
            return "MP3"
        case "audio/aac", "audio/aacp", "audio/x-aac":
            return "AAC"
        case "audio/mp4", "video/mp4", "application/mp4", "audio/x-m4a":
            return "MP4"
        case "audio/ogg", "application/ogg":
            return "OGG"
        case "audio/flac":
            return "FLAC"
        default:
            return fileExtension.uppercased()
        }
    }
}

private extension String {
    func nilIfEmpty(maxLength: Int) -> String? {
        let trimmed = InputSanitizer.text(self, maxLength: maxLength)
        return trimmed.isEmpty ? nil : trimmed
    }
}

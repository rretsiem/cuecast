import Foundation

struct ArtworkAsset {
    let mimeType: String
    let data: Data
}

enum ArtworkResolver {
    static func resolve(sourceURL: URL, session: URLSession, logger: Logger) async -> ArtworkAsset? {
        guard let stationID = tuneInStationID(from: sourceURL) else {
            return nil
        }

        do {
            let describeURL = URL(string: "https://opml.radiotime.com/Describe.ashx?id=\(stationID)")!
            let (describeData, _) = try await session.data(from: describeURL)
            guard
                let xml = String(data: describeData, encoding: .utf8),
                let logoURLString = firstCapture(in: xml, pattern: #"<logo>([^<]+)</logo>"#),
                let logoURL = URL(string: logoURLString)
            else {
                return nil
            }

            let (imageData, imageResponse) = try await session.data(from: logoURL)
            guard !imageData.isEmpty else {
                return nil
            }

            let mimeType = (imageResponse as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type")?
                .split(separator: ";", maxSplits: 1)
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? fallbackMimeType(for: logoURL)

            logger.info("Resolved artwork for \(stationID)")
            return ArtworkAsset(mimeType: mimeType, data: imageData)
        } catch {
            logger.info("Artwork lookup skipped: \(error.localizedDescription)")
            return nil
        }
    }

    private static func tuneInStationID(from url: URL) -> String? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        if let stationID = components?.queryItems?.first(where: { $0.name.lowercased() == "stationid" })?.value {
            return stationID.hasPrefix("s") ? stationID : "s\(stationID)"
        }

        if let id = components?.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value, id.hasPrefix("s") {
            return id
        }

        return firstCapture(in: url.absoluteString, pattern: #"(s\d+)"#)
    }

    private static func fallbackMimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        default:
            return "image/jpeg"
        }
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, options: [], range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captureRange])
    }
}

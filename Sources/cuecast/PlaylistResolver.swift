import Foundation

enum PlaylistResolver {
    private static let playlistExtensions = Set(["pls", "m3u", "m3u8", "asx"])

    static func resolve(url: URL, session: URLSession, logger: Logger) async throws -> URL {
        var current = url

        for _ in 0..<4 {
            let fileExtension = current.pathExtension.lowercased()
            guard playlistExtensions.contains(fileExtension) else {
                return current
            }

            logger.info("Resolving playlist \(current.absoluteString)")

            var request = URLRequest(url: current)
            request.setValue("cuecast/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw StreamRecorderError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw StreamRecorderError.httpStatus(httpResponse.statusCode)
            }

            let body = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""

            guard let next = parse(body: body, fileExtension: fileExtension, baseURL: current) else {
                throw StreamRecorderError.playlistResolutionFailed(current.absoluteString)
            }

            current = next
        }

        return current
    }

    static func parse(body: String, fileExtension: String, baseURL: URL) -> URL? {
        switch fileExtension {
        case "pls":
            return parsePLS(body: body, baseURL: baseURL)
        case "m3u", "m3u8":
            return parseM3U(body: body, baseURL: baseURL)
        case "asx":
            return parseASX(body: body, baseURL: baseURL)
        default:
            return nil
        }
    }

    private static func parsePLS(body: String, baseURL: URL) -> URL? {
        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().hasPrefix("file") else {
                continue
            }
            guard let separator = line.firstIndex(of: "=") else {
                continue
            }
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if let url = URL(string: value, relativeTo: baseURL)?.absoluteURL {
                return url
            }
        }
        return nil
    }

    private static func parseM3U(body: String, baseURL: URL) -> URL? {
        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                return url
            }
        }
        return nil
    }

    private static func parseASX(body: String, baseURL: URL) -> URL? {
        let pattern = #"(?i)<ref[^>]+href="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard
            let match = regex.firstMatch(in: body, options: [], range: range),
            let hrefRange = Range(match.range(at: 1), in: body)
        else {
            return nil
        }

        let href = String(body[hrefRange])
        return URL(string: href, relativeTo: baseURL)?.absoluteURL
    }
}

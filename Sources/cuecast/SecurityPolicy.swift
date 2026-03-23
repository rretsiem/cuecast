import Foundation

enum InputSecurityError: LocalizedError {
    case unsupportedURLScheme(String)
    case missingURLHost(String)
    case oversizedResponse(kind: String, url: String, limitBytes: Int)
    case invalidArtworkResponse(String)
    case unsafeOutputPath(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedURLScheme(let value):
            return "unsupported URL scheme: \(value)"
        case .missingURLHost(let value):
            return "URL must include a host: \(value)"
        case .oversizedResponse(let kind, let url, let limitBytes):
            return "\(kind) response exceeded safety limit of \(limitBytes) bytes: \(url)"
        case .invalidArtworkResponse(let value):
            return "artwork response is not a supported image: \(value)"
        case .unsafeOutputPath(let value):
            return "refusing to write outside records directory: \(value)"
        }
    }
}

enum SecurityPolicy {
    static let maxPlaylistBytes = 512 * 1024
    static let maxArtworkDescriptionBytes = 512 * 1024
    static let maxArtworkBytes = 5 * 1024 * 1024
    static let maxMetadataFields = 32
    static let maxMetadataKeyLength = 64
    static let maxMetadataValueLength = 512
    static let maxSlugLength = 80

    private static let allowedRemoteSchemes = Set(["http", "https"])
    private static let allowedArtworkMimePrefixes = ["image/"]

    static func validatedRemoteURL(_ url: URL) throws -> URL {
        let absoluteURL = url.absoluteURL
        guard let scheme = absoluteURL.scheme?.lowercased(), allowedRemoteSchemes.contains(scheme) else {
            throw InputSecurityError.unsupportedURLScheme(absoluteURL.absoluteString)
        }
        guard absoluteURL.host?.isEmpty == false else {
            throw InputSecurityError.missingURLHost(absoluteURL.absoluteString)
        }
        return absoluteURL
    }

    static func validateResponseSize(kind: String, data: Data, url: URL, limitBytes: Int) throws {
        guard data.count <= limitBytes else {
            throw InputSecurityError.oversizedResponse(
                kind: kind,
                url: url.absoluteString,
                limitBytes: limitBytes
            )
        }
    }

    static func validateArtwork(data: Data, response: URLResponse?, url: URL) throws {
        try validateResponseSize(kind: "artwork", data: data, url: url, limitBytes: maxArtworkBytes)

        let mimeType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let mimeType {
            guard allowedArtworkMimePrefixes.contains(where: { mimeType.hasPrefix($0) }) else {
                throw InputSecurityError.invalidArtworkResponse(mimeType)
            }
            return
        }

        let fallbackExtension = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "gif", "webp"].contains(fallbackExtension) else {
            throw InputSecurityError.invalidArtworkResponse(url.absoluteString)
        }
    }

    static func validatedOutputURL(_ fileURL: URL, within directory: URL) throws -> URL {
        let baseDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidateDirectory = fileURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()

        let basePath = baseDirectory.path.hasSuffix("/") ? baseDirectory.path : baseDirectory.path + "/"
        let candidatePath = candidateDirectory.path.hasSuffix("/") ? candidateDirectory.path : candidateDirectory.path + "/"

        guard candidatePath.hasPrefix(basePath) else {
            throw InputSecurityError.unsafeOutputPath(fileURL.path)
        }

        return fileURL.standardizedFileURL
    }

    static func fetchLimitedData(
        for request: URLRequest,
        session: URLSession,
        kind: String,
        limitBytes: Int
    ) async throws -> (Data, URLResponse) {
        let targetURL = request.url ?? URL(fileURLWithPath: "/")
        let (bytes, response) = try await session.bytes(for: request)

        if response.expectedContentLength > Int64(limitBytes) {
            throw InputSecurityError.oversizedResponse(
                kind: kind,
                url: targetURL.absoluteString,
                limitBytes: limitBytes
            )
        }

        var data = Data()
        let initialCapacity: Int
        if response.expectedContentLength > 0 {
            initialCapacity = min(Int(response.expectedContentLength), limitBytes)
        } else {
            initialCapacity = min(64 * 1024, limitBytes)
        }
        data.reserveCapacity(initialCapacity)

        for try await byte in bytes {
            if data.count >= limitBytes {
                throw InputSecurityError.oversizedResponse(
                    kind: kind,
                    url: targetURL.absoluteString,
                    limitBytes: limitBytes
                )
            }
            data.append(byte)
        }

        return (data, response)
    }
}

enum InputSanitizer {
    static func text(_ value: String, maxLength: Int) -> String {
        let filtered = String(
            value.unicodeScalars.filter { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
            }
        )

        let collapsedWhitespace = filtered.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        let trimmed = collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength {
            return trimmed
        }

        return String(trimmed.prefix(maxLength))
    }
}

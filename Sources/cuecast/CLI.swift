import Foundation

enum Command {
    case help
    case record(RecordOptions)
    case retag(RetagOptions)
}

struct RecordOptions {
    let sourceURL: URL
    let recordsDirectory: URL
    let isQuiet: Bool
    let shouldEmbedTags: Bool
}

struct RetagOptions {
    let targetURL: URL
    let manifestURL: URL?
    let isQuiet: Bool
}

enum CLIError: LocalizedError {
    case helpRequested
    case missingURL
    case missingRetagTarget
    case invalidURL(String)
    case missingValue(String)
    case unexpectedArgument(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case .missingURL:
            return "missing stream URL"
        case .missingRetagTarget:
            return "missing retag target path"
        case .invalidURL(let value):
            return "invalid URL: \(value)"
        case .missingValue(let flag):
            return "missing value for \(flag)"
        case .unexpectedArgument(let value):
            return "unexpected argument: \(value)"
        }
    }
}

enum CLI {
    static let helpText = """
    Cuecast records HTTP radio streams to local files without transcoding.

    Usage:
      cuecast record <url> [--records-dir <path>] [--embed-tags | --no-embed-tags] [--quiet]
      cuecast <url> [--records-dir <path>] [--embed-tags | --no-embed-tags] [--quiet]
      cuecast retag <path> [--manifest <path>] [--quiet]

    Options:
      --records-dir <path>   Directory for recordings. Default: ./records
      --embed-tags           Embed ID3 tags into finalized MP3 segments (default)
      --no-embed-tags        Leave finalized MP3 segments unmodified
      --manifest <path>      Manifest to use when retagging a single MP3 file
      --quiet                Suppress progress logs and live terminal status
      -h, --help             Show help

    Notes:
      - The current MVP supports direct HTTP streams and common playlist links (.pls, .m3u, .m3u8, .asx).
      - ICY metadata changes rotate the output file and drive the slugified filename.
      - On an interactive terminal, Cuecast shows live station/title/runtime status with a segment progress bar.
      - MP3 tagging is tuned for continuous DJ/radio mix streams.
      - `retag` rebuilds MP3 ID3 tags later from a saved session manifest.
    """

    static func parse(arguments: [String]) throws -> Command {
        guard !arguments.isEmpty else {
            return .help
        }

        if arguments.contains("--help") || arguments.contains("-h") || arguments == ["help"] {
            throw CLIError.helpRequested
        }

        if arguments.first == "retag" {
            return try parseRetag(arguments: Array(arguments.dropFirst()))
        }

        var tokens = arguments
        if tokens.first == "record" {
            tokens.removeFirst()
        }

        var urlString: String?
        var recordsDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("records", isDirectory: true)
        var isQuiet = false
        var shouldEmbedTags = true

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "--records-dir":
                index += 1
                guard index < tokens.count else {
                    throw CLIError.missingValue("--records-dir")
                }
                recordsDirectory = URL(fileURLWithPath: tokens[index], relativeTo: nil)
                    .standardizedFileURL
            case "--quiet":
                isQuiet = true
            case "--embed-tags":
                shouldEmbedTags = true
            case "--no-embed-tags":
                shouldEmbedTags = false
            default:
                if token.hasPrefix("-") {
                    throw CLIError.unexpectedArgument(token)
                }
                if urlString == nil {
                    urlString = token
                } else {
                    throw CLIError.unexpectedArgument(token)
                }
            }
            index += 1
        }

        guard let urlString else {
            throw CLIError.missingURL
        }
        guard let sourceURL = URL(string: urlString), sourceURL.scheme != nil else {
            throw CLIError.invalidURL(urlString)
        }
        _ = try SecurityPolicy.validatedRemoteURL(sourceURL)

        return .record(
            RecordOptions(
                sourceURL: sourceURL,
                recordsDirectory: recordsDirectory,
                isQuiet: isQuiet,
                shouldEmbedTags: shouldEmbedTags
            )
        )
    }

    private static func parseRetag(arguments: [String]) throws -> Command {
        var targetPath: String?
        var manifestPath: String?
        var isQuiet = false

        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            switch token {
            case "--manifest":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.missingValue("--manifest")
                }
                manifestPath = arguments[index]
            case "--quiet":
                isQuiet = true
            default:
                if token.hasPrefix("-") {
                    throw CLIError.unexpectedArgument(token)
                }
                if targetPath == nil {
                    targetPath = token
                } else {
                    throw CLIError.unexpectedArgument(token)
                }
            }
            index += 1
        }

        guard let targetPath else {
            throw CLIError.missingRetagTarget
        }

        return .retag(
            RetagOptions(
                targetURL: URL(fileURLWithPath: targetPath).standardizedFileURL,
                manifestURL: manifestPath.map { URL(fileURLWithPath: $0).standardizedFileURL },
                isQuiet: isQuiet
            )
        )
    }
}

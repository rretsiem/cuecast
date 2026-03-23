import Foundation

enum Slugifier {
    static func slugify(_ value: String) -> String {
        let folded = value.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: .current
        )

        var parts: [String] = []
        var current = String.UnicodeScalarView()

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                parts.append(String(current))
                current.removeAll(keepingCapacity: true)
            }
        }

        if !current.isEmpty {
            parts.append(String(current))
        }

        return parts.joined(separator: "-")
    }
}

enum FileNamer {
    static func makeFilename(
        date: Date,
        stationSlug: String,
        titleSlug: String?,
        fileExtension: String
    ) -> String {
        let day = dayFormatter.string(from: date)
        let station = normalizedPart(from: stationSlug, fallback: "Stream")
        let title = normalizedPart(from: titleSlug, fallback: "Live")

        return "\(day)_\(station)_\(title).\(fileExtension)"
    }

    static func uniqueFileURL(
        in directory: URL,
        date: Date,
        stationSlug: String,
        titleSlug: String?,
        fileExtension: String
    ) -> URL {
        let baseFilename = makeFilename(
            date: date,
            stationSlug: stationSlug,
            titleSlug: titleSlug,
            fileExtension: fileExtension
        )

        var candidate = directory.appendingPathComponent(baseFilename)
        var suffix = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            let stem = baseFilename.dropLast(fileExtension.count + 1)
            candidate = directory.appendingPathComponent("\(stem)_\(suffix).\(fileExtension)")
            suffix += 1
        }

        return candidate
    }

    private static func normalizedPart(from value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty else {
            return fallback
        }

        let slug = Slugifier.slugify(value)
        return slug.isEmpty ? fallback : slug
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

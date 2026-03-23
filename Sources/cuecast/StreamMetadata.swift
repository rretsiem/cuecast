import Foundation

struct StreamMetadata {
    let fields: [String: String]

    var streamTitle: String? {
        fields["StreamTitle"]?.trimmedNilIfEmpty
    }

    var titleSlug: String? {
        guard let streamTitle else {
            return nil
        }

        let slug = Slugifier.slugify(streamTitle)
        return slug.isEmpty ? nil : slug
    }

    var displaySummary: String {
        let preferredKeys = ["StreamTitle", "StreamUrl"]
        var parts: [String] = []

        for key in preferredKeys {
            if let value = fields[key]?.trimmedNilIfEmpty, !value.isEmpty {
                parts.append("\(key)=\(value)")
            }
        }

        if parts.isEmpty {
            for key in fields.keys.sorted() {
                guard let value = fields[key]?.trimmedNilIfEmpty, !value.isEmpty else {
                    continue
                }
                parts.append("\(key)=\(value)")
            }
        }

        return parts.isEmpty ? "No metadata fields" : parts.joined(separator: " | ")
    }

    static func parse(from data: Data) -> StreamMetadata {
        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        let trimmed = raw.replacingOccurrences(of: "\0", with: "")
        var fields: [String: String] = [:]

        for part in trimmed.split(separator: ";").prefix(SecurityPolicy.maxMetadataFields) {
            guard let separator = part.firstIndex(of: "=") else {
                continue
            }

            let key = InputSanitizer.text(
                String(part[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines),
                maxLength: SecurityPolicy.maxMetadataKeyLength
            )
            var value = String(part[part.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }

            let sanitizedValue = InputSanitizer.text(
                value,
                maxLength: SecurityPolicy.maxMetadataValueLength
            )

            guard !key.isEmpty, !sanitizedValue.isEmpty else {
                continue
            }

            fields[key] = sanitizedValue
        }

        return StreamMetadata(fields: fields)
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

import Foundation

struct IcyStreamParser {
    private enum State {
        case audio(remaining: Int)
        case metadataLength
        case metadata(remaining: Int)
    }

    private let metaInterval: Int
    private var state: State
    private var audioBuffer = Data()
    private var metadataBuffer = Data()

    init(metaInterval: Int) {
        self.metaInterval = metaInterval
        self.state = .audio(remaining: metaInterval)
    }

    mutating func process(
        byte: UInt8,
        onAudio: (Data) throws -> Void,
        onMetadata: (StreamMetadata) throws -> Void
    ) throws {
        switch state {
        case .audio(let remaining):
            audioBuffer.append(byte)
            let next = remaining - 1
            if next == 0 {
                if !audioBuffer.isEmpty {
                    try onAudio(audioBuffer)
                    audioBuffer.removeAll(keepingCapacity: true)
                }
                state = .metadataLength
            } else {
                state = .audio(remaining: next)
            }

        case .metadataLength:
            let metadataLength = Int(byte) * 16
            if metadataLength == 0 {
                state = .audio(remaining: metaInterval)
            } else {
                metadataBuffer.removeAll(keepingCapacity: true)
                state = .metadata(remaining: metadataLength)
            }

        case .metadata(let remaining):
            metadataBuffer.append(byte)
            let next = remaining - 1
            if next == 0 {
                let metadata = StreamMetadata.parse(from: metadataBuffer)
                metadataBuffer.removeAll(keepingCapacity: true)
                try onMetadata(metadata)
                state = .audio(remaining: metaInterval)
            } else {
                state = .metadata(remaining: next)
            }
        }
    }

    mutating func finish(onAudio: (Data) throws -> Void) throws {
        if !audioBuffer.isEmpty {
            try onAudio(audioBuffer)
            audioBuffer.removeAll(keepingCapacity: true)
        }
    }
}

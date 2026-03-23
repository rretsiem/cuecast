import Foundation

struct DiskSpaceSnapshot {
    let availableBytes: Int64
    let warningThresholdBytes: Int64
    let stopThresholdBytes: Int64

    var isLow: Bool {
        availableBytes <= warningThresholdBytes
    }

    var shouldStop: Bool {
        availableBytes <= stopThresholdBytes
    }
}

enum DiskSpaceMonitorError: LocalizedError {
    case lowDiskSpace(availableBytes: Int64, stopThresholdBytes: Int64)
    case unavailable(URL)

    var errorDescription: String? {
        switch self {
        case .lowDiskSpace(let availableBytes, let stopThresholdBytes):
            return "stopping before disk is full: \(Self.formatBytes(availableBytes)) free, reserve threshold \(Self.formatBytes(stopThresholdBytes))"
        case .unavailable(let url):
            return "unable to determine available disk space for \(url.path)"
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }
}

final class DiskSpaceMonitor {
    private let recordsDirectory: URL
    private let warningThresholdBytes: Int64
    private let stopThresholdBytes: Int64
    private let measurementInterval: TimeInterval

    private var lastSnapshot: DiskSpaceSnapshot?
    private var lastMeasuredAt: Date?
    private var estimatedAvailableBytes: Int64?

    init(
        recordsDirectory: URL,
        warningThresholdBytes: Int64 = 2 * 1024 * 1024 * 1024,
        stopThresholdBytes: Int64 = 1 * 1024 * 1024 * 1024,
        measurementInterval: TimeInterval = 5
    ) {
        self.recordsDirectory = recordsDirectory
        self.warningThresholdBytes = warningThresholdBytes
        self.stopThresholdBytes = stopThresholdBytes
        self.measurementInterval = measurementInterval
    }

    func initialCheck() throws -> DiskSpaceSnapshot {
        try FileManager.default.createDirectory(
            at: recordsDirectory,
            withIntermediateDirectories: true
        )

        let snapshot = try measure()
        try ensureSufficientSpace(snapshot)
        return snapshot
    }

    func validateWrite(incomingBytes: Int) throws -> DiskSpaceSnapshot {
        let now = Date()

        if
            let lastMeasuredAt,
            let estimatedAvailableBytes,
            now.timeIntervalSince(lastMeasuredAt) < measurementInterval
        {
            let adjusted = max(0, estimatedAvailableBytes - Int64(incomingBytes))
            let snapshot = DiskSpaceSnapshot(
                availableBytes: adjusted,
                warningThresholdBytes: warningThresholdBytes,
                stopThresholdBytes: stopThresholdBytes
            )
            self.estimatedAvailableBytes = adjusted
            self.lastSnapshot = snapshot
            try ensureSufficientSpace(snapshot)
            return snapshot
        }

        let snapshot = try measure()
        let adjusted = max(0, snapshot.availableBytes - Int64(incomingBytes))
        let adjustedSnapshot = DiskSpaceSnapshot(
            availableBytes: adjusted,
            warningThresholdBytes: warningThresholdBytes,
            stopThresholdBytes: stopThresholdBytes
        )
        self.lastSnapshot = adjustedSnapshot
        self.lastMeasuredAt = now
        self.estimatedAvailableBytes = adjusted
        try ensureSufficientSpace(adjustedSnapshot)
        return adjustedSnapshot
    }

    private func measure() throws -> DiskSpaceSnapshot {
        let values = try recordsDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])

        let availableBytes = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)

        guard let availableBytes else {
            throw DiskSpaceMonitorError.unavailable(recordsDirectory)
        }

        let snapshot = DiskSpaceSnapshot(
            availableBytes: availableBytes,
            warningThresholdBytes: warningThresholdBytes,
            stopThresholdBytes: stopThresholdBytes
        )
        return snapshot
    }

    private func ensureSufficientSpace(_ snapshot: DiskSpaceSnapshot) throws {
        if snapshot.shouldStop {
            throw DiskSpaceMonitorError.lowDiskSpace(
                availableBytes: snapshot.availableBytes,
                stopThresholdBytes: snapshot.stopThresholdBytes
            )
        }
    }
}

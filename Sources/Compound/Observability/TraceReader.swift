import Foundation

/// Reads back what ``JSONLTracer`` wrote: JSON Lines in, ``TraceRecord``
/// values out. This is the other half of the trace round-trip — without
/// it a trace file is write-only and a run cannot be reconstructed,
/// replayed, or diffed after the fact.
///
/// Reading is deliberately *tolerant*. A trace is a forensic artifact
/// collected from a device that may have been killed mid-write, and it
/// may have been produced by a newer build:
/// - Lines that fail to decode (truncated tail, corrupted bytes, a
///   record missing `ts`) are skipped and counted in
///   ``Batch/skippedLines``, never thrown.
/// - Lines whose `type` this build does not recognize decode as
///   ``TraceEvent/unknown(runID:label:payload:)`` rather than being
///   dropped (see `TraceCoding.swift`).
/// Only I/O errors — a missing or unreadable file — are thrown.
///
/// # Example
/// ```swift
/// let batch = try TraceReader.read(fileURL: url)
/// let run = batch.records.filter { $0.runID == id }
/// ```
public enum TraceReader {
    /// Outcome of a read: what decoded, and how much did not.
    public struct Batch: Sendable, Equatable {
        /// Records in file order (oldest first).
        public var records: [TraceRecord]
        /// Number of non-empty lines that could not be decoded.
        public var skippedLines: Int

        /// Creates a batch.
        public init(records: [TraceRecord] = [], skippedLines: Int = 0) {
            self.records = records
            self.skippedLines = skippedLines
        }

        /// The decoded events, timestamps stripped.
        public var events: [TraceEvent] { records.map(\.event) }

        /// Records belonging to a single run, in file order.
        public func records(for runID: UUID) -> [TraceRecord] {
            records.filter { $0.runID == runID }
        }

        /// Concatenates two batches, summing their skip counts.
        public static func + (lhs: Batch, rhs: Batch) -> Batch {
            Batch(records: lhs.records + rhs.records, skippedLines: lhs.skippedLines + rhs.skippedLines)
        }
    }

    /// Decodes JSONL `data` in memory.
    public static func decode(_ data: Data) -> Batch {
        let decoder = JSONDecoder()
        var batch = Batch()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            // A line of only whitespace (or a stray carriage return) is
            // padding, not corruption — do not count it as skipped.
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
            if let record = try? decoder.decode(TraceRecord.self, from: Data(line)) {
                batch.records.append(record)
            } else {
                batch.skippedLines += 1
            }
        }
        return batch
    }

    /// Reads and decodes a single JSONL trace file.
    ///
    /// - Throws: Any error from reading `fileURL`.
    public static func read(fileURL: URL) throws -> Batch {
        decode(try Data(contentsOf: fileURL))
    }

    /// Reads a rotated trace set — `base.N` … `base.1`, then `base` —
    /// concatenated oldest-first so the result is one chronological
    /// timeline across rotations. Missing generations are skipped.
    ///
    /// - Parameters:
    ///   - baseURL: The current (unrotated) file URL handed to ``JSONLTracer``.
    ///   - maxFiles: Total generations to look for, matching the tracer's
    ///     ``JSONLTracer/init(fileURL:flushPolicy:maxFileBytes:maxFiles:)``.
    /// - Throws: Any error from reading a file that exists.
    public static func readRotated(
        baseURL: URL,
        maxFiles: Int = JSONLTracer.defaultMaxFiles
    ) throws -> Batch {
        var batch = Batch()
        var generation = max(1, maxFiles) - 1
        while generation >= 1 {
            let url = JSONLTracer.archiveURL(base: baseURL, generation: generation)
            if FileManager.default.fileExists(atPath: url.path) {
                batch = batch + (try read(fileURL: url))
            }
            generation -= 1
        }
        if FileManager.default.fileExists(atPath: baseURL.path) {
            batch = batch + (try read(fileURL: baseURL))
        }
        return batch
    }
}

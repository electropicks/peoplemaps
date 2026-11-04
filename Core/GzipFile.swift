import CZlib
import Foundation

/// Gzip on files, in fixed-size chunks, so a 165 MB search index never sits in memory (`Data.gunzipped()` is for the small bundled ones).
public enum GzipFile {
    public enum Failure: Error, Equatable, Sendable { case notGzip, corrupt }

    /// Inflates `source` (one gzip member; zlib checks its CRC-32 and length) into `destination`, replacing any file there.
    /// On a failure the partial output is removed.
    public static func gunzip(from source: URL, to destination: URL) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let writer = try FileHandle(forWritingTo: destination)
        var succeeded = false
        defer { try? writer.close(); if !succeeded { try? fm.removeItem(at: destination) } }

        var stream = z_stream()
        // 15 + 16: a gzip header and trailer, which zlib parses and checks.
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.corrupt }
        defer { inflateEnd(&stream) }
        let chunk = 1 << 18
        var output = [UInt8](repeating: 0, count: chunk)
        var first = true, ended = false
        while !ended {
            guard let read = try reader.read(upToCount: chunk), !read.isEmpty else { throw Failure.corrupt }   // ran out before the end
            var input = Data(read)
            if first {
                guard input.count >= 2, input[0] == 0x1F, input[1] == 0x8B else { throw Failure.notGzip }
                first = false
            }
            try input.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                stream.next_in = raw.bindMemory(to: UInt8.self).baseAddress
                stream.avail_in = UInt32(raw.count)
                repeat {
                    let produced: Int = try output.withUnsafeMutableBufferPointer { out in
                        stream.next_out = out.baseAddress
                        stream.avail_out = UInt32(chunk)
                        let status = inflate(&stream, Z_NO_FLUSH)
                        guard status == Z_OK || status == Z_STREAM_END else { throw Failure.corrupt }
                        if status == Z_STREAM_END { ended = true }
                        return chunk - Int(stream.avail_out)
                    }
                    if produced > 0 { try writer.write(contentsOf: Data(output[0..<produced])) }
                } while stream.avail_in > 0 && !ended
            }
        }
        succeeded = true
    }
}

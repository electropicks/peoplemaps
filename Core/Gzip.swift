import CZlib
import Foundation

extension Data {
    /// Inflates a single-member gzip file (RFC 1952) with zlib; the gzip header is parsed here and the body inflated as raw deflate.
    /// The trailer's size field sizes the output; a short or corrupt stream returns nil.
    func gunzipped() -> Data? {
        guard count >= 18, self[startIndex] == 0x1F, self[startIndex + 1] == 0x8B, self[startIndex + 2] == 8 else { return nil }
        let bytes = [UInt8](self)
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { guard offset + 2 <= bytes.count else { return nil }; offset += 2 + Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {   // file name, comment: zero-terminated
            guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 }   // header CRC
        let trailer = bytes.count - 8
        guard offset < trailer else { return nil }
        let size = (0..<4).reduce(0) { $0 | Int(bytes[trailer + 4 + $1]) << (8 * $1) }
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written: Int = output.withUnsafeMutableBytes { out in
            bytes.withUnsafeBufferPointer { input in
                var stream = z_stream()
                guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return -1 }
                defer { inflateEnd(&stream) }
                stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress! + offset)
                stream.avail_in = UInt32(trailer - offset)
                stream.next_out = out.bindMemory(to: UInt8.self).baseAddress!
                stream.avail_out = UInt32(size)
                return inflate(&stream, Z_FINISH) == Z_STREAM_END ? Int(stream.total_out) : -1
            }
        }
        return written == size ? output : nil
    }
}

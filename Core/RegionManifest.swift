import Foundation

public typealias RegionID = String

/// `Data/regions.json` as the app bundle ships it: the release, and for each region its box, files and which of them the importer writes.
/// Only a region's outputs (`expected/<output>`) are downloaded; the inputs never are.
public struct RegionManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let bytes: Int64
        public let sha256: String
        public init(bytes: Int64, sha256: String) { self.bytes = bytes; self.sha256 = sha256 }
    }
    public struct Region: Codable, Equatable, Sendable {
        public let bbox: [Double]
        public let files: [String: File]
        public let outputs: [String]
        public init(bbox: [Double], files: [String: File], outputs: [String]) { self.bbox = bbox; self.files = files; self.outputs = outputs }

        /// The files to download, by path in the manifest (`expected/seattle-graph.bin`), sorted. An output the manifest has no pin for is left out,
        /// which `isDownloadable` reports.
        public var downloads: [(path: String, file: File)] {
            outputs.compactMap { name in files["expected/" + name].map { ("expected/" + name, $0) } }.sorted { $0.path < $1.path }
        }
        /// False until every output is pinned (a region the importer has not published yet has none).
        public var isDownloadable: Bool { !outputs.isEmpty && outputs.allSatisfy { files["expected/" + $0] != nil } }
        /// What the download transfers.
        public var downloadBytes: Int64 { downloads.reduce(0) { $0 + $1.file.bytes } }
        /// An estimate of the space the region takes once installed. The search index arrives gzipped and is inflated; the rest is kept as sent.
        /// `searchInflateRatio` is measured on the bundled Seattle index, so this is "about", not a measurement of the county files.
        public var installedBytesEstimate: Int64 {
            downloads.reduce(0) { $0 + ($1.path.hasSuffix(".gz") ? Int64(Double($1.file.bytes) * RegionManifest.searchInflateRatio) : $1.file.bytes) }
        }
    }

    public let release: String
    public let regions: [String: Region]
    public init(release: String, regions: [String: Region]) { self.release = release; self.regions = regions }

    /// The bundled Seattle index: 14,675,968 bytes inflated from 4,426,173 gzipped (`gzip -l Core/Resources/seattle-search.sqlite.gz`).
    public static let searchInflateRatio = 14_675_968.0 / 4_426_173.0

    /// Unknown keys in the file (`coverage`, inputs' extra fields) are ignored.
    public init(json: Data) throws { self = try JSONDecoder().decode(Self.self, from: json) }

    /// `regions.json` from the app bundle (the generated project copies `Data/regions.json` in); nil when this build has none.
    public static func bundled() -> RegionManifest? {
        Bundle.main.url(forResource: "regions", withExtension: "json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? RegionManifest(json: $0) }
    }

    /// The object's name in the bucket and on the wire: `<region>--<path with / as __>`, as `Scripts/fetch_data` keys it.
    public static func objectName(region: RegionID, file: String) -> String { region + "--" + file.replacingOccurrences(of: "/", with: "__") }

    /// "232.3 MB", the way the offer card says it (decimal megabytes, as the manifest counts).
    public static func sizeLabel(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// "350 MB": rounded to the nearest 10 MB since it is an estimate, once it is big enough for that to mean something.
    public static func roughSizeLabel(_ bytes: Int64) -> String {
        bytes < 50_000_000 ? sizeLabel(bytes) : sizeLabel((bytes + 5_000_000) / 10_000_000 * 10_000_000)
    }
}

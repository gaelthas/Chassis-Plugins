import CryptoKit
import Foundation

/// 生成插件市场索引。
///
/// 用法：
///   swift make-index.swift --dist ../Examples/dist --out-dir packages --base https://example.com/plugins
///   swift make-index.swift --generate-key .market-key
///
/// 产物：
///   <out-dir>/<id>-<version>.zip   分发包（保留 .chassisplugin 目录结构）
///   Market/index.json              { payload, signature } 或未签名索引（开发期）
struct PackageManifest: Decodable {
    struct LocalizedText: Decodable {
        let values: [String: String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                values = ["en": single]
            } else {
                values = try container.decode([String: String].self)
            }
        }

        func resolve() -> String {
            values["zh-Hans"] ?? values["en"] ?? values.values.first ?? ""
        }
    }

    let id: String
    let version: String
    let minHostVersion: String
    let apiVersion: Int?
    let title: LocalizedText
    let summary: LocalizedText
    let vendor: String?
    let requiredCapabilities: [String]?
    let optionalCapabilities: [String]?
}

struct IndexPlugin: Encodable {
    let id: String
    let name: String
    let summary: String
    let version: String
    let minHostVersion: String
    let apiVersion: Int
    let downloadURL: String
    let sha256: String
    let size: Int
    let vendor: String?
    let requiredCapabilities: [String]
    let optionalCapabilities: [String]
}

struct IndexPayload: Encodable {
    let schema: Int
    let generatedAt: Date
    let plugins: [IndexPlugin]
}

let arguments = CommandLine.arguments
func value(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if let keyPath = value("--generate-key") {
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.base64EncodedString().write(
        toFile: keyPath, atomically: true, encoding: .utf8
    )
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
    print("已生成签名私钥：\(keyPath)")
    print("公钥（写入基座 Info.plist 的 ChassisMarketplacePublicKey）：")
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}

let scriptDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let dist = URL(fileURLWithPath: value("--dist") ?? "../Examples/dist", relativeTo: scriptDirectory)
let outDir = URL(fileURLWithPath: value("--out-dir") ?? "Market/packages", relativeTo: scriptDirectory)
let base = value("--base") ?? "file://\(outDir.path)"
let outFile = URL(fileURLWithPath: value("--out") ?? "Market/index.json", relativeTo: scriptDirectory)

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func sha256Hex(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func zip(bundle: URL, to destination: URL) throws {
    try? FileManager.default.removeItem(at: destination)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", bundle.path, destination.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "make-index", code: 1, userInfo: [NSLocalizedDescriptionKey: "ditto 打包失败：\(bundle.lastPathComponent)"])
    }
}

let candidates = (try FileManager.default.contentsOfDirectory(at: dist, includingPropertiesForKeys: nil))
    .filter { $0.pathExtension == "chassisplugin" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !candidates.isEmpty else {
    FileHandle.standardError.write(Data("未在 \(dist.path) 找到 .chassisplugin\n".utf8))
    exit(1)
}

var plugins: [IndexPlugin] = []
for bundle in candidates {
    let manifestCandidates = [
        bundle.appendingPathComponent("Contents/Resources/manifest.json"),
        bundle.appendingPathComponent("Contents/manifest.json"),
    ]
    guard let manifestURL = manifestCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
        FileHandle.standardError.write(Data("跳过 \(bundle.lastPathComponent)：缺少 manifest.json\n".utf8))
        continue
    }
    let manifest = try JSONDecoder().decode(PackageManifest.self, from: Data(contentsOf: manifestURL))

    let archiveName = "\(manifest.id)-\(manifest.version).zip"
    let archive = outDir.appendingPathComponent(archiveName)
    try zip(bundle: bundle, to: archive)
    let digest = try sha256Hex(archive)
    let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.intValue ?? 0

    plugins.append(
        IndexPlugin(
            id: manifest.id,
            name: manifest.title.resolve(),
            summary: manifest.summary.resolve(),
            version: manifest.version,
            minHostVersion: manifest.minHostVersion,
            apiVersion: manifest.apiVersion ?? 1,
            downloadURL: "\(base)/\(archiveName)",
            sha256: digest,
            size: size,
            vendor: manifest.vendor,
            requiredCapabilities: manifest.requiredCapabilities ?? [],
            optionalCapabilities: manifest.optionalCapabilities ?? []
        )
    )
    print("已收录 \(manifest.id) v\(manifest.version)（\(archiveName)，sha256=\(digest.prefix(12))…）")
}

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let payloadData = try encoder.encode(IndexPayload(schema: 1, generatedAt: Date(), plugins: plugins))
let payload = String(decoding: payloadData, as: UTF8.self)

let keyPath = value("--key") ?? ".market-key"
if FileManager.default.fileExists(atPath: keyPath),
   let keyText = try? String(contentsOfFile: keyPath, encoding: .utf8),
   let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)) {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    let signature = try key.signature(for: Data(payload.utf8))
    let envelope: [String: String] = ["payload": payload, "signature": signature.base64EncodedString()]
    let data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: outFile)
    print("已写入签名索引：\(outFile.path)")
} else {
    try payloadData.write(to: outFile)
    print("⚠️  未找到签名私钥（\(keyPath)），写入未签名索引：\(outFile.path)")
    print("    DEBUG 构建 + 本地地址可用；正式分发必须签名。")
}

import CryptoKit
import Foundation

/// 从 Manifests + Market/packages 生成插件市场索引。
///
/// 用法：
///   swift make-index.swift --manifests ../Manifests --packages packages \
///         --base https://raw.githubusercontent.com/gaelthas/Chassis-Plugins/main/Market/packages \
///         --out index.json --key .market-key
///
/// 每个插件在索引里只出现「Manifests 里声明的版本」一次；只更新一个插件时，
/// 只有它的 version/sha256/downloadURL 变化，其余条目原样复用旧的包文件。
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

let scriptDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

if let keyPath = value("--generate-key") {
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.base64EncodedString().write(toFile: keyPath, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
    print("已生成签名私钥：\(keyPath)")
    print("公钥（写入基座 Info.plist 的 ChassisMarketplacePublicKey）：")
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}

/// 显式传入的路径按当前工作目录解析；默认值按脚本所在目录解析（方便独立使用）。
func resolvePath(_ explicit: String?, defaultPath: String) -> URL {
    if let explicit {
        return explicit.hasPrefix("/")
            ? URL(fileURLWithPath: explicit)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(explicit)
    }
    return URL(fileURLWithPath: defaultPath, relativeTo: scriptDirectory)
}

let manifestsDir = resolvePath(value("--manifests"), defaultPath: "../Manifests")
let packagesDir = resolvePath(value("--packages"), defaultPath: "packages")
let base = (value("--base") ?? "https://raw.githubusercontent.com/gaelthas/Chassis-Plugins/main/Market/packages")
    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
let outFile = resolvePath(value("--out"), defaultPath: "index.json")
let keyPath = value("--key") ?? ".market-key"

func sha256Hex(_ url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

let manifestFiles = (try FileManager.default.contentsOfDirectory(at: manifestsDir, includingPropertiesForKeys: nil))
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !manifestFiles.isEmpty else {
    FileHandle.standardError.write(Data("未在 \(manifestsDir.path) 找到清单\n".utf8))
    exit(1)
}

var plugins: [IndexPlugin] = []
var missing: [String] = []

for file in manifestFiles {
    let manifest = try JSONDecoder().decode(PackageManifest.self, from: Data(contentsOf: file))
    let archiveName = "\(manifest.id)-\(manifest.version).zip"
    let archive = packagesDir.appendingPathComponent(archiveName)
    guard FileManager.default.fileExists(atPath: archive.path) else {
        missing.append(archiveName)
        continue
    }

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
    print("收录 \(manifest.id) v\(manifest.version)（\(archiveName)）")
}

if !missing.isEmpty {
    FileHandle.standardError.write(Data("缺少包文件：\(missing.joined(separator: ", "))\n".utf8))
    exit(1)
}

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let payloadData = try encoder.encode(IndexPayload(schema: 1, generatedAt: Date(), plugins: plugins))
let payload = String(decoding: payloadData, as: UTF8.self)

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
}

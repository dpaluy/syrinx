import CryptoKit
import CoreFoundation
import Foundation

public enum ModelManifestError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidJSON
    case unsupportedSchema(Int)
    case incompatibleModel
    case invalidImmutableCommit
    case incompatibleFluidAudio
    case unsafeRepositoryFolder
    case invalidPath(String)
    case duplicatePath(String)
    case duplicateURL
    case mutableOrWrongCommitURL(String)
    case invalidSHA256(String)
    case invalidFileSize(String)
    case invalidFileCount(expected: Int, actual: Int)
    case invalidTotalSize(expected: Int64, actual: Int64)
    case invalidManifestDigest

    public var description: String {
        switch self {
        case .invalidJSON:
            return "model manifest is not valid JSON"
        case let .unsupportedSchema(schema):
            return "unsupported model manifest schema \(schema)"
        case .incompatibleModel:
            return "model manifest is not for the supported Parakeet v3 int8 model"
        case .invalidImmutableCommit:
            return "model manifest has an invalid immutable model commit"
        case .incompatibleFluidAudio:
            return "model manifest is not compatible with the supported FluidAudio revision"
        case .unsafeRepositoryFolder:
            return "model manifest has an unsafe repository folder"
        case let .invalidPath(path):
            return "model manifest has an invalid relative path: \(Self.redactedPath(path))"
        case let .duplicatePath(path):
            return "model manifest has a duplicate relative path: \(Self.redactedPath(path))"
        case .duplicateURL:
            return "model manifest has duplicate download URLs"
        case let .mutableOrWrongCommitURL(path):
            return "model manifest has a mutable or wrong-commit URL for \(Self.redactedPath(path))"
        case let .invalidSHA256(path):
            return "model manifest has an invalid SHA-256 for \(Self.redactedPath(path))"
        case let .invalidFileSize(path):
            return "model manifest has an invalid file size for \(Self.redactedPath(path))"
        case let .invalidFileCount(expected, actual):
            return "model manifest file count is \(actual), expected \(expected)"
        case let .invalidTotalSize(expected, actual):
            return "model manifest total size is \(actual), expected \(expected)"
        case .invalidManifestDigest:
            return "model manifest content digest does not match"
        }
    }

    private static func redactedPath(_ path: String) -> String {
        path.hasPrefix("/") ? "<redacted>" : path
    }
}

public struct ModelManifest: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public let relativePath: String
        public let size: Int64
        public let sha256: String
        public let url: String
        public let hashVerification: HashVerification

        fileprivate init(
            relativePath: String,
            size: Int64,
            sha256: String,
            url: String,
            hashVerification: HashVerification
        ) {
            self.relativePath = relativePath
            self.size = size
            self.sha256 = sha256
            self.url = url
            self.hashVerification = hashVerification
        }

        public struct HashVerification: Equatable, Sendable {
            public let status: String
            public let method: String
            public let repositoryOid: String
            public let repositoryOidAlgorithm: String
            public let lfsObjectSha256: String?
            public let lfsObjectMatchesLocalSha256: Bool?

            fileprivate init(
                status: String,
                method: String,
                repositoryOid: String,
                repositoryOidAlgorithm: String,
                lfsObjectSha256: String?,
                lfsObjectMatchesLocalSha256: Bool?
            ) {
                self.status = status
                self.method = method
                self.repositoryOid = repositoryOid
                self.repositoryOidAlgorithm = repositoryOidAlgorithm
                self.lfsObjectSha256 = lfsObjectSha256
                self.lfsObjectMatchesLocalSha256 = lfsObjectMatchesLocalSha256
            }
        }
    }

    public struct FluidAudioCompatibility: Equatable, Sendable {
        public let version: String
        public let commit: String
        public let commitUrl: String
        public let swiftToolsVersion: String
        public let platform: String
        public let architecture: String
        public let asrVersion: String
        public let encoderPrecision: String
        public let requiredArtifacts: [String]
        public let sourceAuthority: String
    }

    public struct License: Equatable, Sendable {
        public let spdx: String
        public let declaredBy: String
        public let modelCardUrl: String
        public let modelCardTextLicense: String
        public let apiLicenseField: String?
        public let reviewStatus: String
    }

    public struct Attribution: Equatable, Sendable {
        public let publisher: String
        public let model: String
        public let baseModel: String
        public let datasets: [String]
        public let notice: String
        public let sourceUrl: String
    }

    public struct Staging: Equatable, Sendable {
        public let modelsRoot: String
        public let repositoryFolder: String
        public let loadArgument: String
        public let layout: String
        public let callerMustPassRepositoryFolder: Bool
        public let symlinksAllowed: Bool
        public let extraFilesAllowed: Bool
        public let pathRule: String
        public let sourceEvidence: [String: String]
    }

    public struct HashVerificationSummary: Equatable, Sendable {
        public let fileCount: Int
        public let locallyVerifiedCount: Int
        public let metadataOnlyCount: Int
        public let lfsObjectMatchCount: Int
        public let downloadedOnce: Bool
        public let sizeMatchesForAllFiles: Bool
        public let releaseGate: String
    }

    public struct ManifestContentDigest: Equatable, Sendable {
        public let algorithm: String
        public let hex: String
        public let procedure: String
        public let selfExclusion: String
    }

    public struct ReleaseGate: Equatable, Sendable {
        public let status: String
        public let reasons: [String]
    }

    public let schemaVersion: Int
    public let status: String
    public let modelId: String
    public let variantId: String
    public let repository: String
    public let immutableCommit: String
    public let repositoryCommitUrl: String
    public let fluidAudioCompatibility: FluidAudioCompatibility
    public let license: License
    public let attribution: Attribution
    public let staging: Staging
    public let files: [File]
    public let totalSize: Int64
    public let hashVerificationSummary: HashVerificationSummary
    public let manifestContentDigest: ManifestContentDigest
    public let releaseGate: ReleaseGate

    fileprivate struct Payload: Decodable {
        fileprivate struct RawHashVerification: Decodable {
            fileprivate let status: String
            fileprivate let method: String
            fileprivate let repositoryOid: String
            fileprivate let repositoryOidAlgorithm: String
            fileprivate let lfsObjectSha256: String?
            fileprivate let lfsObjectMatchesLocalSha256: Bool?
        }

        fileprivate struct RawFile: Decodable {
            fileprivate let relativePath: String
            fileprivate let size: Int64
            fileprivate let sha256: String
            fileprivate let url: String
            fileprivate let hashVerification: RawHashVerification
        }

        fileprivate struct RawFluidAudioCompatibility: Decodable {
            fileprivate let version: String
            fileprivate let commit: String
            fileprivate let commitUrl: String
            fileprivate let swiftToolsVersion: String
            fileprivate let platform: String
            fileprivate let architecture: String
            fileprivate let asrVersion: String
            fileprivate let encoderPrecision: String
            fileprivate let requiredArtifacts: [String]
            fileprivate let sourceAuthority: String
        }

        fileprivate struct RawLicense: Decodable {
            fileprivate let spdx: String
            fileprivate let declaredBy: String
            fileprivate let modelCardUrl: String
            fileprivate let modelCardTextLicense: String
            fileprivate let apiLicenseField: String?
            fileprivate let reviewStatus: String
        }

        fileprivate struct RawAttribution: Decodable {
            fileprivate let publisher: String
            fileprivate let model: String
            fileprivate let baseModel: String
            fileprivate let datasets: [String]
            fileprivate let notice: String
            fileprivate let sourceUrl: String
        }

        fileprivate struct RawStaging: Decodable {
            fileprivate let modelsRoot: String
            fileprivate let repositoryFolder: String
            fileprivate let loadArgument: String
            fileprivate let layout: String
            fileprivate let callerMustPassRepositoryFolder: Bool
            fileprivate let symlinksAllowed: Bool
            fileprivate let extraFilesAllowed: Bool
            fileprivate let pathRule: String
            fileprivate let sourceEvidence: [String: String]
        }

        fileprivate struct RawHashVerificationSummary: Decodable {
            fileprivate let fileCount: Int
            fileprivate let locallyVerifiedCount: Int
            fileprivate let metadataOnlyCount: Int
            fileprivate let lfsObjectMatchCount: Int
            fileprivate let downloadedOnce: Bool
            fileprivate let sizeMatchesForAllFiles: Bool
            fileprivate let releaseGate: String
        }

        fileprivate struct RawManifestContentDigest: Decodable {
            fileprivate let algorithm: String
            fileprivate let hex: String
            fileprivate let procedure: String
            fileprivate let selfExclusion: String
        }

        fileprivate struct RawReleaseGate: Decodable {
            fileprivate let status: String
            fileprivate let reasons: [String]
        }

        fileprivate let schemaVersion: Int
        fileprivate let status: String
        fileprivate let modelId: String
        fileprivate let variantId: String
        fileprivate let repository: String
        fileprivate let immutableCommit: String
        fileprivate let repositoryCommitUrl: String
        fileprivate let fluidAudioCompatibility: RawFluidAudioCompatibility
        fileprivate let license: RawLicense
        fileprivate let attribution: RawAttribution
        fileprivate let staging: RawStaging
        fileprivate let files: [RawFile]
        fileprivate let totalSize: Int64
        fileprivate let hashVerificationSummary: RawHashVerificationSummary
        fileprivate let manifestContentDigest: RawManifestContentDigest
        fileprivate let releaseGate: RawReleaseGate
    }

    public init(data: Data) throws {
        let decoder = JSONDecoder()
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            throw ModelManifestError.invalidJSON
        }

        schemaVersion = payload.schemaVersion
        status = payload.status
        modelId = payload.modelId
        variantId = payload.variantId
        repository = payload.repository
        immutableCommit = payload.immutableCommit
        repositoryCommitUrl = payload.repositoryCommitUrl
        fluidAudioCompatibility = FluidAudioCompatibility(
            version: payload.fluidAudioCompatibility.version,
            commit: payload.fluidAudioCompatibility.commit,
            commitUrl: payload.fluidAudioCompatibility.commitUrl,
            swiftToolsVersion: payload.fluidAudioCompatibility.swiftToolsVersion,
            platform: payload.fluidAudioCompatibility.platform,
            architecture: payload.fluidAudioCompatibility.architecture,
            asrVersion: payload.fluidAudioCompatibility.asrVersion,
            encoderPrecision: payload.fluidAudioCompatibility.encoderPrecision,
            requiredArtifacts: payload.fluidAudioCompatibility.requiredArtifacts,
            sourceAuthority: payload.fluidAudioCompatibility.sourceAuthority
        )
        license = License(
            spdx: payload.license.spdx,
            declaredBy: payload.license.declaredBy,
            modelCardUrl: payload.license.modelCardUrl,
            modelCardTextLicense: payload.license.modelCardTextLicense,
            apiLicenseField: payload.license.apiLicenseField,
            reviewStatus: payload.license.reviewStatus
        )
        attribution = Attribution(
            publisher: payload.attribution.publisher,
            model: payload.attribution.model,
            baseModel: payload.attribution.baseModel,
            datasets: payload.attribution.datasets,
            notice: payload.attribution.notice,
            sourceUrl: payload.attribution.sourceUrl
        )
        staging = Staging(
            modelsRoot: payload.staging.modelsRoot,
            repositoryFolder: payload.staging.repositoryFolder,
            loadArgument: payload.staging.loadArgument,
            layout: payload.staging.layout,
            callerMustPassRepositoryFolder: payload.staging.callerMustPassRepositoryFolder,
            symlinksAllowed: payload.staging.symlinksAllowed,
            extraFilesAllowed: payload.staging.extraFilesAllowed,
            pathRule: payload.staging.pathRule,
            sourceEvidence: payload.staging.sourceEvidence
        )
        files = payload.files.map { file in
            File(
                relativePath: file.relativePath,
                size: file.size,
                sha256: file.sha256,
                url: file.url,
                hashVerification: File.HashVerification(
                    status: file.hashVerification.status,
                    method: file.hashVerification.method,
                    repositoryOid: file.hashVerification.repositoryOid,
                    repositoryOidAlgorithm: file.hashVerification.repositoryOidAlgorithm,
                    lfsObjectSha256: file.hashVerification.lfsObjectSha256,
                    lfsObjectMatchesLocalSha256: file.hashVerification.lfsObjectMatchesLocalSha256
                )
            )
        }
        totalSize = payload.totalSize
        hashVerificationSummary = HashVerificationSummary(
            fileCount: payload.hashVerificationSummary.fileCount,
            locallyVerifiedCount: payload.hashVerificationSummary.locallyVerifiedCount,
            metadataOnlyCount: payload.hashVerificationSummary.metadataOnlyCount,
            lfsObjectMatchCount: payload.hashVerificationSummary.lfsObjectMatchCount,
            downloadedOnce: payload.hashVerificationSummary.downloadedOnce,
            sizeMatchesForAllFiles: payload.hashVerificationSummary.sizeMatchesForAllFiles,
            releaseGate: payload.hashVerificationSummary.releaseGate
        )
        manifestContentDigest = ManifestContentDigest(
            algorithm: payload.manifestContentDigest.algorithm,
            hex: payload.manifestContentDigest.hex,
            procedure: payload.manifestContentDigest.procedure,
            selfExclusion: payload.manifestContentDigest.selfExclusion
        )
        releaseGate = ReleaseGate(
            status: payload.releaseGate.status,
            reasons: payload.releaseGate.reasons
        )

        try validate(data: data)
    }

    // Internal test-only initializer. Production construction remains validated by init(data:).
    internal init(
        testFiles: [(relativePath: String, data: Data)],
        baseURL: String,
        immutableCommit: String = ModelManifest.supportedImmutableCommit
    ) {
        self.init(testingFiles: testFiles, baseURL: baseURL, immutableCommit: immutableCommit)
    }

    @_spi(Testing) public init(
        testingFiles: [(relativePath: String, data: Data)],
        baseURL: String,
        immutableCommit: String = ModelManifest.supportedImmutableCommit
    ) {
        schemaVersion = 1
        status = "test"
        modelId = Self.supportedModelID
        variantId = Self.supportedVariantID
        repository = Self.supportedRepository
        self.immutableCommit = immutableCommit
        repositoryCommitUrl = "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/\(immutableCommit)"
        fluidAudioCompatibility = FluidAudioCompatibility(
            version: "0.15.5",
            commit: Self.supportedFluidAudioCommit,
            commitUrl: "https://github.com/FluidInference/FluidAudio/commit/\(Self.supportedFluidAudioCommit)",
            swiftToolsVersion: "6.0",
            platform: "macOS 14+",
            architecture: "Apple Silicon arm64",
            asrVersion: "v3",
            encoderPrecision: "int8",
            requiredArtifacts: Self.supportedArtifactRoots,
            sourceAuthority: "test fixture"
        )
        license = License(spdx: "CC-BY-4.0", declaredBy: "test", modelCardUrl: baseURL, modelCardTextLicense: "test", apiLicenseField: nil, reviewStatus: "test")
        attribution = Attribution(publisher: "test", model: modelId, baseModel: modelId, datasets: [], notice: "test", sourceUrl: baseURL)
        staging = Staging(modelsRoot: "models", repositoryFolder: Self.supportedRepositoryFolder, loadArgument: "repository", layout: "test", callerMustPassRepositoryFolder: true, symlinksAllowed: false, extraFilesAllowed: false, pathRule: "test", sourceEvidence: [:])
        files = testingFiles.map { item in
            File(
                relativePath: item.relativePath,
                size: Int64(item.data.count),
                sha256: SHA256.hash(data: item.data).map { String(format: "%02x", $0) }.joined(),
                url: "\(baseURL)/\(item.relativePath)",
                hashVerification: File.HashVerification(status: "verified", method: "test", repositoryOid: String(repeating: "0", count: 40), repositoryOidAlgorithm: "test", lfsObjectSha256: nil, lfsObjectMatchesLocalSha256: nil)
            )
        }
        totalSize = files.reduce(0) { $0 + $1.size }
        hashVerificationSummary = HashVerificationSummary(fileCount: files.count, locallyVerifiedCount: files.count, metadataOnlyCount: 0, lfsObjectMatchCount: 0, downloadedOnce: false, sizeMatchesForAllFiles: true, releaseGate: "test")
        manifestContentDigest = ManifestContentDigest(algorithm: "SHA-256", hex: String(repeating: "0", count: 64), procedure: "test", selfExclusion: "test")
        releaseGate = ReleaseGate(status: "test", reasons: [])
    }

    public static let supportedModelID = "parakeet-tdt-0.6b-v3"
    public static let supportedVariantID = "int8"
    public static let supportedRepository = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    public static let supportedImmutableCommit = "aed02740059203c4a87495924f685de3722ae9ce"
    public static let supportedFluidAudioCommit = "19600a485baa4998812e4654b70d2bab8f2c9949"
    public static let supportedRepositoryFolder = "parakeet-tdt-0.6b-v3"
    public static let supportedFileCount = 21
    public static let supportedTotalSize: Int64 = 483_105_645

    public static let supportedArtifactRoots = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecisionv3.mlmodelc",
        "parakeet_vocab.json"
    ]

    private static let supportedRelativePaths = Set([
        "Decoder.mlmodelc/analytics/coremldata.bin",
        "Decoder.mlmodelc/coremldata.bin",
        "Decoder.mlmodelc/metadata.json",
        "Decoder.mlmodelc/model.mil",
        "Decoder.mlmodelc/weights/weight.bin",
        "Encoder.mlmodelc/analytics/coremldata.bin",
        "Encoder.mlmodelc/coremldata.bin",
        "Encoder.mlmodelc/metadata.json",
        "Encoder.mlmodelc/model.mil",
        "Encoder.mlmodelc/weights/weight.bin",
        "JointDecisionv3.mlmodelc/analytics/coremldata.bin",
        "JointDecisionv3.mlmodelc/coremldata.bin",
        "JointDecisionv3.mlmodelc/metadata.json",
        "JointDecisionv3.mlmodelc/model.mil",
        "JointDecisionv3.mlmodelc/weights/weight.bin",
        "Preprocessor.mlmodelc/analytics/coremldata.bin",
        "Preprocessor.mlmodelc/coremldata.bin",
        "Preprocessor.mlmodelc/metadata.json",
        "Preprocessor.mlmodelc/model.mil",
        "Preprocessor.mlmodelc/weights/weight.bin",
        "parakeet_vocab.json"
    ])

    public func validate() throws {
        try validate(data: nil)
    }

    private func validate(data: Data?) throws {
        guard schemaVersion == 1 else {
            throw ModelManifestError.unsupportedSchema(schemaVersion)
        }
        guard modelId == Self.supportedModelID,
              variantId == Self.supportedVariantID,
              repository == Self.supportedRepository
        else {
            throw ModelManifestError.incompatibleModel
        }
        guard immutableCommit == Self.supportedImmutableCommit,
              repositoryCommitUrl == "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/\(Self.supportedImmutableCommit)"
        else {
            throw ModelManifestError.invalidImmutableCommit
        }
        guard fluidAudioCompatibility.version == "0.15.5",
              fluidAudioCompatibility.commit == Self.supportedFluidAudioCommit,
              fluidAudioCompatibility.commitUrl == "https://github.com/FluidInference/FluidAudio/commit/\(Self.supportedFluidAudioCommit)",
              fluidAudioCompatibility.swiftToolsVersion == "6.0",
              fluidAudioCompatibility.platform == "macOS 14+",
              fluidAudioCompatibility.architecture == "Apple Silicon arm64",
              fluidAudioCompatibility.asrVersion == "v3",
              fluidAudioCompatibility.encoderPrecision == "int8",
              fluidAudioCompatibility.requiredArtifacts == Self.supportedArtifactRoots,
              fluidAudioCompatibility.sourceAuthority == "AsrModels and ModelNames source at the pinned FluidAudio commit"
        else {
            throw ModelManifestError.incompatibleFluidAudio
        }
        guard staging.repositoryFolder == Self.supportedRepositoryFolder,
              Self.isSafeSinglePathComponent(staging.repositoryFolder),
              staging.symlinksAllowed == false,
              staging.extraFilesAllowed == false
        else {
            throw ModelManifestError.unsafeRepositoryFolder
        }
        guard totalSize == Self.supportedTotalSize else {
            throw ModelManifestError.invalidTotalSize(expected: Self.supportedTotalSize, actual: totalSize)
        }
        guard files.count == Self.supportedFileCount else {
            throw ModelManifestError.invalidFileCount(expected: Self.supportedFileCount, actual: files.count)
        }
        guard hashVerificationSummary.fileCount == files.count,
              hashVerificationSummary.locallyVerifiedCount == files.count,
              hashVerificationSummary.metadataOnlyCount == 0,
              hashVerificationSummary.sizeMatchesForAllFiles
        else {
            throw ModelManifestError.invalidFileCount(
                expected: files.count,
                actual: hashVerificationSummary.fileCount
            )
        }

        var paths = Set<String>()
        var urls = Set<String>()
        var calculatedTotal: Int64 = 0
        for file in files {
            try Self.validate(relativePath: file.relativePath)
            guard paths.insert(file.relativePath).inserted else {
                throw ModelManifestError.duplicatePath(file.relativePath)
            }
            guard urls.insert(file.url).inserted else {
                throw ModelManifestError.duplicateURL
            }
            guard Self.supportedRelativePaths.contains(file.relativePath) else {
                throw ModelManifestError.invalidPath(file.relativePath)
            }
            guard file.size >= 0 else {
                throw ModelManifestError.invalidFileSize(file.relativePath)
            }
            guard Self.isSHA256(file.sha256) else {
                throw ModelManifestError.invalidSHA256(file.relativePath)
            }
            let expectedURL = "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/\(Self.supportedImmutableCommit)/\(file.relativePath)"
            guard file.url == expectedURL else {
                throw ModelManifestError.mutableOrWrongCommitURL(file.relativePath)
            }
            calculatedTotal += file.size
        }
        guard paths == Self.supportedRelativePaths else {
            throw ModelManifestError.invalidPath("required model file set")
        }
        guard calculatedTotal == totalSize else {
            throw ModelManifestError.invalidTotalSize(expected: totalSize, actual: calculatedTotal)
        }

        guard manifestContentDigest.algorithm == "SHA-256",
              Self.isSHA256(manifestContentDigest.hex)
        else {
            throw ModelManifestError.invalidManifestDigest
        }
        if let data {
            guard Self.digest(for: data) == manifestContentDigest.hex else {
                throw ModelManifestError.invalidManifestDigest
            }
        }
    }

    static func validate(relativePath: String) throws {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              !relativePath.contains("\\"),
              !relativePath.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw ModelManifestError.invalidPath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ModelManifestError.invalidPath(relativePath)
        }
    }

    static func isSafeSinglePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
            !value.contains("/") && !value.contains("\\") &&
            !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    static func isAllowedArtifactPath(_ value: String) -> Bool {
        supportedArtifactRoots.contains { root in
            if root == "parakeet_vocab.json" {
                return value == root
            }
            return value == root || value.hasPrefix("\(root)/")
        }
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) ||
                (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    fileprivate static func digest(for data: Data) -> String? {
        guard var object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            return nil
        }
        object.removeValue(forKey: "manifestContentDigest")
        guard let canonical = try? canonicalJSON(object) else {
            return nil
        }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalJSON(_ value: Any) throws -> Data {
        var output = Data()
        try appendCanonicalJSON(value, to: &output)
        return output
    }

    private static func appendCanonicalJSON(_ value: Any, to output: inout Data) throws {
        if let object = value as? [String: Any] {
            output.append(123)
            let keys = object.keys.sorted()
            for (index, key) in keys.enumerated() {
                if index > 0 { output.append(44) }
                appendJSONString(key, to: &output)
                output.append(58)
                guard let child = object[key] else { throw ModelManifestError.invalidJSON }
                try appendCanonicalJSON(child, to: &output)
            }
            output.append(125)
            return
        }
        if let array = value as? [Any] {
            output.append(91)
            for (index, child) in array.enumerated() {
                if index > 0 { output.append(44) }
                try appendCanonicalJSON(child, to: &output)
            }
            output.append(93)
            return
        }
        if let string = value as? String {
            appendJSONString(string, to: &output)
            return
        }
        if value is NSNull {
            output.append(contentsOf: [110, 117, 108, 108])
            return
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                output.append(contentsOf: number.boolValue ? [116, 114, 117, 101] : [102, 97, 108, 115, 101])
                return
            }
            guard let numberData = try? JSONSerialization.data(withJSONObject: [number]),
                  numberData.count >= 2
            else { throw ModelManifestError.invalidJSON }
            output.append(numberData.dropFirst().dropLast())
            return
        }
        throw ModelManifestError.invalidJSON
    }

    private static func appendJSONString(_ string: String, to output: inout Data) {
        output.append(34)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x08:
                output.append(contentsOf: [92, 98])
            case 0x09:
                output.append(contentsOf: [92, 116])
            case 0x0A:
                output.append(contentsOf: [92, 110])
            case 0x0C:
                output.append(contentsOf: [92, 102])
            case 0x0D:
                output.append(contentsOf: [92, 114])
            case 0x00...0x1F:
                let hex = String(format: "%04x", scalar.value)
                output.append(contentsOf: [92, 117])
                output.append(contentsOf: hex.utf8)
            case 0x22, 0x5C:
                output.append(92)
                output.append(UInt8(scalar.value))
            default:
                output.append(contentsOf: String(scalar).utf8)
            }
        }
        output.append(34)
    }
}

public struct ModelFileExpectation: Equatable, Sendable {
    public let relativePath: String
    public let size: Int64
    public let sha256: String

    public init(relativePath: String, size: Int64, sha256: String) {
        self.relativePath = relativePath
        self.size = size
        self.sha256 = sha256
    }
}

public extension ModelManifest.File {
    var expectation: ModelFileExpectation {
        ModelFileExpectation(relativePath: relativePath, size: size, sha256: sha256)
    }
}

import Foundation
import Testing
import TryOmarchyKitClient

struct TryOmarchyKitManifestTests {
    @Test func versionsParseStrictly() {
        #expect(TryOmarchyKitVersion("v1.2.3") == .release(major: 1, minor: 2, patch: 3))
        #expect(TryOmarchyKitVersion("v0.10.0") == .release(major: 0, minor: 10, patch: 0))
        #expect(TryOmarchyKitVersion("development") == .development)
        #expect(TryOmarchyKitVersion("v1.2.3")?.description == "v1.2.3")
        for text in ["1.2.3", "v1.2", "v1.2.3.4", "v01.2.3", "v1..3", "v1.2.3-dirty", "v1.2.-3", "v+1.2.3",
                     "v1234567890.0.0", "v１.2.3", "Development", ""] {
            #expect(TryOmarchyKitVersion(text) == nil, "\(text)")
        }
    }

    @Test func releasesCompareByNumberAndDevelopmentIsNewest() throws {
        let ordered = try ["v0.9.9", "v0.10.0", "v1.0.0", "v1.0.10", "v1.1.0", "v2.0.0", "development"]
            .map { try #require(TryOmarchyKitVersion($0)) }
        for (index, version) in ordered.enumerated() {
            for later in ordered[(index + 1)...] {
                #expect(version < later, "\(version) < \(later)")
            }
        }
        #expect(!(TryOmarchyKitVersion.development < .development))
        #expect(TryOmarchyKitVersion.development.isDevelopment)
        #expect(try #require(TryOmarchyKitVersion("v3.0.0")).isDevelopment == false)
    }

    @Test func kitReadsTheManifestBuildKitWrites() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let kit = TryOmarchyKit.unpacked(in: folder)
        #expect(kit.manifestURL.path == folder.path + "/TryOmarchyKit.bundle/Contents/Resources/kit.json")
        let resources = kit.manifestURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        #expect(throws: TryOmarchyKitManifestError.missing) { try kit.manifest() }
        let written = """
        {
          "format": 1,
          "version": "v1.2.3",
          "runProtocolVersion": \(VMRunProtocol.version),
          "buildDate": "2026-10-23T09:30:05Z",
          "addedLater": {"ignored": true}
        }

        """
        try Data(written.utf8).write(to: kit.manifestURL)
        let manifest = try kit.manifest()
        #expect(manifest.version == .release(major: 1, minor: 2, patch: 3))
        #expect(manifest.runProtocolVersion == VMRunProtocol.version)
        #expect(manifest.isSupported)
        #expect(manifest.buildDate == Date(timeIntervalSince1970: 1_792_747_805))
        #expect(manifest.capabilities.isEmpty)
        #expect(!manifest.supports(.nativeExports))

        try FileManager.default.removeItem(at: kit.manifestURL)
        try FileManager.default.createSymbolicLink(at: kit.manifestURL,
                                                   withDestinationURL: resources.appendingPathComponent("elsewhere.json"))
        #expect(throws: TryOmarchyKitManifestError.invalid) { try kit.manifest() }
    }

    @Test func invalidManifestsAreRejected() throws {
        let valid: [String: Any] = ["format": 1, "version": "development", "runProtocolVersion": 1,
                                    "buildDate": "2026-10-23T09:30:05Z"]
        let validData = try JSONSerialization.data(withJSONObject: valid)
        #expect(try TryOmarchyKitManifest.decode(validData).version == .development)
        let changes: [[String: Any]] = [
            ["format": 2], ["format": true], ["format": "1"],
            ["version": "1.2.3"], ["version": 1],
            ["runProtocolVersion": 0], ["runProtocolVersion": 1.5], ["runProtocolVersion": true],
            ["buildDate": "2026-10-23"], ["buildDate": "2026-10-23T09:30:05.123Z"], ["buildDate": "yesterday"],
            ["capabilities": "native-exports"], ["capabilities": [1]],
        ]
        for change in changes {
            let object = valid.merging(change) { $1 }
            let data = try? JSONSerialization.data(withJSONObject: object)
            #expect(throws: TryOmarchyKitManifestError.invalid) { try TryOmarchyKitManifest.decode(data ?? Data()) }
        }
        for text in ["[]", "not json", ""] {
            #expect(throws: TryOmarchyKitManifestError.invalid) { try TryOmarchyKitManifest.decode(Data(text.utf8)) }
        }
        let protocolTwo = TryOmarchyKitManifest(version: .development, runProtocolVersion: VMRunProtocol.version + 1,
                                                buildDate: Date())
        #expect(!protocolTwo.isSupported)
    }

    @Test func capabilitiesKnownToTheClientAreRead() throws {
        let object: [String: Any] = ["format": 1, "version": "v1.3.1", "runProtocolVersion": 1,
                                     "buildDate": "2026-10-23T09:30:05Z", "capabilities": ["native-exports", "later"]]
        let manifest = try TryOmarchyKitManifest.decode(JSONSerialization.data(withJSONObject: object))
        #expect(manifest.capabilities == [.nativeExports])
        #expect(manifest.supports(.nativeExports))
    }

    @Test func nativeExportsReachOnlyAKitThatListsThem() throws {
        let asked = VMRunConfiguration(productName: "Omarchy", nativeExports: true)
        let listing = TryOmarchyKitManifest(version: .development, runProtocolVersion: VMRunProtocol.version,
                                            buildDate: Date(), capabilities: [.nativeExports])
        let older = TryOmarchyKitManifest(version: .release(major: 1, minor: 3, patch: 0),
                                          runProtocolVersion: VMRunProtocol.version, buildDate: Date())
        #expect(VMRunClient.offered(asked, by: listing).nativeExports)
        #expect(!VMRunClient.offered(asked, by: older).nativeExports)
        #expect(!VMRunClient.offered(asked, by: nil).nativeExports)
        let line = try VMRunClient.offered(asked, by: older).encodedLine()
        #expect(!String(decoding: line, as: UTF8.self).contains("nativeExports"))
    }
}

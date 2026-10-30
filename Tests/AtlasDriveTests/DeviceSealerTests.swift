import AtlasCore
import Foundation
import XCTest
@testable import AtlasDrive

final class DeviceSealerTests: XCTestCase {
    func testSealsAndOpensAndRejectsTheWrongKey() throws {
        let sealer = DeviceSealer(key: DeviceSealer.newKey())!
        let other = DeviceSealer(key: DeviceSealer.newKey())!
        let sealed = try sealer.seal(Data("# Secret\n".utf8))
        XCTAssertNil(sealed.range(of: Data("Secret".utf8)))
        XCTAssertEqual(try sealer.open(sealed), Data("# Secret\n".utf8))
        XCTAssertThrowsError(try other.open(sealed))
        XCTAssertNil(DeviceSealer(key: [1, 2, 3]))
    }

    /// A vault on disk, sealed with it, reopens with its content, and no file shows a title.
    func testAVaultOnDiskReopens() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = DeviceSealer.newKey()
        do {
            let vault = try Vault(storage: try SealedDiskStorage(directory: dir, sealedWith: DeviceSealer(key: key)!))
            try vault.write(text: "# Roadmap\n", at: "Projects/Roadmap.md")
        }
        let reopened = try Vault(storage: try SealedDiskStorage(directory: dir, sealedWith: DeviceSealer(key: key)!))
        XCTAssertEqual(try reopened.text(at: "Projects/Roadmap.md"), "# Roadmap\n")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let bytes = try Data(contentsOf: dir.appendingPathComponent(name))
            XCTAssertNil(bytes.range(of: Data("Roadmap".utf8)), "\(name) shows the title")
        }
    }
}

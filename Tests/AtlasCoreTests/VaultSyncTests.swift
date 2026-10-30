import CryptoKit
import Foundation
import XCTest
@testable import AtlasCore

/// An in-memory Drive with Drive's semantics: `content_version` bumps on every content write,
/// guarded writes fail with `.conflict` when stale, and missing files are `.notFound`.
/// `failEvery` makes every n-th call throw a network error, to interrupt syncs mid-pass.
final class FakeDrive: VaultRemote {
    struct File { var path: String; var data: Data; var version: Int }
    private(set) var files: [String: File] = [:]
    private var nextID = 1
    var failEvery: Int?
    private var calls = 0

    private func maybeFail() throws {
        calls += 1
        if let n = failEvery, calls % n == 0 { throw URLError(.networkConnectionLost) }
    }

    func list() async throws -> [RemoteFile] {
        try maybeFail()
        return files.map { RemoteFile(id: $0.key, path: $0.value.path, version: $0.value.version) }.sorted { $0.id < $1.id }
    }

    func download(_ id: String) async throws -> (data: Data, version: Int) {
        try maybeFail()
        guard let f = files[id] else { throw VaultRemoteError.notFound }
        return (f.data, f.version)
    }

    func create(at path: String, data: Data) async throws -> RemoteFile {
        try maybeFail()
        let id = "f\(nextID)"
        nextID += 1
        files[id] = File(path: path, data: data, version: 1)
        return RemoteFile(id: id, path: path, version: 1)
    }

    func replace(_ id: String, data: Data, expectedVersion: Int) async throws -> Int {
        try maybeFail()
        guard var f = files[id] else { throw VaultRemoteError.notFound }
        guard f.version == expectedVersion else { throw VaultRemoteError.conflict }
        f.data = data
        f.version += 1
        files[id] = f
        return f.version
    }

    func move(_ id: String, to path: String) async throws {
        try maybeFail()
        guard files[id] != nil else { throw VaultRemoteError.notFound }
        files[id]!.path = path
    }

    func delete(_ id: String) async throws {
        try maybeFail()
        guard files.removeValue(forKey: id) != nil else { throw VaultRemoteError.notFound }
    }

    /// What the server holds, as path → text.
    /// What the server holds, as path → text. Two files at one path show as a "DUPLICATE" value,
    /// so a test fails rather than crashes.
    var snapshot: [String: String] {
        Dictionary(files.values.map { ($0.path, String(decoding: $0.data, as: UTF8.self)) }, uniquingKeysWith: { _, _ in "DUPLICATE" })
    }
}

private struct TestSealer: IndexSealer {
    let key = SymmetricKey(size: .bits256)
    func seal(_ plaintext: Data) throws -> Data { try ChaChaPoly.seal(plaintext, using: key).combined }
    func open(_ sealed: Data) throws -> Data { try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key) }
}

final class VaultSyncTests: XCTestCase {
    private func device(_ drive: FakeDrive) throws -> VaultSync {
        var sync = VaultSync(vault: try Vault(storage: MemoryStorage()), remote: drive)
        sync.now = { Date(timeIntervalSince1970: 1_793_000_000) }
        return sync
    }

    private func contents(_ vault: Vault) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try vault.paths.map { ($0, try vault.text(at: $0) ?? "") })
    }

    // MARK: Scenarios

    func testCreateEditAndPullAcrossDevices() async throws {
        let drive = FakeDrive()
        let a = try device(drive), b = try device(drive)
        try a.vault.write(text: "# One\n", at: "One.md")
        try a.vault.write(text: "# Two\n", at: "Notes/Two.md")
        let first = try await a.sync()
        XCTAssertEqual(Set(first.uploaded), ["One.md", "Notes/Two.md"])

        let synced1 = try await b.sync()
        XCTAssertEqual(Set(synced1.updated), ["One.md", "Notes/Two.md"])
        try b.vault.write(text: "# One\n\nEdited on B.\n", at: "One.md")
        let synced2 = try await b.sync()
        XCTAssertEqual(synced2.uploaded, ["One.md"])
        let synced3 = try await a.sync()
        XCTAssertEqual(synced3.updated, ["One.md"])
        XCTAssertEqual(try a.vault.text(at: "One.md"), "# One\n\nEdited on B.\n")
        // Nothing left to do.
        let synced4 = try await a.sync()
        XCTAssertEqual(synced4, SyncReport())
        let synced5 = try await b.sync()
        XCTAssertEqual(synced5, SyncReport())
    }

    func testConcurrentEditsToDifferentLinesMerge() async throws {
        let drive = FakeDrive()
        let a = try device(drive), b = try device(drive)
        try a.vault.write(text: "# Plan\n\nOne\nTwo\nThree\n", at: "Plan.md")
        try await a.sync(); try await b.sync()

        try a.vault.write(text: "# Plan\n\nOne (A)\nTwo\nThree\n", at: "Plan.md")
        try b.vault.write(text: "# Plan\n\nOne\nTwo\nThree (B)\n", at: "Plan.md")
        try await a.sync()
        let report = try await b.sync()
        XCTAssertEqual(report.merged, ["Plan.md"])
        XCTAssertEqual(report.conflicts, [])
        try await a.sync()
        let merged = "# Plan\n\nOne (A)\nTwo\nThree (B)\n"
        XCTAssertEqual(try a.vault.text(at: "Plan.md"), merged)
        XCTAssertEqual(try b.vault.text(at: "Plan.md"), merged)
        XCTAssertEqual(drive.snapshot, ["Plan.md": merged])
    }

    func testConflictingEditsKeepBothVersions() async throws {
        let drive = FakeDrive()
        let a = try device(drive), b = try device(drive)
        try a.vault.write(text: "Line\n", at: "Plan.md")
        try await a.sync(); try await b.sync()

        try a.vault.write(text: "Line by A\n", at: "Plan.md")
        try b.vault.write(text: "Line by B\n", at: "Plan.md")
        try await a.sync()
        let report = try await b.sync()
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertEqual(report.conflicts.first?.path, "Plan.md")
        XCTAssertTrue(report.conflicts[0].copy.hasPrefix("Plan (conflicted copy "))
        XCTAssertTrue(report.conflicts[0].copy.hasSuffix(").md"))
        try await a.sync()
        // The server's (A's) version keeps the page; B's is beside it, everywhere.
        XCTAssertEqual(try contents(a.vault)["Plan.md"], "Line by A\n")
        XCTAssertEqual(try contents(a.vault)[report.conflicts[0].copy], "Line by B\n")
        XCTAssertEqual(try contents(a.vault), try contents(b.vault))
    }

    func testAnEditWinsOverADeletionElsewhere() async throws {
        let drive = FakeDrive()
        let a = try device(drive), b = try device(drive)
        try a.vault.write(text: "Keep me\n", at: "Page.md")
        try await a.sync(); try await b.sync()

        try a.vault.delete(at: "Page.md")
        try b.vault.write(text: "Keep me, edited\n", at: "Page.md")
        let synced6 = try await a.sync()
        XCTAssertEqual(synced6.deletedRemotely, ["Page.md"])
        let synced7 = try await b.sync()
        XCTAssertEqual(synced7.restored, ["Page.md"])
        try await a.sync()
        XCTAssertEqual(try a.vault.text(at: "Page.md"), "Keep me, edited\n")
    }

    func testDeletionsAndMovesPropagate() async throws {
        let drive = FakeDrive()
        let a = try device(drive), b = try device(drive)
        try a.vault.write(text: "x\n", at: "Gone.md")
        try a.vault.write(text: "Body\n", at: "Inbox/Moving.md")
        try await a.sync(); try await b.sync()

        try a.vault.delete(at: "Gone.md")
        try a.vault.move(from: "Inbox/Moving.md", to: "Archive/Moved.md")
        try b.vault.write(text: "Body\nedited while it moved\n", at: "Inbox/Moving.md")
        try await a.sync()
        let report = try await b.sync()
        XCTAssertEqual(report.removed, ["Gone.md"])
        XCTAssertEqual(report.moved, [.init(from: "Inbox/Moving.md", to: "Archive/Moved.md")])
        try await a.sync()
        XCTAssertEqual(try contents(a.vault), ["Archive/Moved.md": "Body\nedited while it moved\n"])
        XCTAssertEqual(try contents(b.vault), try contents(a.vault))
    }

    func testTheSamePathCreatedOnTwoDevices() async throws {
        let drive = FakeDrive()
        let a = try device(drive), b = try device(drive), c = try device(drive)
        try a.vault.write(text: "same\n", at: "Daily/2026-10-29.md")
        try b.vault.write(text: "same\n", at: "Daily/2026-10-29.md")
        try c.vault.write(text: "different\n", at: "Daily/2026-10-29.md")
        try await a.sync()
        let synced8 = try await b.sync()
        XCTAssertEqual(synced8.conflicts, [])  // identical: adopted
        let report = try await c.sync()
        XCTAssertEqual(report.conflicts.count, 1)
        try await a.sync(); try await b.sync()
        XCTAssertEqual(try contents(a.vault), try contents(c.vault))
        XCTAssertEqual(drive.files.count, 2)
    }

    func testAttachmentsAreNeverMergedOnlyKept() async throws {
        let drive = FakeDrive()
        let a = try device(drive), b = try device(drive)
        try a.vault.write(Data([1, 2, 3]), at: "img.png")
        try await a.sync(); try await b.sync()
        try a.vault.write(Data([4]), at: "img.png")
        try b.vault.write(Data([5]), at: "img.png")
        try await a.sync()
        let report = try await b.sync()
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertEqual(try b.vault.content(at: "img.png"), Data([4]))
        XCTAssertEqual(try b.vault.content(at: report.conflicts[0].copy), Data([5]))
    }

    func testAnInterruptedSyncResumesWithoutLoss() async throws {
        let drive = FakeDrive()
        let a = try device(drive)
        for i in 0..<10 { try a.vault.write(text: "page \(i)\n", at: "P\(i).md") }
        drive.failEvery = 4
        var attempts = 0
        while true {
            attempts += 1
            do { try await a.sync(); break } catch is URLError { XCTAssertLessThan(attempts, 20) }
        }
        drive.failEvery = nil
        try await a.sync()
        XCTAssertEqual(drive.snapshot.count, 10)
        XCTAssertEqual(drive.snapshot["P7.md"], "page 7\n")
        XCTAssertTrue(a.vault.records.allSatisfy { !$0.dirty && $0.fileID != nil })
    }

    func testSealedDiskStorageKeepsNoPlaintextAndReopens() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sealer = TestSealer()
        let drive = FakeDrive()
        do {
            let vault = try Vault(storage: SealedDiskStorage(directory: dir, sealedWith: sealer))
            try vault.write(text: "Secret plans\n", at: "Private/Roadmap.md")
            try await VaultSync(vault: vault, remote: drive).sync()
        }
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let bytes = try Data(contentsOf: dir.appendingPathComponent(file))
            XCTAssertNil(bytes.range(of: Data("Secret".utf8)))
            XCTAssertNil(bytes.range(of: Data("Roadmap".utf8)))
            XCTAssertFalse(file.contains("Roadmap"))
        }
        let reopened = try Vault(storage: SealedDiskStorage(directory: dir, sealedWith: sealer))
        XCTAssertEqual(try reopened.text(at: "Private/Roadmap.md"), "Secret plans\n")
        XCTAssertEqual(reopened.record(at: "Private/Roadmap.md")?.dirty, false)
        XCTAssertThrowsError(try Vault(storage: SealedDiskStorage(directory: dir, sealedWith: TestSealer())))
    }

    func testTheJournalSurvivesReopeningCompactionAndATornTail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sealer = TestSealer()
        func open() throws -> Vault { try Vault(storage: SealedDiskStorage(directory: dir, sealedWith: sealer)) }

        // More changes than one compaction's worth, so both the manifest and the journal matter.
        do {
            let vault = try open()
            for i in 0..<(Vault.compactionThreshold + 250) { try vault.write(text: "v\(i)\n", at: "P\(i % 300).md") }
            try vault.move(from: "P1.md", to: "Moved/P1.md")
            try vault.delete(at: "P2.md")
        }
        var reopened = try open()
        XCTAssertEqual(reopened.paths.count, 299)
        XCTAssertEqual(try reopened.text(at: "Moved/P1.md"), "v1201\n")
        XCTAssertNil(try reopened.text(at: "P2.md"))
        XCTAssertEqual(try reopened.text(at: "P0.md"), "v1200\n")

        // A crash mid-append leaves a torn entry: it is ignored and cut off, and later appends work.
        let journal = dir.appendingPathComponent("journal")
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0, 0, 1, 0, 42, 42]))
        try handle.close()
        reopened = try open()
        XCTAssertEqual(try reopened.text(at: "P0.md"), "v1200\n")
        try reopened.write(text: "after the crash\n", at: "P3.md")
        XCTAssertEqual(try open().text(at: "P3.md"), "after the crash\n")

        // The wrong key throws and leaves the journal intact.
        let size = try FileManager.default.attributesOfItem(atPath: journal.path)[.size] as? Int
        XCTAssertThrowsError(try Vault(storage: SealedDiskStorage(directory: dir, sealedWith: TestSealer())))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: journal.path)[.size] as? Int, size)
        XCTAssertEqual(try open().text(at: "P3.md"), "after the crash\n")
    }

    // MARK: Property: random edits on three devices converge, and nothing is lost

    /// 40 seeds in CI; set `ATLAS_SYNC_SEEDS` and `ATLAS_SYNC_OPS` for a longer local run.
    func testRandomEditsOnThreeDevicesConvergeWithoutLoss() async throws {
        let env = ProcessInfo.processInfo.environment
        let seeds = Int(env["ATLAS_SYNC_SEEDS"] ?? "") ?? 40
        let ops = Int(env["ATLAS_SYNC_OPS"] ?? "") ?? 60
        if let only = env["ATLAS_SYNC_TRACE"].flatMap(UInt64.init) {
            trace = true
            return try await runRandomScenario(seed: only, operations: ops)
        }
        for seed in 0..<seeds {
            try await runRandomScenario(seed: UInt64(seed), operations: ops)
        }
    }

    private var trace = false
    private func log(_ s: @autoclosure () -> String) { if trace { print("TRACE", s()) } }

    private func runRandomScenario(seed: UInt64, operations: Int) async throws {
        var rng = SplitMix(seed: seed)
        let drive = FakeDrive()
        let devices = try (0..<3).map { _ in try device(drive) }
        var token = 0
        var removed = Set<String>()  // tokens some device deliberately removed
        var written = Set<String>()

        func tokens(_ text: String) -> [String] { text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("t") } }

        for _ in 0..<operations {
            let d = devices[rng.next(devices.count)]
            let paths = d.vault.paths
            switch rng.next(6) {
            case 0:  // new page (overwriting one that's there deliberately discards its lines)
                token += 1
                let t = "t\(token)"
                written.insert(t)
                let path = "Page \(rng.next(8)).md"
                if let existing = try d.vault.text(at: path) { removed.formUnion(tokens(existing)) }
                try d.vault.write(text: "\(t)\n", at: path)
                log("dev\(devices.firstIndex { $0.vault === d.vault }!) new \(path) = \(t)")
            case 1, 2:  // add or replace a line
                guard let path = paths.randomElement(using: &rng) else { continue }
                var lines = try d.vault.text(at: path)!.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                token += 1
                let t = "t\(token)"
                written.insert(t)
                if lines.count > 1, rng.next(2) == 0 {
                    let i = rng.next(lines.count - 1)
                    removed.formUnion(tokens(lines[i]))
                    lines[i] = t
                } else {
                    lines.insert(t, at: rng.next(lines.count))
                }
                try d.vault.write(text: lines.joined(separator: "\n"), at: path)
                log("dev\(devices.firstIndex { $0.vault === d.vault }!) edit \(path) = \(lines)")
            case 3:  // delete
                guard let path = paths.randomElement(using: &rng), rng.next(3) == 0 else { continue }
                removed.formUnion(tokens(try d.vault.text(at: path)!))
                try d.vault.delete(at: path)
                log("dev\(devices.firstIndex { $0.vault === d.vault }!) delete \(path)")
            case 4:  // move
                guard let path = paths.randomElement(using: &rng) else { continue }
                let to = "Folder \(rng.next(3))/Page \(rng.next(8)).md"
                try d.vault.move(from: path, to: to)
                log("dev\(devices.firstIndex { $0.vault === d.vault }!) move \(path) -> \(to)")
            default:  // sync, sometimes interrupted
                drive.failEvery = rng.next(3) == 0 ? 2 + rng.next(4) : nil
                do {
                    let report = try await d.sync()
                    log("dev\(devices.firstIndex { $0.vault === d.vault }!) sync \(report)")
                } catch {
                    log("dev\(devices.firstIndex { $0.vault === d.vault }!) sync interrupted")
                }
                drive.failEvery = nil
                if trace {
                    for (i, dev) in devices.enumerated() {
                        log("   dev\(i) state: " + dev.vault.records.map { "\($0.path)[\($0.fileID ?? "-")@\($0.baseVersion ?? -1)\($0.dirty ? " dirty" : "")\($0.deleted ? " deleted" : "")]=\((try? dev.vault.text(at: $0.path)).flatMap { $0 }.map { tokens($0).joined(separator: ",") } ?? "")" }.joined(separator: "  "))
                    }
                    log("   server: " + drive.files.sorted { $0.key < $1.key }.map { "\($0.key)@\($0.value.version) \($0.value.path)=\(tokens(String(decoding: $0.value.data, as: UTF8.self)).joined(separator: ","))" }.joined(separator: "  "))
                }
            }
        }

        // Settle: sync everyone until a whole round changes nothing.
        for _ in 0..<6 {
            var quiet = true
            for (i, d) in devices.enumerated() {
                let report = try await d.sync()
                if report != SyncReport() { quiet = false; log("settle dev\(i) sync \(report)") }
                if trace {
                    log("   dev\(i) Page 3: " + d.vault.records.filter { $0.path.contains("Page 3") }.map { "\($0.path)[\($0.fileID ?? "-")@\($0.baseVersion ?? -1)\($0.dirty ? " dirty" : "")]=\((try? d.vault.text(at: $0.path)).flatMap { $0 } ?? "")" }.joined(separator: "  "))
                    log("   server Page 3: " + drive.files.filter { $0.value.path.contains("Page 3") }.map { "\($0.key)@\($0.value.version) \($0.value.path)=\(String(decoding: $0.value.data, as: UTF8.self))" }.joined(separator: "  "))
                }
            }
            if quiet { break }
        }
        for d in devices {
            let report = try await d.sync()
            XCTAssertEqual(report, SyncReport(), "seed \(seed): not quiescent")
        }

        let reference = try contents(devices[0].vault)
        for d in devices.dropFirst() {
            XCTAssertEqual(try contents(d.vault), reference, "seed \(seed): devices disagree")
        }
        XCTAssertEqual(drive.snapshot, reference, "seed \(seed): server disagrees")
        let surviving = Set(reference.values.flatMap(tokens))
        let lost = written.subtracting(removed).subtracting(surviving)
        XCTAssertEqual(lost, [], "seed \(seed): lost edits")
    }
}

final class VaultSyncPerformanceTests: XCTestCase {
    /// A pass with nothing to do must stay cheap at the roadmap's 5,000 pages.
    func testAQuietPassOverFiveThousandFiles() async throws {
        let drive = FakeDrive()
        let vault = try Vault(storage: MemoryStorage())
        for i in 0..<5_000 { try vault.write(text: "page \(i)\n", at: "Folder \(i % 50)/Page \(i).md") }
        let sync = VaultSync(vault: vault, remote: drive)
        var clock = ContinuousClock.now
        try await sync.sync()
        let first = ContinuousClock.now - clock
        clock = .now
        let report = try await sync.sync()
        let quiet = ContinuousClock.now - clock
        print("5,000 files: first sync \(first), quiet pass \(quiet)")
        XCTAssertEqual(report, SyncReport())
        XCTAssertLessThan(quiet, .milliseconds(500))
        XCTAssertLessThan(first, .seconds(10))
    }
}

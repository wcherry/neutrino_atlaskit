import Foundation
import XCTest
@testable import AtlasCore

/// A remote that can hold one kind of call until the test lets it go, to make edits land in
/// the middle of a sync pass.
private final class GatedDrive: VaultRemote {
    let drive = FakeDrive()
    var holdReplace = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    /// Returns once a call is being held.
    func untilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release() { held?.resume(); held = nil; holdReplace = false }

    func list() async throws -> [RemoteFile] { try await drive.list() }
    func download(_ id: String) async throws -> (data: Data, version: Int) { try await drive.download(id) }
    func create(at path: String, data: Data) async throws -> RemoteFile { try await drive.create(at: path, data: data) }
    func replace(_ id: String, data: Data, expectedVersion: Int) async throws -> Int {
        if holdReplace {
            await withCheckedContinuation { c in
                held = c
                heldWaiters.forEach { $0.resume() }
                heldWaiters = []
            }
        }
        return try await drive.replace(id, data: data, expectedVersion: expectedVersion)
    }
    func move(_ id: String, to path: String) async throws { try await drive.move(id, to: path) }
    func delete(_ id: String) async throws { try await drive.delete(id) }
}

@MainActor
final class VaultWorkspaceTests: XCTestCase {
    private func workspace(_ remote: VaultRemote) throws -> VaultWorkspace {
        try VaultWorkspace(vault: try Vault(storage: MemoryStorage()), remote: remote)
    }

    func testTheIndexFollowsEveryChange() async throws {
        let w = try workspace(FakeDrive())
        let a = try w.createPage(titled: "Plan", text: "# Plan\n\nSee [[Notes]] #work\n")
        let b = try w.createPage(titled: "Notes", in: "Inbox", text: "notes\n")
        XCTAssertEqual(a, "Plan.md")
        XCTAssertEqual(b, "Inbox/Notes.md")
        XCTAssertEqual(try w.createPage(titled: "Plan"), "Plan 2.md")
        XCTAssertEqual(try w.index.backlinks(to: b).map(\.source), ["Plan.md"])
        XCTAssertEqual(try w.index.search("notes").map(\.path).sorted(), ["Inbox/Notes.md", "Plan.md"])

        // A rename rewrites the link to it and keeps the backlink.
        let rewritten = try await w.move(from: b, to: "Inbox/Meeting notes.md")
        XCTAssertEqual(rewritten, 1)
        XCTAssertEqual(try w.text(at: a), "# Plan\n\nSee [[Meeting notes]] #work\n")
        XCTAssertEqual(try w.index.backlinks(to: "Inbox/Meeting notes.md").map(\.source), ["Plan.md"])

        try await w.delete(at: "Plan 2.md")
        XCTAssertEqual(w.pages, ["Inbox/Meeting notes.md", "Plan.md"])
        XCTAssertEqual(try w.index.quickSwitch("plan").map(\.path), ["Plan.md"])
    }

    func testSyncResultsReachTheIndex() async throws {
        let drive = FakeDrive()
        let here = try workspace(drive)
        let there = try workspace(drive)
        try there.write(text: "# Elsewhere\n\n#remote\n", at: "Elsewhere.md")
        try await there.sync()

        var moves: [[String: String]] = []
        here.onChange = { moves.append($0) }
        try await here.sync()
        XCTAssertEqual(here.pages, ["Elsewhere.md"])
        XCTAssertEqual(try here.index.tags().map(\.tag), ["remote"])

        _ = try await there.move(from: "Elsewhere.md", to: "Moved.md")
        try await there.sync()
        try await here.sync()
        XCTAssertEqual(moves.last, ["Elsewhere.md": "Moved.md"])
        XCTAssertEqual(try here.index.quickSwitch("moved").map(\.path), ["Moved.md"])
        XCTAssertFalse(here.hasUnsyncedChanges)
    }

    /// The race the workspace exists to prevent: an edit made while the pass pushes the same
    /// page would otherwise be committed as synced, and a later pull would overwrite it.
    func testAnEditDuringAPassIsKeptAndSyncedNext() async throws {
        let remote = GatedDrive()
        let w = try workspace(remote)
        try w.write(text: "one\n", at: "Page.md")
        try await w.sync()
        try w.write(text: "two\n", at: "Page.md")

        remote.holdReplace = true
        let pass = Task { try await w.sync() }
        await remote.untilHeld()
        XCTAssertTrue(w.isSyncing)
        try w.write(text: "three\n", at: "Page.md")
        XCTAssertEqual(try w.text(at: "Page.md"), "three\n", "reads see the held edit")
        XCTAssertEqual(try w.index.search("three").map(\.path), ["Page.md"])
        remote.release()
        _ = try await pass.value

        XCTAssertEqual(remote.drive.snapshot, ["Page.md": "two\n"])
        XCTAssertTrue(w.hasUnsyncedChanges, "the held edit is waiting to be pushed")
        try await w.sync()
        XCTAssertEqual(remote.drive.snapshot, ["Page.md": "three\n"])
        XCTAssertFalse(w.hasUnsyncedChanges)
    }

    func testAMoveWaitsForTheRunningPass() async throws {
        let remote = GatedDrive()
        let w = try workspace(remote)
        try w.write(text: "a\n", at: "A.md")
        try await w.sync()
        try w.write(text: "b\n", at: "A.md")
        remote.holdReplace = true
        let pass = Task { try await w.sync() }
        await remote.untilHeld()
        let move = Task { try await w.move(from: "A.md", to: "B.md") }
        await Task.yield()
        XCTAssertEqual(w.pages, ["A.md"], "the move hasn't run under the pass")
        remote.release()
        _ = try await pass.value
        _ = try await move.value
        XCTAssertEqual(w.pages, ["B.md"])
        try await w.sync()
        XCTAssertEqual(remote.drive.snapshot, ["B.md": "b\n"])
    }
}

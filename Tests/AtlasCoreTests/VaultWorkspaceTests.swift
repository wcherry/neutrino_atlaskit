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

    func testAttachmentsAreNumberedAndSynced() async throws {
        let drive = FakeDrive()
        let w = try workspace(drive)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(try w.addAttachment(png, named: "photo.png", in: "Attachments"), "Attachments/photo.png")
        XCTAssertEqual(try w.addAttachment(png, named: "photo.png", in: "Attachments"), "Attachments/photo 2.png")
        XCTAssertEqual(try w.addAttachment(png, named: "../.secret/x.png", in: ""), "-.secret-x.png", "no folders, not hidden")
        XCTAssertEqual(try w.addAttachment(png, named: ".png", in: ""), "png", "hidden name, no extension left")
        XCTAssertEqual(try w.content(at: "Attachments/photo 2.png"), png)
        _ = try await w.sync()
        let uploaded = try await drive.list().map(\.path)
        XCTAssertTrue(uploaded.contains("Attachments/photo.png"), "\(uploaded)")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(VaultWorkspace.pastedImageName(extension: "png", date: Date(timeIntervalSince1970: 1_793_000_000), calendar: utc),
                       "Pasted image 20261026073320.png")
    }

    func testMovingAFolderMovesEverythingInItAndRewritesLinks() async throws {
        let w = try workspace(FakeDrive())
        try w.write(text: "See [[Work/Plan]] and ![[Work/Assets/chart.png]]\n", at: "Home.md")
        try w.write(text: "# Plan\n\nSee [[Notes]].\n", at: "Work/Plan.md")
        try w.write(text: "notes\n", at: "Work/Notes.md")
        try w.write(Data([0x89, 0x50]), at: "Work/Assets/chart.png")
        try w.write(text: "elsewhere\n", at: "Workshop/Plan.md")

        let rewritten = try await w.moveFolder(from: "Work", to: "Archive/2026/Work")
        XCTAssertGreaterThan(rewritten, 0)
        XCTAssertEqual(w.paths, ["Archive/2026/Work/Assets/chart.png", "Archive/2026/Work/Notes.md", "Archive/2026/Work/Plan.md",
                                 "Home.md", "Workshop/Plan.md"], "a folder named alike is left alone")
        let home = try XCTUnwrap(try w.text(at: "Home.md"))
        XCTAssertTrue(home.contains("[[Work/Plan]]") || home.contains("[[2026/Work/Plan]]") || home.contains("[[Archive/2026/Work/Plan]]"), home)
        XCTAssertEqual(try w.index.backlinks(to: "Archive/2026/Work/Plan.md").map(\.source), ["Home.md"])

        // Not into itself, and not onto files already there.
        do { try await w.moveFolder(from: "Archive", to: "Archive/Inner"); XCTFail("moved into itself") } catch {}
        try w.write(text: "x\n", at: "Other/Notes.md")
        do { try await w.moveFolder(from: "Archive/2026/Work", to: "Other"); XCTFail("overwrote") } catch {}
        XCTAssertNotNil(try w.text(at: "Archive/2026/Work/Notes.md"), "nothing moved")

        XCTAssertEqual(VaultWorkspace.path(of: "Inbox/Idea.md", movedInto: "Projects/"), "Projects/Idea.md")
        XCTAssertEqual(VaultWorkspace.path(of: "Inbox/Idea.md", movedInto: ""), "Idea.md")
        XCTAssertEqual(VaultWorkspace.folder("Inbox/Ideas/", movedInto: "Projects"), "Projects/Ideas")
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

    func testLinkingMentions() async throws {
        let w = try workspace(FakeDrive())
        try w.write(text: "# Plan\n", at: "Projects/Plan.md")
        try w.write(text: "Talked about the plan.\n", at: "Inbox.md")
        let mentions = try w.index.unlinkedMentions(of: "Projects/Plan.md")
        XCTAssertEqual(mentions.map(\.source), ["Inbox.md"])
        XCTAssertEqual(try w.linkMentions(of: "Projects/Plan.md", in: "Inbox.md", name: mentions[0].name), 1)
        XCTAssertEqual(try w.text(at: "Inbox.md"), "Talked about the [[plan]].\n")
        XCTAssertEqual(try w.index.backlinks(to: "Projects/Plan.md").map(\.source), ["Inbox.md"])
        XCTAssertEqual(try w.index.unlinkedMentions(of: "Projects/Plan.md"), [])
    }
}

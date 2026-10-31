import AtlasCore
import XCTest

final class PageListTests: XCTestCase {
    func testRecentPagesPutTheLastOpenedFirstAndKeepTheLimit() {
        var recent = PageList(limit: 3)
        for page in ["A.md", "B.md", "C.md", "A.md", "D.md"] { recent.moveToFront(page) }
        XCTAssertEqual(recent.paths, ["D.md", "A.md", "C.md"])
    }

    func testFavouritesKeepTheirOrderAndToggle() {
        var favourites = PageList(["A.md", "B.md", "A.md"])
        XCTAssertEqual(favourites.paths, ["A.md", "B.md"])
        favourites.toggle("C.md")
        favourites.add("A.md")
        XCTAssertEqual(favourites.paths, ["A.md", "B.md", "C.md"])
        favourites.toggle("A.md")
        XCTAssertEqual(favourites.paths, ["B.md", "C.md"])
        XCTAssertFalse(favourites.contains("A.md"))
    }

    func testFollowsMovesAndDropsDeletedPages() {
        var list = PageList(["A.md", "B.md", "C.md"])
        let pages: Set = ["Folder/A.md", "C.md"]
        list.update(moved: ["A.md": "Folder/A.md"], exists: pages.contains)
        XCTAssertEqual(list.paths, ["Folder/A.md", "C.md"])
        // A page moved onto one already listed is listed once.
        list.update(moved: ["Folder/A.md": "C.md"], exists: { $0 == "C.md" })
        XCTAssertEqual(list.paths, ["C.md"])
    }

    func testRoundTripsAsJSON() throws {
        let list = PageList(["A.md"], limit: 5)
        XCTAssertEqual(try JSONDecoder().decode(PageList.self, from: JSONEncoder().encode(list)), list)
    }
}

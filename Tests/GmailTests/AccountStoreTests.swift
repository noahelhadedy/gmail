import XCTest
@testable import Gmail

final class AccountStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: AccountStore!

    override func setUp() {
        super.setUp()
        suiteName = "accounts.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = AccountStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testEmptyByDefault() {
        XCTAssertEqual(store.load(), [])
    }

    func testAddKeepsOrderAndAssignsDistinctColors() {
        store.add(email: "noohelhadedy@gmail.com")
        store.add(email: "hello@djectstudio.com")
        store.add(email: "noah@djectstudio.com")

        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.email), ["noohelhadedy@gmail.com", "hello@djectstudio.com", "noah@djectstudio.com"])
        XCTAssertEqual(loaded.map(\.colorIndex), [0, 1, 2])
    }

    func testAddingSameEmailTwiceIsANoOp() {
        let first = store.add(email: "alice@example.com")
        let second = store.add(email: "ALICE@example.com")

        XCTAssertEqual(first, second)
        XCTAssertEqual(store.load().count, 1)
    }

    func testRemoveDropsOnlyThatAccount() {
        store.add(email: "a@example.com")
        store.add(email: "b@example.com")

        store.remove(email: "A@example.com")

        XCTAssertEqual(store.load().map(\.email), ["b@example.com"])
    }

    func testRemovedColorIsReused() {
        store.add(email: "a@example.com")
        store.add(email: "b@example.com")
        store.remove(email: "a@example.com")

        let c = store.add(email: "c@example.com")

        XCTAssertEqual(c.colorIndex, 0, "the freed color goes to the next account")
    }

    func testColorsWrapAfterPaletteIsFull() {
        let full = (0..<AccountStore.colorCount).map { StoredAccount(email: "\($0)@x.com", colorIndex: $0) }
        XCTAssertEqual(AccountStore.nextColorIndex(for: full), 0)
    }

    func testPersistsAcrossInstances() {
        store.add(email: "a@example.com")
        XCTAssertEqual(AccountStore(defaults: defaults).load().map(\.email), ["a@example.com"])
    }

    func testMigratesLegacySingleAccount() {
        defaults.set("old@example.com", forKey: AuthService.lastEmailDefaultsKey)

        XCTAssertEqual(store.load(), [StoredAccount(email: "old@example.com", colorIndex: 0)])
    }

    func testLegacyKeyIgnoredOnceListExists() {
        store.add(email: "a@example.com")
        store.remove(email: "a@example.com")
        defaults.set("old@example.com", forKey: AuthService.lastEmailDefaultsKey)

        XCTAssertEqual(store.load(), [], "an empty saved list must not resurrect the legacy account")
    }
}

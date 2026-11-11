import XCTest
@testable import VoiceCalculator

final class VoiceCalculatorTests: XCTestCase {
    private func values(_ text: String) throws -> [Int] {
        let result = try VietnameseNumberParser.parse(text)
        guard case .amounts(let amounts) = result else {
            XCTFail("Expected parsed numbers, got command")
            return []
        }
        return amounts.map { NSDecimalNumber(decimal: $0.value).intValue }
    }

    func testThreeNumbers() throws {
        XCTAssertEqual(try values("15 cộng 19 cộng 17"), [15, 19, 17])
    }

    func testSixAmountsReadWithoutComma() throws {
        XCTAssertEqual(try values("ba mươi ngàn bốn mươi ngàn năm mươi ngàn sáu mươi ngàn bảy mươi ngàn tám mươi ngàn"),
                       [30000, 40000, 50000, 60000, 70000, 80000])
    }

    func testShorthandThousands() throws {
        XCTAssertEqual(try values("bốn ngàn rưỡi"), [4500])
        XCTAssertEqual(try values("năm ngàn sáu"), [5600])
        XCTAssertEqual(try values("mười hai ngàn năm"), [12500])
    }

    func testMillions() throws {
        XCTAssertEqual(try values("một triệu hai"), [1200000])
        XCTAssertEqual(try values("một triệu hai trăm ngàn"), [1200000])
    }

    func testPunctuationAndSymbols() throws {
        XCTAssertEqual(try values("15. 19. 17"), [15, 19, 17])
        XCTAssertEqual(try values("1+2"), [1, 2])
        XCTAssertEqual(try values("15.000 cộng 20.000"), [15000, 20000])
    }

    func testAmbiguousPhraseDoesNotBecomeNumber() throws {
        XCTAssertThrowsError(try VietnameseNumberParser.parse("15 cộng size 6"))
        XCTAssertThrowsError(try VietnameseNumberParser.parse("15 cộng"))
    }

    func testUndoCommand() throws {
        let input = try VietnameseNumberParser.parse("hoàn tác")
        guard case .undo = input else { return XCTFail("Expected undo") }
    }

    @MainActor func testPercentAndArithmetic() throws {
        let entries = [
            CalculationEntry(operation: .add, amount: 100000, isPercent: false, spoken: "100000"),
            CalculationEntry(operation: .subtract, amount: 10, isPercent: true, spoken: "10%")
        ]
        let totals = try CalculationStore.runningTotals(entries)
        XCTAssertEqual(totals.last, 90000)
    }

    @MainActor func testDivisionByZeroIsRejected() {
        let entries = [CalculationEntry(operation: .add, amount: 100, isPercent: false, spoken: "100"),
                       CalculationEntry(operation: .divide, amount: 0, isPercent: false, spoken: "0")]
        XCTAssertThrowsError(try CalculationStore.runningTotals(entries))
    }

    @MainActor func testNoPartialCommitOnUnknownWords() {
        let store = CalculationStore()
        let count = store.entries.count
        store.accept("15 cộng size 6")
        XCTAssertEqual(store.entries.count, count)
        XCTAssertNotNil(store.unrecognizedText)
    }
}
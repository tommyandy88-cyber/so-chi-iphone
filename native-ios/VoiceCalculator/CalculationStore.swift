import Foundation
import Combine

struct CalculationEntry: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var operation: ArithmeticOperation
    var amount: Decimal
    var isPercent: Bool
    var spoken: String
    var timestamp: Date = .now
}

struct ArchivedCalculation: Identifiable, Codable {
    var id: UUID = UUID()
    var started: Date
    var finished: Date
    var entries: [CalculationEntry]
    var total: Decimal
}

@MainActor final class CalculationStore: ObservableObject {
    @Published private(set) var entries: [CalculationEntry] = []
    @Published private(set) var archive: [ArchivedCalculation] = []
    @Published var errorMessage: String?
    @Published var unrecognizedText: String?

    private var started = Date()
    private let key = "kanaan.voicecalculator.native.v2"
    private struct Persisted: Codable {
        var entries: [CalculationEntry]
        var archive: [ArchivedCalculation]
        var started: Date
    }

    init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let object = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        entries = object.entries
        archive = object.archive
        started = object.started
    }

    var total: Decimal { (try? Self.runningTotals(entries).last) ?? 0 }
    var runningTotals: [Decimal] { (try? Self.runningTotals(entries)) ?? [] }

    static func runningTotals(_ entries: [CalculationEntry]) throws -> [Decimal] {
        var total = Decimal(0)
        var sums: [Decimal] = []
        for entry in entries {
            let number = entry.isPercent ? (total * entry.amount / Decimal(100)) : entry.amount
            switch entry.operation {
            case .add: total += number
            case .subtract: total -= number
            case .multiply: total *= number
            case .divide:
                if number == 0 { throw CalculationParseError.unclear("Không được chia cho 0") }
                total /= number
            }
            let check = NSDecimalNumber(decimal: total).doubleValue
            if !check.isFinite || abs(check) > 1.0e14 { throw CalculationParseError.tooLarge }
            sums.append(total)
        }
        return sums
    }

    func accept(_ transcript: String) {
        do {
            let parsed = try VietnameseNumberParser.parse(transcript)
            switch parsed {
            case .undo: undo()
            case .amounts(let items):
                let proposed = entries + items.map { value in
                    CalculationEntry(operation: value.operation,
                                     amount: value.value,
                                     isPercent: value.isPercent,
                                     spoken: value.spoken)
                }
                _ = try Self.runningTotals(proposed)
                entries = proposed
                unrecognizedText = nil
                errorMessage = nil
                save()
            }
        } catch {
            unrecognizedText = transcript
            errorMessage = error.localizedDescription
            // Never change the total on uncertain speech.
        }
    }

    func addManually(_ text: String) { accept(text) }

    func undo() {
        guard !entries.isEmpty else { return }
        entries.removeLast()
        errorMessage = nil
        save()
    }

    func remove(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        var copy = entries
        copy.remove(at: index)
        if (try? Self.runningTotals(copy)) != nil {
            entries = copy
            errorMessage = nil
            save()
        }
    }

    func edit(id: UUID, value: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let parsedAmount = try VietnameseNumberParser.parseAmount(value)
        var copy = entries
        copy[index].amount = parsedAmount
        copy[index].spoken = value
        _ = try Self.runningTotals(copy)
        entries = copy
        errorMessage = nil
        save()
    }

    func finishAndNew() {
        if !entries.isEmpty {
            archive.insert(ArchivedCalculation(started: started, finished: .now,
                                                entries: entries, total: total), at: 0)
            if archive.count > 50 { archive = Array(archive.prefix(50)) }
        }
        entries.removeAll()
        started = .now
        unrecognizedText = nil
        errorMessage = nil
        save()
    }

    func restore(_ item: ArchivedCalculation) {
        if !entries.isEmpty { finishAndNew() }
        entries = item.entries
        started = item.started
        errorMessage = nil
        save()
    }

    func clearError() { errorMessage = nil; unrecognizedText = nil }

    private func save() {
        let object = Persisted(entries: entries, archive: archive, started: started)
        if let bytes = try? JSONEncoder().encode(object) {
            UserDefaults.standard.set(bytes, forKey: key)
        }
    }

    func exportCSVFile() throws -> URL {
        let formatter = ISO8601DateFormatter()
        var rows = ["Date,Operation,Amount,Percent,RunningTotal,Spoken"]
        let sums = runningTotals
        for (index, entry) in entries.enumerated() {
            let spoken = entry.spoken.replacingOccurrences(of: "\"", with: "\"\"")
            let parts = [formatter.string(from: entry.timestamp), entry.operation.symbol,
                         NSDecimalNumber(decimal: entry.amount).stringValue,
                         entry.isPercent ? "true" : "false",
                         NSDecimalNumber(decimal: sums[index]).stringValue,
                         "\"\(spoken)\""]
            rows.append(parts.joined(separator: ","))
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("may-tinh-giong-noi-\(Int(Date().timeIntervalSince1970)).csv")
        try ("\u{FEFF}" + rows.joined(separator: "\n"))
            .write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    static func money(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "."
        formatter.decimalSeparator = ","
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "0"
    }
}
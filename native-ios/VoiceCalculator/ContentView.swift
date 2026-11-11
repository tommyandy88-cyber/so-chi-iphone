import SwiftUI

private enum Design {
    static let background = Color(red: 0.035, green: 0.085, blue: 0.095)
    static let card = Color(red: 0.07, green: 0.16, blue: 0.17)
    static let border = Color(red: 0.16, green: 0.32, blue: 0.31)
    static let mint = Color(red: 0.25, green: 0.82, blue: 0.67)
    static let lightMint = Color(red: 0.70, green: 0.96, blue: 0.84)
    static let muted = Color(red: 0.60, green: 0.72, blue: 0.71)
}

private struct ExportItem: Identifiable {
    let id = UUID()
    var url: URL
}

struct ContentView: View {
    @StateObject private var store = CalculationStore()
    @StateObject private var speech = AppleSpeechEngine()
    @State private var typedText = ""
    @State private var editEntry: CalculationEntry?
    @State private var showHistory = false
    @State private var confirmNew = false
    @State private var exportItem: ExportItem?

    var body: some View {
        ZStack {
            Design.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    totalCard
                    voiceCard
                    actionRow
                    manualInput
                    entryHistory
                    Text("Nhận giọng nói bằng Apple Speech · Không dùng AI API trả phí")
                        .font(.caption)
                        .foregroundStyle(Design.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                }
                .padding(.horizontal, 17)
                .padding(.top, 14)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear { speech.onRecognized = { text in store.accept(text) } }
        .onDisappear { speech.stop() }
        .alert("Kết thúc phép tính hiện tại?", isPresented: $confirmNew) {
            Button("Hủy", role: .cancel) { }
            Button("Lưu & Tính mới") { speech.stop(); store.finishAndNew() }
        } message: {
            Text("Phép tính hiện tại được lưu vào lịch sử. Dữ liệu chưa sửa sẽ không bị tự cộng.")
        }
        .sheet(item: $editEntry) { entry in
            EditEntryView(entry: entry) { revised in
                try store.edit(id: entry.id, value: revised)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                List(store.archive) { session in
                    Button {
                        speech.stop()
                        store.restore(session)
                        showHistory = false
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(CalculationStore.money(session.total) + " Ft")
                                .font(.headline)
                            Text("\(session.entries.count) khoản · " + session.finished.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("Các phép tính đã lưu")
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") { showHistory = false }
                } }
            }
        }
        .sheet(item: $exportItem) { item in
            VStack(spacing: 24) {
                Text("Xuất bảng tính CSV")
                    .font(.headline)
                ShareLink(item: item.url) {
                    Label("Chia sẻ hoặc lưu vào Tệp", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Design.mint)
            }
            .padding(28)
            .presentationDetents([.medium])
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundStyle(Design.mint)
                .frame(width: 53, height: 53)
                .background(Design.card, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text("MÁY TÍNH GIỌNG NÓI")
                    .font(.subheadline.bold())
                    .tracking(1.4)
                Text("Tiếng Việt · Apple Speech · iOS 2.0")
                    .font(.caption)
                    .foregroundStyle(Design.muted)
            }
            Spacer(minLength: 3)
            Button { showHistory = true } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 49, height: 49)
                    .background(Design.card, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Design.border))
            }
            .accessibilityLabel("Mở lịch sử")
        }
    }

    private var totalCard: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack {
                Text("TỔNG HIỆN TẠI")
                    .font(.footnote.bold())
                    .tracking(1.4)
                    .foregroundStyle(Design.muted)
                Spacer()
                Text("HUF / Ft")
                    .font(.caption.bold())
                    .foregroundStyle(Design.lightMint)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.10), in: Capsule())
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(CalculationStore.money(store.total))
                    .font(.system(size: 55, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                Text("Ft")
                    .font(.title3.bold())
                    .foregroundStyle(Design.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider().overlay(Design.border)
            HStack {
                Text("\(store.entries.count) khoản")
                    .foregroundStyle(Design.muted)
                Spacer()
                Button {
                    UIPasteboard.general.string = CalculationStore.money(store.total)
                } label: {
                    Label("Sao chép", systemImage: "doc.on.doc")
                        .foregroundStyle(Design.lightMint)
                }
            }
            .font(.subheadline)
            Button {
                if store.entries.isEmpty { speech.stop(); store.finishAndNew() }
                else { confirmNew = true }
            } label: {
                Label("KẾT THÚC PHÉP TÍNH · TÍNH MỚI", systemImage: "checkmark")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Design.card)
            .background(Design.lightMint, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(23)
        .background(Design.card, in: RoundedRectangle(cornerRadius: 25))
        .overlay(RoundedRectangle(cornerRadius: 25).stroke(Design.border))
    }

    private var voiceCard: some View {
        VStack(spacing: 15) {
            HStack(spacing: 7) {
                Circle()
                    .fill(speech.isListening ? Design.mint : Design.muted)
                    .frame(width: 8, height: 8)
                Text(speech.status)
                    .font(.subheadline)
                    .foregroundStyle(Design.muted)
                    .multilineTextAlignment(.center)
            }
            Button { speech.toggle() } label: {
                Image(systemName: speech.isListening ? "pause.fill" : "mic.fill")
                    .font(.system(size: 50, weight: .regular))
                    .foregroundStyle(Design.background)
                    .frame(width: 145, height: 145)
                    .background(speech.isListening ? Color(red: 0.98, green: 0.40, blue: 0.45) : Design.mint, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.32), lineWidth: 4).padding(8))
            }
            .buttonStyle(.plain)
            .disabled(speech.isStarting)
            .accessibilityLabel(speech.isListening ? "Tạm dừng micro" : "Bắt đầu đọc số")

            Text(speech.isListening ? "CHẠM ĐỂ TẠM DỪNG" : "CHẠM ĐỂ ĐỌC SỐ")
                .font(.subheadline.bold())
                .tracking(1.4)
            Text(speech.liveTranscript.isEmpty ? "Đọc: mười lăm cộng mười chín cộng mười bảy" : speech.liveTranscript)
                .font(.subheadline)
                .foregroundStyle(Design.lightMint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 33)
            if let problem = speech.errorMessage ?? store.errorMessage {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color.red.opacity(0.20), in: RoundedRectangle(cornerRadius: 11))
            }
            if let unclear = store.unrecognizedText {
                Button("Sửa lời nhận dạng: “\(unclear)”") {
                    typedText = unclear
                    store.clearError()
                }
                .font(.footnote)
                .foregroundStyle(Design.lightMint)
                .multilineTextAlignment(.center)
            }
            Divider().overlay(Design.border).padding(.top, 12)
            Text("Micro lớn dùng công nghệ nhận dạng giọng nói của Apple, không cần bàn phím và không gọi máy chủ AI của ứng dụng cũ.")
                .font(.caption)
                .foregroundStyle(Design.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Design.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Design.border))
    }

    private var actionRow: some View {
        HStack(spacing: 11) {
            Button { store.undo() } label: {
                Label("Hoàn tác", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
            }
            .disabled(store.entries.isEmpty)
            Button {
                do { exportItem = ExportItem(url: try store.exportCSVFile()) }
                catch { store.errorMessage = error.localizedDescription }
            } label: {
                Label("Xuất CSV", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
            }
            .disabled(store.entries.isEmpty)
        }
        .font(.subheadline.bold())
        .buttonStyle(.plain)
        .foregroundStyle(Design.lightMint)
        .background(Design.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Design.border))
    }

    private var manualInput: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Nhập số hoặc sửa lời nhận dạng")
                .font(.headline)
            HStack(spacing: 9) {
                TextField("15 cộng 19 cộng 17", text: $typedText)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .padding(15)
                    .background(Design.card, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Design.border))
                    .onSubmit(submitManually)
                Button(action: submitManually) {
                    Text("Thêm +")
                        .font(.headline.bold())
                        .foregroundStyle(Design.background)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 17)
                        .background(Design.mint, in: RoundedRectangle(cornerRadius: 13))
                }
                .disabled(typedText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var entryHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lịch sử phép tính")
                    .font(.title3.bold())
                Spacer()
                Text("\(store.entries.count) khoản")
                    .foregroundStyle(Design.muted)
                    .font(.subheadline)
            }
            if store.entries.isEmpty {
                Text("Chưa có phép tính nào.\nChạm micro lớn để bắt đầu.")
                    .foregroundStyle(Design.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 95)
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(Design.border, style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
            } else {
                VStack(spacing: 0) {
                    ForEach(store.entries) { entry in
                        HStack(spacing: 9) {
                            Text(entry.operation.symbol)
                                .foregroundStyle(Design.mint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(CalculationStore.money(entry.amount) + (entry.isPercent ? "%" : " Ft"))
                                    .font(.headline)
                                Text(entry.spoken)
                                    .font(.caption)
                                    .foregroundStyle(Design.muted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let index = store.entries.firstIndex(where: { $0.id == entry.id }),
                               store.runningTotals.indices.contains(index) {
                                Text(CalculationStore.money(store.runningTotals[index]))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(Design.lightMint)
                            }
                            Button { editEntry = entry } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(Design.mint)
                                    .padding(7)
                            }
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 12)
                        Divider().overlay(Design.border)
                    }
                }
                .background(Design.card, in: RoundedRectangle(cornerRadius: 15))
            }
        }
    }

    private func submitManually() {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addManually(text)
        if store.unrecognizedText == nil { typedText = "" }
    }
}

private struct EditEntryView: View {
    let entry: CalculationEntry
    let onSave: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var number: String
    @State private var error: String?

    init(entry: CalculationEntry, onSave: @escaping (String) throws -> Void) {
        self.entry = entry
        self.onSave = onSave
        _number = State(initialValue: NSDecimalNumber(decimal: entry.amount).stringValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Chỉnh sửa khoản tiền") {
                    TextField("Số tiền", text: $number)
                        .keyboardType(.decimalPad)
                    Text("Đã đọc: " + entry.spoken)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Sửa khoản")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        do { try onSave(number); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}
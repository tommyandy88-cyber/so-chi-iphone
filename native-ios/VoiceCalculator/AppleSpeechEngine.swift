import AVFoundation
import Combine
import Foundation
import Speech

/// Native Apple Speech implementation. It does not use Web Speech, Vosk,
/// Moonshine, Whisper, or a paid speech API.
@MainActor final class AppleSpeechEngine: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    @Published var status = "Chạm micro lớn để bắt đầu"
    @Published var liveTranscript = ""
    @Published var errorMessage: String?

    var onRecognized: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "vi-VN"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var activeTaskID = UUID()
    private var silenceTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var shouldContinue = false
    private var consecutiveErrors = 0

    override init() {
        super.init()
        recognizer?.delegate = self
    }

    func toggle() {
        if isListening || isStarting { stop() }
        else { Task { await start() } }
    }

    private func requestPermissions() async -> Bool {
        let speechPermission: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechPermission == .authorized else {
            errorMessage = "Bạn cần cho phép Nhận dạng giọng nói trong Cài đặt iPhone."
            return false
        }
        let microAllowed = await AVAudioApplication.requestRecordPermission()
        if !microAllowed { errorMessage = "Bạn cần cấp quyền Micro cho ứng dụng trong Cài đặt iPhone." }
        return microAllowed
    }

    func start() async {
        guard !isListening && !isStarting else { return }
        isStarting = true
        errorMessage = nil
        status = "Đang xin quyền micro và nhận dạng tiếng Việt…"
        guard await requestPermissions() else {
            isStarting = false
            status = "Chưa được cấp quyền micro"
            return
        }
        guard let recognizer else {
            isStarting = false
            status = "iPhone không hỗ trợ nhận dạng tiếng Việt"
            errorMessage = "Không tìm thấy bộ nhận dạng vi-VN của Apple trên thiết bị này."
            return
        }
        guard recognizer.isAvailable else {
            isStarting = false
            status = "Bộ nhận dạng Apple chưa sẵn sàng"
            errorMessage = "Bộ nhận dạng giọng nói hiện không khả dụng. Tiếng Việt có thể cần kết nối Internet."
            return
        }
        shouldContinue = true
        consecutiveErrors = 0
        do {
            try beginCycle()
            isListening = true
            status = "Đang nghe · đọc các số để tự cộng"
        } catch {
            shouldContinue = false
            errorMessage = "Không khởi động được micro: \(error.localizedDescription)"
            status = "Micro chưa hoạt động"
            endCycle()
        }
        isStarting = false
    }

    private func beginCycle() throws {
        endCycle()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let recordingRequest = SFSpeechAudioBufferRecognitionRequest()
        recordingRequest.shouldReportPartialResults = true
        recordingRequest.taskHint = .dictation
        recordingRequest.contextualStrings = [
            "mười lăm", "mười chín", "hai mươi", "năm mươi", "một trăm", "một ngàn",
            "một nghìn", "một triệu", "bốn ngàn rưỡi", "năm ngàn sáu",
            "cộng", "trừ", "nhân", "chia", "phần trăm", "forint"
        ]
        if recognizer?.supportsOnDeviceRecognition == true {
            recordingRequest.requiresOnDeviceRecognition = true
        }
        request = recordingRequest
        liveTranscript = ""
        let cycleID = UUID()
        activeTaskID = cycleID

        guard let recognizer else { throw SpeechError.recognizerUnavailable }
        recognitionTask = recognizer.recognitionTask(with: recordingRequest) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.activeTaskID == cycleID, self.shouldContinue else { return }
                if let result {
                    self.liveTranscript = result.bestTranscription.formattedString
                    if result.isFinal { self.commitAndRestart() }
                    else { self.scheduleCommitIfStable() }
                }
                if let error {
                    self.handleSpeechError(error)
                }
            }
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw SpeechError.audioFormat }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recordingRequest.append(buffer)
        }
        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()

        // Apple's classic Speech tasks are not intended to run indefinitely.
        // Restarting a task also flushes the last stable transcription.
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 43_000_000_000)
            guard !Task.isCancelled else { return }
            self?.commitAndRestart()
        }
    }

    private func scheduleCommitIfStable() {
        silenceTask?.cancel()
        let candidate = liveTranscript
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled, let self, self.liveTranscript == candidate else { return }
            // Never commit a trailing incomplete operation or an unclear word.
            guard (try? VietnameseNumberParser.parse(candidate)) != nil else { return }
            self.commitAndRestart()
        }
    }

    private func commitAndRestart() {
        guard shouldContinue else { return }
        let text = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Commit the current recognizer session only once.
        endCycle()
        liveTranscript = ""
        if !text.isEmpty { onRecognized?(text) }
        if shouldContinue {
            do {
                try beginCycle()
                consecutiveErrors = 0
                status = "Đang nghe · tiếp tục đọc"
                isListening = true
            } catch {
                shouldContinue = false
                isListening = false
                status = "Đã dừng do lỗi micro"
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleSpeechError(_ error: Error) {
        guard shouldContinue else { return }
        consecutiveErrors += 1
        if consecutiveErrors > 2 {
            shouldContinue = false
            isListening = false
            status = "Bộ nhận dạng Apple bị gián đoạn"
            errorMessage = error.localizedDescription
            endCycle()
            return
        }
        // A native task can end after a pause or when its internal limit is hit.
        commitAndRestart()
    }

    func stop() {
        shouldContinue = false
        isListening = false
        isStarting = false
        let final = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        endCycle()
        liveTranscript = ""
        status = "Đã tạm dừng · chạm để tiếp tục"
        if !final.isEmpty { onRecognized?(final) }
    }

    private func endCycle() {
        silenceTask?.cancel(); silenceTask = nil
        restartTask?.cancel(); restartTask = nil
        activeTaskID = UUID() // Ignore late results from cancelled tasks.
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        audioEngine.reset()
    }

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            if !available && self?.isListening == true {
                self?.errorMessage = "Bộ nhận dạng Apple tạm thời không khả dụng."
                self?.stop()
            }
        }
    }

    private enum SpeechError: LocalizedError {
        case recognizerUnavailable, audioFormat
        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable: "Không tìm thấy bộ nhận dạng tiếng Việt."
            case .audioFormat: "Không thể đọc định dạng âm thanh từ micro."
            }
        }
    }
}
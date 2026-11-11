# Máy tính giọng nói — ứng dụng iPhone gốc (SwiftUI)

Đây là **ứng dụng iOS riêng**, không phải PWA hay bản Web Speech cũ. Nút micro lớn sử dụng Apple Speech (`SFSpeechRecognizer` với `vi-VN`) và `AVAudioEngine`, không gọi mô hình Vosk, Moonshine, Whisper hay API AI trả phí. Bộ tính bằng Swift, lưu các phép tính trên iPhone.

## Chức năng

- Chạm **một nút micro lớn** để đọc số; hiển thị chữ đang nhận dạng và cộng khi đoạn nói đã ổn định.
- Hỗ trợ cộng/trừ/nhân/chia, phần trăm, cách đọc rút gọn như “4 ngàn rưỡi”, “5 ngàn 6”, 6 khoản hàng chục nghìn.
- Một câu có nhiều khoản chỉ được chốt khi đọc đủ; không cộng các bản kết quả tạm nhiều lần.
- **Lưu & Tính mới** luôn hiển thị ngay dưới tổng; hoàn tác, sửa khoản, lưu lịch sử trên máy và xuất CSV.
- Không tự suy đoán từ bị nhận nhầm; khi không rõ, giữ tổng cũ và hiển thị câu để sửa.

## Cấu hình và biên dịch

Yêu cầu: Mac có Xcode 16+, iPhone iOS 17+ và XcodeGen (`brew install xcodegen`).

```sh
cd native-ios
xcodegen generate
open VoiceCalculator.xcodeproj
```

Trong Xcode, chọn **VoiceCalculator → Signing & Capabilities**, đăng nhập Apple Account, chọn Team của bạn, sửa Bundle Identifier nếu cần, kết nối iPhone và chọn **Run** để cài. Với Apple Account miễn phí, Apple yêu cầu gia hạn chứng chỉ/cài lại định kỳ; để phân phối qua TestFlight cần chương trình Apple Developer Program có phí.

**Chưa có gói `.ipa` đã ký**. Không thể tự thay một biểu tượng PWA hiện có bằng ứng dụng native. Chỉ xóa PWA cũ sau khi ứng dụng native đã được cài và lịch sử cần thiết đã được xuất từ bản cũ.

## Lưu ý nhận giọng nói

Apple hỗ trợ nhận dạng cho những ngôn ngữ như bàn phím Dictation; tính khả dụng phải được kiểm tra trên máy. Nếu thiết bị hỗ trợ `supportsOnDeviceRecognition`, ứng dụng yêu cầu chạy trên máy. Nếu không, bộ nhận dạng Apple có thể cần Internet. Không có lời hứa nhận chính xác 100%; khi bộ nhận dạng nghe sai, người dùng sửa từng khoản.

## Dữ liệu cũ

Ứng dụng iOS dùng UserDefaults riêng. Lịch sử trong web app được lưu ở trình duyệt nên không tự chuyển sang native. Bản web cũ được giữ nguyên; hãy xuất CSV ở bản web trước khi gỡ biểu tượng.

## Trạng thái

Mã Swift được kiểm tra cú pháp, bộ phân tích số được chạy thử trong Swift và có unit tests trong `VoiceCalculatorTests`. Build iOS và ký app phải chạy trên môi trường macOS/Xcode; không coi dự án đã được cài vào điện thoại trước khi xác minh bản build ký hợp lệ.
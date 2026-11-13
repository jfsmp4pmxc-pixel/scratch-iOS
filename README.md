# LƯU Ý
- Đây chỉ là bản fork lại, không phải bản chính thức!
- Chỉ hỗ trợ IOS.

## Bản native (Swift + SwiftUI) — thư mục `native/`

Viết lại Scratch 3 để chạy native trên iPhone/iPad (iOS 15+), không còn WebView/JavaScript.

- `native/Sources/ScratchCore` — lõi Swift thuần (Foundation/CoreGraphics):
  - đọc/ghi `.sb3` (ZIP + `project.json`), giữ nguyên dữ liệu chưa hiểu khi lưu lại
  - bộ thông dịch block (motion, looks, sound, events, control, sensing, operators, variables/lists, pen, custom blocks, clones)
  - bộ vẽ sân khấu bằng CoreGraphics, có bộ rasterize SVG riêng, va chạm theo pixel, lớp bút, monitor biến, bong bóng thoại
- `native/App` — giao diện SwiftUI: sân khấu, cờ xanh/dừng, bàn phím ảo, danh sách sprite, mở/lưu/xuất dự án, hỏi đáp (`ask and wait`), âm thanh
- `native/Tests` — unit test cho lõi

### Build
```sh
cd native
swift test                     # test lõi (macOS)
brew install xcodegen
xcodegen generate              # tạo ScratchNative.xcodeproj
open ScratchNative.xcodeproj   # chạy trên simulator/thiết bị
```

### Chưa có trong bản native (giai đoạn 1)
- Trình chỉnh sửa khối (kéo-thả block), editor vẽ/âm thanh, thư viện sprite/backdrop, extension
- `touching color`, hiệu ứng đồ hoạ ngoài `ghost`, hiệu ứng/âm lượng nâng cao, monitor dạng list/slider
- Âm thanh WAV nén ADPCM có thể không phát được bằng AVAudioPlayer

Mã web cũ (React) vẫn còn trong repo để tham chiếu.

### Nhật ký thay đổi

#### 2.0.0-native (dev):
- bản viết lại native: lõi Swift + giao diện SwiftUI, chạy được file .sb3

#### b1.1.1 (1):
- thêm cơ chế lưu dự án

#### b1.0.4 (4):
- thử nghiệm bản build

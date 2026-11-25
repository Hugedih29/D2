[README.md](https://github.com/user-attachments/files/35418846/README.md)
# DepthEffect Suite cho RootHide

Bộ mã nguồn gồm hai tweak riêng cho iPhone X / iOS 16 / Dopamine RootHide:

1. **DepthLayer** — dùng Vision tách người khỏi ảnh nền rồi đặt lớp người phía trên đồng hồ Màn hình khóa. Đây là hiệu ứng lớp phủ do tweak tạo, không phải bộ dựng Depth Effect gốc của Apple.
2. **NativeDepthUnlock** — thử vượt qua một truy vấn kiểm tra năng lực của iOS nếu tên truy vấn có cả `depth` và từ liên quan đến wallpaper/Màn hình khóa. Đây là thử nghiệm; nó không thể bổ sung mã dựng hiệu ứng của Apple nếu iOS không có hoặc không gọi đường xử lý đó.

Mỗi tweak có một mục riêng trong Cài đặt. DepthLayer mặc định bật với chất lượng Cân bằng; NativeDepthUnlock mặc định tắt. Mỗi gói `.deb` bao gồm cả tweak và giao diện Cài đặt tương ứng.

## Giới hạn

Apple mô tả hiệu ứng ảnh nhiều lớp cho Màn hình khóa ở iOS 16, nhưng iPhone X không nằm trong nhóm được hỗ trợ chính thức cho hiệu ứng tùy chỉnh này. API Vision công khai dùng ở DepthLayer tạo mặt nạ cho người, không phải mọi loại vật thể. NativeDepthUnlock không bảo đảm hiệu ứng gốc sẽ xuất hiện trên iPhone X.

## Build qua GitHub Actions

Đưa nội dung thư mục này vào repository GitHub rồi chạy workflow **Build DepthEffect Suite** trong tab Actions. Workflow tạo hai gói RootHide `.deb`, một gói cho mỗi tweak, đã chứa bảng Cài đặt riêng.

Có thể build trên macOS với RootHide Theos và iOS SDK bằng `make package FINALPACKAGE=1` trong từng thư mục `DepthLayer` và `NativeDepthUnlock`.

## Trạng thái xác minh

Mã nguồn chưa được biên dịch hoặc chạy thử trên iPhone trong môi trường này. Chưa xác định được khóa năng lực Apple công khai, chính xác để bật Depth Effect gốc trên iPhone X. NativeDepthUnlock chỉ thử một truy vấn hẹp theo tên khóa; nếu iOS dùng khóa khác hoặc thiếu bộ dựng cần thiết, công tắc sẽ không tạo ra hiệu ứng. Dùng DepthLayer để thử hiệu ứng lớp người nếu đường xử lý wallpaper của phiên bản iOS cho phép.

//
//  ESPConfig.h
//  ESP isolated module
//

#ifndef ESPConfig_h
#define ESPConfig_h

#define ESP_DEFAULT_PROCESS "ShadowTrackerExtra"
#define ESP_MAX_ACTORS_SCAN 8000
// 1 lượt quét đầy đủ ~452 actor giờ chỉ tốn ~0.3-1.5s (đọc cửa sổ 0xF00/actor
// + bulk mảng), nên TTL ngắn để box bám người. Vẫn còn mutex chặn 2 luồng.
//
// TTL này là độ trễ phụ của quét ĐẦY ĐỦ (re-validate verdict/address reuse).
// Phát hiện địch MỚI không còn lệ thuộc TTL này — xem ESPEngineDiscoverTick
// (phân loại riêng actor chưa biết mỗi ~250ms). TTL chỉ là nhịp quét nền.
//
// 3.0s (kernrw55): log thực tế trên máy KHÔNG lấy được task port (Esign) cho
// thấy quét đầy đủ 1Hz + region-map làm tick refresh bị chặn 135-919ms
// (box perf tick max=919.7ms) và box tắt hàng chục giây. Vị trí box đọc mỗi
// tick ở ESPEngineRefreshBoxes nên TTL không làm box chậm; nó chỉ làm việc
// phân loại lại actor (verdict/address reuse) thưa hơn — đổi 1s -> 3s là
// giảm 2/3 số cú giật do scan.
#define ESP_CACHE_TTL 3.0 // quét nền 3s/lần khi không có task port (xem trên)

// Discover địch mới: khoảng (giây) giữa 2 lần + budget phân loại full/lần.
#define ESP_DISCOVER_INTERVAL 0.25 // 250ms — phát hiện địch mới ngay lập tức
#define ESP_DISCOVER_BUDGET 32 // budget unknown mỗi vòng — phân loại địch nhanh chóng
// Cập nhật vị trí box giữa 2 lượt quét: ESP_REFRESH_HZ lần/giây (đọc lại vị trí
// root + camera, KHÔNG phân loại lại actor — 60Hz bám sát chuyển động 60fps)
#define ESP_REFRESH_HZ 60

// Vị trí actor giờ được đọc lại MỖI frame refresh: 60Hz mượt mà
#define ESP_POS_READ_HZ 60

// Bù trễ pipeline của HUD. Vị trí/camera đọc ở tick T chỉ hiện trên màn hình
// sau khi qua present SpringBoard + 1 vsync, nên box vẽ đúng vị trí T sẽ nằm
// SAU lưng địch/khung hình (log thực tế: "box trễ, không bám" khi địch chạy
// hoặc khi lia camera). Cộng vận tốc * lead vào vị trí chiếu để box nằm đúng
// chỗ địch SẼ ở đó lúc frame HUD hiện ra. 0.016 = 1 frame 60Hz; đây chỉ là bù
// 1 frame nên không thể vọt xa (5m/s * 16ms = 8cm) và địch đứng yên thì
// vận tốc = 0 nên box đứng yên. Máy present chậm (>25ms) có thể nâng lên 0.024.
#define ESP_PREDICT_LEAD 0.016f

// BULK-MAP: map nhiều page liền nhau trong 1 lần.
#define ESP_BULK_MAP_ENABLED 1

// Ngưỡng degraded của ESPProvider:
#define ESP_PROVIDER_DEGRADE_FAILS 32
#define ESP_PROVIDER_RECOVER_READS 1024
#define ESP_PROVIDER_DEGRADED_BUDGET 4

// Nhịp cập nhật VỊ TRÍ label mét (Hz)
#define ESP_OVERLAY_LABEL_HZ 15

// Nhịp PRESENT lên SpringBoard: 60Hz đồng bộ 60 FPS mượt mà không khựng giật
#define ESP_PRESENT_HZ 60

// kernrw43: bitmap overlay (kernrw19-42) đã bị XOÁ HOÀN TOÀN — remote_write
// vài MB + setImage: mỗi frame là nguồn gây đơ máy. ESP giờ chỉ vẽ per-box
// (UIView viền + label) trực tiếp trên bridge.

// Chiều cao kẻ địch (cm) — CHỈ dùng làm mặc định khi không đọc được
// Mesh.Bounds.BoxExtent.Z (thường đọc được: height = extent.Z*2).
// QUAN TRỌNG: RootComponent.RelativeLocation là TÂM (capsule/mesh pivot center),
// KHÔNG phải chân — box phải vẽ pos ± height/2 (giống source Kernel:
// TopBox = Pos + H/2, BottomBox = Pos - H/2). Vẽ pos..pos+H (như cũ) sẽ đẩy
// toàn bộ box cao hơn địch ~80-90cm (đáy vượt gót, nóc vượt đầu).
#define ESP_CHAR_HEIGHT_CM 168.0f

#endif /* ESPConfig_h */

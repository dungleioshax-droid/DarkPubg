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
// (phân loại riêng actor chưa biết mỗi ~120ms). TTL 0.8s chỉ là nhịp quét nền.
#define ESP_CACHE_TTL 1.5 // quét nền 1.5s/lần — giảm tần suất full scan (trước 0.8s gây spike 59ms)

// Discover địch mới: khoảng (giây) giữa 2 lần + budget phân loại full/lần.
// 0.12s ~= 8Hz; budget 16 actor unknown mỗi lượt (page cache warm thì ~vài ms).
#define ESP_DISCOVER_INTERVAL 0.2 // khoảng (giây) giữa 2 lần discover — giảm tần suất scan enemy mới
// Budget unknown mỗi vòng: từ kernrw33 mỗi unknown quen chỉ tốn ~2 read
// (fields window + VTable check, FName walk chỉ cho VTable lạ) nên nâng 16->48
// để quét sạch ~100 unknown trong ~2 vòng (~0.24s) thay vì ~6 vòng (~0.8-2s).
// Địch mới (class đã biết) hiện sau ~1 vòng (~0.12s) thay vì 1-2s.
#define ESP_DISCOVER_BUDGET 24 // budget unknown mỗi vòng — giảm tải scan actor
// Cập nhật vị trí box giữa 2 lượt quét: ESP_REFRESH_HZ lần/giây (đọc lại vị trí
// root + camera, KHÔNG phân loại lại actor — rẻ hơn quét đầy đủ ~40 lần).
// kernrw45: 40->60Hz. Sau kernrw44 gỡ g_espClassifyMutex khỏi đường refresh,
// tick chỉ còn ~1-2ms (region-map memcpy + copy snapshot) nên vừa ngân sách
// 16.7ms. kernrw43 đo được thực chỉ ~25-30Hz + stall 716ms (log box perf
// n=224/7.5s) = box giật khi địch chạy; 60Hz cho step 16.7ms bám vận động.
#define ESP_REFRESH_HZ 30

// Vị trí actor giờ được đọc lại MỖI frame refresh: region map giữ sẵn mapping
// nên mỗi lần đọc chỉ là memcpy (~µs) — không còn đọc thưa + ngoại suy, nhờ đó
// box không còn "đứng im rồi nhảy". ESP_POS_READ_HZ chỉ giữ để tham chiếu.
#define ESP_POS_READ_HZ 20

// BULK-MAP: map nhiều page liền nhau trong 1 lần. Từ bản "region map" (map 1
// lần cho cả vùng vm_map_entry rồi giữ vĩnh viễn, bỏ LRU/dealloc) ESPMemory
// LUÔN map theo vùng — cờ này chỉ còn mang tính thông tin, giữ để tương thích.
#define ESP_BULK_MAP_ENABLED 1

// Ngưỡng degraded của ESPProvider (port DarkSwordMemoryProvider của Fl0rkFF):
// bao nhiêu lần đọc kernel fail LIÊN TIẾP thì vào degraded (bỏ bulk-map,
// discover budget nhỏ, reset task port + xả cache héo 1 lần).
#define ESP_PROVIDER_DEGRADE_FAILS 32
// Bao nhiêu lần đọc kernel OK liên tiếp khi đang degraded thì hồi phục.
#define ESP_PROVIDER_RECOVER_READS 1024
// Discover budget khi degraded (thường = ESP_DISCOVER_BUDGET).
#define ESP_PROVIDER_DEGRADED_BUDGET 4

// Nhịp cập nhật VỊ TRÍ label mét (Hz). Box bám 60Hz, chữ mét 10Hz là đủ mượt;
// giảm tải số remote call vào SpringBoard.
#define ESP_OVERLAY_LABEL_HZ 5

// Nhịp PRESENT lên SpringBoard (IPC remote — KHÔNG phải nội suy thuần CPU).
// kernrw39: 30->40Hz lại. Bản 38 để 30Hz (present thực ~20/s) thì lia máy/
// đi bộ thấy box bước từng nấc 50ms = "trôi/không khớp".
// kernrw45: 40->60Hz cùng ESP_REFRESH_HZ. Gate = 1/60 − 4ms = 12.7ms < tick
// 16.7ms -> present mỗi tick (~60/s); tải IPC ~300ms/s chấp nhận được nhờ
// label-subview + text 2Hz (kernrw38) giữ mỗi lượt ~4-5ms (pAvg ~7ms log43).
#define ESP_PRESENT_HZ 30

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

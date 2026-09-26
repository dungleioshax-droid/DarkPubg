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
#define ESP_CACHE_TTL 0.8 // quét nền 0.8s/lần — re-validate + địch mới qua discover

// Discover địch mới: khoảng (giây) giữa 2 lần + budget phân loại full/lần.
// 0.12s ~= 8Hz; budget 16 actor unknown mỗi lượt (page cache warm thì ~vài ms).
#define ESP_DISCOVER_INTERVAL 0.12
#define ESP_DISCOVER_BUDGET 16
// Cập nhật vị trí box giữa 2 lượt quét: ESP_REFRESH_HZ lần/giây (đọc lại vị trí
// root + camera, KHÔNG phân loại lại actor — rẻ hơn quét đầy đủ ~40 lần).
// 40Hz: mượt mà, bám sát nhịp chuyển động mà không gây nghẽn runloop SpringBoard.
#define ESP_REFRESH_HZ 40

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

// Nhịp cập nhật VỊ TRÍ label mét (Hz). Box bám 40Hz, chữ mét 10Hz là đủ mượt;
// giảm tải số remote call vào SpringBoard.
#define ESP_OVERLAY_LABEL_HZ 10

// Nhịp PRESENT nội suy (thuần CPU + IPC cached, không chạm kernel). App chạy
// NỀN nên CADisplayLink không tick được; 40Hz cực kỳ mượt mà vẫn an toàn tuyệt đối.
#define ESP_PRESENT_HZ 40

#endif /* ESPConfig_h */

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
// Overlay tick qua timer riêng (ds_esp_tick) + cache frame nên mượt mà
// không quá tải IPC sang SpringBoard.
#define ESP_REFRESH_HZ 60

// Nhịp ĐỌC KERNEL vị trí actor (Hz). Refresh ở trên chạy ESP_REFRESH_HZ nhưng
// giữa 2 lần đọc thì box được NGOẠI SUY từ vận tốc, nên box vẫn mượt 60Hz kể
// cả khi đường đọc memory chỉ kịp vài chục lần/giây (log thực tế: ~20ms/lần
// đọc kernel cho 1 actor). Giảm số này = càng nhẹ kernel nhưng ngoại suy càng
// xa (dễ lệch khi mục tiêu đổi hướng đột ngột). 15Hz là điểm cân bằng tốt.
#define ESP_POS_READ_HZ 15
// Khi TASK PORT của game bật được (patch CS_GET_TASK_ALLOW), mỗi lần đọc vị trí
// chỉ là 1 syscall (~µs) nên ESPEngineRefreshBoxes bỏ qua mốc này và đọc vị trí
// MỖI frame (60Hz, box bám sát, không ngoại suy). Giá trị 15Hz chỉ áp dụng cho
// đường kernel exploit (map page / đọc từng field).

// Ngưỡng degraded của ESPProvider (port DarkSwordMemoryProvider của Fl0rkFF):
// bao nhiêu lần đọc kernel fail LIÊN TIẾP thì vào degraded (bỏ bulk-map,
// discover budget nhỏ, reset task port + xả cache héo 1 lần).
#define ESP_PROVIDER_DEGRADE_FAILS 32
// Bao nhiêu lần đọc kernel OK liên tiếp khi đang degraded thì hồi phục.
#define ESP_PROVIDER_RECOVER_READS 1024
// Discover budget khi degraded (thường = ESP_DISCOVER_BUDGET).
#define ESP_PROVIDER_DEGRADED_BUDGET 4

// Nhịp cập nhật VỊ TRÍ label mét (Hz). Box phải bám 60Hz, còn chữ mét lệch vài
// chục ms không nhìn ra; mỗi setCenter/box/frame là phần lớn số remote call còn
// lại sau khi box đã đi qua path layer gộp.
#define ESP_OVERLAY_LABEL_HZ 15

// Nhịp PRESENT nội suy (thuần CPU + IPC cached, không chạm kernel). App chạy
// NỀN nên CADisplayLink không tick được; đây là tương đương vsync gần nhất.
#define ESP_PRESENT_HZ 60

#endif /* ESPConfig_h */

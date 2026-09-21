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
#define ESP_CACHE_TTL 2.0 // quét nền 2s/lần — box refresh đủ nhanh mà không dồn kernel
// Cập nhật vị trí box giữa 2 lượt quét: ESP_REFRESH_HZ lần/giây (đọc lại vị trí
// root + camera, KHÔNG phân loại lại actor — rẻ hơn quét đầy đủ ~40 lần).
// Overlay tick qua timer riêng (ds_esp_tick) + cache frame nên mượt mà
// không quá tải IPC sang SpringBoard.
#define ESP_REFRESH_HZ 8

// Nhịp PRESENT nội suy (thuần CPU + IPC cached, không chạm kernel). App chạy
// NỀN nên CADisplayLink không tick được; đây là tương đương vsync gần nhất.
// Giữ 20Hz: đủ mượt và không dội IPC/RemoteCall vào SpringBoard (30Hz từng
// làm phiên RemoteCall chết sớm).
#define ESP_PRESENT_HZ 20

#endif /* ESPConfig_h */

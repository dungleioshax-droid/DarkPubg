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
// TTL này là độ trễ để ĐỊCH MỚI XUẤT HIỆN có box: chỉ lượt quét mới phân loại
// được actor mới. Để 2.0s thì log thực tế cho thấy phải 5-6s mới thấy box (TTL
// 2s + lượt quét đầy đủ lâu). Sau khi cửa sổ actor đi qua page cache, lượt quét
// "ấm" chỉ tốn ~0.1-0.3s (log: dt=0.1s) nên 0.8s là thoải mái.
#define ESP_CACHE_TTL 0.8 // quét nền 0.8s/lần — địch mới hiện box trong ~1s
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

// Nhịp PRESENT nội suy (thuần CPU + IPC cached, không chạm kernel). App chạy
// NỀN nên CADisplayLink không tick được; đây là tương đương vsync gần nhất.
#define ESP_PRESENT_HZ 60

#endif /* ESPConfig_h */

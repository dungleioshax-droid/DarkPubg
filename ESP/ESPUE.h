//
//  ESPUE.h
//  Struct UE tối thiểu cho ESP.
//

#ifndef ESPUE_h
#define ESPUE_h

#include <stdint.h>

typedef struct {
    float x, y, z;
} ESPVector;

typedef struct {
    uint64_t data;
    uint32_t count;
    uint32_t max;
} ESPUArray;

typedef struct {
    float pitch, yaw, roll; // degrees, UE FRotator
} ESPRotator;

typedef struct {
    ESPVector location; // camera world
    ESPRotator rotation;
    float fov;    // degrees, horizontal-ish
    float aspect; // W/H, fallback tính từ screen
} ESPCamera;

// Box 2D đã project ra màn hình game (landscape points).
// (x,y) là góc trên-trái, w/h là size. distance mét.
// kernrw49: thêm nick (UTF-8, hiển thị dưới box giống Kernel) + kind
// (1 = player, 3 = hình nhân) để bridge vẽ style đúng (line chỉ với player).
typedef struct {
    float x, y, w, h;
    float distance;
    int health; // percent 0-100 cho thanh máu kiểu Source Kernel, -1 chưa đọc
    uint8_t visible; // 1 = đang trong tầm nhìn camera (mesh bRecentlyRendered)
    uint64_t actor; // AActor* pointer for stable slot tracking
    char nick[64];  // nickname UTF-8 ("Unknown" nếu đọc không được, "DUMMY" cho hình nhân)
    uint8_t kind;   // 1 = player character, 3 = hình nhân huấn luyện; 0 = khác
} ESPBox2D;

// Actor đã phân loại để refresh vị trí nhanh giữa 2 lượt quét đầy đủ.
typedef struct {
    uint64_t actor;
    uint64_t root;      // RootComponent (0 nếu không có)
    uint64_t fallback;  // StaticMeshComp/MoveRoot (ComponentToWorld) cho hình nhân
    uint64_t parent;    // AttachedParent của root lúc scan (0 = không có -> refresh bỏ qua parent read)
    int kind;           // 1 = character, 3 = hình nhân
    float height;       // chiều cao box (cm) đọc lúc scan (Mesh.Bounds.BoxExtent.Z*2), 0 = mặc định
} ESPTrackedActor;

// Kết quả scan phase 1
typedef struct {
    uint64_t world;          // UWorld*
    uint64_t level;          // ULevel*
    uint64_t actorCluster;   // ULevelActorContainer*
    uint32_t actorCount;     // TArray count
    uint32_t scanned;        // số actor đã đọc pointer
    uint32_t playerLike;     // tổng số địch + hình nhân đếm được
    uint32_t dummyLike;      // trong đó bao nhiêu là hình nhân huấn luyện
    uint64_t sampleActor;    // 1 actor mẫu để debug
    ESPVector samplePos;     // vị trí mẫu (nếu đọc được)
    BOOL hasSamplePos;
} ESPScanResult;

#endif /* ESPUE_h */

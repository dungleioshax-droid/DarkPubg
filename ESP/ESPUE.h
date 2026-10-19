//
//  ESPUE.h
//  Struct UE tối thiểu cho ESP.
//

#ifndef ESPUE_h
#define ESPUE_h

#include <stdint.h>
#include <limits.h>

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

// Xương (port hướng QBL getBoneWithRotationFast): mỗi khớp là 1 điểm đã
// project ra màn hình game (landscape points). Bridge nối các cặp trong bảng
// cạnh của nó (không cần bảng ở đây — engine chỉ trả điểm).
#define ESP_BOX_BONES 17
typedef struct {
    float x, y;
    uint8_t ok; // 1 = khớp đọc + project được frame này
} ESPBone2D;

// Thứ tự khớp trong ESPBox2D.bones[] — HỢP ĐỒNG engine <-> bridge.
// Trái/phải chỉ là quy ước: bản đồ index runtime tự nhận diện chuỗi vai ->
// khuỷu -> bàn tay / hông -> gối -> bàn chân, nên hoán vị L/R không đổi hình.
enum {
    ESPBone_Head = 0,
    ESPBone_Neck,
    ESPBone_Chest,
    ESPBone_Pelvis,
    ESPBone_LShoulder,
    ESPBone_LElbow,
    ESPBone_LHand,
    ESPBone_RShoulder,
    ESPBone_RElbow,
    ESPBone_RHand,
    ESPBone_LHip,
    ESPBone_LKnee,
    ESPBone_LFoot,
    ESPBone_RHip,
    ESPBone_RKnee,
    ESPBone_RFoot,
    ESPBone_Root,
    ESPBone_Count // == ESP_BOX_BONES
};

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
    // qblpack: 3 field thêm cuối struct (init kiểu {...} cũ vẫn hợp lệ vì phần
    // thừa zero-init).
    int team;         // TeamID (INT_MIN nếu chưa đọc được) — "T<id>" kiểu QBL TeamID
    uint8_t isAI;     // 1 = bot/AI pawn (tên khớp ESPNameIsAIPawn) — AIMarkDifferent
    uint8_t boneCount; // số khớp xương ok trong bones[] (0 = không vẽ xương)
    ESPBone2D bones[ESP_BOX_BONES];
} ESPBox2D;

// Actor đã phân loại để refresh vị trí nhanh giữa 2 lượt quét đầy đủ.
typedef struct {
    uint64_t actor;
    uint64_t root;      // RootComponent (0 nếu không có)
    uint64_t fallback;  // StaticMeshComp/MoveRoot (ComponentToWorld) cho hình nhân
    uint64_t parent;    // AttachedParent của root lúc scan (0 = không có -> refresh bỏ qua parent read)
    uint64_t mesh;      // SkeletalMeshComponent (0 nếu không có) — nguồn xương
    int kind;           // 1 = character, 3 = hình nhân
    float height;       // chiều cao box (cm) đọc lúc scan (Mesh.Bounds.BoxExtent.Z*2), 0 = mặc định
    int team;           // TeamID lúc scan (INT_MIN nếu không đọc được) — qblpack TeamID
    uint8_t isAI;       // 1 = AI/bot (phân loại theo tên/VTable lúc scan) — qblpack
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

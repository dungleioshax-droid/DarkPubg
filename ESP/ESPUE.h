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

// Kết quả scan phase 1
typedef struct {
    uint64_t world;          // UWorld*
    uint64_t level;          // ULevel*
    uint64_t actorCluster;   // ULevelActorContainer*
    uint32_t actorCount;     // TArray count
    uint32_t scanned;        // số actor đã đọc pointer
    uint32_t playerLike;     // actor có RootComponent != 0 (lọc thô)
    uint64_t sampleActor;    // 1 actor mẫu để debug
    ESPVector samplePos;     // vị trí mẫu (nếu đọc được)
    BOOL hasSamplePos;
} ESPScanResult;

#endif /* ESPUE_h */

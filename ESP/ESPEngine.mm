//
//  ESPEngine.mm
//  Phase 1: tìm UWorld qua GUObject enumeration, vào Actors, đếm.
//  Không crash nếu offsets sai — mọi read đều check BOOL.
//

#import "ESPEngine.h"
#import "ESPOffsets.h"
#import "ESPMemory.h"
#import "ESPConfig.h"

#if USE_DARKSWORD
extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

// FUObjectItem size 0x18 (từ dump), Object ở +0x0
static const uint32_t kFUObjectItemSize = 0x18;
// TUObjectArray: Objects ở +0x0 là ptr tới chunk? Dump: TUObjectArray.Objects 0x0, NumElements 0xc
// Thực tế GUObjectArray = struct { TUObjectArray* ... } — dùng cách đọc đơn giản:
// GUObjectArray -> ObjObjects (0x10 từ FUObjectArray) -> TArray chunks.
// Để giữ phase 1 ổn định, ta đi đường tắt: GEngine -> ... -> World?
// Đơn giản + robust nhất hiện tại: enumerate GUObjectArray tìm Class Engine.World.

static uint64_t ESPObjObjectsRuntime(uint64_t gameBase) {
    return ESPRuntime(gameBase, ESPDump_ObjObjects);
}

static BOOL ESPReadPtr(uint64_t vmMap, uint64_t addr, uint64_t *out) {
    if (!addr) return NO;
    BOOL ok = NO;
    uint64_t v = ESPReadU64(vmMap, addr, &ok);
    if (!ok) return NO;
    if (out) *out = v;
    return YES;
}

// Tìm UWorld đầu tiên qua GUObjectArray.
// GUObjectArray layout (UE4.25+): FUObjectArray { TUObjectArray ObjObjects @0x10 { TArray<FUObjectItem> ... } }
// Ta đọc: guArray -> objObjectsPtr = *(guArray+0x10?) — nhưng dump đã cho ObjObjects riêng.
// Đơn giản: ObjObjects = TArray base của FUObjectItem chunks? Thực tế ObjObjects là TUObjectArray*
// Đọc NumElements ở ObjObjects+0xc, Objects ở ObjObjects+0x0 (ptr tới FUObjectItem array hoặc chunks).
// Với Num 206k, nó là flat array (NumElementsPerChunk 0) nên Objects là ptr tới FUObjectItem[Num].
static uint64_t ESPFindWorld(uint64_t vmMap, uint64_t gameBase, uint32_t *outNum) {
    uint64_t objObjects = ESPObjObjectsRuntime(gameBase);
    // objObjects là địa chỉ của TUObjectArray trong memory game (con trỏ tĩnh).
    // Cần deref? Trong dump: ObjObjects: [<Base>+0x10A692D28] = 0x10F636D28 — đó là địa chỉ tĩnh chứa TUObjectArray.
    // Nên đọc TUObjectArray tại đó.
    BOOL ok = NO;
    uint64_t objectsPtr = ESPReadU64(vmMap, objObjects + 0x0, &ok);
    if (!ok || !objectsPtr) return 0;
    uint32_t num = ESPReadU32(vmMap, objObjects + 0xc, &ok);
    if (!ok || num == 0 || num > 500000) return 0;
    if (outNum) *outNum = num;
    uint32_t limit = num > ESP_MAX_ACTORS_SCAN * 40 ? ESP_MAX_ACTORS_SCAN * 40 : num;
    // Quét tìm Object có ClassPrivate trỏ tới UClass tên "World"? Không có GNames decode ở phase 1
    // nên dùng heuristic: UWorld size 0xE38, PersistentLevel ở +0x30 trỏ tới ULevel hợp lệ.
    // Để tránh scan 200k objects nặng, chỉ check mỗi 7th + giới hạn 20k.
    for (uint32_t i = 0; i < limit; i += 7) {
        uint64_t itemAddr = objectsPtr + (uint64_t)i * kFUObjectItemSize;
        uint64_t obj = 0;
        if (!ESPReadPtr(vmMap, itemAddr + 0x0, &obj) || !obj) continue;
        if (obj < 0x100000000ULL) continue;
        uint64_t persistentLevel = 0;
        if (!ESPReadPtr(vmMap, obj + ESPOff_UWorld_PersistentLevel, &persistentLevel)) continue;
        if (!persistentLevel || persistentLevel < 0x100000000ULL) continue;
        // persistentLevel phải có ActorCluster ptr hợp lệ
        uint64_t cluster = 0;
        if (!ESPReadPtr(vmMap, persistentLevel + ESPOff_ULevel_ActorCluster, &cluster)) continue;
        if (!cluster || cluster < 0x100000000ULL) continue;
        // cluster + 0x28 là TArray Actors: data ptr + count
        uint64_t actorsData = 0;
        if (!ESPReadPtr(vmMap, cluster + ESPOff_ActorCluster_Actors + 0x0, &actorsData)) continue;
        uint32_t actorsCount = ESPReadU32(vmMap, cluster + ESPOff_ActorCluster_Actors + 0x8, &ok);
        if (!ok || actorsCount == 0 || actorsCount > 20000) continue;
        if (!actorsData || actorsData < 0x100000000ULL) continue;
        return obj; // UWorld candidate
    }
    return 0;
}

ESPScanResult ESPEngineScan(uint64_t gameBase) {
    ESPScanResult r = {0};
#if !USE_DARKSWORD
    (void)gameBase;
    return r;
#else
    if (!gameBase || !ds_is_ready()) return r;
    // Lấy proc game hiện tại qua Base? DSBridge đã cache proc, nhưng ở đây tự tìm lại nhẹ:
    uint64_t proc = procbyname(ESP_DEFAULT_PROCESS);
    if (!proc) {
        // thử prefix truncated
        proc = procbyname("ShadowTrackerE");
        if (!proc) return r;
    }
    uint64_t task = taskbyproc(proc);
    uint64_t vmMap = task ? task_get_vm_map(task) : 0;
    if (!vmMap) return r;

    uint32_t objNum = 0;
    uint64_t world = ESPFindWorld(vmMap, gameBase, &objNum);
    if (!world) return r;
    r.world = world;

    BOOL ok = NO;
    uint64_t level = ESPReadU64(vmMap, world + ESPOff_UWorld_PersistentLevel, &ok);
    if (!ok || !level) return r;
    r.level = level;
    uint64_t cluster = ESPReadU64(vmMap, level + ESPOff_ULevel_ActorCluster, &ok);
    if (!ok || !cluster) return r;
    r.actorCluster = cluster;
    uint64_t actorsData = ESPReadU64(vmMap, cluster + ESPOff_ActorCluster_Actors + 0x0, &ok);
    if (!ok) return r;
    uint32_t actorsCount = ESPReadU32(vmMap, cluster + ESPOff_ActorCluster_Actors + 0x8, &ok);
    if (!ok) return r;
    r.actorCount = actorsCount;
    if (!actorsData || actorsCount == 0 || actorsCount > 20000) return r;

    uint32_t scanN = actorsCount > ESP_MAX_ACTORS_SCAN ? ESP_MAX_ACTORS_SCAN : actorsCount;
    uint32_t playerLike = 0;
    uint64_t sample = 0;
    ESPVector samplePos = {0,0,0};
    BOOL hasPos = NO;
    for (uint32_t i = 0; i < scanN; i++) {
        uint64_t actor = ESPReadU64(vmMap, actorsData + (uint64_t)i * 8, &ok);
        if (!ok || !actor || actor < 0x100000000ULL) continue;
        r.scanned++;
        uint64_t root = ESPReadU64(vmMap, actor + ESPOff_Actor_RootComponent, &ok);
        if (!ok || !root || root < 0x100000000ULL) continue;
        playerLike++;
        if (!sample) {
            sample = actor;
            // Thử đọc RelativeLocation ở RootComponent+0x1E4
            ESPVector v = {0,0,0};
            if (ESPMemoryRead(vmMap, root + ESPOff_Scene_RelativeLocation, &v, sizeof(v))) {
                samplePos = v;
                hasPos = YES;
            }
        }
    }
    r.playerLike = playerLike;
    r.sampleActor = sample;
    r.samplePos = samplePos;
    r.hasSamplePos = hasPos;
    return r;
#endif
}

static CFAbsoluteTime g_espCheckedAt = 0;
static ESPScanResult g_espCache = {0};

NSString *ESPEngineStatusText(uint64_t gameBase) {
    if (!gameBase) return @"ESP: --";
#if !USE_DARKSWORD
    (void)gameBase;
    return @"ESP: --";
#else
    if (!ds_is_ready()) return @"ESP: wait…";
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - g_espCheckedAt < ESP_CACHE_TTL && g_espCheckedAt > 0) {
        // dùng cache
    } else {
        g_espCache = ESPEngineScan(gameBase);
        g_espCheckedAt = now;
    }
    if (!g_espCache.world) return @"ESP: --";
    return [NSString stringWithFormat:@"ESP: %u actors / %u players",
            (unsigned)g_espCache.actorCount, (unsigned)g_espCache.playerLike];
#endif
}

uint32_t ESPEnginePlayerCount(uint64_t gameBase) {
    if (!gameBase) return 0;
#if !USE_DARKSWORD
    (void)gameBase;
    return 0;
#else
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - g_espCheckedAt >= ESP_CACHE_TTL || g_espCheckedAt == 0) {
        g_espCache = ESPEngineScan(gameBase);
        g_espCheckedAt = now;
    }
    return g_espCache.playerLike;
#endif
}

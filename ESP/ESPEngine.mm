//
//  ESPEngine.mm
//  Phase 1: tìm UWorld qua GUObject enumeration, vào Actors, đếm.
//  Không crash nếu offsets sai — mọi read đều check BOOL.
//

#import "ESPEngine.h"
#import "ESPOffsets.h"
#import "ESPMemory.h"
#import "ESPConfig.h"

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

// MARK: - Camera + W2S + Boxes (phase 2 box thật)

#if USE_DARKSWORD
static BOOL ESPReadVec(uint64_t vmMap, uint64_t addr, ESPVector *out) {
    if (!addr || !out) return NO;
    return ESPMemoryRead(vmMap, addr, out, sizeof(ESPVector));
}
static uint64_t ESPProcVMMap(uint64_t *outProc) {
    uint64_t proc = procbyname(ESP_DEFAULT_PROCESS);
    if (!proc) proc = procbyname("ShadowTrackerE");
    if (!proc) return 0;
    if (outProc) *outProc = proc;
    uint64_t task = taskbyproc(proc);
    return task ? task_get_vm_map(task) : 0;
}
#endif

BOOL ESPEngineCamera(uint64_t gameBase, ESPCamera *outCam) {
    if (!outCam) return NO;
#if !USE_DARKSWORD
    (void)gameBase;
    return NO;
#else
    if (!gameBase || !ds_is_ready()) return NO;
    uint64_t vmMap = ESPProcVMMap(NULL);
    if (!vmMap) return NO;
    // Reuse world từ cache nếu có để đỡ scan lại
    uint64_t world = g_espCache.world;
    if (!world) {
        ESPScanResult r = ESPEngineScan(gameBase);
        world = r.world;
        if (!world) return NO;
    }
    BOOL ok = NO;
    uint64_t gameInst = ESPReadU64(vmMap, world + ESPOff_UWorld_OwningGameInstance, &ok);
    if (!ok || !gameInst) return NO;
    uint64_t localPlayersData = ESPReadU64(vmMap, gameInst + ESPOff_GameInstance_LocalPlayers + 0x0, &ok);
    uint32_t localN = ESPReadU32(vmMap, gameInst + ESPOff_GameInstance_LocalPlayers + 0x8, &ok);
    if (!ok || !localPlayersData || localN == 0) return NO;
    uint64_t localPlayer = ESPReadU64(vmMap, localPlayersData + 0x0, &ok);
    if (!ok || !localPlayer) return NO;
    uint64_t pc = ESPReadU64(vmMap, localPlayer + ESPOff_Player_PlayerController, &ok);
    if (!ok || !pc) return NO;
    uint64_t camMgr = ESPReadU64(vmMap, pc + ESPOff_PC_CameraManager, &ok);
    if (!ok || !camMgr) return NO;
    uint64_t pov = camMgr + ESPOff_CamMgr_CameraCache + ESPOff_Cache_POV;
    ESPVector loc = {0,0,0};
    if (!ESPReadVec(vmMap, pov + ESPOff_POV_Location, &loc)) return NO;
    ESPRotator rot = {0,0,0};
    if (!ESPMemoryRead(vmMap, pov + ESPOff_POV_Rotation, &rot, sizeof(rot))) return NO;
    float fov = 0, aspect = 0;
    {
        float tmp = 0;
        if (!ESPMemoryRead(vmMap, pov + ESPOff_POV_FOV, &tmp, sizeof(tmp))) return NO;
        fov = tmp;
        if (!ESPMemoryRead(vmMap, pov + ESPOff_POV_Aspect, &tmp, sizeof(tmp))) return NO;
        aspect = tmp;
    }
    if (fov < 10 || fov > 170) return NO;
    if (!(aspect > 0.3 && aspect < 4.0)) aspect = 0; // để caller fill từ screen
    outCam->location = loc;
    outCam->rotation = rot;
    outCam->fov = fov;
    outCam->aspect = aspect;
    return YES;
#endif
}

BOOL ESPWorldToScreen(ESPVector world, ESPCamera cam, float screenW, float screenH, float *outX, float *outY, float *outDist) {
    if (screenW <= 0 || screenH <= 0) return NO;
    if (!(cam.fov >= 10 && cam.fov <= 170)) return NO;
    float aspect = cam.aspect;
    if (!(aspect > 0.3 && aspect < 4.0)) aspect = screenW / screenH;
    // UE FRotator degrees -> radians
    const float kPi = 3.141592653589793f;
    float pitch = cam.rotation.pitch * kPi / 180.0f;
    float yaw   = cam.rotation.yaw   * kPi / 180.0f;
    float roll  = cam.rotation.roll  * kPi / 180.0f;
    float cp = cosf(pitch), sp = sinf(pitch);
    float cy = cosf(yaw),   sy = sinf(yaw);
    float cr = cosf(roll),  sr = sinf(roll);
    // UE axes (cm): X forward, Y right, Z up
    // Forward = (cp*cy, cp*sy, sp)? UE pitch dương nhìn lên? Dùng chuẩn:
    // forward=(cp*cy, cp*sy, sp), right=(-sy, cy, 0) bỏ roll, up tính đủ.
    // Để gồm roll cho đúng:
    ESPVector fwd = { cp*cy, cp*sy, sp };
    // Right trước roll: (-sy, cy, 0), Up trước roll: (-sp*cy, -sp*sy, cp)
    ESPVector r0 = { -sy, cy, 0 };
    ESPVector u0 = { -sp*cy, -sp*sy, cp };
    ESPVector right = { r0.x*cr + u0.x*sr, r0.y*cr + u0.y*sr, r0.z*cr + u0.z*sr };
    ESPVector up    = { u0.x*cr - r0.x*sr, u0.y*cr - r0.y*sr, u0.z*cr - r0.z*sr };
    ESPVector d = { world.x - cam.location.x, world.y - cam.location.y, world.z - cam.location.z };
    float distM = sqrtf(d.x*d.x + d.y*d.y + d.z*d.z) / 100.0f; // cm -> m
    float x = d.x*fwd.x + d.y*fwd.y + d.z*fwd.z; // depth (forward)
    if (x < 100.0f) return NO; // sau lưng / quá gần (1m)
    float y = d.x*right.x + d.y*right.y + d.z*right.z;
    float z = d.x*up.x + d.y*up.y + d.z*up.z;
    float tanHalf = tanf(cam.fov * kPi / 360.0f);
    if (!(tanHalf > 0.05f && tanHalf < 5.0f)) return NO;
    float cx = screenW * 0.5f, cyC = screenH * 0.5f;
    float sx = cx + (y / (x * tanHalf * aspect)) * cx;
    float syC = cyC - (z / (x * tanHalf)) * cyC;
    if (outX) *outX = sx;
    if (outY) *outY = syC;
    if (outDist) *outDist = distM;
    // ngoài màn hình vẫn trả YES để caller tự lọc margin? Ở đây lọc luôn:
    if (sx < -100 || sx > screenW + 100 || syC < -100 || syC > screenH + 100) return NO;
    if (distM > 350.0f) return NO;
    return YES;
}

int ESPEngineBoxes(uint64_t gameBase, float screenW, float screenH, ESPBox2D *outBoxes, int maxBoxes) {
    if (!outBoxes || maxBoxes <= 0) return 0;
#if !USE_DARKSWORD
    (void)gameBase; (void)screenW; (void)screenH;
    return 0;
#else
    if (!gameBase || !ds_is_ready()) return 0;
    if (screenW <= 0 || screenH <= 0) return 0;
    uint64_t vmMap = ESPProcVMMap(NULL);
    if (!vmMap) return 0;
    ESPCamera cam;
    if (!ESPEngineCamera(gameBase, &cam)) return 0;
    if (!(cam.aspect > 0.3 && cam.aspect < 4.0)) cam.aspect = screenW / screenH;
    // Lấy actors từ cache/scan
    uint64_t world = g_espCache.world;
    uint64_t level = 0, cluster = 0, actorsData = 0;
    uint32_t actorsCount = 0;
    BOOL ok = NO;
    if (!world) {
        ESPScanResult r = ESPEngineScan(gameBase);
        world = r.world;
    }
    if (!world) return 0;
    // Đọc lại level/cluster để tươi (rẻ, không scan GUObject)
    level = ESPReadU64(vmMap, world + ESPOff_UWorld_PersistentLevel, &ok);
    if (!ok || !level) return 0;
    cluster = ESPReadU64(vmMap, level + ESPOff_ULevel_ActorCluster, &ok);
    if (!ok || !cluster) return 0;
    actorsData = ESPReadU64(vmMap, cluster + ESPOff_ActorCluster_Actors + 0x0, &ok);
    if (!ok) return 0;
    actorsCount = ESPReadU32(vmMap, cluster + ESPOff_ActorCluster_Actors + 0x8, &ok);
    if (!ok || actorsCount == 0 || actorsCount > 20000) return 0;
    uint32_t scanN = actorsCount > ESP_MAX_ACTORS_SCAN ? ESP_MAX_ACTORS_SCAN : actorsCount;
    // Lấy vị trí mình để bỏ qua self (actor gần camera <2m)
    int n = 0;
    float tanHalf = tanf(cam.fov * 3.141592653589793f / 360.0f);
    if (!(tanHalf > 0.05f && tanHalf < 5.0f)) return 0;
    for (uint32_t i = 0; i < scanN && n < maxBoxes; i++) {
        uint64_t actor = ESPReadU64(vmMap, actorsData + (uint64_t)i * 8, &ok);
        if (!ok || !actor || actor < 0x100000000ULL) continue;
        // Vị trí world: thử ReplicatedMovement Location trước
        ESPVector pos = {0,0,0};
        BOOL gotPos = NO;
        {
            ESPVector v = {0,0,0};
            if (ESPMemoryRead(vmMap, actor + ESPOff_Actor_ReplicatedMovement + ESPOff_RepMovement_Location, &v, sizeof(v))) {
                // lọc vector rác
                if (fabsf(v.x) < 200000 && fabsf(v.y) < 200000 && fabsf(v.z) < 200000 && (v.x != 0 || v.y != 0 || v.z != 0)) {
                    pos = v; gotPos = YES;
                }
            }
        }
        if (!gotPos) {
            uint64_t root = ESPReadU64(vmMap, actor + ESPOff_Actor_RootComponent, &ok);
            if (!ok || !root) continue;
            ESPVector v = {0,0,0};
            if (!ESPMemoryRead(vmMap, root + ESPOff_Scene_RelativeLocation, &v, sizeof(v))) continue;
            if (fabsf(v.x) > 200000 || fabsf(v.y) > 200000 || fabsf(v.z) > 200000) continue;
            if (v.x == 0 && v.y == 0 && v.z == 0) continue;
            pos = v; gotPos = YES;
        }
        if (!gotPos) continue;
        float sx = 0, sy = 0, dist = 0;
        // Project chân (pos) và đầu (pos.z + 180cm) để ra chiều cao box
        float hx = 0, hy = 0, hd = 0;
        if (!ESPWorldToScreen(pos, cam, screenW, screenH, &sx, &sy, &dist)) continue;
        if (dist < 2.0f) continue; // self
        ESPVector head = pos; head.z += 180.0f;
        if (!ESPWorldToScreen(head, cam, screenW, screenH, &hx, &hy, &hd)) {
            // đầu ngoài màn nhưng chân trong — vẫn vẽ box ước lượng
            float hEst = (180.0f / (dist * 100.0f * tanHalf)) * (screenH * 0.5f);
            float wEst = hEst * 0.5f;
            if (hEst < 8 || hEst > screenH) continue;
            outBoxes[n++] = (ESPBox2D){ sx - wEst*0.5f, sy - hEst, wEst, hEst, dist, -1 };
            continue;
        }
        float h = fabsf(sy - hy);
        if (h < 8 || h > screenH * 1.2f) continue;
        float w = h * 0.5f;
        outBoxes[n++] = (ESPBox2D){ sx - w*0.5f, hy, w, h, dist, -1 };
    }
    return n;
#endif
}

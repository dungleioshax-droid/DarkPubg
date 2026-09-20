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

// Chain nhanh GEngine->Viewport->World (không scan 200k objects).

static int g_espStep = 0; // debug: kẹt ở đâu (xem StatusText E#)

static uint64_t ESPGEngineRuntime(uint64_t gameBase) {
    return ESPRuntime(gameBase, ESPDump_GEngine);
}

static BOOL ESPReadPtr(uint64_t vmMap, uint64_t addr, uint64_t *out) {
    if (!addr) return NO;
    BOOL ok = NO;
    uint64_t v = ESPReadU64(vmMap, addr, &ok);
    if (!ok) return NO;
    if (out) *out = v;
    return YES;
}

static BOOL ESPIsUserPtr(uint64_t p) {
    return p >= 0x100000000ULL && p < 0x300000000000ULL;
}

// Chain nhanh, không scan 200k objects:
// GEngine_static -> UGameEngine -> GameViewport(0x810) -> World(0x78),
// validate World qua PersistentLevel->ActorCluster->Actors.
static uint64_t ESPWorldViaViewport(uint64_t vmMap, uint64_t gameBase) {
    g_espStep = 3;
    uint64_t geStatic = ESPGEngineRuntime(gameBase);
    BOOL ok = NO;
    uint64_t engine = ESPReadU64(vmMap, geStatic, &ok);
    if (!ok || !ESPIsUserPtr(engine)) return 0;
    g_espStep = 4;
    uint64_t viewport = ESPReadU64(vmMap, engine + ESPOff_Engine_GameViewport, &ok);
    if (!ok || !ESPIsUserPtr(viewport)) {
        // Fallback: UGameEngine->GameInstance->... không cho World trực tiếp,
        // thử GameInstance->LocalPlayers->PC->Pawn->Outer(Level)->OwningWorld
        uint64_t gameInst = ESPReadU64(vmMap, engine + ESPOff_GameEngine_GameInstance, &ok);
        if (!ok || !ESPIsUserPtr(gameInst)) return 0;
        uint64_t lpData = ESPReadU64(vmMap, gameInst + ESPOff_GameInstance_LocalPlayers + 0x0, &ok);
        uint32_t lpN = ESPReadU32(vmMap, gameInst + ESPOff_GameInstance_LocalPlayers + 0x8, &ok);
        if (!ok || !ESPIsUserPtr(lpData) || lpN == 0 || lpN > 8) return 0;
        uint64_t lp = ESPReadU64(vmMap, lpData, &ok);
        if (!ok || !ESPIsUserPtr(lp)) return 0;
        uint64_t pc = ESPReadU64(vmMap, lp + ESPOff_Player_PlayerController, &ok);
        if (!ok || !ESPIsUserPtr(pc)) return 0;
        uint64_t pawn = ESPReadU64(vmMap, pc + 0x528, &ok); // AcknowledgedPawn
        if (!ok || !ESPIsUserPtr(pawn)) return 0;
        uint64_t outer = ESPReadU64(vmMap, pawn + 0x20, &ok); // OuterPrivate -> ULevel?
        if (!ok || !ESPIsUserPtr(outer)) return 0;
        uint64_t world2 = ESPReadU64(vmMap, outer + 0xC0, &ok); // Level OwningWorld
        if (!ok || !ESPIsUserPtr(world2)) return 0;
        g_espStep = 5;
        return world2;
    }
    g_espStep = 5;
    uint64_t world = ESPReadU64(vmMap, viewport + ESPOff_Viewport_World, &ok);
    if (!ok || !ESPIsUserPtr(world)) return 0;
    return world;
}

static BOOL ESPClusterActors(uint64_t vmMap, uint64_t cluster, uint64_t *outData, uint32_t *outCount) {
    BOOL ok = NO;
    uint64_t data = ESPReadU64(vmMap, cluster + ESPOff_ActorCluster_Actors + 0x0, &ok);
    if (!ok) return NO;
    uint32_t count = ESPReadU32(vmMap, cluster + ESPOff_ActorCluster_Actors + 0x8, &ok);
    if (!ok || count > 30000) return NO;
    // data==0 + count==0 (level trống) vẫn ok — caller tự quyết
    if (outData) *outData = data;
    if (outCount) *outCount = count;
    return ESPIsUserPtr(data) || count == 0;
}

// Quét tất cả Levels của World, chọn level có nhiều actors nhất.
// Trả về level/cluster tốt nhất. Set g_espStep 61/62/63 khi fail.
static BOOL ESPLevelAndCluster(uint64_t vmMap, uint64_t world, uint64_t *outLevel, uint64_t *outCluster) {
    BOOL ok = NO;
    uint64_t candidates[18];
    int nCand = 0;
    // 1) PersistentLevel
    {
        uint64_t lv = ESPReadU64(vmMap, world + ESPOff_UWorld_PersistentLevel, &ok);
        if (ok && ESPIsUserPtr(lv) && nCand < 18) candidates[nCand++] = lv;
    }
    // 2) CurrentLevel 0x468
    {
        uint64_t cur = ESPReadU64(vmMap, world + 0x468, &ok);
        if (ok && ESPIsUserPtr(cur)) {
            BOOL dup = NO;
            for (int i = 0; i < nCand; i++) if (candidates[i] == cur) { dup = YES; break; }
            if (!dup && nCand < 18) candidates[nCand++] = cur;
        }
    }
    // 3) Levels[] array (streaming levels — PUBG map lớn)
    {
        uint64_t levelsData = ESPReadU64(vmMap, world + ESPOff_UWorld_Levels + 0x0, &ok);
        uint32_t levelsN = ESPReadU32(vmMap, world + ESPOff_UWorld_Levels + 0x8, &ok);
        if (ok && ESPIsUserPtr(levelsData) && levelsN > 0 && levelsN <= 32) {
            for (uint32_t i = 0; i < levelsN && nCand < 18; i++) {
                uint64_t lv = ESPReadU64(vmMap, levelsData + (uint64_t)i * 8, &ok);
                if (!ok || !ESPIsUserPtr(lv)) continue;
                BOOL dup = NO;
                for (int j = 0; j < nCand; j++) if (candidates[j] == lv) { dup = YES; break; }
                if (!dup) candidates[nCand++] = lv;
            }
        }
    }
    if (nCand == 0) { g_espStep = 61; return NO; }
    // Chọn level có actors nhiều nhất + cluster hợp lệ
    uint64_t bestLv = 0, bestCl = 0;
    uint32_t bestCount = 0;
    BOOL anyLevelOwningOk = NO;
    for (int i = 0; i < nCand; i++) {
        uint64_t lv = candidates[i];
        // check chéo: Level.OwningWorld phải == world (nếu đọc được)
        uint64_t ow = ESPReadU64(vmMap, lv + ESPOff_ULevel_OwningWorld, &ok);
        if (ok && ow == world) anyLevelOwningOk = YES;
        uint64_t cl = ESPReadU64(vmMap, lv + ESPOff_ULevel_ActorCluster, &ok);
        if (!ok || !ESPIsUserPtr(cl)) continue;
        uint64_t ad = 0; uint32_t ac = 0;
        if (!ESPClusterActors(vmMap, cl, &ad, &ac)) continue;
        if (ac > bestCount) { bestCount = ac; bestLv = lv; bestCl = cl; }
        if (bestLv == 0) { bestLv = lv; bestCl = cl; }
    }
    if (bestLv && bestCl) {
        if (outLevel) *outLevel = bestLv;
        if (outCluster) *outCluster = bestCl;
        return YES;
    }
    // Không level nào có cluster hợp lệ: phân biệt world sai vs cluster sai
    g_espStep = anyLevelOwningOk ? 62 : 63;
    return NO;
}

static BOOL ESPValidateWorld(uint64_t vmMap, uint64_t world) {
    uint64_t lv = 0, cl = 0;
    if (ESPLevelAndCluster(vmMap, world, &lv, &cl)) {
        // check actors data/count (g_espStep 71/72 nếu sai)
        BOOL ok = NO;
        uint64_t actorsData = ESPReadU64(vmMap, cl + ESPOff_ActorCluster_Actors + 0x0, &ok);
        uint32_t actorsCount = ESPReadU32(vmMap, cl + ESPOff_ActorCluster_Actors + 0x8, &ok);
        if (!ok) { g_espStep = 71; return NO; }
        if (actorsCount > 30000) { g_espStep = 72; return NO; }
        if (!ESPIsUserPtr(actorsData) && actorsCount != 0) { g_espStep = 71; return NO; }
        return YES;
    }
    // g_espStep đã là 61/62/63
    return NO;
}

ESPScanResult ESPEngineScan(uint64_t gameBase) {
    ESPScanResult r = {0};
#if !USE_DARKSWORD
    (void)gameBase;
    return r;
#else
    g_espStep = 1;
    if (!gameBase || !ds_is_ready()) return r;
    // Lấy proc game hiện tại qua Base? DSBridge đã cache proc, nhưng ở đây tự tìm lại nhẹ:
    uint64_t proc = procbyname(ESP_DEFAULT_PROCESS);
    if (!proc) {
        // thử prefix truncated
        proc = procbyname("ShadowTrackerE");
        if (!proc) { g_espStep = 1; return r; }
    }
    uint64_t task = taskbyproc(proc);
    uint64_t vmMap = task ? task_get_vm_map(task) : 0;
    if (!vmMap) { g_espStep = 2; return r; }

    g_espStep = 3;
    uint64_t world = ESPWorldViaViewport(vmMap, gameBase);
    if (!world) return r; // g_espStep đã set 3/4/5 bên trong
    if (!ESPValidateWorld(vmMap, world)) return r; // g_espStep 61/62/71/72
    g_espStep = 0;
    r.world = world;

    BOOL ok = NO;
    uint64_t level = 0, cluster = 0;
    if (!ESPLevelAndCluster(vmMap, world, &level, &cluster)) return r;
    r.level = level;
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
    if (!g_espCache.world) {
        int step = g_espStep;
        if (step > 0) return [NSString stringWithFormat:@"ESP: -- E%d", step];
        return @"ESP: --";
    }
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

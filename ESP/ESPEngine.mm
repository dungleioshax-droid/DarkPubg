//
//  ESPEngine.mm
//  Phase 1: tìm UWorld qua GUObject enumeration, vào Actors, đếm.
//  Không crash nếu offsets sai — mọi read đều check BOOL.
//

#import "ESPEngine.h"
#import "ESPOffsets.h"
#import "ESPMemory.h"
#import "ESPConfig.h"
#include <unordered_map>
#include <limits.h>

extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

// Chain nhanh GEngine->Viewport->World (không scan 200k objects).

static int g_espStep = 0; // debug: kẹt ở đâu (xem StatusText E#)
static std::unordered_map<uint64_t, char> g_espVerdict; // 1=character, 2=other
static std::unordered_map<uint64_t, int> g_espTeamCache;
static uint64_t g_espVerdictWorld = 0;

static void ESPVerdictResetIfWorldChanged(uint64_t world) {
    if (g_espVerdictWorld != world) {
        g_espVerdict.clear();
        g_espTeamCache.clear();
        g_espVerdictWorld = world;
    }
}

// myTeam qua NetDriver chain (source Kernel). INT_MIN nếu chưa rõ.
static BOOL ESPMyTeamAndPawn(uint64_t vmMap, uint64_t world, uint64_t *outPawn, int *outTeam) {
    BOOL ok = NO;
    uint64_t net = ESPReadU64(vmMap, world + ESPOff_World_NetDriver, &ok);
    if (!ok || !ESPIsUserPtr(net)) return NO;
    uint64_t conn = ESPReadU64(vmMap, net + ESPOff_NetDriver_ServerConn, &ok);
    if (!ok || !ESPIsUserPtr(conn)) return NO;
    uint64_t pc = ESPReadU64(vmMap, conn + ESPOff_Conn_LocalPC, &ok);
    if (!ok || !ESPIsUserPtr(pc)) return NO;
    uint64_t pawn = ESPReadU64(vmMap, pc + ESPOff_PC_LocalPawn, &ok);
    if (!ok || !ESPIsUserPtr(pawn)) return NO;
    int team = (int)ESPReadU32(vmMap, pawn + ESPOff_Char_Team, &ok);
    if (!ok) return NO;
    if (outPawn) *outPawn = pawn;
    if (outTeam) *outTeam = team;
    return YES;
}

// Lọc enemy thật theo source Kernel: Mesh + Health/Max + TeamID, rồi bHidden/bDead/team.
// verdict 2 (other) được cache để lần sau khỏi đọc.
static BOOL ESPIsEnemy(uint64_t vmMap, uint64_t actor, int myTeam, int *outTeam, float *outHp) {
    auto vit = g_espVerdict.find(actor);
    if (vit != g_espVerdict.end() && vit->second == 2) return NO;
    BOOL ok = NO;
    if (vit == g_espVerdict.end()) {
        uint64_t mesh = ESPReadU64(vmMap, actor + ESPOff_Char_Mesh, &ok);
        if (!ok || !ESPIsUserPtr(mesh)) {
            if (g_espVerdict.size() > 3000) { g_espVerdict.clear(); g_espTeamCache.clear(); }
            g_espVerdict[actor] = 2;
            return NO;
        }
        float hp = 0, mx = 0;
        if (!ESPMemoryRead(vmMap, actor + ESPOff_Char_Health, &hp, 4) ||
            !ESPMemoryRead(vmMap, actor + ESPOff_Char_HealthMax, &mx, 4)) {
            g_espVerdict[actor] = 2;
            return NO;
        }
        int team = (int)ESPReadU32(vmMap, actor + ESPOff_Char_Team, &ok);
        if (!ok || !(hp >= 0 && hp <= 2000 && mx > 0 && mx <= 2000 && team >= 0 && team <= 200000000)) {
            if (g_espVerdict.size() > 3000) { g_espVerdict.clear(); g_espTeamCache.clear(); }
            g_espVerdict[actor] = 2;
            return NO;
        }
        if (g_espVerdict.size() > 3000) { g_espVerdict.clear(); g_espTeamCache.clear(); }
        g_espVerdict[actor] = 1;
        g_espTeamCache[actor] = team;
    }
    int team = INT_MIN;
    auto tit = g_espTeamCache.find(actor);
    if (tit != g_espTeamCache.end()) {
        team = tit->second;
    } else {
        team = (int)ESPReadU32(vmMap, actor + ESPOff_Char_Team, &ok);
        if (!ok) return NO;
        g_espTeamCache[actor] = team;
    }
    uint8_t hid = ESPReadU8(vmMap, actor + ESPOff_Actor_HiddenFlag, &ok);
    if (!ok) return NO;
    uint8_t dead = ESPReadU8(vmMap, actor + ESPOff_Char_Dead, &ok);
    if (!ok) return NO;
    if ((hid & 0x1) || (dead & 0x1)) return NO;
    float hp = 0;
    if (!ESPMemoryRead(vmMap, actor + ESPOff_Char_Health, &hp, 4)) return NO;
    if (!(hp > 0 && hp <= 2000)) return NO;
    if (myTeam != INT_MIN && team == myTeam && team != ESPTeam_Dummy) return NO;
    if (outTeam) *outTeam = team;
    if (outHp) *outHp = hp;
    return YES;
}

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

static uint8_t ESPReadU8(uint64_t vmMap, uint64_t addr, BOOL *ok) {
    uint8_t v = 0;
    BOOL r = ESPMemoryRead(vmMap, addr, &v, sizeof(v));
    if (ok) *ok = r;
    return v;
}

// Port từ /home/dungle/Kernel/esp/unity_api/unity.mm DecryptActorsArray(Level, 0xA0, 0x448).
// Trả về địa chỉ của TArray Actors (đọc data ở +0x0, count ở +0x8). 0 nếu fail.
static uint64_t ESPDecryptActorsArray(uint64_t vmMap, uint64_t uLevel) {
    if (!ESPIsUserPtr(uLevel)) return 0;
    BOOL ok = NO;
    uint64_t vA0 = ESPReadU64(vmMap, uLevel + ESPOff_ULevel_Actors, &ok);
    if (ok && vA0 > 0) return uLevel + ESPOff_ULevel_Actors;
    uint64_t v448 = ESPReadU64(vmMap, uLevel + ESPOff_ULevel_EncryptedActors, &ok);
    if (ok && v448 > 0) return uLevel + ESPOff_ULevel_EncryptedActors;
    uint64_t enc[4] = {0,0,0,0};
    for (int i = 0; i < 4; i++) {
        enc[i] = ESPReadU64(vmMap, uLevel + ESPOff_ULevel_EncryptedActors + 0x10 + (uint64_t)i * 8, &ok);
        if (!ok) return 0;
    }
    if (enc[0] > 0) {
        uint32_t vals[8] = {0,0,0,0,0,0,0,0};
        for (int i = 0; i < 8; i++) {
            vals[i] = ESPReadU32(vmMap, enc[0] + 0x80 + (uint64_t)i * 4, &ok);
            if (!ok) return 0;
        }
        uint8_t b[8] = {0,0,0,0,0,0,0,0};
        for (int i = 0; i < 8; i++) {
            b[i] = ESPReadU8(vmMap, enc[0] + vals[i], &ok);
            if (!ok) return 0;
        }
        // Giữ nguyên logic gốc (|| trả về 0/1) — nhánh này hiếm khi chạy ở bản này.
        uint64_t r = ((((uint64_t)(b[0] || (b[1] < 8)) || (b[2] < 0x10))) & 0xFFFFFFULL)
            || ((uint64_t)b[3] < 0x18)
            || ((uint64_t)b[4] < 0x20);
        r = (r & 0xFFFF00FFFFFFFFFFULL)
            || ((uint64_t)b[5] < 0x28)
            || ((uint64_t)b[6] < 0x30)
            || ((uint64_t)b[7] < 0x38);
        return r;
    } else if (enc[1] > 0) {
        uint64_t ea = ESPReadU64(vmMap, enc[1], &ok);
        if (!ok || ea == 0) return 0;
        uint64_t r = ((uint64_t)(uint16_t)(ea - 0x400) & 0xFF00ULL)
            || ((uint64_t)(uint8_t)(ea - 0x04))
            || ((ea + 0xFC0000ULL) & 0xFF0000ULL)
            || ((ea - 0x4000000ULL) & 0xFF000000ULL)
            || ((ea + 0xFC00000000ULL) & 0xFF00000000ULL)
            || ((ea + 0xFC0000000000ULL) & 0xFF0000000000ULL)
            || ((ea + 0xFC000000000000ULL) & 0xFF000000000000ULL)
            || ((ea - 0x400000000000000ULL) & 0xFF00000000000000ULL);
        return r;
    } else if (enc[2] > 0) {
        uint64_t ea = ESPReadU64(vmMap, enc[2], &ok);
        if (!ok || ea == 0) return 0;
        return (ea > 0x38) | (ea < (64 - 0x38));
    } else if (enc[3] > 0) {
        uint64_t ea = ESPReadU64(vmMap, enc[3], &ok);
        if (!ok || ea == 0) return 0;
        return ea ^ 0xCDCD00ULL;
    }
    return 0;
}

static BOOL ESPActorsOfLevel(uint64_t vmMap, uint64_t level, uint64_t *outData, uint32_t *outCount) {
    uint64_t arr = ESPDecryptActorsArray(vmMap, level);
    if (!arr) return NO;
    BOOL ok = NO;
    uint64_t data = ESPReadU64(vmMap, arr + 0x0, &ok);
    if (!ok) return NO;
    uint32_t count = ESPReadU32(vmMap, arr + 0x8, &ok);
    if (!ok || count > 30000) return NO;
    if (outData) *outData = data;
    if (outCount) *outCount = count;
    return ESPIsUserPtr(data) || count == 0;
}

// Quét tất cả Levels của World, chọn level có nhiều actors nhất (qua decrypt 0xA0/0x448).
// Trả về level + TArray actors tốt nhất. Set g_espStep 61/62/63 khi fail.
static BOOL ESPLevelAndActors(uint64_t vmMap, uint64_t world, uint64_t *outLevel,
                              uint64_t *outActorsData, uint32_t *outActorsCount) {
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
    // Chọn level có actors nhiều nhất (qua decrypt 0xA0/0x448)
    uint64_t bestLv = 0;
    uint64_t bestAd = 0;
    uint32_t bestCount = 0;
    BOOL anyLevelOwningOk = NO;
    for (int i = 0; i < nCand; i++) {
        uint64_t lv = candidates[i];
        // check chéo: Level.OwningWorld phải == world (nếu đọc được)
        uint64_t ow = ESPReadU64(vmMap, lv + ESPOff_ULevel_OwningWorld, &ok);
        if (ok && ow == world) anyLevelOwningOk = YES;
        uint64_t ad = 0; uint32_t ac = 0;
        if (!ESPActorsOfLevel(vmMap, lv, &ad, &ac)) continue;
        if (ac > bestCount) { bestCount = ac; bestLv = lv; bestAd = ad; }
        if (bestLv == 0) { bestLv = lv; bestAd = ad; bestCount = ac; }
    }
    if (bestLv && (ESPIsUserPtr(bestAd) || bestCount == 0)) {
        if (outLevel) *outLevel = bestLv;
        if (outActorsData) *outActorsData = bestAd;
        if (outActorsCount) *outActorsCount = bestCount;
        return YES;
    }
    // Không level nào decrypt được actors: phân biệt world sai vs actors sai
    g_espStep = anyLevelOwningOk ? 62 : 63;
    return NO;
}

static BOOL ESPValidateWorld(uint64_t vmMap, uint64_t world) {
    uint64_t lv = 0;
    uint64_t ad = 0;
    uint32_t ac = 0;
    if (ESPLevelAndActors(vmMap, world, &lv, &ad, &ac)) {
        if (ac > 30000) { g_espStep = 72; return NO; }
        if (!ESPIsUserPtr(ad) && ac != 0) { g_espStep = 71; return NO; }
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
    uint64_t level = 0;
    uint64_t actorsData = 0;
    uint32_t actorsCount = 0;
    if (!ESPLevelAndActors(vmMap, world, &level, &actorsData, &actorsCount)) return r;
    r.level = level;
    r.actorCluster = 0; // không dùng cluster ở bản này (decrypt 0xA0/0x448)
    r.actorCount = actorsCount;
    if (!actorsData || actorsCount == 0 || actorsCount > 20000) return r;

    uint32_t scanN = actorsCount > ESP_MAX_ACTORS_SCAN ? ESP_MAX_ACTORS_SCAN : actorsCount;
    ESPVerdictResetIfWorldChanged(world);
    int myTeam = INT_MIN;
    { int t = INT_MIN; uint64_t lp = 0; if (ESPMyTeamAndPawn(vmMap, world, &lp, &t)) myTeam = t; }
    uint32_t enemies = 0;
    uint64_t sample = 0;
    ESPVector samplePos = {0,0,0};
    BOOL hasPos = NO;
    for (uint32_t i = 0; i < scanN; i++) {
        uint64_t actor = ESPReadU64(vmMap, actorsData + (uint64_t)i * 8, &ok);
        if (!ok || !actor || actor < 0x100000000ULL) continue;
        r.scanned++;
        int team = 0; float hp = 0;
        if (!ESPIsEnemy(vmMap, actor, myTeam, &team, &hp)) continue;
        enemies++;
        if (!sample) {
            sample = actor;
            uint64_t root = ESPReadU64(vmMap, actor + ESPOff_Actor_RootComponent, &ok);
            if (ok && ESPIsUserPtr(root)) {
                ESPVector v = {0,0,0};
                if (ESPMemoryRead(vmMap, root + ESPOff_Scene_RelativeLocation, &v, sizeof(v))) {
                    samplePos = v;
                    hasPos = YES;
                }
            }
        }
    }
    r.playerLike = enemies;
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
    // Port đúng công thức Kernel/esp/unity_api/unity.mm World2Screen
    // (cả 2 trục đều dùng screenCenterX).
    if (screenW <= 0 || screenH <= 0) return NO;
    if (!(cam.fov >= 10 && cam.fov <= 170)) return NO;
    const float kPi = 3.141592653589793f;
    float radPitch = cam.rotation.pitch * kPi / 180.0f;
    float radYaw   = cam.rotation.yaw   * kPi / 180.0f;
    float radRoll  = cam.rotation.roll  * kPi / 180.0f;
    float SP = sinf(radPitch), CP = cosf(radPitch);
    float SY = sinf(radYaw),   CY = cosf(radYaw);
    float SR = sinf(radRoll),  CR = cosf(radRoll);
    // Hàng ma trận như RotatorToMatrix gốc
    float m00 = CP*CY, m01 = CP*SY, m02 = SP;
    float m10 = SR*SP*CY - CR*SY, m11 = SR*SP*SY + CR*CY, m12 = -SR*CP;
    float m20 = -(CR*SP*CY + SR*SY), m21 = CY*SR - CR*SP*SY, m22 = CR*CP;
    ESPVector d = { world.x - cam.location.x, world.y - cam.location.y, world.z - cam.location.z };
    // vTransformed = (dot(d,Y), dot(d,Z), dot(d,X)) theo code gốc
    float tx = d.x*m10 + d.y*m11 + d.z*m12;
    float ty = d.x*m20 + d.y*m21 + d.z*m22;
    float tz = d.x*m00 + d.y*m01 + d.z*m02;
    if (tz < 1.0f) tz = 1.0f;
    float distM = sqrtf(d.x*d.x + d.y*d.y + d.z*d.z) / 100.0f;
    float cx = screenW * 0.5f, cyC = screenH * 0.5f;
    float tanHalf = tanf(cam.fov * kPi / 360.0f);
    if (!(tanHalf > 0.05f && tanHalf < 5.0f)) return NO;
    float sx = cx + tx * (cx / tanHalf) / tz;
    float syC = cyC - ty * (cx / tanHalf) / tz;
    if (outX) *outX = sx;
    if (outY) *outY = syC;
    if (outDist) *outDist = distM;
    if (sx < -100 || sx > screenW + 100 || syC < -100 || syC > screenH + 100) return NO;
    if (distM > 350.0f) return NO;
    // sau lưng thật: depth chưa rotate < 0 (dự phòng, vì tz đã clamp)
    float depth = d.x*(CP*CY) + d.y*(CP*SY) + d.z*SP;
    if (depth < 100.0f) return NO;
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
    // Lấy actors từ cache/scan (qua decrypt 0xA0/0x448, không qua cluster)
    uint64_t world = g_espCache.world;
    BOOL ok = NO;
    if (!world) {
        ESPScanResult r = ESPEngineScan(gameBase);
        world = r.world;
        if (world) {
            // dùng actors từ scan mới nhất nếu có
            if (r.actorCount > 0) {
                // r đã có actorCount nhưng không giữ actorsData — đọc lại rẻ:
            }
        }
    }
    if (!world) return 0;
    uint64_t level = 0;
    uint64_t actorsData = 0;
    uint32_t actorsCount = 0;
    if (!ESPLevelAndActors(vmMap, world, &level, &actorsData, &actorsCount)) return 0;
    if (!actorsData || actorsCount == 0 || actorsCount > 20000) return 0;
    uint32_t scanN = actorsCount > ESP_MAX_ACTORS_SCAN ? ESP_MAX_ACTORS_SCAN : actorsCount;
    ESPVerdictResetIfWorldChanged(world);
    int myTeam = INT_MIN;
    { int t = INT_MIN; if (ESPMyTeamAndPawn(vmMap, world, NULL, &t)) myTeam = t; }
    int n = 0;
    float tanHalf = tanf(cam.fov * 3.141592653589793f / 360.0f);
    if (!(tanHalf > 0.05f && tanHalf < 5.0f)) return 0;
    for (uint32_t i = 0; i < scanN && n < maxBoxes; i++) {
        uint64_t actor = ESPReadU64(vmMap, actorsData + (uint64_t)i * 8, &ok);
        if (!ok || !actor || actor < 0x100000000ULL) continue;
        int team = 0; float hp = 0;
        if (!ESPIsEnemy(vmMap, actor, myTeam, &team, &hp)) continue;
        // Vị trí world theo source Kernel: Root.Relative + Parent.Relative
        // ( ComponentToWorld 0x1D0 để dự phòng nếu Relative fail — xem offset.h )
        ESPVector pos = {0,0,0};
        BOOL gotPos = NO;
        {
            uint64_t root = ESPReadU64(vmMap, actor + ESPOff_Actor_RootComponent, &ok);
            if (ok && ESPIsUserPtr(root)) {
                ESPVector loc = {0,0,0};
                if (ESPMemoryRead(vmMap, root + ESPOff_Scene_RelativeLocation, &loc, sizeof(loc)) &&
                    fabsf(loc.x) < 300000 && fabsf(loc.y) < 300000 && fabsf(loc.z) < 300000 &&
                    (loc.x != 0 || loc.y != 0 || loc.z != 0)) {
                    uint64_t parent = ESPReadU64(vmMap, root + ESPOff_Scene_AttachedParent, &ok);
                    if (ok && ESPIsUserPtr(parent)) {
                        ESPVector pl = {0,0,0};
                        if (ESPMemoryRead(vmMap, parent + ESPOff_Scene_RelativeLocation, &pl, sizeof(pl)) &&
                            fabsf(pl.x) < 300000 && fabsf(pl.y) < 300000 && fabsf(pl.z) < 300000) {
                            loc.x += pl.x; loc.y += pl.y; loc.z += pl.z;
                        }
                    }
                    pos = loc; gotPos = YES;
                }
            }
        }
        if (!gotPos) {
            ESPVector v = {0,0,0};
            if (ESPMemoryRead(vmMap, actor + ESPOff_Actor_ReplicatedMovement + ESPOff_RepMovement_Location, &v, sizeof(v))) {
                if (fabsf(v.x) < 300000 && fabsf(v.y) < 300000 && fabsf(v.z) < 300000 && (v.x != 0 || v.y != 0 || v.z != 0)) {
                    pos = v; gotPos = YES;
                }
            }
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
            outBoxes[n++] = (ESPBox2D){ sx - wEst*0.5f, sy - hEst, wEst, hEst, dist, (int)hp };
            continue;
        }
        float h = fabsf(sy - hy);
        if (h < 8 || h > screenH * 1.2f) continue;
        float w = h * 0.5f;
        outBoxes[n++] = (ESPBox2D){ sx - w*0.5f, hy, w, h, dist, (int)hp };
    }
    return n;
#endif
}

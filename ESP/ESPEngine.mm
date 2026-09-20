//
//  ESPEngine.mm
//  Phase 1: tìm UWorld qua GUObject enumeration, vào Actors, đếm.
//  Không crash nếu offsets sai — mọi read đều check BOOL.
//

#import "ESPEngine.h"
#import "ESPOffsets.h"
#import "ESPMemory.h"
#import "ESPConfig.h"
#import "ESPName.h"
#import "ESPLog.h"
#include <unordered_map>
#include <limits.h>
#include <atomic>
#include <string.h>

extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

// Chain nhanh GEngine->Viewport->World (không scan 200k objects).

static BOOL ESPIsUserPtr(uint64_t p);
static uint8_t ESPReadU8(uint64_t vmMap, uint64_t addr, BOOL *ok);

// --- Cửa sổ actor: 1 lần map page lấy HẾT field (trước đây ~8 lần map page) ---
// 0x0 VTable, 0x18 FName, 0xE8 bHidden, 0x208 RootComponent,
// 0x4AC/0x4D0/0x4D4/0x4E8 hình nhân, 0x510 Mesh, 0x998 TeamID,
// 0xE60/0xE64 Health/HealthMax, 0xE7C bDead — tất cả nằm trong 0xF00 byte đầu.
// Mỗi lần đọc 1 field = 1 vòng allocate + make_memory_entry + map + dealloc
// (+1 port) trong kernel. Quét vài trăm actor x ~8 field là hàng nghìn vòng
// -> app bị Jetsam kill giữa lúc quét (scan đứng ~50%). Đọc 1 cửa sổ 0xF00
// byte chỉ còn 1-2 vòng cho mỗi actor.
#define ESP_ACTOR_WINDOW 0xF00

typedef struct {
    uint64_t vtable, root, mesh, tMesh;
    uint32_t nameID;
    float hp, hpMax, tCur, tMax;
    uint8_t bHidden, bDead, tIsUp;
    int team;
    BOOL hasVtable, hasName, hasRoot, hasMesh, hasHp, hasTarget, hasTeam;
    BOOL window; // đọc được cả cửa sổ 1 lần => mọi field đều đáng tin
} ESPActorFields;

static inline uint64_t ESPWinU64(const uint8_t *b, uint32_t off) {
    uint64_t v = 0;
    memcpy(&v, b + off, sizeof(v));
    return v;
}

static inline uint32_t ESPWinU32(const uint8_t *b, uint32_t off) {
    uint32_t v = 0;
    memcpy(&v, b + off, sizeof(v));
    return v;
}

static inline float ESPWinF32(const uint8_t *b, uint32_t off) {
    float v = 0;
    memcpy(&v, b + off, sizeof(v));
    return v;
}

static BOOL ESPReadF32(uint64_t vmMap, uint64_t addr, float *out) {
    BOOL ok = NO;
    uint32_t raw = ESPReadU32(vmMap, addr, &ok);
    if (ok && out) memcpy(out, &raw, sizeof(raw));
    return ok;
}

// Đọc hết field của 1 actor. Không fail cứng: field nào không đọc được thì
// has* = NO, caller tự quyết định (giữ nguyên hành vi cũ khi thiếu field).
static void ESPActorFieldsRead(uint64_t vmMap, uint64_t actor, ESPActorFields *f) {
    memset(f, 0, sizeof(*f));
    f->team = INT_MIN;
    if (!ESPIsUserPtr(actor)) return;
    uint8_t win[ESP_ACTOR_WINDOW];
    if (ESPMemoryRead(vmMap, actor, win, sizeof(win))) {
        f->window = YES;
        f->vtable = ESPWinU64(win, 0x0);
        f->hasVtable = YES;
        f->nameID = ESPWinU32(win, 0x18);
        f->hasName = YES;
        f->bHidden = win[ESPOff_Actor_HiddenFlag];
        f->bDead = win[ESPOff_Char_Dead];
        f->root = ESPWinU64(win, ESPOff_Actor_RootComponent);
        f->hasRoot = YES;
        f->mesh = ESPWinU64(win, ESPOff_Char_Mesh);
        f->hasMesh = YES;
        f->team = (int)ESPWinU32(win, ESPOff_Char_Team);
        f->hasTeam = YES;
        f->hp = ESPWinF32(win, ESPOff_Char_Health);
        f->hpMax = ESPWinF32(win, ESPOff_Char_HealthMax);
        f->hasHp = YES;
        f->tMesh = ESPWinU64(win, ESPOff_Target_Mesh);
        f->tCur = ESPWinF32(win, ESPOff_Target_CurHealth);
        f->tMax = ESPWinF32(win, ESPOff_Target_MaxHealth);
        f->tIsUp = win[ESPOff_Target_IsUp];
        f->hasTarget = YES;
        return;
    }
    // Fallback: object nằm sát cuối vùng mapped -> đọc lẻ từng field.
    BOOL ok = NO;
    f->vtable = ESPReadU64(vmMap, actor + 0x0, &ok);
    f->hasVtable = ok;
    f->nameID = ESPReadU32(vmMap, actor + 0x18, &ok);
    f->hasName = ok;
    f->bHidden = ESPReadU8(vmMap, actor + ESPOff_Actor_HiddenFlag, &ok);
    f->bDead = ESPReadU8(vmMap, actor + ESPOff_Char_Dead, &ok);
    f->root = ESPReadU64(vmMap, actor + ESPOff_Actor_RootComponent, &ok);
    f->hasRoot = ok;
    f->mesh = ESPReadU64(vmMap, actor + ESPOff_Char_Mesh, &ok);
    f->hasMesh = ok;
    uint32_t rawTeam = ESPReadU32(vmMap, actor + ESPOff_Char_Team, &ok);
    if (ok) {
        f->team = (int)rawTeam;
        f->hasTeam = YES;
    } else {
        f->team = INT_MIN;
    }
    f->hasHp = ESPReadF32(vmMap, actor + ESPOff_Char_Health, &f->hp);
    (void)ESPReadF32(vmMap, actor + ESPOff_Char_HealthMax, &f->hpMax);
    f->tMesh = ESPReadU64(vmMap, actor + ESPOff_Target_Mesh, &ok);
    if (ok && ESPReadF32(vmMap, actor + ESPOff_Target_MaxHealth, &f->tMax) &&
        ESPReadF32(vmMap, actor + ESPOff_Target_CurHealth, &f->tCur)) {
        f->tIsUp = ESPReadU8(vmMap, actor + ESPOff_Target_IsUp, &ok);
        f->hasTarget = ok;
    }
}


static int g_espStep = 0; // debug: kẹt ở đâu (xem StatusText E#)
static int g_espPasses = 0; // số lượt quét xong từ khi đổi world (đủ 3 lượt mới full)
static int g_espSliceTurn = 0; // xoay vòng 1/3 actors/lượt như Kernel
static std::atomic_int g_espProgress{-1}; // index đang lọc (để hiện %)
static std::atomic_int g_espProgressTotal{0};
static uint64_t g_espUName = 0; // GNames đã giải mã cho base hiện tại
static uint64_t g_espPlayerVTable = 0; // VTable class player đã học
static std::unordered_map<uint64_t, char> g_espVerdict; // 1=character, 3=target, 2=other
static std::unordered_map<uint64_t, int> g_espTeamCache;
static std::unordered_map<uint64_t, int> g_espVerdictFrame; // frame lúc kết luận, để hết hạn
static int g_espFrame = 0;
static const int kESPverdictExpiryFrames = 6; // verdict 2 quá 6 scans thì đánh giá lại
static uint64_t g_espVerdictWorld = 0;

static void ESPVerdictResetIfWorldChanged(uint64_t world) {
    if (g_espVerdictWorld != world) {
        g_espVerdict.clear();
        g_espTeamCache.clear();
        g_espVerdictFrame.clear();
        g_espVerdictWorld = world;
        g_espPlayerVTable = 0; // học lại VTable cho world mới
        g_espPasses = 0;
        g_espSliceTurn = 0;
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

static void ESPVerdictSet(uint64_t actor, char v, int team) {
    if (g_espVerdict.size() > 3000) {
        g_espVerdict.clear();
        g_espTeamCache.clear();
        g_espVerdictFrame.clear();
    }
    g_espVerdict[actor] = v;
    g_espVerdictFrame[actor] = g_espFrame;
    if (v == 1 || v == 3) g_espTeamCache[actor] = team;
}

// Lọc enemy thật theo source Kernel: Mesh + Health/Max + TeamID, rồi bHidden/bDead/team.
// verdict 1=character, 3=target huấn luyện, 2=other.
// verdict 2 hết hạn sau kESPverdictExpiryFrames scans để đánh giá lại
// (tránh kẹt 1/4 do lúc map chưa load đã kết luận).
static BOOL ESPIsEnemy(uint64_t vmMap, uint64_t actor, int myTeam, int *outTeam, float *outHp) {
    auto vit = g_espVerdict.find(actor);
    if (vit != g_espVerdict.end() && vit->second == 2) {
        auto fit = g_espVerdictFrame.find(actor);
        int age = (fit != g_espVerdictFrame.end()) ? (g_espFrame - fit->second) : 999;
        if (age <= kESPverdictExpiryFrames) return NO;
        g_espVerdict.erase(actor);
        g_espVerdictFrame.erase(actor);
        g_espTeamCache.erase(actor);
        vit = g_espVerdict.end();
    }
    if (vit == g_espVerdict.end()) {
        // 1 lần đọc cửa sổ actor: đủ field cho mọi nhánh phân loại bên dưới.
        ESPActorFields f;
        ESPActorFieldsRead(vmMap, actor, &f);
        // 0) VTable đã học (từ pawn của mình hoặc actor đầu): 0 read thêm.
        if (f.hasVtable && g_espPlayerVTable && f.vtable == g_espPlayerVTable) {
            ESPVerdictSet(actor, 1, (f.hasTeam && f.team >= 0 && f.team <= 200000000) ? f.team : INT_MIN);
            goto check_live;
        }
        // 1) FName qua GNames (như Kernel GetFName -> IsASTExtraPlayerCharacter)
        if (g_espUName && f.hasName) {
            char nm[64] = {0};
            if (ESPActorNameByID(vmMap, g_espUName, f.nameID, nm) && ESPIsPlayerCharacterName(nm)) {
                if (f.hasVtable && f.vtable && !g_espPlayerVTable) {
                    g_espPlayerVTable = f.vtable;
                    ESPLog("learned player VTable=0x%llx from %s", (unsigned long long)f.vtable, nm);
                }
                ESPVerdictSet(actor, 1, (f.hasTeam && f.team >= 0 && f.team <= 200000000) ? f.team : INT_MIN);
                goto check_live;
            }
        }
        // 2) heuristic Mesh/Health/Team (dự phòng khi GNames fail)
        // Thử character trước (Mesh skeletal 0x510)
        if (f.window && ESPIsUserPtr(f.mesh) &&
            f.hp >= 0 && f.hp <= 2000 && f.hpMax > 0 && f.hpMax <= 2000 &&
            f.hasTeam && f.team >= 0 && f.team <= 200000000) {
            ESPVerdictSet(actor, 1, f.team);
            goto check_live;
        }
        // Thử hình nhân huấn luyện (StaticMesh 0x4E8, không skeletal 0x510)
        if (f.hasTarget && ESPIsUserPtr(f.tMesh) && !ESPIsUserPtr(f.mesh) && ESPIsUserPtr(f.root)) {
            if (f.tMax >= 50 && f.tMax <= 2000 && f.tCur >= 0 && f.tCur <= f.tMax &&
                (f.tIsUp == 0 || f.tIsUp == 1)) {
                ESPVerdictSet(actor, 3, ESPTeam_Dummy);
                if (outTeam) *outTeam = ESPTeam_Dummy;
                if (outHp) *outHp = f.tCur;
                return YES;
            }
        }
        ESPVerdictSet(actor, 2, INT_MIN);
        g_espTeamCache.erase(actor);
        return NO;
    }
    if (vit->second == 3) {
        // target huấn luyện: hiện cả khi bị bắn gục (hp 0) như Kernel GatherTarget.
        // Chỉ cần đọc được hp là tính.
        float tCur = 0;
        if (!ESPMemoryRead(vmMap, actor + ESPOff_Target_CurHealth, &tCur, 4)) return NO;
        if (outTeam) *outTeam = ESPTeam_Dummy;
        if (outHp) *outHp = tCur;
        return YES;
    }
check_live:;
    // 1 lần đọc cửa sổ cho check sống (trước đây 3-4 lần map page/actor/scan).
    ESPActorFields f;
    ESPActorFieldsRead(vmMap, actor, &f);
    if ((f.bHidden & 0x1) || (f.bDead & 0x1)) return NO;
    int team = INT_MIN;
    if (f.hasTeam && f.team >= 0 && f.team <= 200000000) {
        team = f.team;
        g_espTeamCache[actor] = team;
    } else {
        auto tit = g_espTeamCache.find(actor);
        if (tit != g_espTeamCache.end()) team = tit->second;
    }
    // hp: chỉ loại khi đọc được cả cửa sổ (fallback có thể miss field).
    if (f.window && !(f.hp > 0 && f.hp <= 2000)) return NO;
    if (myTeam != INT_MIN && team != INT_MIN && team == myTeam && team != ESPTeam_Dummy) return NO;
    if (outTeam) *outTeam = team;
    if (outHp) *outHp = f.hasHp ? f.hp : 0;
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
    g_espFrame++; // frame để verdict 2 hết hạn rồi đánh giá lại
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
    if (!world) { ESPLog("scan world FAIL step=%d base=0x%llx", g_espStep, (unsigned long long)gameBase); return r; }
    if (!ESPValidateWorld(vmMap, world)) { ESPLog("scan validate FAIL step=%d", g_espStep); return r; }
    g_espStep = 0;
    r.world = world;

    BOOL ok = NO;
    uint64_t level = 0;
    uint64_t actorsData = 0;
    uint32_t actorsCount = 0;
    if (!ESPLevelAndActors(vmMap, world, &level, &actorsData, &actorsCount)) { ESPLog("scan actors FAIL step=%d", g_espStep); return r; }
    r.level = level;
    r.actorCluster = 0; // không dùng cluster ở bản này (decrypt 0xA0/0x448)
    r.actorCount = actorsCount;
    if (!actorsData || actorsCount == 0 || actorsCount > 20000) { ESPLog("scan bad count=%u", (unsigned)actorsCount); return r; }
    ESPLog("scan start actors=%u base=0x%llx", (unsigned)actorsCount, (unsigned long long)gameBase);
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();

    // Giải mã GNames 1 lần cho cả scan (để đọc tên class)
    g_espUName = ESPResolveUName(vmMap, gameBase);
    ESPLog("uname=0x%llx vtableKnown=%d", (unsigned long long)g_espUName, g_espPlayerVTable ? 1 : 0);

    uint32_t scanN = actorsCount > ESP_MAX_ACTORS_SCAN ? ESP_MAX_ACTORS_SCAN : actorsCount;
    ESPVerdictResetIfWorldChanged(world);
    int myTeam = INT_MIN;
    {
        int t = INT_MIN;
        uint64_t lp = 0;
        if (ESPMyTeamAndPawn(vmMap, world, &lp, &t)) {
            myTeam = t;
            // Học VTable player ngay từ pawn của mình (như Kernel): các actor
            // sau chỉ cần so VTable là ra player, khỏi đọc FName từng con.
            if (lp && !g_espPlayerVTable) {
                BOOL okv = NO;
                uint64_t vt = ESPReadU64(vmMap, lp, &okv);
                if (okv && ESPIsUserPtr(vt)) {
                    g_espPlayerVTable = vt;
                    ESPLog("learned player VTable=0x%llx from local pawn", (unsigned long long)vt);
                }
            }
        }
    }
    // Đọc gộp toàn bộ mảng pointers 1 lần (như Kernel ReadBuf):
    // 452 actors lẻ = 452 mappings, gộp = 1-2 mappings.
    uint32_t bulkN = scanN > 2048 ? 2048 : scanN;
    static uint64_t s_actorBuf[2048];
    BOOL haveBulk = ESPMemoryRead(vmMap, actorsData, s_actorBuf, (uint64_t)bulkN * 8);
    g_espProgressTotal.store((int)scanN);
    g_espProgress.store(0);
    uint32_t enemies = 0;
    uint64_t sample = 0;
    ESPVector samplePos = {0,0,0};
    BOOL hasPos = NO;
    for (uint32_t i = 0; i < scanN; i++) {
        if ((i & 15) == 0) g_espProgress.store((int)i);
        uint64_t actor = 0;
        if (haveBulk && i < bulkN) {
            actor = s_actorBuf[i];
        } else {
            BOOL ok2 = NO;
            actor = ESPReadU64(vmMap, actorsData + (uint64_t)i * 8, &ok2);
            if (!ok2) continue;
        }
        if (!ESPIsUserPtr(actor)) continue;
        // Actor chưa biết thì chỉ phân loại ở lượt của nó (xoay 1/3 như Kernel
        // s_frame % 3) — đã biết rồi thì check sống luôn (rẻ: verdict 2 = 0 read).
        if (g_espVerdict.find(actor) == g_espVerdict.end() && (int)(i % 3) != (g_espSliceTurn % 3)) continue;
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
    g_espProgress.store((int)scanN);
    g_espSliceTurn = (g_espSliceTurn + 1) % 3;
    g_espPasses++;
    r.playerLike = enemies;
    r.sampleActor = sample;
    r.samplePos = samplePos;
    r.hasSamplePos = hasPos;
    ESPLog("scan done enemies=%u scanned=%u dt=%.1fs", (unsigned)enemies, (unsigned)r.scanned,
           CFAbsoluteTimeGetCurrent() - t0);
    return r;
#endif
}

static CFAbsoluteTime g_espCheckedAt = 0;
static ESPScanResult g_espCache = {0};
static int g_espCachePasses = 0; // số lượt lúc cache được ghi
static std::atomic_bool g_espScanning(false);
static CFAbsoluteTime g_espScanStart = 0; // lúc bắt đầu lần quét hiện tại
static const double kESPScanStuckTimeout = 25.0; // quá từng này giây coi như kẹt, cho quét lại
static double g_espLastScanSeconds = 0; // lần quét xong gần nhất mất bao lâu
static int g_espLastScanEnemies = -1; // -1 = chưa xong lần nào
static uint32_t g_espLightActors = 0; // actors của lần quét nhẹ gần nhất
static uint64_t g_espLightWorld = 0;  // world tương ứng (0 = chưa quét được)

static dispatch_queue_t ESPScanQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.huami.darkspeed.esp-scan", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

void ESPEngineRequestScan(uint64_t gameBase) {
#if !USE_DARKSWORD
    (void)gameBase;
    return;
#else
    if (!gameBase || !ds_is_ready()) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - g_espCheckedAt < ESP_CACHE_TTL && g_espCheckedAt > 0) return;
    bool expected = false;
    if (!g_espScanning.compare_exchange_strong(expected, true)) {
        // Đang quét — nếu kẹt quá lâu thì nhả cờ cho quét lại
        if (g_espScanStart > 0 && now - g_espScanStart > kESPScanStuckTimeout) {
            g_espScanning.store(false);
            expected = false;
            if (!g_espScanning.compare_exchange_strong(expected, true)) return;
        } else {
            return;
        }
    }
    g_espScanStart = now;
    g_espProgress.store(-1);
    g_espProgressTotal.store(0);
    dispatch_async(ESPScanQueue(), ^{
        @autoreleasepool {
            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
            ESPScanResult r = ESPEngineScan(gameBase);
            g_espCache = r;
            g_espCachePasses = g_espPasses;
            g_espCheckedAt = CFAbsoluteTimeGetCurrent();
            g_espLastScanSeconds = g_espCheckedAt - t0;
            g_espLastScanEnemies = r.world ? (int)r.playerLike : -2; // -2 = fail
            ESPLog("scan finished dt=%.1fs enemies=%d step=%d", g_espLastScanSeconds,
                   g_espLastScanEnemies, g_espStep);
        }
        g_espScanStart = 0;
        g_espScanning.store(false);
    });
#endif
}

static NSString *ESPCacheText(void) {
    if (!g_espCache.world) {
        int step = g_espStep;
        if (step > 0) return [NSString stringWithFormat:@"ESP: -- E%d", step];
        return @"ESP: --";
    }
    // Chưa đủ 3 lượt xoay thì số players còn thiếu — đánh dấu ~ đang warmup
    if (g_espCachePasses < 3) {
        return [NSString stringWithFormat:@"ESP: %u actors / %u~ players",
                (unsigned)g_espCache.actorCount, (unsigned)g_espCache.playerLike];
    }
    return [NSString stringWithFormat:@"ESP: %u actors / %u players",
            (unsigned)g_espCache.actorCount, (unsigned)g_espCache.playerLike];
}

// Quét NHẸ đồng bộ (~15 lần đọc kernel): world -> level -> actors count.
// Không lọc players — để hiện số actors ngay khi vào trận.
// An toàn gọi từ tick (bridge queue), KHÔNG gọi từ main thread.
static uint32_t ESPFastActors(uint64_t gameBase, uint64_t *outWorld) {
    if (outWorld) *outWorld = 0;
    if (!gameBase || !ds_is_ready()) return 0;
    uint64_t proc = procbyname(ESP_DEFAULT_PROCESS);
    if (!proc) proc = procbyname("ShadowTrackerE");
    if (!proc) return 0;
    uint64_t task = taskbyproc(proc);
    uint64_t vmMap = task ? task_get_vm_map(task) : 0;
    if (!vmMap) return 0;
    BOOL ok = NO;
    uint64_t geStatic = ESPGEngineRuntime(gameBase);
    uint64_t engine = ESPReadU64(vmMap, geStatic, &ok);
    if (!ok || !ESPIsUserPtr(engine)) return 0;
    uint64_t viewport = ESPReadU64(vmMap, engine + ESPOff_Engine_GameViewport, &ok);
    if (!ok || !ESPIsUserPtr(viewport)) return 0;
    uint64_t world = ESPReadU64(vmMap, viewport + ESPOff_Viewport_World, &ok);
    if (!ok || !ESPIsUserPtr(world)) return 0;
    if (outWorld) *outWorld = world;
    uint64_t level = 0, ad = 0;
    uint32_t ac = 0;
    if (!ESPLevelAndActors(vmMap, world, &level, &ad, &ac)) return 0;
    if (ac > 20000) return 0;
    return ac;
}

NSString *ESPEngineStatusText(uint64_t gameBase) {
    if (!gameBase) return @"ESP: --";
#if !USE_DARKSWORD
    (void)gameBase;
    return @"ESP: --";
#else
    if (!ds_is_ready()) return @"ESP: wait…";
    ESPEngineRequestScan(gameBase); // lọc players chạy nền, không block
    if (g_espCheckedAt != 0) return ESPCacheText();
    // Chưa lọc xong lần nào: quét nhẹ lấy số actors hiện ngay — nhưng KHÔNG
    // đọc kernel song song với scan nền (vmmapremotepage không re-entrant,
    // 2 thread cùng đọc là hỏng vm entry -> respring). Trong lúc scan thì
    // dùng lại số actors của lần quét nhẹ trước.
    if (!g_espScanning.load()) {
        uint64_t w = 0;
        uint32_t fresh = ESPFastActors(gameBase, &w);
        if (w && fresh <= 20000) {
            g_espLightActors = fresh;
            g_espLightWorld = w;
        }
    }
    if (g_espLightWorld) {
        uint32_t actors = g_espLightActors;
        int prog = g_espProgress.load();
        int total = g_espProgressTotal.load();
        if (actors > 0) {
            if (prog >= 0 && total > 0) {
                int pct = (int)((int64_t)prog * 100 / total);
                if (pct < 0) pct = 0;
                if (pct > 99) pct = 99;
                return [NSString stringWithFormat:@"ESP: %u actors / .. %d%%", (unsigned)actors, pct];
            }
            return [NSString stringWithFormat:@"ESP: %u actors / ..", (unsigned)actors];
        }
        return @"ESP: 0 actors / ..";
    }
    // World còn chưa ra — hiện số giây đang quét để biết có kẹt không
    if (g_espScanStart > 0) {
        int el = (int)(CFAbsoluteTimeGetCurrent() - g_espScanStart);
        if (el < 0) el = 0;
        if (el > 999) el = 999;
        return [NSString stringWithFormat:@"ESP: .. %ds", el];
    }
    return @"ESP: ..";
#endif
}

uint32_t ESPEnginePlayerCount(uint64_t gameBase) {
    if (!gameBase) return 0;
#if !USE_DARKSWORD
    (void)gameBase;
    return 0;
#else
    ESPEngineRequestScan(gameBase); // nền, không block
    return g_espCache.playerLike;
#endif
}

NSString *ESPEngineCachedStatusText(void) {
#if !USE_DARKSWORD
    return @"ESP: --";
#else
    if (g_espCheckedAt == 0) return @"ESP: ..";
    return ESPCacheText();
#endif
}

NSString *ESPEngineScanInfoText(void) {
#if !USE_DARKSWORD
    return @"scan sim";
#else
    if (g_espScanning.load()) {
        int prog = g_espProgress.load();
        int total = g_espProgressTotal.load();
        double el = (g_espScanStart > 0) ? (CFAbsoluteTimeGetCurrent() - g_espScanStart) : 0;
        if (el < 0) el = 0;
        if (prog >= 0 && total > 0) {
            int pct = (int)((int64_t)prog * 100 / total);
            if (pct < 0) pct = 0;
            if (pct > 99) pct = 99;
            return [NSString stringWithFormat:@"scan %d%% %.0fs", pct, el];
        }
        return [NSString stringWithFormat:@"scan .. %.0fs", el];
    }
    if (g_espCheckedAt == 0) return @"scan idle";
    if (g_espLastScanEnemies >= 0) {
        return [NSString stringWithFormat:@"scan ok %d %.1fs", g_espLastScanEnemies, g_espLastScanSeconds];
    }
    return [NSString stringWithFormat:@"scan fail E%d %.1fs", g_espStep, g_espLastScanSeconds];
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
    uint32_t bulkN2 = scanN > 2048 ? 2048 : scanN;
    static uint64_t s_boxBuf[2048];
    BOOL haveBulk2 = ESPMemoryRead(vmMap, actorsData, s_boxBuf, (uint64_t)bulkN2 * 8);
    int n = 0;
    float tanHalf = tanf(cam.fov * 3.141592653589793f / 360.0f);
    if (!(tanHalf > 0.05f && tanHalf < 5.0f)) return 0;
    for (uint32_t i = 0; i < scanN && n < maxBoxes; i++) {
        uint64_t actor = 0;
        if (haveBulk2 && i < bulkN2) {
            actor = s_boxBuf[i];
        } else {
            BOOL ok2 = NO;
            actor = ESPReadU64(vmMap, actorsData + (uint64_t)i * 8, &ok2);
            if (!ok2) continue;
        }
        if (!ESPIsUserPtr(actor)) continue;
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

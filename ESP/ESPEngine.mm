//
//  ESPEngine.mm
//  Phase 1: tìm UWorld qua GUObject enumeration, vào Actors, đếm.
//  Không crash nếu offsets sai — mọi read đều check BOOL.
//

#import "ESPEngine.h"
#import "ESPOffsets.h"
#import "ESPMemory.h"
#import "ESPTask.h"
#import "ESPConfig.h"
#import "ESPName.h"
#import "ESPLog.h"
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <algorithm>
#include <limits.h>
#include <atomic>
#include <mutex>
#include <stdarg.h>
#include <unistd.h> // usleep: scan nhường mutex cho box refresh
#include <string.h>
#include <stdio.h>
#include <vector>

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
//
// Cửa sổ này đi qua PAGE CACHE của ESPMemory (không phải ESPReadWindow map-rồi-
// nhả từng lần): 0xF00 < 1 page nên nó nằm gọn trong page đầu của actor, và
// page đó sau lần đầu ở lại cache (256 slot, LRU). Log thực tế trước đây:
// quét đầy đủ mất ~10s (132 actor x 1 vòng map+refcount+dealloc); sau khi dùng
// cache thì các lượt quét sau chỉ còn memcpy — scan đầy đủ không còn là cú
// giật 10s, và kernel cũng bớt hàng nghìn vòng map/refcount mỗi phút.
#define ESP_ACTOR_WINDOW 0xF00
// Bound sanity cho tọa độ world (cm): map PUBG origin ở góc nên tọa độ tới
// ~800.000cm (log thực tế cam x=835.589). Bound cũ 300.000 loại nhầm vị trí
// hợp lệ -> box mất cả trận. 2.000.000 vẫn chặn được rác/NaN (thường rất lớn).
#define ESP_POS_BOUND 2000000.0f

typedef struct {
    uint64_t vtable, root, mesh, tMesh;
    uint32_t nameID;
    float hp, hpMax, tCur, tMax;
    uint8_t bHidden, bDead, tIsUp;
    int team;
    BOOL hasVtable, hasName, hasRoot, hasMesh, hasHp, hasTarget, hasTeam;
    BOOL window; // đọc được cả cửa sổ 1 lần => mọi field đều đáng tin
} ESPActorFields;

// Chẩn đoán: vì sao 1 actor bị loại (ghi vào ESP.log ở lượt quét chi tiết
// đầu tiên của mỗi world). rule: 1=vtable 2=tên player 3=tên hình nhân
// 4=chữ ký character 5=chữ ký target 0=không khớp -1=bị lọc (ẩn/chết/team)
typedef struct {
    int rule;
    int win;
    int nearChar;
    int nearDummy;
    int team;
    unsigned tIsUp;
    float hp, hpMax, tCur, tMax;
    uint64_t vt, mesh, tMesh, root;
    uint32_t nameID;
} ESPClassifyDiag;

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
    // ESPMemoryRead (page cache) chứ không ESPReadWindow (map+dealloc mỗi lần).
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
// g_espPasses/g_espVerboseLeft đọc từ cả scan queue, bridge queue lẫn main
// thread nên dùng atomic (ghi chính vẫn dưới g_espClassifyMutex).
static std::atomic_int g_espPasses{0}; // số lượt quét xong từ khi đổi world (đủ 3 lượt mới full)
static std::atomic_int g_espProgress{-1}; // index đang lọc (để hiện %)
static std::atomic_int g_espProgressTotal{0};
// Mutex cho verdict maps + VTable + frame + tracked list: ESPEngineScan chạy
// trên queue nền trong khi ESPEngineBoxes/RefreshBoxes chạy trên timer bridge
// (1Hz). Trước đây 2 luồng đọc/ghi unordered_map + vector cùng lúc (UB):
// scan vừa clear/push tracked + set verdict, box path vừa iterate/read —
// kết quả là box path ra 0 (hoặc crash ngầm) dù scan đếm đúng players.
static std::mutex g_espClassifyMutex;
static uint64_t g_espVMProc = 0; // cache proc/vmMap cho box refresh 8Hz
static uint64_t g_espVMMap = 0;
static CFAbsoluteTime g_espVMAt = 0;
static uint64_t g_espUName = 0; // GNames đã giải mã cho base hiện tại
static uint64_t g_espPlayerVTable = 0; // VTable class player đã học
static std::unordered_map<uint64_t, char> g_espVerdict; // 1=character, 3=target, 2=other
static std::unordered_map<uint64_t, int> g_espTeamCache;
static std::unordered_map<uint64_t, int> g_espVerdictFrame; // frame lúc kết luận, để hết hạn
// VTable lúc kết luận "other" — để phát hiện object pool TÁI DÙNG địa chỉ
// (địch mới spawn lấy lại chỗ của object không phải địch). Xem ESPIsEnemy.
static std::unordered_map<uint64_t, uint64_t> g_espVerdictVt;
static int g_espFrame = 0;
// Verdict 2 (không phải địch) được đánh giá lại sau bao nhiêu lượt quét.
// Đây TỪNG là 6 — với TTL 2s thì một object-đã-biến-thành-địch phải 12s mới
// được soi lại (log thực tế: địch xuất hiện 5-6s mới có box). Cửa sổ actor giờ
// nằm trong page cache nên soi lại rẻ; kèm peek VTable ở ESPIsEnemy thì ca
// "đổi class" còn được nhận ra ngay ở lượt kế tiếp.
static const int kESPverdictExpiryFrames = 1;
static uint64_t g_espVerdictWorld = 0;
// Số lượt quét còn ghi log chi tiết (field từng actor + histogram VTable).
// Đặt lại mỗi khi đổi world => mỗi map/trận chỉ ghi vài lượt đầu.
static std::atomic_int g_espVerboseLeft{2};
// Actor địch/hình nhân đã biết (kind 1/3) để refresh vị trí NHANH giữa 2 lượt
// quét đầy đủ — ESP_REFRESH_HZ lần/giây, mỗi actor chỉ 1 lần đọc root + 1 lần
// đọc camera thay vì phân loại lại từ đầu.
static std::vector<ESPTrackedActor> g_espTracked;
// Tăng mỗi khi tracked publish/swap/xả: bridge dùng để biết mẫu refresh mới
// có cùng "thế hệ" actor với mẫu cũ không (cùng gen + cùng count mới nội suy
// được theo index, khác thì snap).
static uint64_t g_espTrackGen = 0;
uint64_t ESPEngineTrackedGen(void) {
    std::lock_guard<std::mutex> lk(g_espClassifyMutex);
    return g_espTrackGen;
}

// Diag box pipeline cho lần gọi Boxes/RefreshBoxes gần nhất (xem ESP.log khi
// B=0 mà P>0): "R trk=8 hid=1 pos=0 w2s=5 h=1 ok=2",
// "F act=452 ene=6 pos=1 w2s=3 h=0 ok=2", "F camFail", "R camFail", "R empty".
static char g_espBoxDiag[160] = "n/a";
static void ESPBoxDiagSet(const char *fmt, ...) {
    if (!fmt) return;
    va_list args;
    va_start(args, fmt);
    vsnprintf(g_espBoxDiag, sizeof(g_espBoxDiag), fmt, args);
    va_end(args);
}
const char *ESPEngineLastBoxDiag(void) {
    return g_espBoxDiag;
}
static const char *ESPCameraResolveDiag(void); // định nghĩa ở cụm camera bên dưới
static BOOL ESPCameraIsResolved(void);
static void ESPGameInstanceDump(uint64_t vmMap, uint64_t world, uint64_t gameBase);

// Cooldown Pass 1 discover — file-scope để ESPVerdictResetIfWorldChanged xả
// theo world (addr tái dùng giữa match không bị kẹt cooldown cũ).
static std::unordered_map<uint64_t, CFAbsoluteTime> g_espPass1At;
static void ESPDiscoverResetCooldowns(void) {
    // Gọi khi ĐÃ giữ g_espClassifyMutex (từ ESPVerdictResetIfWorldChanged).
    g_espPass1At.clear();
}

static void ESPVerdictResetIfWorldChanged(uint64_t world) {
    std::lock_guard<std::mutex> lk(g_espClassifyMutex);
    if (g_espVerdictWorld != world) {
        g_espVerdict.clear();
        g_espTeamCache.clear();
        g_espVerdictFrame.clear();
        g_espVerdictVt.clear();
        g_espVerdictWorld = world;
        g_espPlayerVTable = 0; // học lại VTable cho world mới
        g_espPasses = 0;
        g_espVerboseLeft = 2; // log chi tiết 2 lượt đầu của world mới
        g_espTracked.clear(); // world mới => tracked cũ sai hết, xả luôn
        g_espTrackGen++; // mẫu refresh cũ hết hiệu lực nội suy
        ESPGameTaskReset(); // world mới => task port cũ héo, resolve lại
        g_espVMProc = 0; // match mới có thể task mới => resolve lại proc/vmMap
        g_espVMMap = 0;
        g_espVMAt = 0;
        ESPDiscoverResetCooldowns();
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

static void ESPVerdictSetLocked(uint64_t actor, char v, int team) {
    // Gọi khi ĐÃ giữ g_espClassifyMutex (ESPIsEnemy giữ suốt lần phân loại).
    if (g_espVerdict.size() > 3000) {
        g_espVerdict.clear();
        g_espTeamCache.clear();
        g_espVerdictFrame.clear();
        g_espVerdictVt.clear();
    }
    g_espVerdict[actor] = v;
    g_espVerdictFrame[actor] = g_espFrame;
    if (v == 1 || v == 3) g_espTeamCache[actor] = team;
}

// Lọc enemy thật theo source Kernel: Mesh + Health/Max + TeamID, rồi bHidden/bDead/team.
// verdict 1=character, 3=target huấn luyện, 2=other.
// verdict 2 hết hạn sau kESPverdictExpiryFrames scans để đánh giá lại.
static BOOL ESPIsEnemy(uint64_t vmMap, uint64_t actor, int myTeam, uint64_t myPawn, int *outTeam, float *outHp,
                       ESPClassifyDiag *diag) {
    // Giữ mutex suốt lần phân loại: map verdict/team/frame + VTable được đọc
    // và ghi từ cả scan queue lẫn timer bridge. Mỗi lần giữ chỉ ~vài lần đọc
    // kernel của 1 actor nên contention không đáng kể.
    std::lock_guard<std::mutex> lk(g_espClassifyMutex);
    if (diag) {
        memset(diag, 0, sizeof(*diag));
        diag->rule = -2;
        diag->nearChar = -1;
        diag->nearDummy = -1;
    }
    // Lọc chính mình (local pawn) ngay từ đầu. PHẢI set verdict=2: nếu return
    // không ghi gì, discover nhai lại actor này mỗi 120ms mãi (log unk=1 left=0).
    if (myPawn && actor == myPawn) {
        if (diag) diag->rule = -4;
        if (g_espVerdict.find(actor) == g_espVerdict.end()) {
            ESPVerdictSetLocked(actor, 2, INT_MIN);
            BOOL vtok = NO;
            uint64_t vtp = ESPReadU64(vmMap, actor, &vtok);
            if (vtok && vtp) g_espVerdictVt[actor] = vtp;
        }
        return NO;
    }
    auto vit = g_espVerdict.find(actor);
    if (vit != g_espVerdict.end() && vit->second == 2) {
        auto fit = g_espVerdictFrame.find(actor);
        int age = (fit != g_espVerdictFrame.end()) ? (g_espFrame - fit->second) : 999;
        if (age <= kESPverdictExpiryFrames) {
            // Verdict còn hạn — nhưng actor pool của PUBG TÁI DÙNG địa chỉ: một
            // object "không phải địch" có thể BỊ THAY bằng nhân vật mới spawn.
            // Peek VTable (8 byte, chỉ đọc từ page cache — không map page mới)
            // rồi so với VTable lúc kết luận. Khác => object đã đổi => phân loại
            // lại NGAY, không đợi hết hạn. Đây là fix cho "địch xuất hiện 5-6s
            // mới có box" (trước đây đợi 6 lượt quét).
            uint64_t vtOld = 0, vtNow = 0;
            auto vti = g_espVerdictVt.find(actor);
            if (vti != g_espVerdictVt.end()) vtOld = vti->second;
            if (!vtOld || !ESPMemoryReadCached(vmMap, actor, &vtNow, sizeof(vtNow)) || vtNow == vtOld) {
                if (diag) diag->rule = -3; // verdict cũ còn hiệu lực
                return NO;
            }
        }
        g_espVerdict.erase(actor);
        g_espVerdictFrame.erase(actor);
        g_espTeamCache.erase(actor);
        g_espVerdictVt.erase(actor);
        vit = g_espVerdict.end();
    }
    if (vit == g_espVerdict.end()) {
        // 1 lần đọc cửa sổ actor: đủ field cho mọi nhánh phân loại bên dưới.
        ESPActorFields f;
        ESPActorFieldsRead(vmMap, actor, &f);
        if (diag) {
            diag->win = f.window ? 1 : 0;
            diag->vt = f.vtable;
            diag->mesh = f.mesh;
            diag->tMesh = f.tMesh;
            diag->root = f.root;
            diag->nameID = f.nameID;
            diag->hp = f.hp;
            diag->hpMax = f.hpMax;
            diag->tCur = f.tCur;
            diag->tMax = f.tMax;
            diag->tIsUp = f.tIsUp;
            diag->team = f.team;
        }
        // 0) VTable đã học (từ pawn của mình hoặc actor đầu): 0 read thêm.
        if (f.hasVtable && g_espPlayerVTable && f.vtable == g_espPlayerVTable) {
            if (diag) diag->rule = 1;
            ESPVerdictSetLocked(actor, 1, (f.hasTeam && f.team >= 0 && f.team <= 200000000) ? f.team : INT_MIN);
            goto check_live;
        }
        // 1) FName qua GNames (như Kernel GetFName -> IsASTExtraPlayerCharacter)
        if (g_espUName && f.hasName) {
            char nm[64] = {0};
            if (ESPActorNameByID(vmMap, g_espUName, f.nameID, nm)) {
                if (ESPIsPlayerCharacterName(nm)) {
                    if (f.hasVtable && f.vtable && !g_espPlayerVTable) {
                        g_espPlayerVTable = f.vtable;
                        ESPLog("learned player VTable=0x%llx from %s", (unsigned long long)f.vtable, nm);
                    }
                    if (diag) diag->rule = 2;
                    ESPVerdictSetLocked(actor, 1, (f.hasTeam && f.team >= 0 && f.team <= 200000000) ? f.team : INT_MIN);
                    goto check_live;
                }
                // 1b) Hình nhân huấn luyện (ShootingPracticeTarget) nhận theo TÊN.
                if (ESPIsTrainingDummyName(nm)) {
                    if (diag) diag->rule = 3;
                    ESPVerdictSetLocked(actor, 3, ESPTeam_Dummy);
                    if (outTeam) *outTeam = ESPTeam_Dummy;
                    if (outHp) *outHp = f.tCur;
                    ESPLog("training dummy: %s", nm);
                    return YES;
                }
            }
        }
        // 2) Heuristic Mesh/Health/Team (dự phòng khi GNames fail)
        // Yêu cầu: SkeletalMesh hợp lệ, HealthMax 50..2000, Health 0..hpMax,
        // và nếu đã biết player VTable thì VTable PHẢI khớp (như Kernel sameClass).
        if (f.hasMesh && ESPIsUserPtr(f.mesh) &&
            f.hasHp && f.hp >= 0 && f.hpMax >= 50 && f.hpMax <= 2000 && f.hp <= f.hpMax + 50 &&
            f.hasTeam && f.team >= 0 && f.team <= 200000000) {
            bool sameClass = YES;
            if (g_espPlayerVTable) {
                sameClass = (f.hasVtable && f.vtable == g_espPlayerVTable);
            }
            if (sameClass) {
                if (!g_espPlayerVTable && f.hasVtable && f.vtable) {
                    g_espPlayerVTable = f.vtable;
                    ESPLog("learned player VTable=0x%llx from heuristic", (unsigned long long)f.vtable);
                }
                if (diag) diag->rule = 4;
                ESPVerdictSetLocked(actor, 1, f.team);
                goto check_live;
            }
        }
        if (diag && f.hasMesh && ESPIsUserPtr(f.mesh)) diag->nearChar = 1;
        // 3) Hình nhân huấn luyện (ShootingPracticeTarget) theo field — dự phòng khi GNames hỏng.
        // StaticMeshComp (0x4E8), RootComponent (0x208), KHÔNG có SkeletalMesh (0x510),
        // MaxHealth (0x4AC) trong khoảng 50..2000, CurHealth (0x4D0) trong khoảng 0..MaxHealth.
        // Giống hoàn toàn Kernel: tMesh && !sMesh && tRoot && tMax>=50 && tCur>=0 && tCur<=tMax.
        if (f.hasTarget && ESPIsUserPtr(f.tMesh) && (!f.hasMesh || !ESPIsUserPtr(f.mesh)) &&
            f.hasRoot && ESPIsUserPtr(f.root) &&
            f.tMax >= 50 && f.tMax <= 2000 && f.tCur >= 0 && f.tCur <= f.tMax &&
            (f.tIsUp == 0 || f.tIsUp == 1)) {
            if (diag) diag->rule = 5;
            ESPVerdictSetLocked(actor, 3, ESPTeam_Dummy);
            if (outTeam) *outTeam = ESPTeam_Dummy;
            if (outHp) *outHp = f.tCur;
            static int s_dummyLogs = 0;
            if (s_dummyLogs < 8) {
                char dnm[64] = {0};
                if (g_espUName && f.hasName && ESPActorNameByID(vmMap, g_espUName, f.nameID, dnm)) {
                    ESPLog("dummy(field) name=%s tMax=%.0f tCur=%.0f isUp=%u",
                           dnm, f.tMax, f.tCur, (unsigned)f.tIsUp);
                } else {
                    ESPLog("dummy(field) name=? tMax=%.0f tCur=%.0f isUp=%u",
                           f.tMax, f.tCur, (unsigned)f.tIsUp);
                }
                s_dummyLogs++;
            }
            return YES;
        }
        if (diag && f.hasTarget && ESPIsUserPtr(f.tMesh)) diag->nearDummy = 1;
        ESPVerdictSetLocked(actor, 2, INT_MIN);
        g_espTeamCache.erase(actor);
        // Nhớ VTable để lượt sau phát hiện object đổi class (tái dùng địa chỉ).
        if (f.hasVtable) g_espVerdictVt[actor] = f.vtable;
        if (diag) diag->rule = 0;
        return NO;
    }
    if (vit->second == 3) {
        float tCur = 0;
        (void)ESPMemoryRead(vmMap, actor + ESPOff_Target_CurHealth, &tCur, 4);
        if (outTeam) *outTeam = ESPTeam_Dummy;
        if (outHp) *outHp = tCur;
        return YES;
    }
check_live:;
    // 1 lần đọc cửa sổ cho check sống.
    ESPActorFields f;
    ESPActorFieldsRead(vmMap, actor, &f);
    if ((f.bHidden & 0x1) || (f.bDead & 0x1)) {
        if (diag) diag->rule = -1;
        // Giữ verdict 1 để khi unhide/revive không cần phân loại lại từ đầu —
        // nhưng discover sẽ throttle Pass 1 theo cooldown (không spam cls).
        return NO;
    }
    // Lọc chính mình (local pawn)
    if (myPawn && actor == myPawn) {
        if (diag) diag->rule = -4;
        return NO;
    }
    // Đồng đội: hạ verdict 1 -> 2 ngay (check_live path).
    // (Pass ở trên đã set khi team đọc được — đây là safety nếu vào từ nhánh khác.)
    int team = INT_MIN;
    if (f.hasTeam && f.team >= 0 && f.team <= 200000000) {
        team = f.team;
        g_espTeamCache[actor] = team;
    } else {
        auto tit = g_espTeamCache.find(actor);
        if (tit != g_espTeamCache.end()) team = tit->second;
    }
    // Không lọc theo hp: người/hình nhân bị bắn gục (hp 0) vẫn tính như Kernel
    // (chỉ loại theo bHidden/bDead).
    if (myTeam != INT_MIN && team != INT_MIN && team == myTeam && team != ESPTeam_Dummy) {
        if (diag) diag->rule = -4; // đồng đội
        // Hạ verdict 1 -> 2: teammate không bao giờ là địch. Giữ verdict 1 làm
        // discover Pass 1 (enemyVerdict) gọi ESPIsEnemy lại mỗi 120ms (log cls=17).
        // Vẫn ghi VTable để address-reuse (pool tái dùng) bắt được nếu ô đổi class.
        ESPVerdictSetLocked(actor, 2, INT_MIN);
        if (f.hasVtable) g_espVerdictVt[actor] = f.vtable;
        return NO;
    }
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

// PersistentLevel là level chính chứa players, bots, dummies và dynamic actors (như Kernel kPersistentLevel = 0x30).
// Không quét streaming levels (Levels[]) vì chúng chỉ chứa địa hình/cây cối tĩnh, làm tăng từ 139 lên 830 actors và gây lag/nhận nhầm.
static BOOL ESPLevelAndActors(uint64_t vmMap, uint64_t world, uint64_t *outLevel,
                              uint64_t *outActorsData, uint32_t *outActorsCount) {
    if (!ESPIsUserPtr(world)) return NO;
    BOOL ok = NO;
    // 1) PersistentLevel
    uint64_t pLevel = ESPReadU64(vmMap, world + ESPOff_UWorld_PersistentLevel, &ok);
    if (ok && ESPIsUserPtr(pLevel)) {
        uint64_t ad = 0;
        uint32_t ac = 0;
        if (ESPActorsOfLevel(vmMap, pLevel, &ad, &ac) && (ESPIsUserPtr(ad) || ac == 0)) {
            if (outLevel) *outLevel = pLevel;
            if (outActorsData) *outActorsData = ad;
            if (outActorsCount) *outActorsCount = ac;
            return YES;
        }
    }
    // 2) Fallback: CurrentLevel 0x468
    uint64_t curLevel = ESPReadU64(vmMap, world + 0x468, &ok);
    if (ok && ESPIsUserPtr(curLevel) && curLevel != pLevel) {
        uint64_t ad = 0;
        uint32_t ac = 0;
        if (ESPActorsOfLevel(vmMap, curLevel, &ad, &ac) && (ESPIsUserPtr(ad) || ac == 0)) {
            if (outLevel) *outLevel = curLevel;
            if (outActorsData) *outActorsData = ad;
            if (outActorsCount) *outActorsCount = ac;
            return YES;
        }
    }
    g_espStep = 62;
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
    return NO;
}

// Đang chạy ESPEngineScan ở thread này — chặn ESPEngineCamera tự gọi scan
// (trước đây tạo đệ quy vô hạn: diag probe camera -> scan mới -> diag mới…).
// RAII guard nhả cờ trên MỌI nhánh return của ESPEngineScan.
static thread_local bool t_espInScan = false;
struct ESPScanReentryGuard {
    ~ESPScanReentryGuard() { t_espInScan = false; }
};

ESPScanResult ESPEngineScan(uint64_t gameBase) {
    ESPScanResult r = {0};
#if !USE_DARKSWORD
    (void)gameBase;
    return r;
#else
    // Chống re-entry: nếu scan khác đang chạy trên thread này thì trả rỗng
    // (trước đây diag probe camera -> scan mới -> diag mới… đệ quy vô hạn).
    if (t_espInScan) return r;
    t_espInScan = true;
    ESPScanReentryGuard reentryGuard; (void)reentryGuard;
    g_espStep = 1;
    if (!gameBase || !ds_is_ready()) return r;
    { std::lock_guard<std::mutex> lk(g_espClassifyMutex); g_espFrame++; } // frame để verdict 2 hết hạn rồi đánh giá lại
    uint64_t proc = procbyname(ESP_DEFAULT_PROCESS);
    if (!proc) {
        proc = procbyname("ShadowTrackerE");
        if (!proc) { g_espStep = 1; return r; }
    }
    uint64_t task = taskbyproc(proc);
    uint64_t vmMap = task ? task_get_vm_map(task) : 0;
    if (!vmMap) { g_espStep = 2; return r; }

    // Task port game (như aovcheat): lấy NGAY ĐẦU lượt quét để lượt quét đầu
    // tiên đã đọc bulk bằng vm_read_overwrite — trước đây port chưa bật nên
    // lượt đầu phải map từng page (~5s cho ~130 actor) rồi box mới lên.
    // Chưa lấy được thì vẫn rơi về đường kernel như cũ (không hỏng gì).
    ESPGameTaskEnsure();

    g_espStep = 3;
    uint64_t world = ESPWorldViaViewport(vmMap, gameBase);
    if (!world) { ESPLog("scan world FAIL step=%d base=0x%llx", g_espStep, (unsigned long long)gameBase); return r; }
    if (!ESPValidateWorld(vmMap, world)) { ESPLog("scan validate FAIL step=%d", g_espStep); return r; }
    g_espStep = 0;
    r.world = world;

    uint64_t level = 0;
    uint64_t actorsData = 0;
    uint32_t actorsCount = 0;
    if (!ESPLevelAndActors(vmMap, world, &level, &actorsData, &actorsCount) || !actorsData || actorsCount == 0) {
        ESPLog("scan actors FAIL step=%d", g_espStep);
        return r;
    }
    r.level = level;
    r.actorCluster = 0;
    r.actorCount = actorsCount;
    ESPLog("scan start actors=%u level=0x%llx base=0x%llx",
           (unsigned)actorsCount, (unsigned long long)level, (unsigned long long)gameBase);
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();

    // Giải mã GNames 1 lần cho cả scan (để đọc tên class).
    // Resolve FAIL tốn cả khối diag (~30 kernel read + ~8 dòng log) và lặp lại
    // MỖI lượt quét (TTL 2s) mà kết quả không đổi -> chỉ thử 2 lượt đầu cho mỗi
    // game base. VTable vẫn là đường nhận diện chính khi GNames không có.
    {
        static uint64_t s_unameBase = 0;
        static int s_unameTries = 0;
        if (s_unameBase != gameBase) {
            s_unameBase = gameBase;
            s_unameTries = 0;
        }
        if (g_espUName) {
            // đã có, không đọc lại
        } else if (s_unameTries >= 2) {
            // đã fail 2 lượt cho base này: bỏ qua, không read/log lại
        } else {
            s_unameTries++;
            g_espUName = ESPResolveUName(vmMap, gameBase);
            std::lock_guard<std::mutex> lk(g_espClassifyMutex);
            ESPLog("uname=0x%llx vtableKnown=%d", (unsigned long long)g_espUName, g_espPlayerVTable ? 1 : 0);
        }
    }

    uint32_t scanN = actorsCount > ESP_MAX_ACTORS_SCAN ? ESP_MAX_ACTORS_SCAN : actorsCount;
    static uint64_t s_actors[ESP_MAX_ACTORS_SCAN];
    uint32_t got = 0;
    while (got < scanN) {
        uint32_t chunk = scanN - got;
        if (chunk > 2048) chunk = 2048;
        if (!ESPReadWindow(vmMap, actorsData + (uint64_t)got * 8, s_actors + got, (uint64_t)chunk * 8)) {
            for (uint32_t k = 0; k < chunk; k++) {
                BOOL okk = NO;
                s_actors[got + k] = ESPReadU64(vmMap, actorsData + (uint64_t)(got + k) * 8, &okk);
            }
        }
        got += chunk;
    }

    BOOL verbose = (g_espVerboseLeft > 0) || (g_espVerdictWorld != world);
    ESPVerdictResetIfWorldChanged(world);
    // Camera chưa resolve được PC: dump cấu trúc GameInstance 1 lần/world
    // (không phụ thuộc verbose) để tìm offset đúng từ log giDump.
    {
        static uint64_t s_dumpWorld = 0;
        if (world != s_dumpWorld && !ESPCameraIsResolved()) {
            s_dumpWorld = world;
            ESPGameInstanceDump(vmMap, world, gameBase);
        }
    }
    int myTeam = INT_MIN;
    uint64_t myPawn = 0;
    {
        int t = INT_MIN;
        uint64_t lp = 0;
        if (ESPMyTeamAndPawn(vmMap, world, &lp, &t)) {
            myTeam = t;
            myPawn = lp;
            // Học VTable player ngay từ pawn của mình (như Kernel)
            {
                std::lock_guard<std::mutex> lk(g_espClassifyMutex);
                if (lp && !g_espPlayerVTable) {
                    BOOL okv = NO;
                    uint64_t vt = ESPReadU64(vmMap, lp, &okv);
                    if (okv && ESPIsUserPtr(vt)) {
                        g_espPlayerVTable = vt;
                        ESPLog("learned player VTable=0x%llx from local pawn", (unsigned long long)vt);
                    }
                }
            }
        } else if (verbose) {
            ESPLog("diag pawn FAIL (NetDriver chain)");
        }
    }
    if (verbose) {
        int inList = -1;
        for (uint32_t i = 0; i < scanN; i++) {
            if (s_actors[i] == myPawn && myPawn) { inList = (int)i; break; }
        }
        ESPActorFields pf;
        ESPActorFieldsRead(vmMap, myPawn, &pf);
        ESPLog("diag pawn=0x%llx inList=%d team=%d vTable=0x%llx nid=0x%x mesh=0x%llx hp=%.1f/%.1f bHide=%u bDead=%u tm=0x%llx tMax=%.1f tCur=%.1f up=%u win=%d",
               (unsigned long long)myPawn, inList, myTeam, (unsigned long long)pf.vtable,
               pf.nameID, (unsigned long long)pf.mesh, pf.hp, pf.hpMax,
               (unsigned)pf.bHidden, (unsigned)pf.bDead, (unsigned long long)pf.tMesh,
               pf.tMax, pf.tCur, (unsigned)pf.tIsUp, pf.window ? 1 : 0);
        // Camera: chẩn đoán tại sao không vẽ được box (chain toàn bộ).
        ESPCamera camProbe;
        BOOL camOK = ESPEngineCamera(gameBase, &camProbe);
        if (camOK) {
            ESPLog("diag cam OK fov=%.1f loc=(%.0f,%.0f,%.0f) rot=(%.0f,%.0f,%.0f)",
                   camProbe.fov, camProbe.location.x, camProbe.location.y,
                   camProbe.location.z, camProbe.rotation.pitch,
                   camProbe.rotation.yaw, camProbe.rotation.roll);
        } else {
            // Soi cả 2 nguồn PC: NetDriver chain (Kernel) + GameInstance resolver.
            BOOL okn = NO;
            uint64_t net2 = ESPReadU64(vmMap, world + ESPOff_World_NetDriver, &okn);
            uint64_t conn2 = (okn && ESPIsUserPtr(net2))
                ? ESPReadU64(vmMap, net2 + ESPOff_NetDriver_ServerConn, &okn) : 0;
            uint64_t pc2 = (okn && ESPIsUserPtr(conn2))
                ? ESPReadU64(vmMap, conn2 + ESPOff_Conn_LocalPC, &okn) : 0;
            BOOL okc = NO;
            uint64_t gameInst2 = ESPReadU64(vmMap, world + ESPOff_UWorld_OwningGameInstance, &okc);
            ESPLog("diag cam FAIL net=0x%llx conn=0x%llx pc=0x%llx gInst=%llx %s",
                   (unsigned long long)net2, (unsigned long long)conn2,
                   (unsigned long long)pc2, (unsigned long long)gameInst2,
                   ESPCameraResolveDiag());
        }
    }
    g_espProgressTotal.store((int)scanN);
    g_espProgress.store(0);
    uint32_t enemies = 0;
    uint32_t dummies = 0;
    // Build tracked trên vector LOCAL rồi swap 1 lần dưới lock ở cuối scan:
    // box path (bridge queue) copy dưới lock nên không bao giờ thấy vector
    // đang clear/push dở (trước đây là race -> tracked rỗng/rác -> box 0).
    std::vector<ESPTrackedActor> localTracked;
    localTracked.reserve(64);
    uint32_t nVt = 0, nName = 0, nDummyName = 0, nChar = 0, nDummySig = 0;
    uint32_t nNo = 0, nFiltered = 0, nCached = 0;
    uint32_t nearChar = 0, nearDummy = 0, winOK = 0, winFail = 0;
    std::unordered_map<uint64_t, uint32_t> vtHist;
    uint64_t sample = 0;
    ESPVector samplePos = {0,0,0};
    BOOL hasPos = NO;
    int logged = 0;
    for (uint32_t i = 0; i < scanN; i++) {
        if ((i & 15) == 0) g_espProgress.store((int)i);
        // Nhường mutex read cho box refresh chen vào: scan giữ từng read hàng
        // chục ms, không nhường thì refresh đói tới vài giây (max 4.8s đo thực
        // tế). Nhịp 15Hz/1ms thay vì 64/3ms: cửa sổ actor giờ đi qua page cache
        // nên vòng lặp vào/ra mutex rất nhanh -> nhường thưa thì refresh bị
        // starve (mutex không fair) và tick vẽ bị treo cả giây.
        if ((i & 15) == 0) usleep(1000);
        uint64_t actor = s_actors[i];
        if (!ESPIsUserPtr(actor)) continue;
        r.scanned++;
        int team = 0; float hp = 0;
        ESPClassifyDiag dg;
        BOOL isEnemy = ESPIsEnemy(vmMap, actor, myTeam, myPawn, &team, &hp, &dg);
        switch (dg.rule) {
            case 1: nVt++; break;
            case 2: nName++; break;
            case 3: nDummyName++; break;
            case 4: nChar++; break;
            case 5: nDummySig++; break;
            case 0: nNo++; break;
            case -1: case -4: nFiltered++; break;
            case -3: nCached++; break;
            default: break;
        }
        BOOL readFields = (dg.rule != -2 && dg.rule != -3);
        if (readFields) {
            if (dg.win) winOK++; else winFail++;
            if (dg.nearChar == 1) nearChar++;
            if (dg.nearDummy == 1) nearDummy++;
        }
        if (dg.vt) vtHist[dg.vt]++;
        if (verbose && logged < 24) {
            ESPLog("a[%u] 0x%llx r=%d w=%d vt=0x%llx nid=0x%x m=0x%llx hp=%.0f/%.0f team=%d tm=0x%llx tMax=%.0f tCur=%.0f up=%u nc=%d nd=%d",
                   i, (unsigned long long)actor, dg.rule, dg.win, (unsigned long long)dg.vt,
                   dg.nameID, (unsigned long long)dg.mesh, dg.hp, dg.hpMax, dg.team,
                   (unsigned long long)dg.tMesh, dg.tMax, dg.tCur, dg.tIsUp,
                   dg.nearChar, dg.nearDummy);
            logged++;
        }
        if (!isEnemy) continue;
        enemies++;
        if (team == ESPTeam_Dummy) dummies++;
        // Lưu lại để refresh vị trí nhanh giữa các lượt quét (ESPTrackedActor).
        // Dùng diag (field đọc trong ESPIsEnemy) — biến f ở nhánh phân loại
        // không còn scope ở đây.
        if (localTracked.size() < 64) {
            ESPTrackedActor tr;
            tr.actor = actor;
            tr.root = (ESPIsUserPtr(dg.root)) ? dg.root : 0;
            tr.fallback = 0;
            tr.parent = 0;
            if (team == ESPTeam_Dummy) {
                tr.kind = 3;
                if (ESPIsUserPtr(dg.tMesh)) tr.fallback = dg.tMesh;
                if (!tr.root && tr.fallback) tr.root = tr.fallback;
            } else {
                tr.kind = 1;
            }
            // Nhớ AttachedParent ngay lúc track: root character thường không có
            // parent -> refresh sau này bỏ hẳn parent read (tiết kiệm 1-2 reads).
            if (tr.root) {
                BOOL okp = NO;
                uint64_t par = ESPReadU64(vmMap, tr.root + ESPOff_Scene_AttachedParent, &okp);
                if (okp && ESPIsUserPtr(par)) tr.parent = par;
            }
            localTracked.push_back(tr);
        }
        if (!sample) {
            sample = actor;
            BOOL okRoot = NO;
            uint64_t root = ESPReadU64(vmMap, actor + ESPOff_Actor_RootComponent, &okRoot);
            if (okRoot && ESPIsUserPtr(root)) {
                ESPVector v = {0,0,0};
                if (ESPMemoryRead(vmMap, root + ESPOff_Scene_RelativeLocation, &v, sizeof(v))) {
                    samplePos = v;
                    hasPos = YES;
                }
            }
        }
    }
    g_espProgress.store((int)scanN);
    {
        // Publish tracked cho box path (swap dưới lock, giữ lock cực ngắn).
        // Lượt quét ra 0 actor KHÔNG xoá tracked: hụt 1 lượt (world vừa đổi,
        // read fail, actor chưa spawn) mà xoá là refresh 60Hz trả 0 box cho tới
        // lượt quét sau (TTL 2s) — nhìn như box tắt/bật giật. Xoá tracked là
        // việc của ESPVerdictResetIfWorldChanged khi ĐỔI world.
        std::lock_guard<std::mutex> lk(g_espClassifyMutex);
        if (!localTracked.empty()) {
            g_espTracked.swap(localTracked);
            g_espTrackGen++;
        }
        g_espPasses++;
    }
    r.playerLike = enemies;
    r.dummyLike = dummies;
    r.sampleActor = sample;
    r.samplePos = samplePos;
    r.hasSamplePos = hasPos;
    ESPLog("scan done enemies=%u dummy=%u scanned=%u win=%u/%u vt=%u nm=%u dnm=%u ch=%u dm=%u no=%u filt=%u cache=%u nc=%u nd=%u dt=%.1fs",
           (unsigned)enemies, (unsigned)dummies, (unsigned)r.scanned, (unsigned)winOK,
           (unsigned)winFail, (unsigned)nVt, (unsigned)nName, (unsigned)nDummyName,
           (unsigned)nChar, (unsigned)nDummySig, (unsigned)nNo,
           (unsigned)nFiltered, (unsigned)nCached, (unsigned)nearChar,
           (unsigned)nearDummy,
           CFAbsoluteTimeGetCurrent() - t0);
    if (verbose) {
        std::vector<std::pair<uint64_t, uint32_t>> vts(vtHist.begin(), vtHist.end());
        std::sort(vts.begin(), vts.end(), [](const std::pair<uint64_t,uint32_t> &a,
                                             const std::pair<uint64_t,uint32_t> &b) {
            return a.second > b.second;
        });
        char buf[512] = {0};
        int bl = 0;
        for (size_t i = 0; i < vts.size() && i < 8; i++) {
            bl += snprintf(buf + bl, sizeof(buf) - (size_t)bl, " 0x%llx:%u",
                           (unsigned long long)vts[i].first, (unsigned)vts[i].second);
            if (bl > (int)sizeof(buf) - 32) break;
        }
        uint64_t pawnVtCopy = 0;
        int verboseLeftCopy = 0;
        {
            std::lock_guard<std::mutex> lk(g_espClassifyMutex);
            pawnVtCopy = g_espPlayerVTable;
            verboseLeftCopy = g_espVerboseLeft;
        }
        ESPLog("diag vtHist(%zu)%s pawnVt=0x%llx", vts.size(), buf,
               (unsigned long long)pawnVtCopy);
        if (verboseLeftCopy > 0) {
            std::lock_guard<std::mutex> lk(g_espClassifyMutex);
            if (g_espVerboseLeft > 0) g_espVerboseLeft--;
        }
    }
    return r;
#endif
}

static CFAbsoluteTime g_espCheckedAt = 0;
static ESPScanResult g_espCache = {0};
static int g_espCachePasses = 0; // số lượt lúc cache được ghi
static std::atomic_bool g_espScanning(false);
static CFAbsoluteTime g_espScanStart = 0; // lúc bắt đầu lần quét hiện tại
static const double kESPScanStuckTimeout = 45.0; // quá từng này giây coi như kẹt, cho quét lại
static double g_espLastScanSeconds = 0; // lần quét xong gần nhất mất bao lâu
static int g_espLastScanEnemies = -1; // -1 = chưa xong lần nào
static int g_espLastScanDummies = -1; // số hình nhân trong lần quét xong gần nhất
static int g_espLastBoxes = 0;        // số box refresh gần nhất (hiện trên app)
static int g_espTrackedCount = 0;     // số actor đang theo dõi (mirror của g_espTracked)

void ESPBoxCounterSet(int n) {
    g_espLastBoxes = n;
}
static uint32_t g_espLightActors = 0; // actors của lần quét nhẹ gần nhất
static uint64_t g_espLightWorld = 0;  // world tương ứng (0 = chưa quét được)
static CFAbsoluteTime g_espLightAt = 0; // lúc quét nhẹ lần cuối (cache 1s)

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
    // Vài lượt đầu quét dày hơn để số players chóng đúng, sau đó về TTL thường.
    // Vài lượt đầu quét dày để địch/players hiện số đúng sớm nhất có thể (TTL
    // là khoảng nghỉ TỐI THIỂU, lượt quét dài bao nhiêu còn tuỳ cache).
    double ttl = (g_espPasses < 3) ? 0.5 : ESP_CACHE_TTL;
    if (now - g_espCheckedAt < ttl && g_espCheckedAt > 0) return;
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
            // World đổi (map/trận mới): page cache còn giữ mapping của world
            // cũ -> xả để nhả mapping + port, và tránh đọc page héo.
            static uint64_t s_lastCacheWorld = 0;
            if (r.world && r.world != s_lastCacheWorld) {
                if (s_lastCacheWorld) ESPMemoryFlushPageCache();
                s_lastCacheWorld = r.world;
            }
            g_espCache = r;
            g_espCachePasses = g_espPasses;
            g_espCheckedAt = CFAbsoluteTimeGetCurrent();
            g_espLastScanSeconds = g_espCheckedAt - t0;
            g_espLastScanEnemies = r.world ? (int)r.playerLike : -2; // -2 = fail
            g_espLastScanDummies = r.world ? (int)r.dummyLike : -1;
            g_espTrackedCount = (int)g_espTracked.size();
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
    // Một lượt quét giờ đã phân loại hết actor, nên chỉ lượt đầu tiên mới cần
    // đánh dấu ~ (đang warmup) — lượt sau là số chính thức.
    if (g_espCachePasses < 2) {
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
    if (ESPLevelAndActors(vmMap, world, &level, &ad, &ac)) {
        return ac;
    }
    return 0;
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
    // Quét nhẹ (~20 lần đọc) để có số actors hiện ngay từ tick đầu. Chạy được
    // cả khi scan nền đang chạy: mọi lần đọc đều xếp hàng qua mutex trong
    // ESPMemoryRead nên 2 luồng không đụng nhau trong kernel.
    // Quét nhẹ tốn vài chục lần đọc kernel: cache 1s để tick HUD không bị
    // nghẽn (trước đây tick nào cũng quét lại => HUD đứng vài giây mới ra số).
    CFAbsoluteTime lightNow = CFAbsoluteTimeGetCurrent();
    if (lightNow - g_espLightAt > 1.0) {
        g_espLightAt = lightNow;
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
        // "%d D" = trong đó có bao nhiêu là hình nhân huấn luyện — để biết
        // ngay con hình nhân nào bị lọt khỏi bộ lọc. "B %d" = số box đang vẽ
        // trên SpringBoard (cam+track OK). B=0 mà P>0 thì camera/track lỗi.
        if (g_espTrackedCount > 0 || g_espLastBoxes > 0) {
            return [NSString stringWithFormat:@"scan ok %d P %d D B%d %.1fs",
                    g_espLastScanEnemies, g_espLastScanDummies, g_espLastBoxes,
                    g_espLastScanSeconds];
        }
        return [NSString stringWithFormat:@"scan ok %d P %d D %.1fs",
                g_espLastScanEnemies, g_espLastScanDummies, g_espLastScanSeconds];
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
    // procbyname duyệt proclist qua kernel (đắt) — box refresh gọi 8Hz nên
    // cache proc/vmMap 30s (globals g_espVM* khai báo ở trên, flush khi đổi
    // world). u64/double đọc-ghi benign cross-thread; stale thì fail-safe.
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (g_espVMMap && now - g_espVMAt < 30.0) {
        if (outProc) *outProc = g_espVMProc;
        return g_espVMMap;
    }
    uint64_t proc = procbyname(ESP_DEFAULT_PROCESS);
    if (!proc) proc = procbyname("ShadowTrackerE");
    if (!proc) return g_espVMMap; // giữ stale còn hơn 0 (reads fail-safe)
    if (outProc) *outProc = proc;
    uint64_t task = taskbyproc(proc);
    uint64_t vmMap = task ? task_get_vm_map(task) : 0;
    if (vmMap) {
        g_espVMProc = proc;
        g_espVMMap = vmMap;
        g_espVMAt = now;
    }
    return vmMap ? vmMap : g_espVMMap;
}
#endif

#if USE_DARKSWORD
// Phát hiện địch MỚI: quét nền đầy đủ mất 0.3–5s+TTL nên địch spawn/unhide
// phải đợi lượt quét kế tiếp mới vào tracked (log: 5–6s). Hàm này chạy ~8Hz
// trên tick bridge: bulk-read mảng actor, chỉ phân loại actor CHƯA có verdict
// (budget) + re-check verdict địch chưa vào tracked + peek VTable verdict-2
// (địa chỉ object pool tái dùng). KHÔNG giữ g_espClassifyMutex khi gọi
// ESPIsEnemy (hàm đó tự lock — giữ song song sẽ deadlock).
void ESPEngineDiscoverTick(uint64_t gameBase) {
    if (!gameBase || !ds_is_ready()) return;
    static CFAbsoluteTime s_last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (s_last && now - s_last < ESP_DISCOVER_INTERVAL) return;
    s_last = now;

    uint64_t vmMap = ESPProcVMMap(NULL);
    if (!vmMap) return;
    uint64_t world = g_espCache.world;
    if (!world) {
        world = ESPWorldViaViewport(vmMap, gameBase);
        if (!world) return;
        // Giúp path Boxes/Refresh có world ngay cả khi scan nền chưa xong.
        if (!g_espCache.world) g_espCache.world = world;
    }
    ESPVerdictResetIfWorldChanged(world);

    // Snapshot tracked + verdict DƯỚI 1 lock ngắn; sau đó nhả lock rồi mới
    // ESPIsEnemy (hàm đó tự lock cùng mutex).
    std::unordered_set<uint64_t> trackedSet;
    std::unordered_set<uint64_t> hasVerdict;
    std::unordered_set<uint64_t> enemyVerdict;
    std::unordered_map<uint64_t, uint64_t> verdictVt;
    {
        std::lock_guard<std::mutex> lk(g_espClassifyMutex);
        trackedSet.reserve(g_espTracked.size());
        for (const auto &t : g_espTracked) trackedSet.insert(t.actor);
        hasVerdict.reserve(g_espVerdict.size());
        for (const auto &kv : g_espVerdict) {
            hasVerdict.insert(kv.first);
            if (kv.second == 1 || kv.second == 3) enemyVerdict.insert(kv.first);
        }
        verdictVt = g_espVerdictVt;
    }

    uint64_t level = 0, actorsData = 0;
    uint32_t actorsCount = 0;
    if (!ESPLevelAndActors(vmMap, world, &level, &actorsData, &actorsCount) ||
        !actorsData || actorsCount == 0 || actorsCount > 20000) {
        return;
    }
    uint32_t scanN = actorsCount > ESP_MAX_ACTORS_SCAN ? ESP_MAX_ACTORS_SCAN : actorsCount;

    static thread_local std::vector<uint64_t> discActors;
    discActors.resize(scanN);
    uint32_t got = 0;
    while (got < scanN) {
        uint32_t chunk = scanN - got;
        if (chunk > 2048) chunk = 2048;
        if (!ESPReadWindow(vmMap, actorsData + (uint64_t)got * 8, discActors.data() + got,
                           (uint64_t)chunk * 8)) {
            for (uint32_t k = 0; k < chunk; k++) {
                BOOL okk = NO;
                discActors[got + k] = ESPReadU64(vmMap, actorsData + (uint64_t)(got + k) * 8, &okk);
            }
        }
        got += chunk;
    }

    int myTeam = INT_MIN;
    uint64_t myPawn = 0;
    {
        int t = INT_MIN;
        uint64_t lp = 0;
        if (ESPMyTeamAndPawn(vmMap, world, &lp, &t)) {
            myTeam = t;
            myPawn = lp;
        }
    }

    // Round-robin: unknown không dồn vào đầu mảng mãi (budget hết thì lượt sau
    // lấy unknown kế tiếp, không quét lại 16 actor cũ).
    static uint32_t s_discOff = 0;
    std::vector<uint32_t> unknownIdx;
    unknownIdx.reserve(64);
    std::vector<ESPTrackedActor> newTracked;
    newTracked.reserve(8);
    int cls = 0;  // số ESPIsEnemy gọi thật (unknown full + enemy-not-tracked + vt-peek)
    int added = 0;

    auto addTracked = [&](uint64_t actor, int team, const ESPClassifyDiag &dg) {
        if (trackedSet.count(actor) || newTracked.size() >= 64) return;
        ESPTrackedActor tr;
        tr.actor = actor;
        tr.root = ESPIsUserPtr(dg.root) ? dg.root : 0;
        tr.fallback = 0;
        tr.parent = 0;
        if (team == ESPTeam_Dummy) {
            tr.kind = 3;
            if (ESPIsUserPtr(dg.tMesh)) tr.fallback = dg.tMesh;
            if (!tr.root && tr.fallback) tr.root = tr.fallback;
        } else {
            tr.kind = 1;
        }
        if (tr.root) {
            BOOL okp = NO;
            uint64_t par = ESPReadU64(vmMap, tr.root + ESPOff_Scene_AttachedParent, &okp);
            if (okp && ESPIsUserPtr(par)) tr.parent = par;
        }
        newTracked.push_back(tr);
        trackedSet.insert(actor);
        added++;
    };

    // Pass 1: verdict địch 1/3 chưa tracked (vừa unhide) + peek VTable
    // verdict-2 (object pool tái dùng địa chỉ -> có thể đã thành địch).
    // Unknown gom vào pass 2 theo budget.
    // Cooldown Pass 1: địch chết/ẩn giữ verdict 1 — check_live mỗi 120ms trên
    // hàng chục actor là cls=17 spam (window read thừa). 0.4s vẫn bắt unhide
    // đủ nhanh, giảm ~3 lần kernel đọc mỗi discover.
    // Map này cũng được ESPVerdictResetIfWorldChanged clear dưới cùng mutex
    // classify — truy cập ngắn dưới lock, không giữ qua ESPIsEnemy.
    const CFAbsoluteTime pass1Cd = 0.4;
    for (uint32_t i = 0; i < scanN; i++) {
        uint64_t actor = discActors[i];
        if (!ESPIsUserPtr(actor) || trackedSet.count(actor)) continue;
        if (!hasVerdict.count(actor)) {
            unknownIdx.push_back(i);
            continue;
        }
        if (enemyVerdict.count(actor)) {
            BOOL pass1Skip = NO;
            {
                std::lock_guard<std::mutex> lk(g_espClassifyMutex);
                auto p1 = g_espPass1At.find(actor);
                if (p1 != g_espPass1At.end() && now - p1->second < pass1Cd) {
                    pass1Skip = YES;
                } else {
                    g_espPass1At[actor] = now;
                }
            }
            if (pass1Skip) continue;
            // Verdict 1/3 nhưng chưa tracked: check_live (ẩn/chết) rồi add.
            int team = 0;
            float hp = 0;
            ESPClassifyDiag dg;
            cls++;
            if (ESPIsEnemy(vmMap, actor, myTeam, myPawn, &team, &hp, &dg)) {
                addTracked(actor, team, dg);
            }
            continue;
        }
        // Verdict 2: peek 8B VTable từ page cache. Đổi class => phân loại lại
        // ngay. KHÔNG gọi ESPIsEnemy khi age hết hạn — full scan lo re-validate
        // (gọi ESPIsEnemy lúc age>kESPverdictExpiryFrames sẽ full-read TOÀN BỘ
        // verdict-2 mỗi 120ms — hundreds of window reads, giật tick).
        uint64_t vtOld = 0;
        auto vti = verdictVt.find(actor);
        if (vti != verdictVt.end()) vtOld = vti->second;
        if (!vtOld) continue;
        uint64_t vtNow = 0;
        if (!ESPMemoryReadCached(vmMap, actor, &vtNow, sizeof(vtNow)) || vtNow == vtOld) {
            continue;
        }
        int team = 0;
        float hp = 0;
        ESPClassifyDiag dg;
        cls++;
        if (ESPIsEnemy(vmMap, actor, myTeam, myPawn, &team, &hp, &dg)) {
            addTracked(actor, team, dg);
        }
    }

    // Pass 2: phân loại unknown theo budget + round-robin.
    int budget = ESP_DISCOVER_BUDGET;
    int unknownTried = 0;
    if (!unknownIdx.empty()) {
        uint32_t off = s_discOff % (uint32_t)unknownIdx.size();
        for (int b = 0; b < budget && !unknownIdx.empty(); b++) {
            uint32_t i = unknownIdx[(off + (uint32_t)b) % (uint32_t)unknownIdx.size()];
            uint64_t actor = discActors[i];
            if (trackedSet.count(actor)) continue;
            int team = 0;
            float hp = 0;
            ESPClassifyDiag dg;
            cls++;
            unknownTried++;
            if (ESPIsEnemy(vmMap, actor, myTeam, myPawn, &team, &hp, &dg)) {
                addTracked(actor, team, dg);
            }
        }
        s_discOff = off + (uint32_t)budget;
    }

    if (!newTracked.empty()) {
        std::lock_guard<std::mutex> lk(g_espClassifyMutex);
        for (const auto &nt : newTracked) {
            bool exists = false;
            for (const auto &t : g_espTracked) {
                if (t.actor == nt.actor) { exists = true; break; }
            }
            if (!exists) g_espTracked.push_back(nt);
        }
        g_espTrackGen++;
        g_espTrackedCount = (int)g_espTracked.size();
    }
    // Log khi THẬT SỰ thêm địch, hoặc unknown đổi số (không nhai lại cùng 1
    // actor mỗi 120ms). Heartbeat hiếm khi còn unknown để chẩn đoán.
    static CFAbsoluteTime s_lastUnkLog = 0;
    if (added > 0) {
        ESPLog("discover: cls=%d +E=%d unk=%zu left=%zu trk=%d",
               cls, added, unknownIdx.size(), unknownIdx.size() > (size_t)unknownTried
                   ? unknownIdx.size() - (size_t)unknownTried : 0,
               g_espTrackedCount);
    } else if (!unknownIdx.empty() && now - s_lastUnkLog >= 5.0) {
        s_lastUnkLog = now;
        ESPLog("discover: cls=%d +E=0 unk=%zu left=%zu trk=%d",
               cls, unknownIdx.size(), unknownIdx.size() > (size_t)unknownTried
                   ? unknownIdx.size() - (size_t)unknownTried : 0,
               g_espTrackedCount);
    }
}
#else
void ESPEngineDiscoverTick(uint64_t gameBase) {
    (void)gameBase;
}
#endif

// --- Camera PC resolver: field LocalPlayers trong UGameInstance trôi theo
// bản game (0x48 ở dump cũ đã gãy: gameInst đọc OK nhưng +0x48 fail).
// Resolver thử các candidate offset, validate BẰNG CẢ CHAIN xuống tới FOV
// (data/count -> LP -> PC -> CamMgr -> FOV 10..170), rồi cache offset theo
// GameInstance. Lần sau chỉ tốn ~5 reads để re-validate.
static uint32_t g_espLPOffFound = 0;   // field offset đã validate
static uint64_t g_espLPInstFound = 0;  // gameInstance tương ứng
static uint64_t g_espLPNegInst = 0;    // gameInstance resolve fail gần nhất
static CFAbsoluteTime g_espLPNegAt = 0; // lúc fail (cache âm 5s chống spam)
static char g_espLPDiag[160] = "n/a";  // diag lần resolve gần nhất

static BOOL ESPFovSaneAt(uint64_t vmMap, uint64_t camMgr) {
    float fov = 0;
    if (!ESPMemoryRead(vmMap, camMgr + ESPOff_CamMgr_ViewTarget + ESPOff_ViewTarget_POV + ESPOff_POV_FOV,
                       &fov, sizeof(fov))) return NO;
    return (fov >= 10.0f && fov <= 170.0f);
}

// Validate 1 candidate offset. Trả PC nếu cả chain OK, 0 nếu gãy (ghi stage).
static uint64_t ESPTryLPOff(uint64_t vmMap, uint64_t gameInst, uint32_t off,
                            char *stageBuf, size_t stageN) {
    BOOL ok = NO;
    uint64_t data = ESPReadU64(vmMap, gameInst + off, &ok);
    if (!ok || !ESPIsUserPtr(data)) {
        if (stageBuf) snprintf(stageBuf, stageN, "off=0x%x dataFail ok=%d raw=0x%llx",
                               off, ok ? 1 : 0, (unsigned long long)data);
        return 0;
    }
    uint32_t n = ESPReadU32(vmMap, gameInst + off + 8, &ok);
    if (!ok || n == 0 || n > 8) {
        if (stageBuf) snprintf(stageBuf, stageN, "off=0x%x n=%u", off, (unsigned)n);
        return 0;
    }
    uint64_t lp = ESPReadU64(vmMap, data, &ok);
    if (!ok || !ESPIsUserPtr(lp)) {
        if (stageBuf) snprintf(stageBuf, stageN, "off=0x%x lpFail", off);
        return 0;
    }
    uint64_t pc = ESPReadU64(vmMap, lp + ESPOff_Player_PlayerController, &ok);
    if (!ok || !ESPIsUserPtr(pc)) {
        if (stageBuf) snprintf(stageBuf, stageN, "off=0x%x pcFail", off);
        return 0;
    }
    uint64_t cm = ESPReadU64(vmMap, pc + ESPOff_PC_CameraManager, &ok);
    if (!ok || !ESPIsUserPtr(cm)) {
        if (stageBuf) snprintf(stageBuf, stageN, "off=0x%x cmFail", off);
        return 0;
    }
    if (!ESPFovSaneAt(vmMap, cm)) {
        if (stageBuf) snprintf(stageBuf, stageN, "off=0x%x fovFail", off);
        return 0;
    }
    if (stageBuf) snprintf(stageBuf, stageN, "off=0x%x OK", off);
    return pc;
}

static uint64_t ESPResolvePC(uint64_t vmMap, uint64_t gameInst) {
    if (!ESPIsUserPtr(gameInst)) return 0;
    std::lock_guard<std::mutex> lk(g_espClassifyMutex);
    // 1) Cache dương: re-validate nhanh (gameInst đổi/world mới thì tự rớt).
    if (g_espLPInstFound == gameInst && g_espLPOffFound) {
        char st[64] = {0};
        uint64_t pc = ESPTryLPOff(vmMap, gameInst, g_espLPOffFound, st, sizeof(st));
        if (pc) return pc;
        g_espLPInstFound = 0;
        g_espLPOffFound = 0;
    }
    // 2) Cache âm 5s (box tick 1Hz + scan probe gọi liên tục).
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (g_espLPNegInst == gameInst && now - g_espLPNegAt < 5.0) return 0;
    // 3) Quét candidates full-range 0x28..0xE0 (class UGameInstance rộng,
    // LocalPlayers có thể nằm ngoài dải đoán ban đầu). ~23 slot x ~2 reads,
    // chỉ chạy khi cache miss (cache âm 5s).
    static const uint32_t kCand[] = {
        ESPOff_GameInstance_LocalPlayers,
        0x28, 0x30, 0x38, 0x40, 0x48, 0x50, 0x58, 0x60, 0x68, 0x70,
        0x78, 0x80, 0x88, 0x90, 0x98, 0xA0, 0xA8, 0xB0, 0xB8, 0xC0,
        0xC8, 0xD0, 0xD8, 0xE0,
    };
    // Giữ MỌI stage "hay" (không phải dataFail — dataFail ở hầu hết slot là
    // bình thường): cho biết chính xác slot 0x38 rớt ở lp/pc/cm/fov mốc nào.
    char best[256] = {0};
    int nStages = 0;
    for (size_t i = 0; i < sizeof(kCand) / sizeof(kCand[0]); i++) {
        char st[96] = {0};
        uint64_t pc = ESPTryLPOff(vmMap, gameInst, kCand[i], st, sizeof(st));
        if (strstr(st, "dataFail") == NULL) {
            if (nStages < 8) {
                size_t bl = strlen(best);
                snprintf(best + bl, sizeof(best) - bl, " %s", st);
                nStages++;
            }
        } else if (best[0] == '\0') {
            snprintf(best, sizeof(best), "%s", st); // toàn dataFail: giữ cái đầu (có ok/raw)
        }
        if (pc) {
            g_espLPInstFound = gameInst;
            g_espLPOffFound = kCand[i];
            snprintf(g_espLPDiag, sizeof(g_espLPDiag), "inst=0x%llx %s",
                     (unsigned long long)gameInst, st);
            ESPLog("camLP resolved %s", g_espLPDiag);
            return pc;
        }
    }
    g_espLPNegInst = gameInst;
    g_espLPNegAt = now;
    snprintf(g_espLPDiag, sizeof(g_espLPDiag), "inst=0x%llx FAIL last=%s",
             (unsigned long long)gameInst, best);
    ESPLog("camLP FAIL %s", g_espLPDiag);
    return 0;
}

static const char *ESPCameraResolveDiag(void) {
    return g_espLPDiag;
}

static BOOL ESPCameraIsResolved(void) {
    std::lock_guard<std::mutex> lk(g_espClassifyMutex);
    return g_espLPInstFound != 0;
}

// Dump 1 lần/world khi camera chưa resolve: đối chiếu GameInstance từ 3 nguồn
// (world+0x470, viewport+0x80, engine+0xE20) + liệt kê mọi slot trông như
// TArray {data,count 1..8} trong 0x20..0x180 của object đó. Đủ để hardcode
// offset đúng mà không cần đoán thêm vòng nào.
static void ESPGameInstanceDump(uint64_t vmMap, uint64_t world, uint64_t gameBase) {
    BOOL ok = NO;
    uint64_t gi1 = ESPReadU64(vmMap, world + ESPOff_UWorld_OwningGameInstance, &ok);
    if (!ok) gi1 = 0;
    uint64_t engine = ESPReadU64(vmMap, ESPGEngineRuntime(gameBase), &ok);
    if (!ok) engine = 0;
    uint64_t viewport = (engine && ESPIsUserPtr(engine))
        ? ESPReadU64(vmMap, engine + ESPOff_Engine_GameViewport, &ok) : 0;
    if (!ok) viewport = 0;
    uint64_t gi2 = (viewport && ESPIsUserPtr(viewport))
        ? ESPReadU64(vmMap, viewport + ESPOff_Viewport_GameInstance, &ok) : 0;
    if (!ok) gi2 = 0;
    uint64_t gi3 = (engine && ESPIsUserPtr(engine))
        ? ESPReadU64(vmMap, engine + ESPOff_GameEngine_GameInstance, &ok) : 0;
    if (!ok) gi3 = 0;
    ESPLog("giDump w470=0x%llx vp80=0x%llx engE20=0x%llx",
           (unsigned long long)gi1, (unsigned long long)gi2, (unsigned long long)gi3);
    uint64_t gi = gi1 ? gi1 : (gi2 ? gi2 : gi3);
    if (!ESPIsUserPtr(gi)) {
        ESPLog("giDump no valid GameInstance");
        return;
    }
    char buf[768] = {0};
    int bl = 0, found = 0;
    for (uint32_t off = 0x20; off <= 0x180 && found < 10; off += 8) {
        BOOL okd = NO, okn = NO;
        uint64_t data = ESPReadU64(vmMap, gi + off, &okd);
        uint32_t n = ESPReadU32(vmMap, gi + off + 8, &okn);
        if (okd && okn && ESPIsUserPtr(data) && n >= 1 && n <= 8) {
            bl += snprintf(buf + bl, sizeof(buf) - (size_t)bl, " 0x%x:{0x%llx x%u}",
                           off, (unsigned long long)data, (unsigned)n);
            if (bl > (int)sizeof(buf) - 48) break;
            found++;
        }
    }
    ESPLog("giDump gi=0x%llx tarray(%d)%s", (unsigned long long)gi, found, buf);
}

// Perf refresh box: đo ms mỗi lần RefreshBoxes/Boxes chạy xong, TÁCH 3 khâu
// (proc=proc/task lookup, cam=camera, act=vòng actors) để biết khâu nào nặng.
// Chỉ chạm từ bridge queue nên không cần lock. Text đọc + reset mỗi 10s.
static double g_perfSumProc = 0, g_perfSumCam = 0, g_perfSumAct = 0;
static int g_perfN = 0;
static double g_perfMaxMs = 0;
static char g_perfBuf[256] = "n/a";
static uint64_t g_perfLastHit = 0, g_perfLastMiss = 0;
static uint64_t g_perfLastTask = 0, g_perfLastKernel = 0;
static void ESPPerfSample(double procMs, double camMs, double actMs) {
    g_perfSumProc += procMs;
    g_perfSumCam += camMs;
    g_perfSumAct += actMs;
    g_perfN++;
    double tot = procMs + camMs + actMs;
    if (tot > g_perfMaxMs) g_perfMaxMs = tot;
}
const char *ESPEngineBoxPerfText(void) {
    uint64_t hit = 0, miss = 0;
    ESPMemoryCacheStats(&hit, &miss);
    uint64_t dHit = hit - g_perfLastHit, dMiss = miss - g_perfLastMiss;
    g_perfLastHit = hit;
    g_perfLastMiss = miss;
    // read(t=.. k=..): bao nhiêu lần đọc đi task port (nhanh) vs kernel exploit.
    // t=0 nghĩa là task port chưa bật được -> box vẫn đi đường chậm.
    uint64_t taskReads = 0, kernelReads = 0;
    ESPMemoryReadPathStats(&taskReads, &kernelReads);
    uint64_t dTask = taskReads - g_perfLastTask, dKernel = kernelReads - g_perfLastKernel;
    g_perfLastTask = taskReads;
    g_perfLastKernel = kernelReads;
    if (g_perfN > 0) {
        snprintf(g_perfBuf, sizeof(g_perfBuf),
                 "n=%d proc=%.1f cam=%.1f act=%.1f avg=%.1f max=%.1f cache(h=%llu m=%llu) read(t=%llu k=%llu)",
                 g_perfN, g_perfSumProc / (double)g_perfN, g_perfSumCam / (double)g_perfN,
                 g_perfSumAct / (double)g_perfN,
                 (g_perfSumProc + g_perfSumCam + g_perfSumAct) / (double)g_perfN, g_perfMaxMs,
                 (unsigned long long)dHit, (unsigned long long)dMiss,
                 (unsigned long long)dTask, (unsigned long long)dKernel);
    } else {
        snprintf(g_perfBuf, sizeof(g_perfBuf), "n=0 cache(h=%llu m=%llu) read(t=%llu k=%llu)",
                 (unsigned long long)dHit, (unsigned long long)dMiss,
                 (unsigned long long)dTask, (unsigned long long)dKernel);
    }
    g_perfSumProc = 0;
    g_perfSumCam = 0;
    g_perfSumAct = 0;
    g_perfN = 0;
    g_perfMaxMs = 0;
    return g_perfBuf;
}

// PC cache theo world: PC (controller) ổn định cả trận, resolve lại khi đổi
// world hoặc khi CamMgr read fail. Tiết kiệm 3 kernel reads mỗi refresh.
static uint64_t s_camPC = 0;
static uint64_t s_camWorld = 0;
static uint64_t s_camMgr = 0; // PC ổn định cả trận -> cammgr cũng ổn định, cache luôn

static uint64_t ESPResolvePCCached(uint64_t vmMap, uint64_t world) {
    // Không giữ lock ngoài suốt quá trình (ESPResolvePC tự lock trong —
    // mutex non-recursive). 2 threads cùng resolve 1 lúc là benign.
    {
        std::lock_guard<std::mutex> lk(g_espClassifyMutex);
        if (s_camWorld == world && s_camPC) return s_camPC;
    }
    BOOL ok = NO;
    uint64_t pc = 0;
    // Đường Kernel trước (đã chứng minh sống), GI resolver fallback.
    uint64_t net = ESPReadU64(vmMap, world + ESPOff_World_NetDriver, &ok);
    if (ok && ESPIsUserPtr(net)) {
        uint64_t conn = ESPReadU64(vmMap, net + ESPOff_NetDriver_ServerConn, &ok);
        if (ok && ESPIsUserPtr(conn)) {
            uint64_t p = ESPReadU64(vmMap, conn + ESPOff_Conn_LocalPC, &ok);
            if (ok && ESPIsUserPtr(p)) pc = p;
        }
    }
    if (!pc) {
        uint64_t gameInst = ESPReadU64(vmMap, world + ESPOff_UWorld_OwningGameInstance, &ok);
        if (ok && ESPIsUserPtr(gameInst)) pc = ESPResolvePC(vmMap, gameInst);
    }
    if (pc) {
        std::lock_guard<std::mutex> lk(g_espClassifyMutex);
        if (s_camWorld != world) ESPLog("camPC pc=0x%llx", (unsigned long long)pc);
        s_camPC = pc;
        s_camWorld = world;
    }
    return pc;
}

static void ESPCamPCClear(void) {
    std::lock_guard<std::mutex> lk(g_espClassifyMutex);
    s_camPC = 0;
    s_camWorld = 0;
    s_camMgr = 0;
}

// CamMgr cache theo (world, pc): đọc 1 lần rồi dùng lại, xả khi read fail.
static uint64_t ESPCamMgrCached(uint64_t vmMap, uint64_t world, uint64_t pc) {
    {
        std::lock_guard<std::mutex> lk(g_espClassifyMutex);
        if (s_camWorld == world && s_camPC == pc && s_camMgr) return s_camMgr;
    }
    BOOL ok = NO;
    uint64_t cm = ESPReadU64(vmMap, pc + ESPOff_PC_CameraManager, &ok);
    if (!ok || !ESPIsUserPtr(cm)) {
        ESPCamPCClear();
        return 0;
    }
    std::lock_guard<std::mutex> lk(g_espClassifyMutex);
    if (s_camWorld == world && s_camPC == pc) s_camMgr = cm;
    return cm;
}

BOOL ESPEngineCamera(uint64_t gameBase, ESPCamera *outCam) {
    if (!outCam) return NO;
#if !USE_DARKSWORD
    (void)gameBase;
    return NO;
#else
    if (!gameBase || !ds_is_ready()) return NO;
    uint64_t vmMap = ESPProcVMMap(NULL);
    if (!vmMap) return NO;
    // Reuse world từ cache nếu có để đỡ scan lại. TUYỆT ĐỐI không tự kick scan:
    // ESPEngineScan gọi hàm này (diag probe) và HUD tick gọi nó 4Hz — tự kick
    // scan ở đây là đệ quy vô hạn (bug: log 'scan start' spam, không scan nào
    // kết thúc). Scan nền do ESPEngineRequestScan lo; camera chỉ ăn theo cache.
    uint64_t world = g_espCache.world;
    if (!world || t_espInScan) {
        // Đang scan hoặc chưa có world: tự đi tìm world qua viewport, rẻ.
        world = ESPWorldViaViewport(vmMap, gameBase);
        if (!world) return NO;
    }
    uint64_t pc = ESPResolvePCCached(vmMap, world);
    if (!pc) return NO;
    uint64_t camMgr = ESPCamMgrCached(vmMap, world, pc);
    if (!camMgr) return NO;
    // POV qua ViewTarget (FTViewTarget @ 0x10A0 + 0x10) — đúng như source
    // Kernel đang chạy được (CameraCache 0x520 không có camera thật ở bản này).
    // Đọc GỘP 56B 1 lần (loc 0x0 + rot 0x18 + fov 0x24 + aspect 0x34) như
    // Kernel ReadBuf POV — 1 kernel read thay vì 4.
    uint64_t pov = camMgr + ESPOff_CamMgr_ViewTarget + ESPOff_ViewTarget_POV;
    ESPVector loc = {0,0,0};
    ESPRotator rot = {0,0,0};
    float fov = 0, aspect = 0;
    {
        uint8_t raw[0x38] = {0};
        // ESPMemoryRead (0x38 < 1 page) đi đường page cache — sau lần đầu là
        // memcpy thuần; ESPReadWindow luôn map page mới (~20ms). cam rẻ hơn ~10x.
        if (ESPMemoryRead(vmMap, pov, raw, sizeof(raw))) {
            memcpy(&loc, raw + ESPOff_POV_Location, sizeof(loc));
            memcpy(&rot, raw + ESPOff_POV_Rotation, sizeof(rot));
            memcpy(&fov, raw + ESPOff_POV_FOV, sizeof(fov));
            memcpy(&aspect, raw + ESPOff_POV_Aspect, sizeof(aspect));
        } else {
            if (!ESPReadVec(vmMap, pov + ESPOff_POV_Location, &loc)) return NO;
            if (!ESPMemoryRead(vmMap, pov + ESPOff_POV_Rotation, &rot, sizeof(rot))) return NO;
            float tmp = 0;
            if (!ESPMemoryRead(vmMap, pov + ESPOff_POV_FOV, &tmp, sizeof(tmp))) return NO;
            fov = tmp;
            if (!ESPMemoryRead(vmMap, pov + ESPOff_POV_Aspect, &tmp, sizeof(tmp))) return NO;
            aspect = tmp;
        }
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

// --- View-projection "matrix" (kiểu buildViewProjection/copyViewProjection
// của aovcheat) ---
// Trước đây MỖI điểm cần project đều tính lại sin/cos 3 góc + tan(fov/2)
// (2 điểm/actor => 2 lần trig/actor, ~8 nhân ma trận/actor). Giờ dựng basis 1
// lần cho mỗi lần đọc camera rồi project mọi actor bằng nhân ma trận thuần:
// 9 phép nhân + 1 chia cho mỗi điểm. Công thức GIỮ NGUYÊN bản gốc của source
// Kernel (cả 2 trục đều dùng screenCenterX) nên kết quả không đổi.
typedef struct {
    float m00, m01, m02; // trục X của rotator
    float m10, m11, m12; // trục Y
    float m20, m21, m22; // trục Z
    float lx, ly, lz;    // camera location
    float k;             // screenWidth*0.5 / tan(fov/2)
    float cx, cy;        // tâm màn hình
} ESPCamBasis;

static BOOL ESPCamBasisBuild(const ESPCamera *cam, float screenW, float screenH, ESPCamBasis *b) {
    if (!cam || !b) return NO;
    if (screenW <= 0 || screenH <= 0) return NO;
    if (!(cam->fov >= 10.0f && cam->fov <= 170.0f)) return NO;
    const float kPi = 3.141592653589793f;
    float radPitch = cam->rotation.pitch * kPi / 180.0f;
    float radYaw   = cam->rotation.yaw   * kPi / 180.0f;
    float radRoll  = cam->rotation.roll  * kPi / 180.0f;
    float SP = sinf(radPitch), CP = cosf(radPitch);
    float SY = sinf(radYaw),   CY = cosf(radYaw);
    float SR = sinf(radRoll),  CR = cosf(radRoll);
    float tanHalf = tanf(cam->fov * kPi / 360.0f);
    if (!(tanHalf > 0.05f && tanHalf < 5.0f)) return NO;
    // Hàng ma trận như RotatorToMatrix gốc
    b->m00 = CP*CY;                  b->m01 = CP*SY;                  b->m02 = SP;
    b->m10 = SR*SP*CY - CR*SY;       b->m11 = SR*SP*SY + CR*CY;       b->m12 = -SR*CP;
    b->m20 = -(CR*SP*CY + SR*SY);    b->m21 = CY*SR - CR*SP*SY;       b->m22 = CR*CP;
    b->lx = cam->location.x; b->ly = cam->location.y; b->lz = cam->location.z;
    b->cx = screenW * 0.5f;
    b->cy = screenH * 0.5f;
    b->k = b->cx / tanHalf;
    return YES;
}

static BOOL ESPCamBasisProject(const ESPCamBasis *b, ESPVector world,
                               float *outX, float *outY, float *outDist) {
    if (!b) return NO;
    float dx = world.x - b->lx, dy = world.y - b->ly, dz = world.z - b->lz;
    // vTransformed = (dot(d,Y), dot(d,Z), dot(d,X)) theo code gốc
    float tx = dx*b->m10 + dy*b->m11 + dz*b->m12;
    float ty = dx*b->m20 + dy*b->m21 + dz*b->m22;
    float tz = dx*b->m00 + dy*b->m01 + dz*b->m02;
    if (tz < 10.0f) return NO; // Sau lưng hoặc quá sát camera (< 10cm)
    float distM = sqrtf(dx*dx + dy*dy + dz*dz) / 100.0f;
    if (distM > 400.0f) return NO;
    if (outX) *outX = b->cx + tx * b->k / tz;
    if (outY) *outY = b->cy - ty * b->k / tz;
    if (outDist) *outDist = distM;
    return YES;
}

BOOL ESPWorldToScreen(ESPVector world, ESPCamera cam, float screenW, float screenH, float *outX, float *outY, float *outDist) {
    ESPCamBasis basis;
    if (!ESPCamBasisBuild(&cam, screenW, screenH, &basis)) return NO;
    return ESPCamBasisProject(&basis, world, outX, outY, outDist);
}

int ESPEngineBoxes(uint64_t gameBase, float screenW, float screenH, ESPBox2D *outBoxes, int maxBoxes) {
    if (!outBoxes || maxBoxes <= 0) return 0;
#if !USE_DARKSWORD
    (void)gameBase; (void)screenW; (void)screenH;
    return 0;
#else
    if (!gameBase || !ds_is_ready()) return 0;
    if (screenW <= 0 || screenH <= 0) return 0;
    CFAbsoluteTime tBox0 = CFAbsoluteTimeGetCurrent(); // perf refresh
    uint64_t vmMap = ESPProcVMMap(NULL);
    if (!vmMap) { ESPBoxDiagSet("F noVmMap"); return 0; }
    CFAbsoluteTime tProc = CFAbsoluteTimeGetCurrent();
    ESPCamera cam;
    if (!ESPEngineCamera(gameBase, &cam)) { ESPBoxDiagSet("F camFail"); return 0; }
    if (!(cam.aspect > 0.3 && cam.aspect < 4.0)) cam.aspect = screenW / screenH;
    // Dựng basis 1 lần cho cả vòng actor (thay 2 lần trig/actor như trước).
    ESPCamBasis basis;
    if (!ESPCamBasisBuild(&cam, screenW, screenH, &basis)) {
        ESPBoxDiagSet("F badFov %.1f", cam.fov);
        return 0;
    }
    // Chỉ dùng world từ cache — KHÔNG scan đồng bộ ở đây: hàm này chạy trên
    // timer 4Hz của bridge; scan đầy đủ là việc của ESPEngineRequestScan (queue
    // nền, TTL riêng). Trước đây scan ở đây làm HUD tick kẹt cả giây.
    uint64_t world = g_espCache.world;
    if (!world) { ESPBoxDiagSet("F noWorld"); return 0; }
    BOOL ok = NO;
    uint64_t level = 0;
    uint64_t actorsData = 0;
    uint32_t actorsCount = 0;
    if (!ESPLevelAndActors(vmMap, world, &level, &actorsData, &actorsCount)) { ESPBoxDiagSet("F noActors"); return 0; }
    if (!actorsData || actorsCount == 0 || actorsCount > 20000) { ESPBoxDiagSet("F badActors"); return 0; }
    uint32_t scanN = actorsCount > ESP_MAX_ACTORS_SCAN ? ESP_MAX_ACTORS_SCAN : actorsCount;
    ESPVerdictResetIfWorldChanged(world);
    int myTeam = INT_MIN;
    uint64_t myPawn = 0;
    { int t = INT_MIN; uint64_t lp = 0; if (ESPMyTeamAndPawn(vmMap, world, &lp, &t)) { myTeam = t; myPawn = lp; } }
    uint32_t bulkN2 = scanN > 2048 ? 2048 : scanN;
    static uint64_t s_boxBuf[2048];
    BOOL haveBulk2 = ESPReadWindow(vmMap, actorsData, s_boxBuf, (uint64_t)bulkN2 * 8);
    int n = 0;
    // Buffer tái sử dụng (thread_local): hàm này chạy 1Hz trên bridge queue,
    // cấp phát vector mới mỗi lần là rác heap + page fault trong đường vẽ.
    static thread_local std::vector<ESPTrackedActor> foundTracked;
    foundTracked.clear();
    // Đếm rớt từng khâu để chẩn đoán B=0 mà P>0 (xem ESPEngineLastBoxDiag).
    uint32_t cEne = 0, cPos = 0, cW2s = 0, cSelf = 0, cH = 0;
    CFAbsoluteTime tCam = CFAbsoluteTimeGetCurrent();
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
        // Lấy luôn diag: root + StaticMeshComp của hình nhân đã có sẵn từ cửa
        // sổ 0xF00 mà ESPIsEnemy đã đọc -> khỏi đọc lại 2-3 lần/actor.
        ESPClassifyDiag dg;
        if (!ESPIsEnemy(vmMap, actor, myTeam, myPawn, &team, &hp, &dg)) continue;
        cEne++;
        uint64_t rootComp = ESPIsUserPtr(dg.root) ? dg.root : 0;
        if (foundTracked.size() < 64) {
            ESPTrackedActor tr;
            tr.actor = actor;
            tr.root = rootComp;
            tr.fallback = (team == ESPTeam_Dummy && ESPIsUserPtr(dg.tMesh)) ? dg.tMesh : 0;
            tr.parent = 0;
            if (tr.root) {
                BOOL okp = NO;
                uint64_t par = ESPReadU64(vmMap, tr.root + ESPOff_Scene_AttachedParent, &okp);
                if (okp && ESPIsUserPtr(par)) tr.parent = par;
            }
            tr.kind = (team == ESPTeam_Dummy) ? 3 : 1;
            foundTracked.push_back(tr);
        }
        // Vị trí world theo source Kernel: Root.Relative + Parent.Relative
        // ( ComponentToWorld 0x1D0 để dự phòng nếu Relative fail — xem offset.h )
        ESPVector pos = {0,0,0};
        BOOL gotPos = NO;
        {
            uint64_t root = rootComp;
            if (root) {
                ESPVector loc = {0,0,0};
                if (ESPMemoryRead(vmMap, root + ESPOff_Scene_RelativeLocation, &loc, sizeof(loc)) &&
                    fabsf(loc.x) < ESP_POS_BOUND && fabsf(loc.y) < ESP_POS_BOUND && fabsf(loc.z) < ESP_POS_BOUND &&
                    (loc.x != 0 || loc.y != 0 || loc.z != 0)) {
                    uint64_t parent = ESPReadU64(vmMap, root + ESPOff_Scene_AttachedParent, &ok);
                    if (ok && ESPIsUserPtr(parent)) {
                        ESPVector pl = {0,0,0};
                        if (ESPMemoryRead(vmMap, parent + ESPOff_Scene_RelativeLocation, &pl, sizeof(pl)) &&
                            fabsf(pl.x) < ESP_POS_BOUND && fabsf(pl.y) < ESP_POS_BOUND && fabsf(pl.z) < ESP_POS_BOUND) {
                            loc.x += pl.x; loc.y += pl.y; loc.z += pl.z;
                        }
                    }
                    pos = loc; gotPos = YES;
                }
            }
        }
        if (!gotPos) {
            // Hình nhân: target sân tập ở StaticMeshComp 0x4E8 (đã có trong diag)
            uint64_t comp = ESPIsUserPtr(dg.tMesh) ? dg.tMesh : 0;
            if (comp) {
                ESPVector v = {0,0,0};
                if (ESPMemoryRead(vmMap, comp + ESPOff_Comp_ComponentToWorld + ESPOff_Transform_Translation, &v, sizeof(v)) &&
                    fabsf(v.x) < ESP_POS_BOUND && fabsf(v.y) < ESP_POS_BOUND && fabsf(v.z) < ESP_POS_BOUND &&
                    (v.x != 0 || v.y != 0 || v.z != 0)) {
                    pos = v; gotPos = YES;
                }
            }
        }
        if (!gotPos) {
            ESPVector v = {0,0,0};
            if (ESPMemoryRead(vmMap, actor + ESPOff_Actor_ReplicatedMovement + ESPOff_RepMovement_Location, &v, sizeof(v))) {
                if (fabsf(v.x) < ESP_POS_BOUND && fabsf(v.y) < ESP_POS_BOUND && fabsf(v.z) < ESP_POS_BOUND && (v.x != 0 || v.y != 0 || v.z != 0)) {
                    pos = v; gotPos = YES;
                }
            }
        }
        if (!gotPos) { cPos++; continue; }
        float sx = 0, sy = 0, dist = 0;
        if (!ESPCamBasisProject(&basis, pos, &sx, &sy, &dist)) { cW2s++; continue; }
        if (dist < 2.0f) { cSelf++; continue; } // self
        ESPVector head = pos; head.z += 175.0f;
        float hx = 0, hy = 0, hd = 0;
        float topY = 0, bottomY = 0, boxH = 0, boxW = 0, centerX = sx;
        if (ESPCamBasisProject(&basis, head, &hx, &hy, &hd)) {
            topY = fminf(sy, hy);
            bottomY = fmaxf(sy, hy);
            boxH = bottomY - topY;
            centerX = (sx + hx) * 0.5f;
        } else {
            float tz = dist * 100.0f;
            if (tz < 10.0f) tz = 10.0f;
            boxH = (175.0f / tz) * basis.k;
            topY = sy - boxH;
            centerX = sx;
        }
        if (boxH < 8.0f) boxH = 8.0f;
        if (boxH > screenH * 2.0f) { cH++; continue; }
        boxW = boxH * 0.5f;
        if (centerX + boxW * 0.5f < -50.0f || centerX - boxW * 0.5f > screenW + 50.0f ||
            topY > screenH + 50.0f || topY + boxH < -50.0f) {
            cW2s++; continue;
        }
        outBoxes[n++] = (ESPBox2D){ centerX - boxW*0.5f, topY, boxW, boxH, dist, (int)hp, 1, actor };
    }
    ESPBoxDiagSet("F act=%u ene=%u pos=%u w2s=%u self=%u h=%u ok=%d",
                  (unsigned)scanN, (unsigned)cEne, (unsigned)cPos,
                  (unsigned)cW2s, (unsigned)cSelf, (unsigned)cH, n);
    ESPPerfSample((tProc - tBox0) * 1000.0, (tCam - tProc) * 1000.0,
                  (CFAbsoluteTimeGetCurrent() - tCam) * 1000.0);
    if (!foundTracked.empty()) {
        std::lock_guard<std::mutex> lk(g_espClassifyMutex);
        if (g_espTracked.empty()) {
            g_espTracked = foundTracked;
            g_espTrackGen++;
        }
    }
    return n;
#endif
}

// MARK: - Refresh nhanh giữa 2 lượt quét đầy đủ

// Đọc vị trí world của 1 tracked actor: root.Relative (+parent) trước, rồi
// ComponentToWorld của fallback (hình nhân), rồi ReplicatedMovement.
static BOOL ESPTrackedPos(uint64_t vmMap, const ESPTrackedActor *tr, ESPVector *out) {
    if (!tr || !out) return NO;
    // Lượt scan ăn VERDICT CACHE (`r=-3`, log `w=0`) không đọc cửa sổ actor nên
    // tracked có thể thiếu root/fallback -> trước đây refresh fail hết
    // (log thực tế: "REFRESH-ZERO: trk=4 hid=0 pos=4") và box tắt ngóm tới lượt
    // scan đầy đủ kế tiếp (~10s). Đọc bù 1 lần ở đây rẻ hơn nhiều so với mất box.
    uint64_t rootComp = tr->root;
    if (!rootComp || !ESPIsUserPtr(rootComp)) {
        BOOL okr = NO;
        uint64_t r = ESPReadU64(vmMap, tr->actor + ESPOff_Actor_RootComponent, &okr);
        rootComp = (okr && ESPIsUserPtr(r)) ? r : 0;
    }
    if (rootComp && ESPIsUserPtr(rootComp)) {
        ESPVector loc = {0,0,0};
        if (ESPMemoryRead(vmMap, rootComp + ESPOff_Scene_RelativeLocation, &loc, sizeof(loc)) &&
            fabsf(loc.x) < ESP_POS_BOUND && fabsf(loc.y) < ESP_POS_BOUND && fabsf(loc.z) < ESP_POS_BOUND &&
            (loc.x != 0 || loc.y != 0 || loc.z != 0)) {
            // Parent đã nhớ lúc scan: ==0 thì bỏ hẳn parent read (đa số root
            // character). !=0 thì đọc ploc từ cached ptr (parent hiếm khi đổi;
            // héo thì dùng tạm loc, scan sau sửa).
            if (tr->parent && ESPIsUserPtr(tr->parent)) {
                ESPVector pl = {0,0,0};
                if (ESPMemoryRead(vmMap, tr->parent + ESPOff_Scene_RelativeLocation, &pl, sizeof(pl)) &&
                    fabsf(pl.x) < ESP_POS_BOUND && fabsf(pl.y) < ESP_POS_BOUND && fabsf(pl.z) < ESP_POS_BOUND) {
                    loc.x += pl.x; loc.y += pl.y; loc.z += pl.z;
                }
            }
            *out = loc;
            return YES;
        }
    }
    // Hình nhân: StaticMeshComp có thể cũng chưa biết (scan ăn cache) -> đọc bù.
    // CHỈ thử cho kind 3: với character thường, offset 0x4E8 là field khác nên
    // có thể ra pointer rác (dù ESPIsUserPtr + bound vẫn chặn phần lớn).
    uint64_t fb = tr->fallback;
    if ((!fb || !ESPIsUserPtr(fb)) && tr->kind == 3) {
        BOOL okf = NO;
        uint64_t m = ESPReadU64(vmMap, tr->actor + ESPOff_Target_Mesh, &okf);
        fb = (okf && ESPIsUserPtr(m)) ? m : 0;
    }
    if (fb && ESPIsUserPtr(fb)) {
        ESPVector v = {0,0,0};
        if (ESPMemoryRead(vmMap, fb + ESPOff_Comp_ComponentToWorld + ESPOff_Transform_Translation, &v, sizeof(v)) &&
            fabsf(v.x) < ESP_POS_BOUND && fabsf(v.y) < ESP_POS_BOUND && fabsf(v.z) < ESP_POS_BOUND &&
            (v.x != 0 || v.y != 0 || v.z != 0)) {
            *out = v;
            return YES;
        }
    }
    return NO;
}

// --- Snapshot + NGOẠI SUY vị trí (kiểu aovcheat: đọc thưa, project dày) ---
// Refresh chạy ESP_REFRESH_HZ (60) nhưng chỉ ĐỌC KERNEL vị trí mỗi actor
// ESP_POS_READ_HZ (15) lần/giây; giữa 2 lần đọc thì ngoại suy từ vận tốc (delta
// 2 mẫu gần nhất). Trước đây mỗi frame đều đọc kernel -> box nhảy theo nhịp đọc
// (giật) và timer 60Hz bị trễ theo. Hash theo actor (actor cấp phát theo 0x1000
// nên shift 4 là tản đủ); va chạm chỉ làm miss 1 frame, không sai.
#define ESP_POS_HIST 96
// Vận tốc tối đa dùng cho ngoại suy: 60 m/s (xe/airdrop PUBG ~150km/h = 41m/s).
// Mẫu vượt mức này là rác (read torn / actor vừa respawn) — kẹp lại.
#define ESP_MAX_VEL 6000.0f    // cm/s
// Bước nhảy tối đa giữa 2 mẫu liên tiếp trước khi coi là mẫu rác: 20 m.
// (Ở nhịp đọc 15Hz thì 20m = 300m/s — không có gì trong game nhảy vậy.)
#define ESP_MAX_JUMP 2000.0f   // cm

typedef struct {
    uint64_t actor;
    ESPVector pos;
    ESPVector vel;   // cm/giây
    CFAbsoluteTime at;
    int outliers;    // số mẫu bất thường liên tiếp (để tự hồi phục)
    BOOL valid;
} ESPPosHist;
static ESPPosHist s_posHist[ESP_POS_HIST];

static ESPPosHist *ESPPosHistSlot(uint64_t actor) {
    ESPPosHist *h = &s_posHist[(size_t)((actor >> 4) % ESP_POS_HIST)];
    if (h->valid && h->actor == actor) return h;
    // Slot của actor khác: coi như chưa có mẫu (lần này sẽ đọc thật).
    h->actor = actor;
    h->valid = NO;
    h->outliers = 0;
    h->pos = (ESPVector){0, 0, 0};
    h->vel = (ESPVector){0, 0, 0};
    h->at = 0;
    return h;
}

int ESPEngineRefreshBoxes(uint64_t gameBase, float screenW, float screenH, ESPBox2D *outBoxes, int maxBoxes,
                         uint64_t *outGen) {
    if (outGen) *outGen = 0;
    if (!outBoxes || maxBoxes <= 0) return 0;
#if !USE_DARKSWORD
    (void)gameBase; (void)screenW; (void)screenH;
    return 0;
#else
    if (!gameBase || !ds_is_ready()) return 0;
    if (screenW <= 0 || screenH <= 0) return 0;
    // Copy tracked + gen DƯỚI CÙNG 1 lock để bridge biết mẫu này thuộc thế hệ nào.
    // thread_local: refresh chạy 60Hz nên giữ capacity, không cấp phát mỗi frame.
    static thread_local std::vector<ESPTrackedActor> tracked;
    {
        std::lock_guard<std::mutex> lk(g_espClassifyMutex);
        tracked = g_espTracked;
        if (outGen) *outGen = g_espTrackGen;
    }
    if (tracked.empty()) { ESPBoxDiagSet("R empty"); return 0; }
    CFAbsoluteTime tBox0 = CFAbsoluteTimeGetCurrent(); // perf refresh
    uint64_t vmMap = ESPProcVMMap(NULL);
    if (!vmMap) { ESPBoxDiagSet("R noVmMap"); return 0; }
    CFAbsoluteTime tProc = CFAbsoluteTimeGetCurrent();
    ESPCamera cam;
    if (!ESPEngineCamera(gameBase, &cam)) { ESPBoxDiagSet("R camFail"); return 0; }
    if (!(cam.aspect > 0.3 && cam.aspect < 4.0)) cam.aspect = screenW / screenH;
    // Dựng basis view-projection 1 lần cho cả danh sách tracked (không trig/actor).
    ESPCamBasis basis;
    if (!ESPCamBasisBuild(&cam, screenW, screenH, &basis)) {
        ESPBoxDiagSet("R badFov %.1f", cam.fov);
        return 0;
    }
    CFAbsoluteTime tCam = CFAbsoluteTimeGetCurrent();
    for (int i = 0; i < maxBoxes; i++) {
        outBoxes[i] = (ESPBox2D){0, 0, 0, 0, 0, -1, 0, 0};
    }

    int n = 0;
    uint32_t cHid = 0, cPos = 0, cW2s = 0, cSelf = 0, cH = 0;
    // Có task port thì đọc vị trí mỗi frame (một syscall, ~µs) — box bám sát,
    // không cần ngoại suy. Chưa có port thì vẫn đọc thưa + ngoại suy như cũ
    // (đường kernel ~ms/lần đọc cho mỗi actor).
    const double kPosReadInterval = (ESPGameTaskPort() != MACH_PORT_NULL)
                                        ? 0.0
                                        : 1.0 / (double)ESP_POS_READ_HZ;
    for (size_t i = 0; i < tracked.size() && n < maxBoxes; i++) {
        const ESPTrackedActor *tr = &tracked[i];
        CFAbsoluteTime nowF = CFAbsoluteTimeGetCurrent();
        ESPPosHist *h = ESPPosHistSlot(tr->actor);
        ESPVector pos = {0,0,0};
        if (h->valid && nowF - h->at < kPosReadInterval) {
            // Còn trong cửa sổ ngoại suy: KHÔNG chạm kernel, chỉ cộng vận tốc.
            // Chặn dt để một frame trễ (timer dồn) không đẩy box vọt xa.
            float dt = (float)(nowF - h->at);
            if (dt > 0.25f) dt = 0.25f;
            pos.x = h->pos.x + h->vel.x * dt;
            pos.y = h->pos.y + h->vel.y * dt;
            pos.z = h->pos.z + h->vel.z * dt;
        } else {
            // Đến hạn đọc: đọc cả cờ ẩn/chết ở đây (thay vì đọc mỗi frame).
            // bHidden ở 0xE8, bDead ở 0xE7C — cách xa nên không gộp 1 lần đọc;
            // đọc bHidden trước, ẩn/chết thì khỏi đọc bDead.
            uint8_t flags[2] = {0, 0};
            if (ESPMemoryRead(vmMap, tr->actor + ESPOff_Actor_HiddenFlag, flags, 1)) {
                if (flags[0] & 0x1) { cHid++; h->valid = NO; continue; }
                if (ESPMemoryRead(vmMap, tr->actor + ESPOff_Char_Dead, flags + 1, 1)) {
                    if (flags[1] & 0x1) { cHid++; h->valid = NO; continue; }
                }
            }
            ESPVector fresh = {0,0,0};
            if (!ESPTrackedPos(vmMap, tr, &fresh)) { cPos++; h->valid = NO; continue; }
            // Vận tốc = delta 2 mẫu gần nhất, nhưng phải KIỂM TRA HỢP LÝ trước
            // khi dùng: 1 mẫu rác (read torn giữa 2 frame game / actor respawn /
            // mapping héo) nhân với dt sẽ bắn box khỏi màn hình -> W2S fail hết.
            // Log thực tế bản smooth3: "REFRESH-ZERO: trk=4 pos=0 w2s=4" xen kẽ
            // BOX-JUMP dx/dy ±100px đúng kiểu vận tốc rác.
            BOOL sampleReject = NO;
            if (h->valid && h->at > 0) {
                double ddt = nowF - h->at;
                float dx = fresh.x - h->pos.x, dy = fresh.y - h->pos.y, dz = fresh.z - h->pos.z;
                float jump = sqrtf(dx*dx + dy*dy + dz*dz);
                if (ddt > 0.001 && ddt < 1.0 && jump <= ESP_MAX_JUMP) {
                    ESPVector v = { dx / (float)ddt, dy / (float)ddt, dz / (float)ddt };
                    float sp = sqrtf(v.x*v.x + v.y*v.y + v.z*v.z);
                    if (sp > ESP_MAX_VEL) {
                        float s = ESP_MAX_VEL / sp;
                        v.x *= s; v.y *= s; v.z *= s;
                    }
                    h->vel = v;
                    h->outliers = 0;
                } else {
                    // Mẫu bất thường: không ngoại suy. Nếu đúng là nhảy thật
                    // (respawn/teleport) thì 2 mẫu liên tiếp sẽ được chấp nhận
                    // (tránh box "đóng băng" ở vị trí cũ mãi).
                    h->vel = (ESPVector){0, 0, 0};
                    if (jump > ESP_MAX_JUMP && ++h->outliers < 2) {
                        sampleReject = YES;
                    } else {
                        h->outliers = 0;
                    }
                }
            } else {
                h->vel = (ESPVector){0, 0, 0};
                h->outliers = 0;
            }
            h->at = nowF;
            h->valid = YES;
            if (sampleReject) {
                pos = h->pos;      // giữ vị trí cũ cho frame này
            } else {
                h->pos = fresh;    // mẫu hợp lệ -> theo vị trí mới
                pos = fresh;
            }
        }
        float sx = 0, sy = 0, dist = 0;
        if (!ESPCamBasisProject(&basis, pos, &sx, &sy, &dist)) { cW2s++; continue; }
        if (dist < 2.0f) { cSelf++; continue; }
        ESPVector head = pos; head.z += 175.0f;
        float hx = 0, hy = 0, hd = 0;
        float topY = 0, bottomY = 0, boxH = 0, boxW = 0, centerX = sx;
        if (ESPCamBasisProject(&basis, head, &hx, &hy, &hd)) {
            topY = fminf(sy, hy);
            bottomY = fmaxf(sy, hy);
            boxH = bottomY - topY;
            centerX = (sx + hx) * 0.5f;
        } else {
            float tz = dist * 100.0f;
            if (tz < 10.0f) tz = 10.0f;
            boxH = (175.0f / tz) * basis.k;
            topY = sy - boxH;
            centerX = sx;
        }
        if (boxH < 8.0f) boxH = 8.0f;
        if (boxH > screenH * 2.0f) { cH++; continue; }
        boxW = boxH * 0.5f;
        if (centerX + boxW * 0.5f < -50.0f || centerX - boxW * 0.5f > screenW + 50.0f ||
            topY > screenH + 50.0f || topY + boxH < -50.0f) {
            cW2s++; continue;
        }
        outBoxes[n++] = (ESPBox2D){ centerX - boxW*0.5f, topY, boxW, boxH, dist, -1, 1, tr->actor };
    }
    ESPBoxDiagSet("R trk=%zu hid=%u pos=%u w2s=%u self=%u h=%u ok=%d",
                  tracked.size(), (unsigned)cHid, (unsigned)cPos,
                  (unsigned)cW2s, (unsigned)cSelf, (unsigned)cH, n);
    if (tracked.size() > 0 && n == 0) {
        static CFAbsoluteTime s_lastZeroRefreshLog = 0;
        CFAbsoluteTime nowLog = CFAbsoluteTimeGetCurrent();
        if (nowLog - s_lastZeroRefreshLog >= 2.0) {
            s_lastZeroRefreshLog = nowLog;
            // CHỈ xả cache khi ĐỌC VỊ TRÍ THẤT BẠI (pos>0) — lúc đó mới nghi
            // mapping héo/hết memory entry.
            //
            // KHÔNG xả khi chỉ w2s>0 (project bị từ chối): w2s là lỗi TOÁN, không
            // phải lỗi đọc. Bản smooth3 xả ở đây nên cứ ~2s lại quét sạch 130+
            // page của actor, lượt quét đầy đủ sau đó phải map lại từ đầu -> 5.0s
            // (log smooth3: `win=132/6 dt=5.0s`), và ĐÓ chính là độ trễ 5-6s để
            // địch mới hiện box.
            // IfIdle: không chờ mutex đọc (scan nền có thể đang map page) — flush
            // blocking từng làm tick vẽ treo (log: box perf max=1425ms).
            BOOL didFlush = NO;
            if (cPos > 0) didFlush = ESPMemoryFlushPageCacheIfIdle();
            ESPLog("REFRESH-ZERO: trk=%zu hid=%u pos=%u w2s=%u self=%u h=%u (flush=%d)",
                   tracked.size(), cHid, cPos, cW2s, cSelf, cH, didFlush ? 1 : 0);
        }
    }
    ESPPerfSample((tProc - tBox0) * 1000.0, (tCam - tProc) * 1000.0,
                  (CFAbsoluteTimeGetCurrent() - tCam) * 1000.0);
    return n;
#endif
}

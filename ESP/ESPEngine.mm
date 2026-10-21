//
//  ESPEngine.mm
//  Phase 1: tìm UWorld qua GUObject enumeration, vào Actors, đếm.
//  Không crash nếu offsets sai — mọi read đều check BOOL.
//

#import "ESPEngine.h"
#import "ESPOffsets.h"
#import "ESPMemory.h"
#import "ESPProvider.h"
#import "ESPTask.h"
#import "ESPConfig.h"
#import "ESPName.h"
#import "ESPLog.h"
#include "ESPBoneMap.h" // tự dò bảng index 17 khớp từ ref pose (không cần GNames)
#import <mach/mach.h>
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
#include <ctype.h>
#include <vector>

extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}
// vmmapremotepage khai tay (vm.h kéo RemoteCall.h @import, không compile được
// ở file này) — layout đồng nhất với struct vmshmem như ESPMemory.mm.
struct ESPVmShmem {
    uint64_t port;
    uint64_t remoteAddress;
    uint64_t localAddress;
    bool used;
};
extern "C" struct ESPVmShmem vmmapremotepage(uint64_t vmMap, uint64_t address);
extern "C" kern_return_t mach_vm_deallocate(task_t task, mach_vm_address_t addr, mach_vm_size_t size);
// Ép DSBridge quét lại base ngay (bypass TTL 30s), dùng khi engine phát hiện
// base stale (pid đổi / world fail liên tiếp mà pid/base không đổi).
extern void DSBridgeRefreshGameBase(void);

// Chain nhanh GEngine->Viewport->World (không scan 200k objects).

static BOOL ESPIsUserPtr(uint64_t p);
static uint8_t ESPReadU8(uint64_t vmMap, uint64_t addr, BOOL *ok);
static void ESPBonesReset(void); // qblpack: xoá cấu hình xương khi đổi world
static BOOL ESPBonesConfigure(uint64_t vmMap, uint64_t mesh, uint64_t gameBase,
                              BOOL allowNameScan); // qblpack: dò bảng xương (định nghĩa cuối file)
// qblpack: cờ xương dùng ngay trong vòng quét (dòng ~1181) — khai báo trước vì
// định nghĩa static ở cuối file (build kernrw58: undeclared identifier).
static std::atomic_bool g_espBonesWant{false};
static std::atomic_bool g_espBonesReady{false};   // đã dò được offset + bảng index

// --- Cửa sổ actor: 1 lần map page lấy HẾT field (trước đây ~8 lần map page) ---
// 0x0 VTable, 0x18 FName, 0xE8 bHidden, 0x208 RootComponent,
// 0x4AC/0x4D0/0x4D4/0x4E8 hình nhân, 0x510 Mesh, 0x998 TeamID,
// 0xE60/0xE64 Health/HealthMax, 0xE7C bDead — tất cả nằm trong 0xF00 byte đầu.
// Mỗi lần đọc 1 field = 1 vòng allocate + make_memory_entry + map + dealloc
// (+1 port) trong kernel. Quét vài trăm actor x ~8 field là hàng nghìn vòng
// -> app bị Jetsam kill giữa lúc quét (scan đứng ~50%). Đọc 1 cửa sổ 0xF00
// byte chỉ còn 1-2 vòng cho mỗi actor.
//
// Cửa sổ này đi qua REGION MAP của ESPMemory (không phải ESPReadWindow map-rồi-
// nhả từng lần): 0xF00 < 1 page nên nó nằm gọn trong page đầu của actor, và cả
// VÙNG chứa page đó được map 1 lần rồi giữ vĩnh viễn. Log thực tế trước đây:
// quét đầy đủ mất ~10s (132 actor x 1 vòng map+refcount+dealloc); sau khi dùng
// region map thì các lượt quét sau chỉ còn memcpy — quét đầy đủ không còn là cú
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
    uint8_t ai; // qblpack: 1 = tên khớp ESPNameIsAIPawn (chỉ đường phân loại theo tên)
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
    int ai; // qblpack: 1 = bot/AI (tên class khớp list AI)
    unsigned tIsUp;
    float hp, hpMax, tCur, tMax;
    uint64_t vt, mesh, tMesh, root;
    uint32_t nameID;
} ESPClassifyDiag;

// Mesh để đọc chiều cao box: theo kind, fallback đọc 0x510 (cache-hit verdict
// không có diag.mesh -> 1 read/actor/scan là chấp nhận được).
static uint64_t ESPBoxMesh(uint64_t vmMap, uint64_t actor, const ESPClassifyDiag *dg, int team) {
    if (dg) {
        uint64_t m = (team == ESPTeam_Dummy) ? dg->tMesh : dg->mesh;
        if (ESPIsUserPtr(m)) return m;
        uint64_t alt = (team == ESPTeam_Dummy) ? dg->mesh : dg->tMesh;
        if (ESPIsUserPtr(alt)) return alt;
    }
    BOOL okm = NO;
    uint64_t m = ESPReadU64(vmMap, actor + ESPOff_Char_Mesh, &okm);
    return (okm && ESPIsUserPtr(m)) ? m : 0;
}

// Chiều cao box: Mesh.Bounds.BoxExtent.Z * 2 (nguồn Kernel, 30..200cm),
// không đọc được thì mặc định ESP_CHAR_HEIGHT_CM.
static float ESPActorBoxHeight(uint64_t vmMap, uint64_t mesh) {
    if (ESPIsUserPtr(mesh)) {
        float extZ = 0;
        if (ESPMemoryRead(vmMap, mesh + ESPOff_Mesh_BoxExtentZ, &extZ, sizeof(extZ)) &&
            extZ > 30.0f && extZ < 200.0f) {
            return extZ * 2.0f;
        }
    }
    return ESP_CHAR_HEIGHT_CM;
}

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

// HP percent 0-100 cho thanh máu kiểu Source Kernel (-1 nếu chưa đọc được).
// kind 3 (hình nhân): máu ở Target_Cur/MaxHealth; còn lại Char_Health/Max.
// Validate max như classify (50..2000) để không vẽ bar từ số rác.
static float s_hpDbgCur = 0, s_hpDbgMax = 0;
static int s_hpDbgPct = -1;
static int s_hpDbgFails = 0;
void ESPEngineHPSample(float *cur, float *max, int *pct, int *fails) {
    if (cur) *cur = s_hpDbgCur;
    if (max) *max = s_hpDbgMax;
    if (pct) *pct = s_hpDbgPct;
    if (fails) *fails = s_hpDbgFails;
}
static int ESPHPPercent(uint64_t vmMap, uint64_t actor, int kind) {
    if (!vmMap || !actor) return -1;
    float cur = 0, max = 0;
    if (kind == 3) {
        if (!ESPReadF32(vmMap, actor + ESPOff_Target_CurHealth, &cur)) { s_hpDbgFails++; return -1; }
        if (!ESPReadF32(vmMap, actor + ESPOff_Target_MaxHealth, &max)) { s_hpDbgFails++; return -1; }
    } else {
        uint8_t hb[8] = {0, 0, 0, 0, 0, 0, 0, 0};
        if (!ESPMemoryRead(vmMap, actor + ESPOff_Char_Health, hb, sizeof(hb))) { s_hpDbgFails++; return -1; }
        memcpy(&cur, hb, 4);
        memcpy(&max, hb + 4, 4);
    }
    s_hpDbgCur = cur; s_hpDbgMax = max;
    if (!(max >= 50.0f && max <= 2000.0f) || !(cur >= 0.0f) || !(cur <= max + 50.0f)) {
        s_hpDbgPct = -1; s_hpDbgFails++;
        return -1;
    }
    int pct = (int)(cur * 100.0f / max + 0.5f);
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    s_hpDbgPct = pct; s_hpDbgFails = 0;
    return pct;
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
    BOOL okhp = ESPReadF32(vmMap, actor + ESPOff_Char_Health, &f->hp);
    BOOL okhpMax = ESPReadF32(vmMap, actor + ESPOff_Char_HealthMax, &f->hpMax);
    f->hasHp = (okhp && okhpMax);
    f->tMesh = ESPReadU64(vmMap, actor + ESPOff_Target_Mesh, &ok);
    if (ok && ESPReadF32(vmMap, actor + ESPOff_Target_MaxHealth, &f->tMax) &&
        ESPReadF32(vmMap, actor + ESPOff_Target_CurHealth, &f->tCur)) {
        f->tIsUp = ESPReadU8(vmMap, actor + ESPOff_Target_IsUp, &ok);
        f->hasTarget = ok;
    }
}


static int g_espStep = 0; // debug: kẹt ở đâu (xem StatusText E#)
// Engine hợp lệ nhưng field null = game đang load: chờ, không ép rescan.
static BOOL g_espWaitingLoad = NO;
// g_espPasses/g_espVerboseLeft đọc từ cả scan queue, bridge queue lẫn main
// thread nên dùng atomic (ghi chính vẫn dưới g_espClassifyMutex).
static std::atomic_int g_espPasses{0}; // số lượt quét xong từ khi đổi world (đủ 3 lượt mới full)
static std::atomic_int g_espProgress{-1}; // index đang lọc (để hiện %)
static std::atomic_int g_espProgressTotal{0};
static int g_espLastFastPawns = 0; // số pawn đọc được từ PlayerArray (fast path)
// Mutex cho verdict maps + VTable + frame + tracked list: ESPEngineScan chạy
// trên queue nền trong khi ESPEngineBoxes/RefreshBoxes chạy trên timer bridge
// (1Hz). Trước đây 2 luồng đọc/ghi unordered_map + vector cùng lúc (UB):
// scan vừa clear/push tracked + set verdict, box path vừa iterate/read —
// kết quả là box path ra 0 (hoặc crash ngầm) dù scan đếm đúng players.
static std::recursive_mutex g_espClassifyMutex;
static uint64_t g_espVMProc = 0; // cache proc/vmMap cho box refresh 8Hz
static uint64_t g_espVMMap = 0;
static pid_t g_espVMPid = 0; // pid validate kèm cache (chống proc stale/UAF)
static CFAbsoluteTime g_espVMAt = 0;
static uint64_t g_espUName = 0; // GNames đã giải mã cho base hiện tại
static uint64_t g_espPlayerVTable = 0; // VTable class player đã học (primary)
static std::unordered_set<uint64_t> g_espPlayerVTables; // Mọi VTable player/bot đã biết
// VTable rác đã biết (lựu đạn, đạn, loot, xe, hiệu ứng...): gặp lại thì verdict
// 2 ngay bằng 1 lần đọc, khỏi FName walk qua GNames. Học từ mọi verdict-2.
// Đây là đường nhanh khiến 91 unknown chỉ còn vài FName walk mỗi vòng (Kernel
// làm tương tự với PlayerVTable/GrenadeVTable). Xả theo world như player set.
static std::unordered_set<uint64_t> g_espJunkVTables;
// qblpack AIMarkDifferent: VTable của bot/AI đã học (bot dùng chung 1 class nên
// gặp VTable này ở bất kỳ actor nào là biết AI, khỏi đọc tên lại — cùng cách
// g_espPlayerVTables). Xả theo world.
static std::unordered_set<uint64_t> g_espAIVTables;
static int s_unameTries = 0; // Số lần thử giải mã GNames per game base
// kernrw44: mutex RIÊNG cho cache camera (s_cam*). Trước đây các cache này
// nằm dưới g_espClassifyMutex — mutex CŨNG do scan nền giữ suốt từng lần phân
// loại actor (vài chục ms mỗi lần, xem ESPIsEnemy + usleep nhường mutex ở scan)
// -> tick refresh phải CHỜ sau lưng scan dù chỉ đọc vài memcpy:
// log kernrw43: cam=8.7ms trong avg=8.7ms của refresh, trong khi vòng actors
// (cùng đường ESPMemoryRead, không lock) = 0.0ms, và max=716.8ms = 1 tick bị
// chặn gần 1 giây -> box đứng hình. Tách riêng: camera chỉ còn chờ nhau.
static std::recursive_mutex g_espCamMutex;
static uint64_t s_camPC = 0;
static uint64_t s_camWorld = 0;
static uint64_t s_camMgr = 0;
// Hysteresis chống chain rách lẻ: PC/mgr mới chỉ nhận sau 2 tick liên tiếp
// giống nhau (xem ESPResolvePCCached). Tick lẻ giữ cache cũ.
static uint64_t s_camPCPending = 0;
static int s_camPCPendingN = 0;
static uint64_t s_camMgrPending = 0;
static int s_camMgrPendingN = 0;

static void ESPCamPCClearLocked(void) {
    s_camPC = 0;
    s_camWorld = 0;
    s_camMgr = 0;
    s_camPCPending = 0;
    s_camPCPendingN = 0;
    s_camMgrPending = 0;
    s_camMgrPendingN = 0;
}
static void ESPCamPCClear(void) {
    std::lock_guard<std::recursive_mutex> lk(g_espCamMutex);
    ESPCamPCClearLocked();
}
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
// kernrw44: ẢNH CHÉP tracked cho đường refresh (leaf lock).
// Mọi writer sửa g_espTracked DƯỚI g_espClassifyMutex (scan/discover/verdict)
// rồi GỌI ESPTrackedSnapPublishLocked() — copy 1 vector <=64 phần tử = ~µs.
// Đọc (refresh 40Hz) chỉ lấy snapshot dưới g_espSnapMutex -> KHÔNG BAO GIỜ
// chờ scan nền, trừ lúc copy snapshot đang chạy (micro giây).
// Thứ tự lock: classify -> snap; reader chỉ giữ snap -> không có vòng.
static std::recursive_mutex g_espSnapMutex;
static std::vector<ESPTrackedActor> g_espTrackedSnap;
static uint64_t g_espTrackGenSnap = 0;
// Gọi KHI ĐANG giữ g_espClassifyMutex (writer đã sửa g_espTracked/g_espTrackGen).
static void ESPTrackedSnapPublishLocked(void) {
    std::lock_guard<std::recursive_mutex> lk(g_espSnapMutex);
    g_espTrackedSnap = g_espTracked;
    g_espTrackGenSnap = g_espTrackGen;
}
uint64_t ESPEngineTrackedGen(void) {
    std::lock_guard<std::recursive_mutex> lk(g_espSnapMutex);
    return g_espTrackGenSnap;
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
    std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
    if (g_espVerdictWorld != world) {
        g_espVerdict.clear();
        g_espTeamCache.clear();
        g_espVerdictFrame.clear();
        g_espVerdictVt.clear();
        g_espVerdictWorld = world;
        g_espPlayerVTable = 0; // học lại VTable cho world mới
        g_espPlayerVTables.clear();
        g_espJunkVTables.clear(); // world mới => học lại rác từ đầu
        g_espAIVTables.clear();   // qblpack: học lại VTable bot
        ESPBonesReset();          // qblpack: rig/offset xương có thể đổi theo world
        g_espPasses = 0;
        g_espVerboseLeft = 2; // log chi tiết 2 lượt đầu của world mới
        g_espTracked.clear(); // world mới => tracked cũ sai hết, xả luôn
        g_espTrackGen++; // mẫu refresh cũ hết hiệu lực nội suy
        ESPTrackedSnapPublishLocked();
        ESPGameTaskReset(); // world mới => task port cũ héo, resolve lại
        ESPProviderShutdown(); // world mới => trạng thái provider mới
        g_espVMProc = 0; // match mới có thể task mới => resolve lại proc/vmMap
        g_espVMMap = 0;
        g_espVMPid = 0;
        g_espVMAt = 0;
        // KHÔNG reset s_unameTries theo world: base không đổi thì kết quả resolve
        // cũng không đổi, reset ở đây làm ESPResolveUName (kèm diag nặng) chạy lại
        // MỖI lượt quét -> scan chậm, box lên trễ. Reset chỉ khi game base đổi
        // (đã xử lý trong ESPEngineScan).
        ESPCamPCClear();
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
    if (!ok || !ESPIsUserPtr(pawn)) {
        pawn = ESPReadU64(vmMap, pc + 0x528, &ok); // Fallback: AcknowledgedPawn
    }
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

// --- Fast player list (PlayerArray) ---------------------------------------
// Đọc thẳng danh sách người chơi/bot mà game đang giữ, thay vì duyệt 8000
// actor. Mọi bước đều check BOOL; offset sai -> trả 0 -> caller quay về quét
// actor array như cũ (không bao giờ làm mất box vì fast path hỏng).
typedef struct {
    uint64_t pawn;
    uint8_t isBot;
} ESPPlayerPawn;

static int ESPReadPlayerPawns(uint64_t vmMap, uint64_t world, ESPPlayerPawn *out, int cap) {
    if (!vmMap || !world || !out || cap <= 0) return 0;
    BOOL ok = NO;
    uint64_t gs = ESPReadU64(vmMap, world + ESPOff_UWorld_GameState, &ok);
    // Fallback: mode listen/training có thể để UWorld.GameState null nhưng
    // AuthorityGameMode->GameState vẫn hợp lệ. Client thuần thì path này null
    // và ta quay về actor array như cũ.
    if (!ok || !ESPIsUserPtr(gs)) {
        BOOL okgm = NO;
        uint64_t gm = ESPReadU64(vmMap, world + ESPOff_UWorld_AuthorityGameMode, &okgm);
        if (okgm && ESPIsUserPtr(gm)) {
            BOOL okgs = NO;
            uint64_t gs2 = ESPReadU64(vmMap, gm + ESPOff_GameMode_GameState, &okgs);
            if (okgs && ESPIsUserPtr(gs2)) { gs = gs2; ok = YES; }
        }
    }
    if (!ok || !ESPIsUserPtr(gs)) return 0;
    uint64_t data = ESPReadU64(vmMap, gs + ESPOff_GameState_PlayerArray, &ok);
    if (!ok || !ESPIsUserPtr(data)) return 0;
    uint32_t count = ESPReadU32(vmMap, gs + ESPOff_GameState_PlayerArray + 8, &ok);
    if (!ok || count == 0) return 0;
    if (count > 256) count = 256; // sanity: 100 player + spectator, chặn rác
    // Đọc cả mảng con trỏ 1 lần (vùng liền nhau) thay vì 256 read 8 byte.
    // Fail (mảng băng qua page chưa map) thì fallback từng pointer như cũ.
    uint64_t psArr[256];
    BOOL bulk = ESPMemoryRead(vmMap, data, psArr, (size_t)count * sizeof(uint64_t));
    int n = 0;
    for (uint32_t i = 0; i < count && n < cap; i++) {
        BOOL okp = bulk ? YES : NO;
        uint64_t ps = bulk ? psArr[i] : ESPReadU64(vmMap, data + (uint64_t)i * 8, &okp);
        if (!okp || !ESPIsUserPtr(ps)) continue;
        uint64_t pawn = ESPReadU64(vmMap, ps + ESPOff_PlayerState_PawnPrivate, &okp);
        if (!okp || !ESPIsUserPtr(pawn)) continue;
        BOOL dup = NO;
        for (int k = 0; k < n; k++) {
            if (out[k].pawn == pawn) { dup = YES; break; }
        }
        if (dup) continue;
        out[n].pawn = pawn;
        out[n].isBot = 0;
        BOOL okb = NO;
        uint8_t bot = ESPReadU8(vmMap, ps + ESPOff_PlayerState_IsABot, &okb);
        // 0x4DC là byte bitfield: bit0 bIsSpectator, bit1 bOnlySpectator,
        // bit2 bIsABot (SDK xếp cùng offset). Check đúng bit 2.
        if (okb && (bot & 0x4)) out[n].isBot = 1;
        n++;
    }
    return n;
}

// Chẩn đoán 1 lần/world: vì sao PlayerArray trả 0. Log đủ chuỗi để lần test
// sau biết chết ở GameState, PlayerArray hay PawnPrivate — không đoán mò.
static void ESPPlayerArrayProbe(uint64_t vmMap, uint64_t world) {
    if (!vmMap || !world) return;
    static uint64_t s_probeWorld = 0;
    if (world == s_probeWorld) return;
    s_probeWorld = world;
    BOOL ok = NO;
    uint64_t gs = ESPReadU64(vmMap, world + ESPOff_UWorld_GameState, &ok);
    BOOL gsOk = ok;
    uint64_t gm = ESPReadU64(vmMap, world + ESPOff_UWorld_AuthorityGameMode, &ok);
    BOOL gmOk = ok;
    uint64_t gs2 = 0;
    BOOL gs2Ok = NO;
    if (gmOk && ESPIsUserPtr(gm)) {
        gs2 = ESPReadU64(vmMap, gm + ESPOff_GameMode_GameState, &gs2Ok);
        if (!gs2Ok) gs2 = 0;
    }
    ESPLog("fast diag: world=0x%llx gs=0x%llx(ok=%d) gm=0x%llx(ok=%d) gs2=0x%llx(ok=%d)",
           (unsigned long long)world, (unsigned long long)gs, gsOk,
           (unsigned long long)gm, gmOk, (unsigned long long)gs2, gs2Ok);
    uint64_t gsCand[2] = { gs, gs2 };
    for (int ci = 0; ci < 2; ci++) {
        uint64_t g = gsCand[ci];
        if (!ESPIsUserPtr(g)) continue;
        BOOL dataOk = NO;
        uint64_t data = ESPReadU64(vmMap, g + ESPOff_GameState_PlayerArray, &dataOk);
        uint32_t count = 0, maxc = 0;
        if (dataOk) {
            count = ESPReadU32(vmMap, g + ESPOff_GameState_PlayerArray + 8, &ok);
            maxc = ESPReadU32(vmMap, g + ESPOff_GameState_PlayerArray + 12, &ok);
        }
        uint64_t ps0 = 0, pawn0 = 0;
        BOOL psOk = NO, pawnOk = NO;
        uint8_t bot = 0;
        if (dataOk && ESPIsUserPtr(data) && count > 0) {
            ps0 = ESPReadU64(vmMap, data, &psOk);
            if (psOk && ESPIsUserPtr(ps0)) {
                pawn0 = ESPReadU64(vmMap, ps0 + ESPOff_PlayerState_PawnPrivate, &pawnOk);
                bot = ESPReadU8(vmMap, ps0 + ESPOff_PlayerState_IsABot, &ok);
            }
        }
        ESPLog("fast diag[%d]: gs=0x%llx data=0x%llx(ok=%d) count=%u max=%u "
               "ps0=0x%llx(ok=%d) pawn0=0x%llx(ok=%d) bot=0x%02x",
               ci, (unsigned long long)g, (unsigned long long)data, dataOk,
               (unsigned)count, (unsigned)maxc, (unsigned long long)ps0, psOk,
               (unsigned long long)pawn0, pawnOk, (unsigned)bot);
    }
}

// Lọc enemy thật theo source Kernel: Mesh + Health/Max + TeamID, rồi bHidden/bDead/team.
// verdict 1=character, 3=target huấn luyện, 2=other.
// verdict 2 hết hạn sau kESPverdictExpiryFrames scans để đánh giá lại.
static BOOL ESPIsEnemy(uint64_t vmMap, uint64_t actor, int myTeam, uint64_t myPawn, int *outTeam, float *outHp,
                       ESPClassifyDiag *diag) {
    // Giữ mutex suốt lần phân loại: map verdict/team/frame + VTable được đọc
    // và ghi từ cả scan queue lẫn timer bridge. Mỗi lần giữ chỉ ~vài lần đọc
    // kernel của 1 actor nên contention không đáng kể.
    std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
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
        if (f.hasVtable && f.vtable && ((g_espPlayerVTable && f.vtable == g_espPlayerVTable) || (g_espPlayerVTables.count(f.vtable) > 0))) {
            if (diag) {
                diag->rule = 1;
                if (g_espAIVTables.count(f.vtable)) diag->ai = 1; // bot dùng chung VTable
            }
            ESPVerdictSetLocked(actor, 1, (f.hasTeam && f.team >= 0 && f.team <= 200000000) ? f.team : INT_MIN);
            goto check_live;
        }
        // 0b) VTable rác đã biết: verdict 2 ngay, 0 read thêm, KHỎI FName walk
        // qua GNames (phần đắt nhất của phân loại). VTable định danh CLASS nên
        // cùng class luôn cùng verdict; địa chỉ pool tái dùng khác class thì
        // VTable khác -> rơi vào FName/heuristic như thường. Check player
        // trước (ở trên) nên không bao giờ nuốt nhầm địch.
        if (f.hasVtable && f.vtable && g_espJunkVTables.count(f.vtable) > 0) {
            if (diag) diag->rule = 6;
            ESPVerdictSetLocked(actor, 2, INT_MIN);
            g_espTeamCache.erase(actor);
            g_espVerdictVt[actor] = f.vtable;
            return NO;
        }
        // 1) FName qua GNames (như Kernel GetFName -> IsASTExtraPlayerCharacter)
        if (g_espUName && f.hasName) {
            char nm[64] = {0};
            if (ESPActorNameByID(vmMap, g_espUName, f.nameID, nm)) {
                if (ESPIsPlayerCharacterName(nm)) {
                    if (f.hasVtable && f.vtable) {
                        if (!g_espPlayerVTable) g_espPlayerVTable = f.vtable;
                        if (g_espPlayerVTables.insert(f.vtable).second) {
                            ESPLog("learned player VTable=0x%llx from %s", (unsigned long long)f.vtable, nm);
                        }
                    }
                    f.ai = ESPNameIsAIPawn(nm) ? 1 : 0; // qblpack: AIMarkDifferent
                    if (f.ai && f.hasVtable && f.vtable) g_espAIVTables.insert(f.vtable);
                    if (diag) { diag->rule = 2; diag->ai = f.ai; }
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
        // Yêu cầu: SkeletalMesh hợp lệ (0x510), RootComponent hợp lệ (0x208),
        // HealthMax 50..2000, Health 0..hpMax+50,
        // TeamID 0..200000000.
        // Không ép trùng 1 VTable: bot (BP_PlayerPawn_TPlanAI_C) và người chơi
        // giới tính/skin khác nhau có VTable khác nhau!
        if (f.hasMesh && ESPIsUserPtr(f.mesh) &&
            f.hasRoot && ESPIsUserPtr(f.root) &&
            f.hasHp && f.hp >= 0 && f.hpMax >= 50 && f.hpMax <= 2000 && f.hp <= f.hpMax + 50 &&
            f.hasTeam && f.team >= 0 && f.team <= 200000000) {
            if (f.hasVtable && f.vtable) {
                if (!g_espPlayerVTable) g_espPlayerVTable = f.vtable;
                if (g_espPlayerVTables.insert(f.vtable).second) {
                    ESPLog("learned player VTable=0x%llx from heuristic", (unsigned long long)f.vtable);
                }
            }
            if (diag) diag->rule = 4;
            ESPVerdictSetLocked(actor, 1, f.team);
            goto check_live;
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
        // Nhớ VTable để lượt sau phát hiện object đổi class (tái dùng địa chỉ),
        // đồng thời dạy junk set để lần sau gặp class này thì skip FName walk.
        if (f.hasVtable) g_espVerdictVt[actor] = f.vtable;
        if (f.hasVtable && f.vtable) {
            if (g_espJunkVTables.size() > 4096) g_espJunkVTables.clear();
            g_espJunkVTables.insert(f.vtable);
        }
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
    // qblpack: verdict-1 lấy từ cache không chạy lại nhánh tên — nhận AI theo
    // VTable bot đã học (bot dùng chung class → cùng VTable).
    if (diag && diag->ai == 0 && f.hasVtable && f.vtable && g_espAIVTables.count(f.vtable)) {
        diag->ai = 1;
    }
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
    // Đồng đội:
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
    // Đồng đội: chỉ lọc khi CẢ HAI đều có team > 0 và BẰNG NHAU.
    // Nếu team == 0 hoặc myTeam <= 0 (đảo chờ / solo / chưa chia team) -> KHÔNG lọc!
    // KHÔNG hạ verdict 1 -> 2 để tránh mất vĩnh viễn actor khi game chia lại team.
    if (myTeam > 0 && team > 0 && team == myTeam && team != ESPTeam_Dummy) {
        if (diag) diag->rule = -4; // đồng đội
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
    BOOL okEng = ok;
    if (!okEng || !ESPIsUserPtr(engine)) {
        g_espWaitingLoad = NO; // engine đọc hỏng => nghi base, không phải load
        // Phân xử divergence: base scan đọc cùng địa chỉ ra pointer đẹp mà
        // engine ra 0. Map TƯƠI trực tiếp 1 page (không qua region cache) rồi
        // đọc — so 3 đường: region-memcpy (engine) vs map-tươi (direct).
        uint64_t direct = 0;
        {
            struct ESPVmShmem sh = vmmapremotepage(vmMap, geStatic & ~(uint64_t)(PAGE_SIZE - 1));
            if (sh.used && sh.localAddress) {
                direct = *(volatile uint64_t *)(uintptr_t)(sh.localAddress + (geStatic & (PAGE_SIZE - 1)));
                mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)sh.localAddress, PAGE_SIZE);
                if (sh.port) mach_port_deallocate(mach_task_self(), (mach_port_t)sh.port);
            }
        }
        ESPLog("world chain geA=0x%llx engOk=%d eng=0x%llx direct=0x%llx",
               (unsigned long long)geStatic, okEng, (unsigned long long)engine,
               (unsigned long long)direct);
        return 0;
    }
    g_espStep = 4;
    uint64_t viewport = ESPReadU64(vmMap, engine + ESPOff_Engine_GameViewport, &ok);
    BOOL okVp = ok;
    if (!okVp || !ESPIsUserPtr(viewport)) {
        // Phân biệt object engine giả (base sai) vs offset viewport đổi bản:
        // đọc thêm GameInstance (0xE20). Cả hai rác => object sai; GameInstance
        // đẹp mà viewport rác => offset đổi => cần dò slot.
        BOOL okGi = NO;
        uint64_t gameInstProbe = ESPReadU64(vmMap, engine + ESPOff_GameEngine_GameInstance, &okGi);
        ESPLog("world chain eng=0x%llx vpOk=%d vp=0x%llx giOk=%d gi=0x%llx",
               (unsigned long long)engine, okVp, (unsigned long long)viewport,
               okGi, (unsigned long long)gameInstProbe);
        // Engine object hợp lệ nhưng viewport+gameinstance đều null = game
        // đang load/khởi tạo (object mới chưa gán field), KHÔNG phải base sai:
        // chờ game load xong, đừng ép rescan vô ích.
        if (okVp && okGi && !viewport && !gameInstProbe) {
            g_espWaitingLoad = YES;
        }
    }
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
    if (!ok || !ESPIsUserPtr(world)) {
        ESPLog("world chain geA=0x%llx engOk=%d eng=0x%llx vpOk=%d vp=0x%llx wOk=%d w=0x%llx",
               (unsigned long long)geStatic, okEng, (unsigned long long)engine,
               okVp, (unsigned long long)viewport, ok,
               (unsigned long long)(ok ? world : 0));
        return 0;
    }
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
    g_espLastFastPawns = 0;
    ESPScanReentryGuard reentryGuard; (void)reentryGuard;
    g_espStep = 1;
    if (!gameBase || !ds_is_ready()) return r;
    { std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex); g_espFrame++; } // frame để verdict 2 hết hạn rồi đánh giá lại
    uint64_t proc = procbyname(ESP_DEFAULT_PROCESS);
    if (!proc) {
        proc = procbyname("ShadowTrackerE");
        if (!proc) { g_espStep = 1; return r; }
    }
    // Log proc phía engine (so với phía DSBridge trong "ds base refresh"):
    // hai bên phải cùng pid/name, lệch là resolve nhầm process.
    {
        static uint64_t s_loggedProc = 0;
        if (proc != s_loggedProc) {
            s_loggedProc = proc;
            pid_t lp = (off_proc_p_pid && proc) ? (pid_t)ds_kread32(proc + off_proc_p_pid) : 0;
            char nm[33] = {0};
            if (proc) ds_kread(proc + off_proc_p_name, nm, 32);
            ESPLog("eng proc=0x%llx pid=%d name=%s", (unsigned long long)proc, lp, nm);
        }
    }
    uint64_t vmMap = ESPMemoryOpenVMMapForProc(proc);
    pid_t scanPid = (off_proc_p_pid && proc) ? (pid_t)ds_kread32(proc + off_proc_p_pid) : 0;
    if (!vmMap || scanPid <= 0) {
        g_espStep = 2;
        return r; // proc/map rác (proc đang teardown) -> bỏ lượt, không walk
    }
    {   // Game restart (pid/base đổi): xả region map + task của game cũ để
        // không đọc dữ liệu cũ lẫn walk map cũ.
        static uint64_t s_scanPid = 0;
        static uint64_t s_scanBase = 0;
        if (s_scanPid != (uint64_t)scanPid || s_scanBase != gameBase) {
            if (s_scanPid || s_scanBase) {
                ESPLog("game restart: pid=%llu->%d base=0x%llx->0x%llx (flush)",
                       (unsigned long long)s_scanPid, scanPid,
                       (unsigned long long)s_scanBase, (unsigned long long)gameBase);
                ESPMemoryFlushPageCache();
                ESPGameTaskReset();
                // Base DSBridge có thể stale (TTL 30s chưa quét lại sau khi
                // game restart) -> ép quét lại ngay, lần scan sau dùng base mới.
                DSBridgeRefreshGameBase();
            }
            s_scanPid = (uint64_t)scanPid;
            s_scanBase = gameBase;
        }
    }

    g_espStep = 3;
    uint64_t world = ESPWorldViaViewport(vmMap, gameBase);
    {
        // World fail liên tiếp mà pid/base không đổi = base sai nhưng DSBridge
        // tưởng còn đúng (TTL skip) -> ép quét lại, cooldown 15s chống spam.
        static int s_worldFails = 0;
        static CFAbsoluteTime s_lastForce = 0;
        if (!world) {
            s_worldFails++;
        } else {
            s_worldFails = 0;
        }
        if (!world && s_worldFails >= 5 && !g_espWaitingLoad &&
            CFAbsoluteTimeGetCurrent() - s_lastForce > 15.0) {
            s_lastForce = CFAbsoluteTimeGetCurrent();
            ESPLog("world fail x%d pid=%d base=0x%llx: force base rescan",
                   s_worldFails, scanPid, (unsigned long long)gameBase);
            DSBridgeRefreshGameBase();
        }
    }
    if (!world) { ESPLog("scan world FAIL step=%d base=0x%llx pid=%d%s", g_espStep, (unsigned long long)gameBase, scanPid, g_espWaitingLoad ? " waiting-load" : ""); return r; }
    if (!ESPValidateWorld(vmMap, world)) { ESPLog("scan validate FAIL step=%d", g_espStep); return r; }
    g_espStep = 0;
    g_espWaitingLoad = NO; // có world = game load xong, hết chờ
    r.world = world;
    ESPPlayerArrayProbe(vmMap, world);

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
    // kernrw52g: bỏ log scan start (I/O mỗi scan)

    // GNames/UName không còn ở đây. Đo được: scan đầu mất 13.0s thì ~11s là
    // ESPResolveUName quét GNames (region cache còn lạnh), mà ra vẫn 0x0 —
    // enemies=4 thu về nhờ VTable. Đặt TRƯỚC vòng phân loại là giữ tracked
    // (tức là giữ box) chờ đúng bước vừa chậm vừa vô dụng đó.
    // Xem khối resolve ở cuối hàm, sau khi đã swap tracked.

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
                std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
                if (lp) {
                    BOOL okv = NO;
                    uint64_t vt = ESPReadU64(vmMap, lp, &okv);
                    if (okv && ESPIsUserPtr(vt)) {
                        if (!g_espPlayerVTable) {
                            g_espPlayerVTable = vt;
                            ESPLog("learned player VTable=0x%llx from local pawn", (unsigned long long)vt);
                        }
                        g_espPlayerVTables.insert(vt);
                    }
                }
            }
        } else if (verbose) {
            ESPLog("diag pawn FAIL (NetDriver chain)");
        }
    }
    // qblpack: fast path — lấy thẳng player/bot từ GameState.PlayerArray.
    // fastPawnN > 0 => actor array chỉ quét lát để bắt hình nhân; = 0 => giữ
    // nguyên full scan cũ làm fallback.
    static ESPPlayerPawn s_fastPawns[128];
    int fastPawnN = ESPReadPlayerPawns(vmMap, world, s_fastPawns, 128);
    g_espLastFastPawns = fastPawnN;
    {
        static uint64_t s_fastLoggedWorld = 0;
        if (fastPawnN > 0 && world != s_fastLoggedWorld) {
            s_fastLoggedWorld = world;
            ESPLog("fast players: %d via PlayerArray", fastPawnN);
        }
    }
    if (verbose) {
        int inList = -1;
        for (uint32_t i = 0; i < scanN; i++) {
            if (s_actors[i] == myPawn && myPawn) { inList = (int)i; break; }
        }
        ESPActorFields pf;
        ESPActorFieldsRead(vmMap, myPawn, &pf);
        // kernrw52g: bỏ log diag pawn (I/O mỗi scan)
        // Camera: chẩn đoán tại sao không vẽ được box (chain toàn bộ).
        ESPCamera camProbe;
        BOOL camOK = ESPEngineCamera(gameBase, &camProbe);
        if (camOK) {
            // kernrw52g: bỏ log diag cam OK (I/O mỗi scan)
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
    uint32_t enemies = 0;
    uint32_t dummies = 0;
    // Build tracked trên vector LOCAL rồi swap 1 lần dưới lock ở cuối scan:
    // box path (bridge queue) copy dưới lock nên không bao giờ thấy vector
    // đang clear/push dở (trước đây là race -> tracked rỗng/rác -> box 0).
    std::vector<ESPTrackedActor> localTracked;
    localTracked.reserve(80);
    std::unordered_set<uint64_t> localSeen;

    auto addLocalTracked = [&](uint64_t actor, int team, const ESPClassifyDiag &dg, int aiHint) {
        if (localTracked.size() >= 64 || localSeen.count(actor)) return;
        ESPTrackedActor tr;
        tr.actor = actor;
        tr.root = (ESPIsUserPtr(dg.root)) ? dg.root : 0;
        tr.fallback = 0;
        tr.parent = 0;
        uint64_t meshComp = ESPBoxMesh(vmMap, actor, &dg, team);
        tr.mesh = meshComp;
        tr.height = ESPActorBoxHeight(vmMap, meshComp);
        tr.team = (team != ESPTeam_Dummy && team >= 0 && team <= 200000000) ? team : INT_MIN;
        tr.isAI = (dg.ai || aiHint) ? 1 : 0;
        // qblpack: dò bảng xương ngay trên queue scan nền (không chặn tick).
        if (g_espBonesWant.load() && !g_espBonesReady.load() &&
            team != ESPTeam_Dummy && meshComp && ESPIsUserPtr(meshComp)) {
            ESPBonesConfigure(vmMap, meshComp, gameBase, YES);
        }
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
        localSeen.insert(actor);
    };

    // Fast path: PlayerArray (player + bot). Phân loại TRƯỚC actor array để
    // box có ngay cả khi vòng actor bị budget cắt hoặc player nằm cuối mảng.
    for (int p = 0; p < fastPawnN; p++) {
        uint64_t actor = s_fastPawns[p].pawn;
        if (!ESPIsUserPtr(actor) || actor == myPawn) continue;
        int team = 0;
        float hp = 0;
        ESPClassifyDiag dg;
        if (ESPIsEnemy(vmMap, actor, myTeam, myPawn, &team, &hp, &dg)) {
            enemies++;
            if (team == ESPTeam_Dummy) dummies++;
            addLocalTracked(actor, team, dg, s_fastPawns[p].isBot ? 1 : 0);
        }
    }

    // PlayerArray có dữ liệu => actor array chỉ cần lát 2048 actor/lượt để bắt
    // hình nhân huấn luyện (kind 3). Không cắt actor array ở lượt đầu: lát cắt
    // lạnh vẫn tốn ~50ms/actor và sẽ tạo lag đúng lúc box vừa hiện; để nó chạy
    // song song lúc HUD/overlay đang dựng (như log 2026-10-21) rồi mới warm.
    uint32_t scanStart = 0;
    uint32_t scanCount = scanN;
    static uint32_t s_scanSlice = 0; // con trỏ lát actor; resume nếu budget cắt
    BOOL sliced = (fastPawnN > 0 && scanN > 2048);
    if (sliced) {
        scanCount = 2048;
        scanStart = s_scanSlice % scanN;
    }
    if (sliced) {
        // Giữ hình nhân đã track (có thể nằm ngoài lát hiện tại) để box không
        // chớp tắt; player thì luôn được dựng lại từ PlayerArray mỗi lượt.
        std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
        for (const auto &t : g_espTracked) {
            if (t.kind == 3 && localTracked.size() < 64 && !localSeen.count(t.actor)) {
                localTracked.push_back(t);
                localSeen.insert(t.actor);
            }
        }
    }
    g_espProgressTotal.store((int)scanCount);
    g_espProgress.store(0);
    uint32_t nVt = 0, nName = 0, nDummyName = 0, nChar = 0, nDummySig = 0;
    uint32_t nNo = 0, nFiltered = 0, nCached = 0;
    uint32_t nearChar = 0, nearDummy = 0, winOK = 0, winFail = 0;
    std::unordered_map<uint64_t, uint32_t> vtHist;
    uint64_t sample = 0;
    ESPVector samplePos = {0,0,0};
    BOOL hasPos = NO;
    int logged = 0;
    // Budget thời gian cho vòng phân loại (kernrw34): lúc game loading mỗi
    // actor tốn hàng chục ms (GNames lạnh + tranh lock với tick 40Hz + discover
    // budget 48) — log thực tế có lượt scan 23.3s. Quá 0.5s thì dừng, phần còn
    // lại để lượt quét sau (TTL 0.8s) + discover (0.12s) phân loại nốt. Lượt
    // thường chỉ 0.0-0.2s nên ngưỡng này không bao giờ chạm khi vào trận.
    // Budget 0.5s chỉ tính cho vòng actor: fast path PlayerArray có thể đã tốn
    // ~1s map page, không để nó ăn hết budget của lát actor.
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    uint32_t scanProcessed = 0;
    bool scanCompleted = true;
    for (uint32_t step = 0; step < scanCount; step++) {
        uint32_t i = scanStart + step;
        if (i >= scanN) i -= scanN;
        if ((step & 15) == 0) g_espProgress.store((int)step);
        if ((step & 63) == 0 && step > 0 && CFAbsoluteTimeGetCurrent() - t0 > 0.5) {
            // kernrw52g: bỏ log scan budget cut (I/O mỗi scan)
            scanCompleted = false;
            break;
        }
        // Nhường mutex read cho box refresh chen vào: scan giữ từng read hàng
        // chục ms, không nhường thì refresh đói tới vài giây (max 4.8s đo thực
        // tế). qblpack: 250us thay vì 1ms — vẫn đủ để tick 60Hz chen vào giữa
        // 2 actor, nhưng bớt 750ms sleep/8000 actor (scan xong sớm hơn = ít
        // thời gian tranh provider với box refresh).
        if ((step & 15) == 0) usleep(250);
        scanProcessed = step + 1;
        uint64_t actor = s_actors[i];
        if (!ESPIsUserPtr(actor)) continue;
        if (localSeen.count(actor)) continue; // fast path/giữ hình nhân đã xử lý
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
            // kernrw52g: bỏ log a[i] (I/O blocking mỗi scan)
            logged++;
        }
        if (!isEnemy) continue;
        enemies++;
        if (team == ESPTeam_Dummy) dummies++;
        // Lưu lại để refresh vị trí nhanh giữa các lượt quét (ESPTrackedActor).
        // Dùng diag (field đọc trong ESPIsEnemy) — biến f ở nhánh phân loại
        // không còn scope ở đây.
        addLocalTracked(actor, team, dg, 0);
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
    if (sliced) {
        // Resume đúng chỗ budget cắt, không nhảy cóc 2048 actor.
        uint32_t next = scanStart + scanProcessed;
        s_scanSlice = (scanN > 0) ? (next % scanN) : 0;
    }
    g_espProgress.store((int)scanCount);
    {
        // Publish tracked cho box path (swap dưới lock, giữ lock cực ngắn).
        // Lượt quét ra 0 actor KHÔNG xoá tracked: hụt 1 lượt (world vừa đổi,
        // read fail, actor chưa spawn) mà xoá là refresh 60Hz trả 0 box cho tới
        // lượt quét sau (TTL 2s) — nhìn như box tắt/bật giật. Xoá tracked là
        // việc của ESPVerdictResetIfWorldChanged khi ĐỔI world.
        // Budget-cut: fast path (fastPawnN>0) vẫn SWAP vì localTracked đã có
        // đủ player sống từ PlayerArray + hình nhân giữ lại + lát actor vừa
        // xử lý — swap để player chết rơi khỏi tracked. Full-scan fallback
        // (fastPawnN=0) mới MERGE để không rơi địch ngoài phần đã quét.
        std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
        if (!localTracked.empty()) {
            if (scanCompleted || fastPawnN > 0) {
                g_espTracked.swap(localTracked);
                g_espTrackGen++;
            } else {
                for (const auto &nt : localTracked) {
                    bool exists = false;
                    for (const auto &t : g_espTracked) {
                        if (t.actor == nt.actor) { exists = true; break; }
                    }
                    if (!exists && g_espTracked.size() < 64) g_espTracked.push_back(nt);
                }
                g_espTrackGen++;
            }
        }
        ESPTrackedSnapPublishLocked();
        g_espPasses++;
    }
    r.playerLike = enemies;
    r.dummyLike = dummies;
    r.sampleActor = sample;
    r.samplePos = samplePos;
    r.hasSamplePos = hasPos;
    // kernrw52g: bỏ log scan done (I/O mỗi scan)

    // GNames/UEtTÊN: chỉ quét khi CHƯA có địch nào. Đã có địch nhờ VTable thì
    // bỏ hẳn — ESPResolveUName tốn ~11s ở lượt đầu mà ra 0x0, và quét nền giữ
    // unique_lock mỗi lần map vùng sẽ tranh với tick vẽ 40Hz (chính là nguồn
    // giật). Chưa lọc được địch nào thì mới cần tên để phân loại tiếp.
    // Thử tối đa 4 lượt cho mỗi game base (s_unameTries chỉ reset khi base đổi).
    {
        static uint64_t s_unameBase = 0;
        if (s_unameBase != gameBase) {
            s_unameBase = gameBase;
            s_unameTries = 0;
        }
        if (g_espUName) {
            // đã có, không đọc lại
        } else if (s_unameTries >= 4) {
            // đã fail 4 lượt cho base này: bỏ qua, không read/log lại
        } else if (enemies > 0) {
            // ĐÃ có địch nhờ VTable/heuristic -> không cần tên class nữa.
        } else {
            // Cooldown 10s giữa các lần thử (kernrw34): lúc game loading mỗi
            // lần walk GNames tốn hàng giây trên cache lạnh + tranh lock với
            // tick 40Hz (log: tries 1-4 chạy 4s liên tiếp). Không vội —
            // VTable/heuristic vẫn bắt địch trong lúc chờ GNames.
            static CFAbsoluteTime s_unameLastTry = 0;
            CFAbsoluteTime nowU = CFAbsoluteTimeGetCurrent();
            if (s_unameTries > 0 && nowU - s_unameLastTry < 10.0) {
                // bỏ qua lượt này, chờ nguội
            } else {
                s_unameLastTry = nowU;
                s_unameTries++;
                g_espUName = ESPResolveUName(vmMap, gameBase);
                std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
                ESPLog("uname=0x%llx vtableKnown=%d tries=%d", (unsigned long long)g_espUName, g_espPlayerVTable ? 1 : 0, s_unameTries);
            }
        }
    }
    if (verbose) {
        std::vector<std::pair<uint64_t, uint32_t>> vts(vtHist.begin(), vtHist.end());
        std::sort(vts.begin(), vts.end(), [](const std::pair<uint64_t,uint32_t> &a,
                                             const std::pair<uint64_t,uint32_t> &b) {
            return a.second > b.second;
        });
        char buf[512] = {0};
        int bl = 0;
        for (size_t i = 0; i < vts.size() && i < 8; i++) {
            if (bl > (int)sizeof(buf) - 32) break;
        }
        uint64_t pawnVtCopy = 0;
        int verboseLeftCopy = 0;
        {
            std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
            pawnVtCopy = g_espPlayerVTable;
            verboseLeftCopy = g_espVerboseLeft;
        }
        // kernrw52g: bỏ log diag vtHist (I/O mỗi scan)
        if (verboseLeftCopy > 0) {
            std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
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
    // kernrw52d: khi provider degraded (task port fail, reads chậm), tăng TTL
    // lên 3.0s để giảm tần suất scan (scan degraded chậm, không giúp gì).
    if (ESPProviderIsDegraded()) ttl = (ttl < 3.0) ? 3.0 : ttl;
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
            ESPProviderBeginRead();
            ESPScanResult r = ESPEngineScan(gameBase);
            ESPProviderEndRead();
            ESPProviderNoteFullScan();
            // World đổi (map/trận mới): page cache còn giữ mapping của world
            // cũ -> xả để nhả mapping + port, và tránh đọc page héo.
            static uint64_t s_lastCacheWorld = 0;
            if (r.world && r.world != s_lastCacheWorld) {
                if (s_lastCacheWorld) ESPMemoryFlushPageCache();
                ESPProviderShutdown(); // world mới => provider reset
                s_lastCacheWorld = r.world;
            }
            g_espCache = r;
            g_espCachePasses = g_espPasses;
            g_espCheckedAt = CFAbsoluteTimeGetCurrent();
            g_espLastScanSeconds = g_espCheckedAt - t0;
            g_espLastScanEnemies = r.world ? (int)r.playerLike : -2; // -2 = fail
            g_espLastScanDummies = r.world ? (int)r.dummyLike : -1;
            g_espTrackedCount = (int)g_espTracked.size();
            // qblpack: log nhịp quét 5s để biết "scan actors lâu" là do 1 lượt
            // quét chậm hay do TTL 3s. fast>0 = PlayerArray hoạt động; khi đó
            // scanned chỉ là lát 2048 actor (không phải budget cut). fast=0 và
            // scanned < actors nghĩa là lượt quét bị budget 0.5s cắt giữa chừng.
            static CFAbsoluteTime s_lastScanStat = 0;
            if (g_espCheckedAt - s_lastScanStat >= 5.0) {
                s_lastScanStat = g_espCheckedAt;
                ESPLog("scan stat: ms=%.0f actors=%u scanned=%u enemies=%d dummies=%d tracked=%d fast=%d",
                       g_espLastScanSeconds * 1000.0,
                       g_espCache.actorCount, g_espCache.scanned,
                       g_espLastScanEnemies, g_espLastScanDummies, g_espTrackedCount,
                       g_espLastFastPawns);
            }
            // kernrw52g: bỏ log scan finished (I/O) g_espLastScanSeconds,
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
        return [NSString stringWithFormat:@"%u Địch (~)", (unsigned)g_espCache.playerLike];
    }
    return [NSString stringWithFormat:@"%u Địch", (unsigned)g_espCache.playerLike];
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
    uint64_t vmMap = ESPMemoryOpenVMMapForProc(proc);
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
        }
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
    // Cache proc/vmMap cho box refresh 8Hz NHƯNG validate mỗi lần dùng:
    // proc cũ sau game restart là UAF — walk vm_map stale = kernel panic
    // (log: respring rồi reboot, SpringBoard pid 5162->34). Không bao giờ
    // trả stale khi resolve fail.
    uint64_t oldProc = g_espVMProc; // proc đang cache (để so sánh khi đổi)
    if (g_espVMMap && g_espVMProc) {
        // 1 kernel read rẻ: pid của proc cache còn khớp?
        pid_t p = (off_proc_p_pid) ? (pid_t)ds_kread32(g_espVMProc + off_proc_p_pid) : 0;
        if (p > 0 && p == g_espVMPid && ds_isvalid(g_espVMMap)) {
            if (outProc) *outProc = g_espVMProc;
            return g_espVMMap;
        }
        // Proc chết/đổi (game restart) hoặc đọc lỗi: bỏ cache.
        g_espVMProc = 0; g_espVMMap = 0; g_espVMPid = 0;
    } else {
        // Không cache: throttle procbyname đắt (full proclist walk).
        CFAbsoluteTime now0 = CFAbsoluteTimeGetCurrent();
        if (g_espVMAt > 0 && now0 - g_espVMAt < 3.0) return 0;
    }
    uint64_t oldProcCached = oldProc;
    uint64_t proc = procbyname(ESP_DEFAULT_PROCESS);
    if (!proc) proc = procbyname("ShadowTrackerE");
    g_espVMAt = CFAbsoluteTimeGetCurrent();
    if (!proc || !ds_isvalid(proc)) return 0; // KHÔNG trả stale
    pid_t pid = (off_proc_p_pid) ? (pid_t)ds_kread32(proc + off_proc_p_pid) : 0;
    if (pid <= 0) return 0;
    if (outProc) *outProc = proc;
    uint64_t vmMap = ESPMemoryOpenVMMapForProc(proc);
    if (!vmMap) return 0;
    if (oldProcCached && oldProcCached != proc) {
        // Proc khác (game restart): vùng region map của game cũ sai hết.
        // IfIdle (try-lock) để không bao giờ deadlock với scan nền.
        ESPMemoryFlushPageCacheIfIdle();
    }
    g_espVMProc = proc;
    g_espVMPid = pid;
    g_espVMMap = vmMap;
    return vmMap;
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
    // kernrw52d: adaptive discover interval — bắt đầu ESP_DISCOVER_INTERVAL,
    // nếu 3 lượt liên tiếp không tìm thấy địch mới thì tăng lên 1.0s (giảm tải).
    // Khi tìm thấy địch mới → reset về ESP_DISCOVER_INTERVAL.
    static int s_emptyStreak = 0;
    static double s_adaptiveInterval = ESP_DISCOVER_INTERVAL;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (s_last && now - s_last < s_adaptiveInterval) return;
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
        std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
        trackedSet.reserve(g_espTracked.size());
        for (const auto &t : g_espTracked) trackedSet.insert(t.actor);
        hasVerdict.reserve(g_espVerdict.size());
        for (const auto &kv : g_espVerdict) {
            hasVerdict.insert(kv.first);
            if (kv.second == 1 || kv.second == 3) enemyVerdict.insert(kv.first);
        }
        verdictVt = g_espVerdictVt;
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
        uint64_t meshComp = ESPBoxMesh(vmMap, actor, &dg, team);
        tr.mesh = meshComp;
        tr.height = ESPActorBoxHeight(vmMap, meshComp);
        tr.team = (team != ESPTeam_Dummy && team >= 0 && team <= 200000000) ? team : INT_MIN;
        tr.isAI = dg.ai ? 1 : 0;
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

    // Cooldown Pass 1: địch chết/ẩn giữ verdict 1 — check_live mỗi 120ms trên
    // hàng chục actor là cls=17 spam (window read thừa). 0.4s vẫn bắt unhide
    // đủ nhanh, giảm ~3 lần kernel đọc mỗi discover.
    const CFAbsoluteTime pass1Cd = 0.4;

    // Pass 0 (fast): PlayerArray. Không phụ thuộc độ dài/thứ tự actor array;
    // người chơi mới/unhide vào tracked trong 1 nhịp discover (~250ms-1s).
    static ESPPlayerPawn s_discPawns[128];
    int pawnN = ESPReadPlayerPawns(vmMap, world, s_discPawns, 128);
    for (int p = 0; p < pawnN; p++) {
        uint64_t actor = s_discPawns[p].pawn;
        if (!ESPIsUserPtr(actor) || trackedSet.count(actor)) continue;
        if (!hasVerdict.count(actor)) {
            int team = 0;
            float hp = 0;
            ESPClassifyDiag dg;
            cls++;
            if (ESPIsEnemy(vmMap, actor, myTeam, myPawn, &team, &hp, &dg)) {
                if (s_discPawns[p].isBot) dg.ai = 1;
                addTracked(actor, team, dg);
            }
            hasVerdict.insert(actor);
            continue;
        }
        if (enemyVerdict.count(actor)) {
            BOOL pass1Skip = NO;
            {
                std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
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
        // verdict 2: để full scan re-validate (tránh window read mỗi 120ms).
    }

    // Actor array: khi PlayerArray hoạt động chỉ cần 1Hz để tìm hình nhân
    // huấn luyện; player/bot đã được Pass 0 phủ. PlayerArray hỏng (pawnN=0)
    // thì chạy full như cũ.
    static CFAbsoluteTime s_lastActorDisc = 0;
    BOOL doActorDisc = (pawnN == 0) || (now - s_lastActorDisc >= 1.0);
    if (doActorDisc) {
        s_lastActorDisc = now;
        uint64_t level = 0, actorsData = 0;
        uint32_t actorsCount = 0;
        if (ESPLevelAndActors(vmMap, world, &level, &actorsData, &actorsCount) &&
            actorsData && actorsCount > 0 && actorsCount <= 20000) {
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

            // Pass 1: verdict địch 1/3 chưa tracked (vừa unhide) + peek VTable
            // verdict-2 (object pool tái dùng địa chỉ -> có thể đã thành địch).
            // Unknown gom vào pass 2 theo budget.
            // Map g_espPass1At cũng được ESPVerdictResetIfWorldChanged clear
            // dưới cùng mutex classify — truy cập ngắn dưới lock, không giữ
            // qua ESPIsEnemy.
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
                        std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
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
            // Degraded: budget nhỏ lại để nhẹ kernel (port DarkSwordMemoryProvider).
            int budget = ESPProviderDiscoverBudget();
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
        }
    }

    if (!newTracked.empty()) {
        std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
        for (const auto &nt : newTracked) {
            bool exists = false;
            for (const auto &t : g_espTracked) {
                if (t.actor == nt.actor) { exists = true; break; }
            }
            if (!exists && g_espTracked.size() < 64) g_espTracked.push_back(nt);
        }
        g_espTrackGen++;
        ESPTrackedSnapPublishLocked();
        g_espTrackedCount = (int)g_espTracked.size();
    }
    // Log khi THẬT SỰ thêm địch, hoặc unknown đổi số (không nhai lại cùng 1
    // actor mỗi 120ms). Heartbeat hiếm khi còn unknown để chẩn đoán.
    static CFAbsoluteTime s_lastUnkLog = 0;
    if (added > 0) {
        // kernrw52g: bỏ log discover (I/O mỗi discover)
    } else if (!unknownIdx.empty() && now - s_lastUnkLog >= 5.0) {
        s_lastUnkLog = now;
        // kernrw52g: bỏ log discover +E=0 (I/O mỗi discover)
    }
    // kernrw52d: adaptive interval — nếu không tìm thấy địch mới, tăng interval
    // lên 1.0s (giảm tải). Khi tìm thấy → reset về ESP_DISCOVER_INTERVAL.
    if (added > 0) {
        s_emptyStreak = 0;
        s_adaptiveInterval = ESP_DISCOVER_INTERVAL;
    } else {
        s_emptyStreak++;
        if (s_emptyStreak >= 3) {
            s_adaptiveInterval = 1.0; // 1s khi stable
        }
    }
}

static dispatch_queue_t ESPDiscoverQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.huami.darkspeed.esp-discover", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static std::atomic_bool g_espDiscovering{false};

void ESPEngineRequestDiscover(uint64_t gameBase) {
    if (!gameBase || !ds_is_ready()) return;
    static CFAbsoluteTime s_lastReq = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (s_lastReq && now - s_lastReq < ESP_DISCOVER_INTERVAL) return;
    s_lastReq = now;

    bool expected = false;
    if (!g_espDiscovering.compare_exchange_strong(expected, true)) return;

    dispatch_async(ESPDiscoverQueue(), ^{
        @autoreleasepool {
            ESPProviderBeginRead();
            ESPEngineDiscoverTick(gameBase);
            ESPProviderEndRead();
            g_espDiscovering.store(false);
        }
    });
}
#else
void ESPEngineDiscoverTick(uint64_t gameBase) {
    (void)gameBase;
}
void ESPEngineRequestDiscover(uint64_t gameBase) {
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
        return 0;
    }
    uint32_t n = ESPReadU32(vmMap, gameInst + off + 8, &ok);
    if (!ok || n == 0 || n > 8) {
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
    std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
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
                nStages++;
            }
        } else if (best[0] == '\0') {
            snprintf(best, sizeof(best), "%s", st); // toàn dataFail: giữ cái đầu (có ok/raw)
        }
        if (pc) {
            g_espLPInstFound = gameInst;
            g_espLPOffFound = kCand[i];
            ESPLog("camLP resolved %s", g_espLPDiag);
            return pc;
        }
    }
    g_espLPNegInst = gameInst;
    g_espLPNegAt = now;
    ESPLog("camLP FAIL %s", g_espLPDiag);
    return 0;
}

static const char *ESPCameraResolveDiag(void) {
    return g_espLPDiag;
}

static BOOL ESPCameraIsResolved(void) {
    std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
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
    // kernrw52g: bỏ log giDump (I/O mỗi scan)
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
            if (bl > (int)sizeof(buf) - 48) break;
            found++;
        }
    }
    // kernrw52g: bỏ log giDump (I/O)
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
    // chunk(m=.. p=.. f=..): bulk map — 1 lần map phủ nhiều page (bản kernel của
    // "đọc bulk" trong aovcheat). m=0 nghĩa là vẫn map từng page.
    uint64_t chunkMaps = 0, chunkPages = 0, chunkFails = 0;
    ESPMemoryChunkStats(&chunkMaps, &chunkPages, &chunkFails);
    static uint64_t g_perfLastChunkMaps = 0, g_perfLastChunkPages = 0;
    uint64_t dChunkMaps = chunkMaps - g_perfLastChunkMaps;
    uint64_t dChunkPages = chunkPages - g_perfLastChunkPages;
    g_perfLastChunkMaps = chunkMaps;
    g_perfLastChunkPages = chunkPages;
    uint64_t deadDrops = ESPMemoryDeadRegionDrops();
    static uint64_t g_perfLastDead = 0;
    uint64_t dDead = deadDrops - g_perfLastDead;
    g_perfLastDead = deadDrops;
    if (g_perfN > 0) {
        // kernrw52g: bỏ perf snprintf chi tiết (I/O), chỉ giữ n/a
        snprintf(g_perfBuf, sizeof(g_perfBuf), "n=%d", g_perfN);
    } else {
        snprintf(g_perfBuf, sizeof(g_perfBuf),
                 "n=0 cache(h=%llu m=%llu) read(t=%llu k=%llu) chunk(m=%llu p=%llu f=%llu) dead=%llu",
                 (unsigned long long)dHit, (unsigned long long)dMiss,
                 (unsigned long long)dTask, (unsigned long long)dKernel,
                 (unsigned long long)dChunkMaps, (unsigned long long)dChunkPages,
                 (unsigned long long)chunkFails, (unsigned long long)dDead);
    }
    g_perfSumProc = 0;
    g_perfSumCam = 0;
    g_perfSumAct = 0;
    g_perfN = 0;
    g_perfMaxMs = 0;
    return g_perfBuf;
}

static uint64_t ESPResolvePCCached(uint64_t vmMap, uint64_t world) {
    // kernrw40: resolve FRESH mỗi tick (chain chỉ 3 read cached) thay vì tin
    // cache cả trận. Game realloc PlayerController/CameraManager khi đổi
    // possess, lên/xuống xe, chết/respawn mà world KHÔNG đổi -> cache cũ trỏ
    // vào object chết/memory tái dùng -> camera đứng hình/lệch (đúng kiểu
    // "đi bộ box đứng yên, xoay camera box trôi rồi dính lại"; log kernrw39 có
    // cam teleport dLoc=146.7m = đổi possess). Hysteresis 2 tick: PC mới chỉ
    // nhận sau 2 lần liên tiếp giống nhau (chain rách lẻ 1 tick thì giữ cũ).
    // Không giữ lock ngoài suốt quá trình (ESPResolvePC tự lock trong —
    // mutex non-recursive). 2 threads cùng resolve 1 lúc là benign.
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
    // kernrw44: g_espCamMutex thay g_espClassifyMutex (ESPResolvePC phía trên đã
    // tự lock classify và RELEASE trước khi vào đây -> không bao giờ giữ 2 lock).
    std::lock_guard<std::recursive_mutex> lk(g_espCamMutex);
    if (!pc) return s_camPC; // read fail: giữ cache cũ, đừng chớp tắt
    if (s_camWorld != world) {
        // World mới: nhận ngay (ClearLocked đã xả pending), không hysteresis.
        ESPLog("camPC pc=0x%llx", (unsigned long long)pc);
        s_camPC = pc;
        s_camWorld = world;
        s_camMgr = 0;
        s_camPCPending = 0; s_camPCPendingN = 0;
        s_camMgrPending = 0; s_camMgrPendingN = 0;
        return pc;
    }
    if (pc == s_camPC) {
        s_camPCPending = 0; s_camPCPendingN = 0;
        return s_camPC;
    }
    if (s_camPC == 0) {
        // Chưa từng có PC (đầu trận): nhận ngay, khỏi chờ 2 tick.
        ESPLog("camPC pc=0x%llx", (unsigned long long)pc);
        s_camPC = pc;
        s_camPCPending = 0; s_camPCPendingN = 0;
        return pc;
    }
    if (pc == s_camPCPending) {
        if (++s_camPCPendingN >= 2) {
            ESPLog("camPC re-resolve 0x%llx->0x%llx (possess/vehicle/respawn?)",
                   (unsigned long long)s_camPC, (unsigned long long)pc);
            s_camPC = pc;
            s_camMgr = 0; // mgr của PC cũ hết hiệu lực
            s_camPCPending = 0; s_camPCPendingN = 0;
            s_camMgrPending = 0; s_camMgrPendingN = 0;
            return pc;
        }
    } else {
        s_camPCPending = pc;
        s_camPCPendingN = 1;
    }
    return s_camPC; // giữ cũ 1 tick
}

// CamMgr resolve fresh theo PC hiện tại (mgr cũng realloc cùng possess).
// Hysteresis 2 tick như PC.
static uint64_t ESPCamMgrCached(uint64_t vmMap, uint64_t world, uint64_t pc) {
    if (!pc) return 0;
    BOOL ok = NO;
    uint64_t cm = ESPReadU64(vmMap, pc + ESPOff_PC_CameraManager, &ok);
    if (!ok || !ESPIsUserPtr(cm)) {
        return 0; // read fail: giữ im, đừng clear cache cả cụm vì 1 tick rách
    }
    // kernrw44: cache camera -> mutex riêng (không xếp hàng sau scan nền).
    std::lock_guard<std::recursive_mutex> lk(g_espCamMutex);
    if (s_camWorld == world && s_camPC == pc) {
        if (cm == s_camMgr) {
            s_camMgrPending = 0; s_camMgrPendingN = 0;
            return s_camMgr;
        }
        if (s_camMgr == 0) {
            s_camMgr = cm;
            s_camMgrPending = 0; s_camMgrPendingN = 0;
            return cm;
        }
        if (cm == s_camMgrPending) {
            if (++s_camMgrPendingN >= 2) {
                s_camMgr = cm;
                s_camMgrPending = 0; s_camMgrPendingN = 0;
                return cm;
            }
        } else {
            s_camMgrPending = cm;
            s_camMgrPendingN = 1;
        }
        return s_camMgr; // giữ cũ 1 tick
    }
    return cm; // PC/world khác cache: trả fresh, caller (ESPEngineCamera) tự xử
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
    // Viewport world luôn trỏ map/world đang active. Fallback về cache.
    uint64_t world = ESPWorldViaViewport(vmMap, gameBase);
    if (!world) world = g_espCache.world;
    if (!world) return NO;
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
        // ESPMemoryRead (0x38 < 1 page) đi đường region map — sau lần đầu là
        // memcpy thuần; trước đây ESPReadWindow map page mới mỗi lần (~20ms).
        if (ESPMemoryRead(vmMap, pov, raw, sizeof(raw))) {
            // Đọc kép chống rách (kernrw32): POV 56B đọc đúng lúc game đang
            // ghi -> trộn 2 frame (log kernrw31: dYaw 40-57° + dLoc 2m trong
            // 1 tick, ~10 lần/85s lúc combat; rách nhỏ hơn ngưỡng guard vẫn
            // lọt -> box nhảy 60-80px). Đọc 2 lần cách nhau µs: giống nhau
            // (memcmp) thì lấy; khác -> đọc lần 3, lấy mẫu trùng 2/3; không
            // trùng -> giữ mẫu đầu (fail-open, guard ngưỡng ở refresh bắt
            // nốt). Chi phí +1 memcpy 56B/tick. Không còn tick camera stale.
            uint8_t raw2[0x38];
            if (ESPMemoryRead(vmMap, pov, raw2, sizeof(raw2)) &&
                memcmp(raw, raw2, sizeof(raw)) != 0) {
                uint8_t raw3[0x38];
                if (ESPMemoryRead(vmMap, pov, raw3, sizeof(raw3)) &&
                    memcmp(raw, raw3, sizeof(raw)) != 0 &&
                    memcmp(raw2, raw3, sizeof(raw2)) == 0) {
                    memcpy(raw, raw2, sizeof(raw)); // A rách, B==C đúng
                }
            }
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
    if (fov < 10 || fov > 170) {
        // kernrw46: FOV rách (đọc kép 2/3 mẫu vẫn chọn nhầm khi cả 3 cùng hướng
        // rách) -> đọc lại POV 1 lần nữa TRƯỚC khi fail. 1 tick camFail = box
        // đứng yên grace 1.2s rồi ẩn ("đóng băng, phải xoay cam mới hồi").
        uint8_t rawR[0x38] = {0};
        if (ESPMemoryRead(vmMap, pov, rawR, sizeof(rawR))) {
            float fovR = 0, aspR = 0;
            memcpy(&fovR, rawR + ESPOff_POV_FOV, sizeof(fovR));
            if (fovR >= 10 && fovR <= 170) {
                memcpy(&loc, rawR + ESPOff_POV_Location, sizeof(loc));
                memcpy(&rot, rawR + ESPOff_POV_Rotation, sizeof(rot));
                memcpy(&fov, rawR + ESPOff_POV_FOV, sizeof(fov));
                memcpy(&aspR, rawR + ESPOff_POV_Aspect, sizeof(aspR));
                aspect = aspR;
            } else {
                return NO;
            }
        } else {
            return NO;
        }
    }
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

// MARK: - Xương / skeleton (port hướng QBL getBoneWithRotationFast)
//
// QBL: getBoneWithRotationFast(actor, boneIndex, FTransform) đọc transform
// xương trong SkeletalMeshComponent, nhân với ComponentToWorld rồi trả vị trí
// world — sau đó project ra màn hình và nối các khớp.
//
// DUMP/SDK xác nhận mảng xương nằm trong USkeletalMeshComponent:
//   0xCD0 CachedBoneSpaceTransforms / 0xCE0 CachedComponentSpaceTransforms.
// ComponentToWorld cũng đã xác nhận ở 0x208 (xem ESPOffsets.h). Engine vẫn
// validate runtime thay vì tin offset mù:
//   1. Thử 0xCE0 rồi 0xCD0 (offset từ DUMP), sau đó quét dải cũ
//      mesh+[0x480..0xC00) làm fallback nếu bản game sau dời field.
//   2. Với mỗi ứng viên, thử 3 bảng index khớp phổ biến (UE4 mannequin /
//      biến thể PUBG mobile) và VALIDATE bằng tỉ lệ cơ thể thật:
//      đầu > cổ > ngực > hông, tay 2 bên ngược hướng, độ dài từng đoạn tay/chân
//      trong khoảng người thật. Chỉ nhận khi TẤT CẢ điều kiện khớp.
//   3. Mỗi tick còn kiểm tra chéo: đầu phải nằm quanh mép trên box. Lệch liên
//      tục => tự tắt xương (tránh vẽ rác) + ghi log.
// Không dò được => xương tắt (các tính năng khác không bị ảnh hưởng).
// Muốn thêm bảng index cho bản game khác: thêm vào kESPBoneMaps bên dưới.

static std::atomic_int g_espBoneBadTicks{0};
static uint32_t g_espBoneOff = 0;      // offset TArray<FTransform> trong mesh
static int g_espBoneMap[ESPBone_Count] = {0};
static CFAbsoluteTime g_espBoneTryAt = 0;
static char g_espBoneStatus[64] = "bones off";
// qblpack 2026-10-21: 0xCD0/0xCE0 bị game xoá (Num=0). Dùng BoneSpaceTransforms
// (0xC98) rồi tự nhân theo ParentIndex của USkeleton.BoneTree — không cần GNames.
static std::atomic_bool g_espBoneComposed{false};

// Thứ tự slot: head, neck, chest, pelvis, LShoulder, LElbow, LHand,
// RShoulder, RElbow, RHand, LHip, LKnee, LFoot, RHip, RKnee, RFoot, Root.

// D = UE4 mannequin ĐỦ xương đòn (clavicle) — rig mặc định của PUBG mobile:
//   0 root, 1 pelvis, 2 spine_01, 3 spine_02, 4 spine_03, 5 neck_01, 6 head,
//   7 clavicle_l, 8 upperarm_l, 9 lowerarm_l, 10 hand_l,
//   11 clavicle_r, 12 upperarm_r, 13 lowerarm_r, 14 hand_r,
//   15 thigh_l, 16 calf_l, 17 foot_l, 18 ball_l,
//   19 thigh_r, 20 calf_r, 21 foot_r, 22 ball_r.
static const int kESPBoneMapD[ESPBone_Count] = {
    6, 5, 4, 1,
    8, 9, 10, 12, 13, 14,
    15, 16, 17, 19, 20, 21,
    0
};
// E = rig không có clavicle trong chuỗi tay (Upperarm 7, Lowerarm 8, Hand 9 / 11, 12, 13):
static const int kESPBoneMapE[ESPBone_Count] = {
    6, 5, 4, 1,
    7, 8, 9, 11, 12, 13,
    15, 16, 17, 19, 20, 21,
    0
};
// A = UE4 mannequin chuẩn (khớp public cho PUBG mobile):
static const int kESPBoneMapA[ESPBone_Count] = {
    6, 5, 4, 1,
    7, 8, 10, 11, 12, 14,
    15, 16, 17, 19, 20, 21,
    0
};
// B = rig có thêm 1 đốt spine (đầu 7, cổ 6, ngực 5) — vài bản skin/season:
static const int kESPBoneMapB[ESPBone_Count] = {
    7, 6, 5, 1,
    8, 9, 10, 12, 13, 14,
    15, 16, 17, 19, 20, 21,
    0
};
// C = rig có pelvis_01 (hông 2) + đốt spine phụ:
static const int kESPBoneMapC[ESPBone_Count] = {
    7, 6, 5, 2,
    8, 9, 10, 12, 13, 14,
    15, 16, 17, 18, 20, 21,
    1
};
// F = rig đầu 5, cổ 4, ngực 3:
static const int kESPBoneMapF[ESPBone_Count] = {
    5, 4, 3, 1,
    8, 9, 10, 12, 13, 14,
    15, 16, 17, 19, 20, 21,
    0
};
static const int *const kESPBoneMaps[] = {
    kESPBoneMapD, kESPBoneMapE, kESPBoneMapA, kESPBoneMapB, kESPBoneMapC, kESPBoneMapF
};
#define ESP_BONE_MAP_COUNT ((int)(sizeof(kESPBoneMaps) / sizeof(kESPBoneMaps[0])))

static inline BOOL ESPFiniteV(float f) { return f == f && fabsf(f) < 1e9f; }

// Đổi world => có thể đổi mode/rig: dò lại từ đầu (chỉ khi toggle đang bật).
static void ESPBonesReset(void) {
    g_espBonesReady.store(false);
    g_espBoneBadTicks.store(0);
    g_espBoneTryAt = 0;
    g_espBoneOff = 0;
    memset(g_espBoneMap, 0, sizeof(g_espBoneMap));
    g_espBoneComposed.store(false);
    snprintf(g_espBoneStatus, sizeof(g_espBoneStatus),
             g_espBonesWant.load() ? "bones detect" : "bones off");
}

// Khoảng cách 3D giữa 2 khớp (component space, cm).
static float ESPBoneDist(const ESPVector *p, int a, int b) {
    float dx = p[a].x - p[b].x, dy = p[a].y - p[b].y, dz = p[a].z - p[b].z;
    return sqrtf(dx*dx + dy*dy + dz*dz);
}

// Validate 1 bảng index trên vị trí component-space của các xương.
// whyOut (tuỳ chọn) nhận lý do fail để log chẩn đoán — không spam mỗi frame.
static BOOL ESPBoneMapValidateEx(const ESPVector *p, int count, const int *map,
                                 const char **whyOut) {
    if (whyOut) *whyOut = "args";
    if (!p || !map || count < 8) return NO;
    for (int i = 0; i < ESPBone_Count; i++) {
        if (map[i] < 0 || map[i] >= count) { if (whyOut) *whyOut = "index>=count"; return NO; }
    }
    const ESPVector &head = p[map[ESPBone_Head]];
    const ESPVector &neck = p[map[ESPBone_Neck]];
    const ESPVector &chest = p[map[ESPBone_Chest]];
    const ESPVector &pelvis = p[map[ESPBone_Pelvis]];
    // 1) Chuỗi thân thẳng đứng: đầu > cổ > ngực > hông, mỗi đoạn 3..60cm,
    //    đầu-hông 45..130cm (người 1m4..2m + sai số).
    float dHeadPelvis = ESPBoneDist(p, map[ESPBone_Head], map[ESPBone_Pelvis]);
    if (whyOut) *whyOut = "head-pelvis distance";
    if (dHeadPelvis < 40.0f || dHeadPelvis > 140.0f) return NO;
    if (whyOut) *whyOut = "spine z order";
    if (!(head.z > neck.z + 1.0f && neck.z > chest.z + 1.0f && chest.z > pelvis.z + 1.0f)) return NO;
    if (whyOut) *whyOut = "head-neck distance";
    if (ESPBoneDist(p, map[ESPBone_Head], map[ESPBone_Neck]) > 45.0f) return NO;
    // 2) Tay: vai gần ngực, vai-khuỷu và khuỷu-bàn tay 15..55cm.
    if (whyOut) *whyOut = "arm lengths";
    for (int side = 0; side < 2; side++) {
        int s = side ? ESPBone_RShoulder : ESPBone_LShoulder;
        int e = side ? ESPBone_RElbow : ESPBone_LElbow;
        int h = side ? ESPBone_RHand : ESPBone_LHand;
        if (ESPBoneDist(p, map[s], map[ESPBone_Chest]) > 55.0f) return NO;
        if (ESPBoneDist(p, map[s], map[e]) < 12.0f || ESPBoneDist(p, map[s], map[e]) > 55.0f) return NO;
        if (ESPBoneDist(p, map[e], map[h]) < 12.0f || ESPBoneDist(p, map[e], map[h]) > 55.0f) return NO;
    }
    // 3) Chân: hông sát hông, hông-gối và gối-bàn chân 20..75cm, bàn chân thấp
    //    hơn hông (trục Z hướng lên).
    if (whyOut) *whyOut = "leg lengths";
    for (int side = 0; side < 2; side++) {
        int hp = side ? ESPBone_RHip : ESPBone_LHip;
        int kn = side ? ESPBone_RKnee : ESPBone_LKnee;
        int ft = side ? ESPBone_RFoot : ESPBone_LFoot;
        if (ESPBoneDist(p, map[hp], map[ESPBone_Pelvis]) > 45.0f) return NO;
        if (ESPBoneDist(p, map[hp], map[kn]) < 20.0f || ESPBoneDist(p, map[hp], map[kn]) > 75.0f) return NO;
        if (ESPBoneDist(p, map[kn], map[ft]) < 20.0f || ESPBoneDist(p, map[kn], map[ft]) > 75.0f) return NO;
        if (!(p[map[ft]].z < p[map[kn]].z + 5.0f && p[map[kn]].z < p[map[hp]].z + 5.0f)) return NO;
    }
    // 4) 2 vai phải ở 2 phía ngực (tích vô hướng vector ngực->vai không dương).
    if (whyOut) *whyOut = "shoulder symmetry";
    {
        const ESPVector &c = p[map[ESPBone_Chest]];
        const ESPVector &l = p[map[ESPBone_LShoulder]];
        const ESPVector &r = p[map[ESPBone_RShoulder]];
        float ux = l.x - c.x, uy = l.y - c.y, uz = l.z - c.z;
        float vx = r.x - c.x, vy = r.y - c.y, vz = r.z - c.z;
        float ul = sqrtf(ux*ux + uy*uy + uz*uz);
        float vl = sqrtf(vx*vx + vy*vy + vz*vz);
        if (ul < 1.0f || vl < 1.0f) return NO;
        if ((ux*vx + uy*vy + uz*vz) / (ul * vl) > 0.35f) return NO;
        // 2 vai cách nhau 18..90cm (rộng vai người thật).
        float dx = l.x - r.x, dy = l.y - r.y, dz = l.z - r.z;
        float sep = sqrtf(dx*dx + dy*dy + dz*dz);
        if (sep < 18.0f || sep > 90.0f) return NO;
    }
    if (whyOut) *whyOut = "ok";
    return YES;
}

static BOOL ESPBoneMapValidate(const ESPVector *p, int count, const int *map) {
    return ESPBoneMapValidateEx(p, count, map, NULL);
}

// Đọc header TArray<FTransform> tại mesh+off. data/user-ptr + count 15..800.
static BOOL ESPBoneArrayAt(uint64_t vmMap, uint64_t mesh, uint32_t off,
                           uint64_t *outData, uint32_t *outCount) {
    uint8_t hdr[16];
    if (!ESPMemoryRead(vmMap, mesh + off, hdr, sizeof(hdr))) return NO;
    uint64_t d = 0;
    uint32_t c = 0;
    memcpy(&d, hdr, 8);
    memcpy(&c, hdr + 8, 4);
    if (!ESPIsUserPtr(d) || c < 15 || c > 800) return NO;
    if (outData) *outData = d;
    if (outCount) *outCount = c;
    return YES;
}

// Đọc translation (component space) của `count` FTransform đầu trong mảng.
// Chỉ cần >=15 khớp chính hợp lệ là pass; khớp phụ / NaN không làm rơi cả skeleton.
static BOOL ESPReadBoneLocals(uint64_t vmMap, uint64_t data, ESPVector *out, int count) {
    if (!out || count <= 0 || count > (int)ESPOff_Bone_NumMax) return NO;
    uint8_t buf[ESPOff_Bone_NumMax * ESPOff_BoneTransformSize];
    if (!ESPMemoryRead(vmMap, data, buf, (size_t)count * ESPOff_BoneTransformSize)) return NO;
    int validCount = 0;
    for (int i = 0; i < count; i++) {
        float x = 0, y = 0, z = 0;
        memcpy(&x, buf + (size_t)i * ESPOff_BoneTransformSize + ESPOff_Transform_Translation + 0, 4);
        memcpy(&y, buf + (size_t)i * ESPOff_BoneTransformSize + ESPOff_Transform_Translation + 4, 4);
        memcpy(&z, buf + (size_t)i * ESPOff_BoneTransformSize + ESPOff_Transform_Translation + 8, 4);
        if (!ESPFiniteV(x) || !ESPFiniteV(y) || !ESPFiniteV(z) ||
            fabsf(x) > 500.0f || fabsf(y) > 500.0f || fabsf(z) > 500.0f) {
            out[i] = (ESPVector){ NAN, NAN, NAN };
            continue;
        }
        out[i] = (ESPVector){ x, y, z };
        validCount++;
    }
    return validCount >= 15;
}

// --- qblpack 2026-10-21: bone-space -> component-space ---------------------
// 0xC98 = BoneSpaceTransforms (local so với parent). Game xoá 0xCD0/0xCE0
// (Cached*) nên phải tự nhân theo ParentIndex trong USkeleton.BoneTree.
// Không dùng FName => không phụ thuộc GNames đang chết trên build này.
typedef struct { float x, y, z, w; } ESPQuat;

static ESPQuat ESPQuatMul(ESPQuat a, ESPQuat b) {
    ESPQuat r;
    r.w = a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z;
    r.x = a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y;
    r.y = a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x;
    r.z = a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w;
    return r;
}

static ESPVector ESPQuatRotate(ESPQuat q, ESPVector v) {
    float cx = q.y*v.z - q.z*v.y;
    float cy = q.z*v.x - q.x*v.z;
    float cz = q.x*v.y - q.y*v.x;
    float ux = 2.0f * (cx + q.w*v.x);
    float uy = 2.0f * (cy + q.w*v.y);
    float uz = 2.0f * (cz + q.w*v.z);
    return (ESPVector){ v.x + (q.y*uz - q.z*uy),
                        v.y + (q.z*ux - q.x*uz),
                        v.z + (q.x*uy - q.y*ux) };
}

// out = a * b (UE FTransform::Multiply): rotation a*b, translation
// a.t + rotate(a.q, b.t * a.scale), scale a.scale*b.scale.
static void ESPTransformMul(const uint8_t *a, const uint8_t *b, uint8_t *out) {
    ESPQuat qa = {0, 0, 0, 1}, qb = {0, 0, 0, 1};
    ESPVector ta = {0, 0, 0}, tb = {0, 0, 0};
    ESPVector sa = {1, 1, 1}, sb = {1, 1, 1};
    memcpy(&qa, a + 0x00, sizeof(qa));
    memcpy(&qb, b + 0x00, sizeof(qb));
    memcpy(&ta, a + ESPOff_Transform_Translation, sizeof(ta));
    memcpy(&tb, b + ESPOff_Transform_Translation, sizeof(tb));
    memcpy(&sa, a + 0x20, sizeof(sa));
    memcpy(&sb, b + 0x20, sizeof(sb));
    if (!ESPFiniteV(qa.x) || !ESPFiniteV(qa.y) || !ESPFiniteV(qa.z) || !ESPFiniteV(qa.w)) qa = (ESPQuat){0,0,0,1};
    if (!ESPFiniteV(qb.x) || !ESPFiniteV(qb.y) || !ESPFiniteV(qb.z) || !ESPFiniteV(qb.w)) qb = (ESPQuat){0,0,0,1};
    if (!ESPFiniteV(sa.x) || sa.x < 0.01f || sa.x > 100.0f) sa.x = 1.0f;
    if (!ESPFiniteV(sa.y) || sa.y < 0.01f || sa.y > 100.0f) sa.y = 1.0f;
    if (!ESPFiniteV(sa.z) || sa.z < 0.01f || sa.z > 100.0f) sa.z = 1.0f;
    if (!ESPFiniteV(sb.x) || sb.x < 0.01f || sb.x > 100.0f) sb.x = 1.0f;
    if (!ESPFiniteV(sb.y) || sb.y < 0.01f || sb.y > 100.0f) sb.y = 1.0f;
    if (!ESPFiniteV(sb.z) || sb.z < 0.01f || sb.z > 100.0f) sb.z = 1.0f;
    ESPQuat q = ESPQuatMul(qa, qb);
    float qlen = sqrtf(q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w);
    if (qlen > 0.0001f && ESPFiniteV(qlen)) {
        q.x /= qlen; q.y /= qlen; q.z /= qlen; q.w /= qlen;
    } else {
        q = (ESPQuat){0, 0, 0, 1};
    }
    ESPVector st = { tb.x * sa.x, tb.y * sa.y, tb.z * sa.z };
    ESPVector rt = ESPQuatRotate(qa, st);
    ESPVector t = { ta.x + rt.x, ta.y + rt.y, ta.z + rt.z };
    ESPVector s = { sa.x * sb.x, sa.y * sb.y, sa.z * sb.z };
    memcpy(out + 0x00, &q, sizeof(q));
    memcpy(out + ESPOff_Transform_Translation, &t, sizeof(t));
    memcpy(out + 0x20, &s, sizeof(s));
}

// Đọc ParentIndex (int32 @ +8) của từng FBoneNode trong USkeleton.BoneTree.
// Thử vài offset BoneTree (DUMP 0x30 + ứng viên) và yêu cầu parent index luôn
// nhỏ hơn index con — đúng thứ tự DFS của FReferenceSkeleton, đồng thời loại
// offset trỏ vào rác.
static BOOL ESPBoneReadParents(uint64_t vmMap, uint64_t mesh, int *outParents,
                               uint32_t *outCount) {
    if (!vmMap || !ESPIsUserPtr(mesh) || !outParents || !outCount) return NO;
    uint64_t skelMesh = 0, skel = 0;
    if (!ESPMemoryRead(vmMap, mesh + ESPOff_Mesh_SkeletalMesh, &skelMesh, 8) ||
        !ESPIsUserPtr(skelMesh)) {
        static CFAbsoluteTime s_logAt = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - s_logAt > 10.0) {
            s_logAt = now;
            ESPLog("bones parents: no SkeletalMesh mesh=0x%llx", (unsigned long long)mesh);
        }
        return NO;
    }
    if (!ESPMemoryRead(vmMap, skelMesh + ESPOff_SkeletalMesh_Skeleton, &skel, 8) ||
        !ESPIsUserPtr(skel)) {
        static CFAbsoluteTime s_logAt2 = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - s_logAt2 > 10.0) {
            s_logAt2 = now;
            ESPLog("bones parents: no USkeleton skelMesh=0x%llx", (unsigned long long)skelMesh);
        }
        return NO;
    }
    static const uint32_t kTreeOffs[] = {
        ESPOff_Skeleton_BoneTree, 0x68, 0x78, 0x28
    };
    static thread_local uint8_t tree[ESPOff_Bone_NumMax * ESPOff_BoneNodeSize];
    for (size_t t = 0; t < sizeof(kTreeOffs) / sizeof(kTreeOffs[0]); t++) {
        uint8_t hdr[16];
        if (!ESPMemoryRead(vmMap, skel + kTreeOffs[t], hdr, sizeof(hdr))) continue;
        uint64_t data = 0;
        uint32_t count = 0, maxc = 0;
        memcpy(&data, hdr, 8);
        memcpy(&count, hdr + 8, 4);
        memcpy(&maxc, hdr + 12, 4);
        if (!ESPIsUserPtr(data) || count < 15 || count > (uint32_t)ESPOff_Bone_NumMax ||
            maxc < count) continue;
        if (!ESPMemoryRead(vmMap, data, tree, (size_t)count * ESPOff_BoneNodeSize)) continue;
        BOOL good = YES;
        for (uint32_t i = 0; i < count; i++) {
            int32_t p = -1;
            memcpy(&p, tree + (size_t)i * ESPOff_BoneNodeSize + 8, 4);
            // parent phải đứng trước con (hoặc -1 cho root); ngược lại là rác.
            if (p < -1 || p >= (int32_t)i) { good = NO; break; }
        }
        if (!good) continue;
        for (uint32_t i = 0; i < count; i++) {
            int32_t p = -1;
            memcpy(&p, tree + (size_t)i * ESPOff_BoneNodeSize + 8, 4);
            outParents[i] = (int)p;
        }
        *outCount = count;
        return YES;
    }
    return NO;
}

// Nhân dồn `local` (bone space, n FTransform) theo parents -> component space.
// Tách riêng để dùng chung cho BoneSpaceTransforms (0xC98) và RefLocalPoses
// của USkeleton (ref pose) — hai mảng cùng layout, cùng cách compose.
static BOOL ESPBoneComposeTransforms(const uint8_t *local, int n, const int *parents,
                                     ESPVector *outPts, const char **whyOut) {
    if (whyOut) *whyOut = "args";
    if (!local || !parents || !outPts || n < 15 || n > (int)ESPOff_Bone_NumMax) return NO;
    static thread_local uint8_t comp[ESPOff_Bone_NumMax * ESPOff_BoneTransformSize];
    uint8_t done[ESPOff_Bone_NumMax] = {0};
    // BoneTree thường đã theo thứ tự parent trước con, nhưng lặp nhiều pass để
    // chịu được rig có thứ tự lạ; không tiến bộ => cycle/layout sai.
    int remaining = n;
    for (int pass = 0; pass < n && remaining > 0; pass++) {
        BOOL progressed = NO;
        for (int i = 0; i < n; i++) {
            if (done[i]) continue;
            int p = parents[i];
            if (p >= n) {
                if (whyOut) *whyOut = "parent index";
                return NO;
            }
            if (p >= 0 && !done[p]) continue;
            uint8_t *dst = comp + (size_t)i * ESPOff_BoneTransformSize;
            const uint8_t *src = local + (size_t)i * ESPOff_BoneTransformSize;
            if (p < 0) {
                memcpy(dst, src, ESPOff_BoneTransformSize);
            } else {
                ESPTransformMul(comp + (size_t)p * ESPOff_BoneTransformSize, src, dst);
            }
            done[i] = 1;
            remaining--;
            progressed = YES;
        }
        if (!progressed) {
            if (whyOut) *whyOut = "parent cycle";
            return NO;
        }
    }
    if (remaining != 0) {
        if (whyOut) *whyOut = "parent order";
        return NO;
    }
    for (int i = 0; i < n; i++) {
        float x = 0, y = 0, z = 0;
        const uint8_t *t = comp + (size_t)i * ESPOff_BoneTransformSize + ESPOff_Transform_Translation;
        memcpy(&x, t + 0, 4);
        memcpy(&y, t + 4, 4);
        memcpy(&z, t + 8, 4);
        // Một xương phụ (vũ khí/IK) xa hoặc NaN không được làm rơi cả skeleton:
        // đánh dấu NaN, validator chỉ xét 17 khớp đã map nên vẫn nhận được.
        if (!ESPFiniteV(x) || !ESPFiniteV(y) || !ESPFiniteV(z) ||
            fabsf(x) > 400.0f || fabsf(y) > 400.0f || fabsf(z) > 400.0f) {
            outPts[i] = (ESPVector){ NAN, NAN, NAN };
            continue;
        }
        outPts[i] = (ESPVector){ x, y, z };
    }
    if (whyOut) *whyOut = "ok";
    return YES;
}

// Đọc BoneSpaceTransforms @0xC98 và nhân dồn theo parent để ra component space.
static BOOL ESPBoneComposeAt(uint64_t vmMap, uint64_t mesh, ESPVector *outPts,
                             int *outCount, const char **whyOut) {
    if (whyOut) *whyOut = "args";
    if (!outPts || !outCount) return NO;
    uint64_t data = 0;
    uint32_t count = 0;
    if (!ESPBoneArrayAt(vmMap, mesh, ESPOff_Mesh_BoneSpaceTransforms, &data, &count)) {
        if (whyOut) *whyOut = "0xc98 header";
        return NO;
    }
    int parents[ESPOff_Bone_NumMax];
    uint32_t treeCount = 0;
    if (!ESPBoneReadParents(vmMap, mesh, parents, &treeCount)) {
        if (whyOut) *whyOut = "BoneTree/parents";
        return NO;
    }
    uint32_t n = (count < treeCount) ? count : treeCount;
    if (n < 15 || n > (uint32_t)ESPOff_Bone_NumMax) {
        if (whyOut) *whyOut = "bone count";
        return NO;
    }
    static thread_local uint8_t local[ESPOff_Bone_NumMax * ESPOff_BoneTransformSize];
    if (!ESPMemoryRead(vmMap, data, local, (size_t)n * ESPOff_BoneTransformSize)) {
        if (whyOut) *whyOut = "read 0xc98 data";
        return NO;
    }
    if (!ESPBoneComposeTransforms(local, (int)n, parents, outPts, whyOut)) return NO;
    *outCount = (int)n;
    if (whyOut) *whyOut = "ok";
    return YES;
}

// Ref pose (USkeleton.RefLocalPoses) đã compose -> component space.
// Vì sao không dùng component space live để dò bảng: người chơi có thể đang
// nằm/ngồi/leo, hình học biến dạng làm mốc "đầu cao nhất / chân thấp nhất" sai.
// Ref pose là T/A-pose cố định của rig nên dò 1 lần là đúng mãi.
static BOOL ESPBoneReadRefPose(uint64_t vmMap, uint64_t mesh, const int *parents,
                               int parentCount, ESPVector *outPts, int *outCount) {
    if (!vmMap || !ESPIsUserPtr(mesh) || !parents || !outPts || parentCount < 18) return NO;
    uint64_t skelMesh = 0, skel = 0;
    if (!ESPMemoryRead(vmMap, mesh + ESPOff_Mesh_SkeletalMesh, &skelMesh, 8) ||
        !ESPIsUserPtr(skelMesh)) return NO;
    if (!ESPMemoryRead(vmMap, skelMesh + ESPOff_SkeletalMesh_Skeleton, &skel, 8) ||
        !ESPIsUserPtr(skel)) return NO;
    uint64_t data = 0;
    uint32_t count = 0;
    if (!ESPBoneArrayAt(vmMap, skel, ESPOff_Skeleton_RefLocalPoses, &data, &count)) return NO;
    int n = (count < (uint32_t)parentCount) ? (int)count : parentCount;
    if (n < 18 || n > (int)ESPOff_Bone_NumMax) return NO;
    static thread_local uint8_t local[ESPOff_Bone_NumMax * ESPOff_BoneTransformSize];
    if (!ESPMemoryRead(vmMap, data, local, (size_t)n * ESPOff_BoneTransformSize)) return NO;
    const char *why = NULL;
    if (!ESPBoneComposeTransforms(local, n, parents, outPts, &why)) return NO;
    if (outCount) *outCount = n;
    return YES;
}

// Dựng bảng index 17 khớp từ ref pose — KHÔNG cần GNames, không phụ thuộc
// thứ tự xương hard-code. Đây là đường chính khi rig khác 4 bảng có sẵn.
static BOOL ESPBoneAutoMapForMesh(uint64_t vmMap, uint64_t mesh,
                                  int outMap[ESPBone_Count], int *outCount,
                                  char *why, size_t whyCap) {
    if (why && whyCap) why[0] = '\0';
    if (!outMap) return NO;
    if (outCount) *outCount = 0;
    int parents[ESPOff_Bone_NumMax];
    uint32_t treeCount = 0;
    if (!ESPBoneReadParents(vmMap, mesh, parents, &treeCount)) {
        if (why && whyCap) snprintf(why, whyCap, "parents");
        return NO;
    }
    static thread_local ESPVector refPts[ESPOff_Bone_NumMax];
    int n = 0;
    if (!ESPBoneReadRefPose(vmMap, mesh, parents, (int)treeCount, refPts, &n) || n < 18) {
        if (why && whyCap) snprintf(why, whyCap, "ref pose");
        return NO;
    }
    if (!ESPBoneMapBuild(refPts, n, parents, outMap, why, (int)whyCap)) return NO;
    if (outCount) *outCount = n; // số xương của skeleton: chỉ áp map cho mảng cùng cỡ
    return YES;
}

// Validator "lỏng" cho bảng tự dò: chỉ kiểm tra index + ĐỘ DÀI xương, không
// kiểm tra thứ tự Z (người đang nằm/bò làm đầu thấp hơn hông — vẫn đúng
// skeleton). Nhờ vậy auto-map không bị loại oan theo pose hiện tại.
static BOOL ESPBoneMapPlausible(const ESPVector *p, int n, const int *map,
                                const char **whyOut) {
    if (whyOut) *whyOut = "args";
    if (!p || !map || n < 18) return NO;
    for (int i = 0; i < ESPBone_Count; i++) {
        if (map[i] < 0 || map[i] >= n) { if (whyOut) *whyOut = "index"; return NO; }
        if (!ESPFiniteV(p[map[i]].x) || !ESPFiniteV(p[map[i]].y) ||
            !ESPFiniteV(p[map[i]].z)) { if (whyOut) *whyOut = "nan"; return NO; }
        if (i == ESPBone_Root) continue;
        for (int j = i + 1; j < ESPBone_Count; j++) {
            if (j == ESPBone_Root) continue;
            if (map[i] == map[j]) { if (whyOut) *whyOut = "duplicate"; return NO; }
        }
    }
    float hp = ESPBoneDist(p, map[ESPBone_Head], map[ESPBone_Pelvis]);
    if (hp < 40.0f || hp > 150.0f) { if (whyOut) *whyOut = "head-pelvis"; return NO; }
    if (ESPBoneDist(p, map[ESPBone_Head], map[ESPBone_Neck]) > 50.0f) {
        if (whyOut) *whyOut = "head-neck"; return NO;
    }
    for (int side = 0; side < 2; side++) {
        int sh = side ? ESPBone_RShoulder : ESPBone_LShoulder;
        int el = side ? ESPBone_RElbow : ESPBone_LElbow;
        int hd = side ? ESPBone_RHand : ESPBone_LHand;
        if (ESPBoneDist(p, map[sh], map[ESPBone_Chest]) > 65.0f) {
            if (whyOut) *whyOut = "shoulder"; return NO;
        }
        if (ESPBoneDist(p, map[sh], map[el]) > 60.0f) {
            if (whyOut) *whyOut = "upper arm"; return NO;
        }
        if (ESPBoneDist(p, map[el], map[hd]) > 60.0f) {
            if (whyOut) *whyOut = "forearm"; return NO;
        }
    }
    for (int side = 0; side < 2; side++) {
        int hpj = side ? ESPBone_RHip : ESPBone_LHip;
        int kn = side ? ESPBone_RKnee : ESPBone_LKnee;
        int ft = side ? ESPBone_RFoot : ESPBone_LFoot;
        if (ESPBoneDist(p, map[hpj], map[ESPBone_Pelvis]) > 45.0f) {
            if (whyOut) *whyOut = "hip"; return NO;
        }
        if (ESPBoneDist(p, map[hpj], map[kn]) < 10.0f ||
            ESPBoneDist(p, map[hpj], map[kn]) > 85.0f) {
            if (whyOut) *whyOut = "thigh"; return NO;
        }
        if (ESPBoneDist(p, map[kn], map[ft]) < 10.0f ||
            ESPBoneDist(p, map[kn], map[ft]) > 85.0f) {
            if (whyOut) *whyOut = "calf"; return NO;
        }
    }
    // Đối xứng trái/phải: xương cùng tên ở 2 bên phải dài gần bằng nhau ở MỌI
    // pose (độ dài xương không đổi) -> chặn nhận nhầm mảng rác.
    {
        struct { int a1, b1, a2, b2; const char *why; } sym[] = {
            { ESPBone_LShoulder, ESPBone_LElbow, ESPBone_RShoulder, ESPBone_RElbow, "arm sym" },
            { ESPBone_LElbow, ESPBone_LHand, ESPBone_RElbow, ESPBone_RHand, "forearm sym" },
            { ESPBone_LHip, ESPBone_LKnee, ESPBone_RHip, ESPBone_RKnee, "thigh sym" },
            { ESPBone_LKnee, ESPBone_LFoot, ESPBone_RKnee, ESPBone_RFoot, "calf sym" },
            { ESPBone_Chest, ESPBone_LShoulder, ESPBone_Chest, ESPBone_RShoulder, "shoulder sym" },
        };
        for (size_t s = 0; s < sizeof(sym) / sizeof(sym[0]); s++) {
            float d1 = ESPBoneDist(p, map[sym[s].a1], map[sym[s].b1]);
            float d2 = ESPBoneDist(p, map[sym[s].a2], map[sym[s].b2]);
            float mx = fmaxf(d1, d2);
            if (mx > 1.0f && fabsf(d1 - d2) > 0.40f * mx) {
                if (whyOut) *whyOut = sym[s].why;
                return NO;
            }
        }
        if (ESPBoneDist(p, map[ESPBone_LHip], map[ESPBone_RHip]) < 5.0f) {
            if (whyOut) *whyOut = "hip separation";
            return NO;
        }
    }
    if (whyOut) *whyOut = "ok";
    return YES;
}

// Thử nhận 0xC98 (đã compose) với bảng tên / bảng tự dò / bảng index. Chỉ nhận
// khi hình học qua validator — sai offset/layout thì fail, không vẽ rác.
static BOOL ESPBoneTryComposedLocked(uint64_t vmMap, uint64_t mesh,
                                     const int *nameMap, const int *autoMap,
                                     int autoCount, ESPVector *pts) {
    if (!vmMap || !ESPIsUserPtr(mesh) || !pts) return NO;
    int n = 0;
    const char *why = NULL;
    if (!ESPBoneComposeAt(vmMap, mesh, pts, &n, &why)) {
        static CFAbsoluteTime s_logAt = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - s_logAt > 10.0) {
            s_logAt = now;
            ESPLog("bones compose: 0xc98 fail (%s) mesh=0x%llx",
                   why ? why : "-", (unsigned long long)mesh);
        }
        return NO;
    }
    if (nameMap) {
        int need = 0;
        for (int i = 0; i < ESPBone_Count; i++) {
            if (nameMap[i] + 1 > need) need = nameMap[i] + 1;
        }
        const char *whyMap = NULL;
        if (need > 0 && need <= n && ESPBoneMapValidateEx(pts, n, nameMap, &whyMap)) {
            g_espBoneOff = ESPOff_Mesh_BoneSpaceTransforms;
            g_espBoneComposed.store(true);
            memcpy(g_espBoneMap, nameMap, sizeof(g_espBoneMap));
            g_espBoneBadTicks.store(0);
            g_espBonesReady.store(true);
            snprintf(g_espBoneStatus, sizeof(g_espBoneStatus), "bones 0xc98 name ok");
            ESPLog("bones: offset=0xc98 COMPOSED NAME-MAP ok bones=%d", n);
            return YES;
        }
    }
    // qblpack: bảng tự dò từ ref pose — không cần GNames, không phụ thuộc thứ
    // tự xương hard-code. Đây là đường cứu rig PUBG đổi clavicle/spine.
    // Chỉ áp bảng tự dò khi số xương khớp ĐÚNG skeleton đã dò: mảng compact
    // (RequiredBones) có thứ tự khác, áp index full-skeleton vào sẽ lệch khớp.
    if (autoMap && autoCount > 0 && n == autoCount) {
        const char *whyAuto = NULL;
        if (ESPBoneMapPlausible(pts, n, autoMap, &whyAuto)) {
            g_espBoneOff = ESPOff_Mesh_BoneSpaceTransforms;
            g_espBoneComposed.store(true);
            memcpy(g_espBoneMap, autoMap, sizeof(g_espBoneMap));
            g_espBoneBadTicks.store(0);
            g_espBonesReady.store(true);
            snprintf(g_espBoneStatus, sizeof(g_espBoneStatus), "bones 0xc98 auto ok");
            ESPLog("bones: offset=0xc98 AUTO-MAP ok bones=%d head=%d neck=%d chest=%d "
                   "pelvis=%d Lsh=%d Lel=%d Rsh=%d Rel=%d Lhp=%d Lkn=%d Rhp=%d Rkn=%d",
                   n, autoMap[ESPBone_Head], autoMap[ESPBone_Neck],
                   autoMap[ESPBone_Chest], autoMap[ESPBone_Pelvis],
                   autoMap[ESPBone_LShoulder], autoMap[ESPBone_LElbow],
                   autoMap[ESPBone_RShoulder], autoMap[ESPBone_RElbow],
                   autoMap[ESPBone_LHip], autoMap[ESPBone_LKnee],
                   autoMap[ESPBone_RHip], autoMap[ESPBone_RKnee]);
            return YES;
        }
        static CFAbsoluteTime s_autoLogAt = 0;
        CFAbsoluteTime nowA = CFAbsoluteTimeGetCurrent();
        if (nowA - s_autoLogAt > 10.0) {
            s_autoLogAt = nowA;
            ESPLog("bones compose: 0xc98 auto-map fail (%s) n=%d",
                   whyAuto ? whyAuto : "-", n);
        }
    }
    for (int m = 0; m < ESP_BONE_MAP_COUNT; m++) {
        const int *mMap = kESPBoneMaps[m];
        int need = 0;
        for (int i = 0; i < ESPBone_Count; i++) {
            if (mMap[i] + 1 > need) need = mMap[i] + 1;
        }
        if (need > n) continue;
        if (ESPBoneMapValidateEx(pts, n, mMap, NULL) ||
            ESPBoneMapPlausible(pts, n, mMap, NULL)) {
            g_espBoneOff = ESPOff_Mesh_BoneSpaceTransforms;
            g_espBoneComposed.store(true);
            memcpy(g_espBoneMap, mMap, sizeof(g_espBoneMap));
            g_espBoneBadTicks.store(0);
            g_espBonesReady.store(true);
            snprintf(g_espBoneStatus, sizeof(g_espBoneStatus), "bones 0xc98 map%d ok", m);
            ESPLog("bones: offset=0xc98 COMPOSED map=%d bones=%d (auto-detect)", m, n);
            return YES;
        }
    }
    return NO;
}

// ---------------------------------------------------------------------------
// qblpack: dò TÊN xương từ USkeleton thay vì chỉ hard-code index.
// PUBG đổi rig/season làm index lệch, nhưng tên xương ("head", "pelvis",
// "upperarm_l"...) ổn định. BoneTree là mảng ref-skeleton, cùng thứ tự với
// CachedComponentSpaceTransforms của mesh full-body. Validate hình học xong
// mới nhận; fail thì caller fallback 3 bảng index cũ.
// ---------------------------------------------------------------------------

static void ESPBoneLowerCopy(char *dst, size_t cap, const char *src) {
    if (!dst || cap == 0) return;
    size_t i = 0;
    for (; src && src[i] && i + 1 < cap; i++) {
        unsigned char c = (unsigned char)src[i];
        dst[i] = (char)((c >= 'A' && c <= 'Z') ? (c - 'A' + 'a') : c);
    }
    dst[i] = '\0';
}

// 1 = trái, 2 = phải, 0 = không rõ. Hỗ trợ "_l", ".l", "left", "l_",
// "bip01 l upperarm" (space token) và hậu tố "... l".
static int ESPBoneNameSide(const char *n) {
    if (!n || !n[0]) return 0;
    if (strstr(n, "_l") || strstr(n, ".l") || strstr(n, "_left") ||
        strstr(n, "left") || strstr(n, " l") || strncmp(n, "l_", 2) == 0 ||
        strncmp(n, "l ", 2) == 0) return 1;
    if (strstr(n, "_r") || strstr(n, ".r") || strstr(n, "_right") ||
        strstr(n, "right") || strstr(n, " r") || strncmp(n, "r_", 2) == 0 ||
        strncmp(n, "r ", 2) == 0) return 2;
    return 0;
}

// Điểm khớp theo tên (đã lowercase). 0 = không phải khớp này.
// Điểm càng cao càng khớp: 100 = tên chuẩn UE4, 60 = biến thể, 40 = dự phòng.
static int ESPBoneNameScore(const char *n, int slot) {
    if (!n || !n[0]) return 0;
    // Bone phụ/đồ trang bị — bỏ để không bắt nhầm (twist, finger, weapon...).
    static const char *const kSkip[] = {
        "twist", "roll", "ik", "socket", "weapon", "attach", "camera",
        "spring", "muzzle", "backpack", "vest", "helmet", "hair", "cloth",
        "skirt", "ball", "toe", "finger", "thumb", "index", "middle",
        "ring", "pinky", "eye", "jaw", "breast", "ponytail", "beard",
        "mask", "glass", "hat", "bag", "footstep", "root_motion"
    };
    for (size_t i = 0; i < sizeof(kSkip) / sizeof(kSkip[0]); i++) {
        if (strstr(n, kSkip[i])) return 0;
    }
    int side = ESPBoneNameSide(n);
    int want = 0;
    if (slot == ESPBone_LShoulder || slot == ESPBone_LElbow || slot == ESPBone_LHand ||
        slot == ESPBone_LHip || slot == ESPBone_LKnee || slot == ESPBone_LFoot) want = 1;
    if (slot == ESPBone_RShoulder || slot == ESPBone_RElbow || slot == ESPBone_RHand ||
        slot == ESPBone_RHip || slot == ESPBone_RKnee || slot == ESPBone_RFoot) want = 2;
    if (want) {
        if (side != want) return 0;
    } else if (side) {
        return 0; // head/neck/spine/pelvis không được có hậu tố trái/phải
    }
    switch (slot) {
        case ESPBone_Head:
            if (!strcmp(n, "head") || !strcmp(n, "head_01") || !strcmp(n, "head1")) return 100;
            if (!strcmp(n, "bip01 head")) return 90;
            if (strstr(n, "head")) return 40;
            break;
        case ESPBone_Neck:
            if (!strcmp(n, "neck") || !strcmp(n, "neck_01") || !strcmp(n, "neck1")) return 100;
            if (strstr(n, "neck")) return 50;
            break;
        case ESPBone_Chest:
            if (!strcmp(n, "spine_03") || !strcmp(n, "spine3") || !strcmp(n, "spine_03_01")) return 100;
            if (!strcmp(n, "spine_02") || !strcmp(n, "spine2")) return 80;
            if (!strcmp(n, "spine_01") || !strcmp(n, "spine1") || !strcmp(n, "spine")) return 60;
            if (strstr(n, "spine")) return 30;
            break;
        case ESPBone_Pelvis:
            if (!strcmp(n, "pelvis") || !strcmp(n, "pelvis_01") ||
                !strcmp(n, "hips") || !strcmp(n, "hip")) return 100;
            if (strstr(n, "pelvis")) return 60;
            break;
        case ESPBone_LShoulder:
            if (!strcmp(n, "upperarm_l") || !strcmp(n, "upper_arm_l") ||
                !strcmp(n, "arm_l") || !strcmp(n, "l_upperarm")) return 100;
            if (strstr(n, "upperarm") || strstr(n, "upper_arm") || strstr(n, " arm")) return 60;
            if (strstr(n, "clavicle") || strstr(n, "collar")) return 40;
            break;
        case ESPBone_LElbow:
            if (!strcmp(n, "lowerarm_l") || !strcmp(n, "lower_arm_l") ||
                !strcmp(n, "forearm_l") || !strcmp(n, "l_forearm")) return 100;
            if (strstr(n, "lowerarm") || strstr(n, "lower_arm") || strstr(n, "forearm")) return 60;
            break;
        case ESPBone_LHand:
            if (!strcmp(n, "hand_l") || !strcmp(n, "l_hand")) return 100;
            if (strstr(n, "hand")) return 40;
            break;
        case ESPBone_RShoulder:
            if (!strcmp(n, "upperarm_r") || !strcmp(n, "upper_arm_r") ||
                !strcmp(n, "arm_r") || !strcmp(n, "r_upperarm")) return 100;
            if (strstr(n, "upperarm") || strstr(n, "upper_arm") || strstr(n, " arm")) return 60;
            if (strstr(n, "clavicle") || strstr(n, "collar")) return 40;
            break;
        case ESPBone_RElbow:
            if (!strcmp(n, "lowerarm_r") || !strcmp(n, "lower_arm_r") ||
                !strcmp(n, "forearm_r") || !strcmp(n, "r_forearm")) return 100;
            if (strstr(n, "lowerarm") || strstr(n, "lower_arm") || strstr(n, "forearm")) return 60;
            break;
        case ESPBone_RHand:
            if (!strcmp(n, "hand_r") || !strcmp(n, "r_hand")) return 100;
            if (strstr(n, "hand")) return 40;
            break;
        case ESPBone_LHip:
            if (!strcmp(n, "thigh_l") || !strcmp(n, "upperleg_l") || !strcmp(n, "leg_l")) return 100;
            if (strstr(n, "thigh") || strstr(n, "upperleg")) return 60;
            break;
        case ESPBone_LKnee:
            if (!strcmp(n, "calf_l") || !strcmp(n, "lowerleg_l") || !strcmp(n, "shin_l")) return 100;
            if (strstr(n, "calf") || strstr(n, "shin") || strstr(n, "lowerleg")) return 60;
            break;
        case ESPBone_LFoot:
            if (!strcmp(n, "foot_l") || !strcmp(n, "l_foot")) return 100;
            if (strstr(n, "foot")) return 40;
            break;
        case ESPBone_RHip:
            if (!strcmp(n, "thigh_r") || !strcmp(n, "upperleg_r") || !strcmp(n, "leg_r")) return 100;
            if (strstr(n, "thigh") || strstr(n, "upperleg")) return 60;
            break;
        case ESPBone_RKnee:
            if (!strcmp(n, "calf_r") || !strcmp(n, "lowerleg_r") || !strcmp(n, "shin_r")) return 100;
            if (strstr(n, "calf") || strstr(n, "shin") || strstr(n, "lowerleg")) return 60;
            break;
        case ESPBone_RFoot:
            if (!strcmp(n, "foot_r") || !strcmp(n, "r_foot")) return 100;
            if (strstr(n, "foot")) return 40;
            break;
        case ESPBone_Root:
            if (!strcmp(n, "root") || !strcmp(n, "root_01") || !strcmp(n, "bip01")) return 100;
            break;
        default:
            break;
    }
    return 0;
}

// Đọc BoneTree của USkeleton và trả bảng index theo tên. NO nếu không đủ khớp.
static BOOL ESPBoneSkeletonMap(uint64_t vmMap, uint64_t gameBase, uint64_t mesh,
                               int outMap[ESPBone_Count]) {
    if (!outMap || !vmMap || !ESPIsUserPtr(mesh)) return NO;
    if (!ESPUNameReady(gameBase) || !gameBase) return NO;
    uint64_t uname = ESPResolveUName(vmMap, gameBase);
    if (!uname) return NO;
    uint64_t skelMesh = 0;
    if (!ESPMemoryRead(vmMap, mesh + ESPOff_Mesh_SkeletalMesh, &skelMesh, 8) ||
        !ESPIsUserPtr(skelMesh)) {
        static CFAbsoluteTime s_logAt = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - s_logAt > 10.0) { s_logAt = now; ESPLog("bones names: no SkeletalMesh (mesh=0x%llx)", (unsigned long long)mesh); }
        return NO;
    }
    uint64_t skel = 0;
    if (!ESPMemoryRead(vmMap, skelMesh + ESPOff_SkeletalMesh_Skeleton, &skel, 8) ||
        !ESPIsUserPtr(skel)) {
        static CFAbsoluteTime s_logAt2 = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - s_logAt2 > 10.0) { s_logAt2 = now; ESPLog("bones names: no USkeleton (skelMesh=0x%llx)", (unsigned long long)skelMesh); }
        return NO;
    }
    // Offset BoneTree: DUMP 0x30; thêm vài ứng viên phòng bản game đổi layout.
    static const uint32_t kTreeOffs[] = {
        ESPOff_Skeleton_BoneTree, 0x68, 0x78, 0x28
    };
    for (size_t t = 0; t < sizeof(kTreeOffs) / sizeof(kTreeOffs[0]); t++) {
        uint32_t off = kTreeOffs[t];
        uint8_t hdr[16];
        if (!ESPMemoryRead(vmMap, skel + off, hdr, sizeof(hdr))) continue;
        uint64_t data = 0;
        uint32_t count = 0, maxc = 0;
        memcpy(&data, hdr, 8);
        memcpy(&count, hdr + 8, 4);
        memcpy(&maxc, hdr + 12, 4);
        if (!ESPIsUserPtr(data) || count < 20 || count > 2000 || maxc < count) continue;
        uint32_t limit = count < 512 ? count : 512;
        static uint8_t tree[512 * ESPOff_BoneNodeSize];
        if (!ESPMemoryRead(vmMap, data, tree, (size_t)limit * ESPOff_BoneNodeSize)) continue;

        int best[ESPBone_Count];
        int bestScore[ESPBone_Count];
        for (int i = 0; i < ESPBone_Count; i++) { best[i] = -1; bestScore[i] = 0; }
        int resolved = 0;
        for (uint32_t i = 0; i < limit; i++) {
            uint32_t fid = 0;
            memcpy(&fid, tree + (size_t)i * ESPOff_BoneNodeSize, 4);
            if (!fid || fid >= 2000000) continue;
            char raw[96] = {0};
            if (!ESPActorNameByID(vmMap, uname, fid, raw)) continue;
            resolved++;
            char nm[96];
            ESPBoneLowerCopy(nm, sizeof(nm), raw);
            for (int slot = 0; slot < ESPBone_Count; slot++) {
                int sc = ESPBoneNameScore(nm, slot);
                if (sc > bestScore[slot]) { bestScore[slot] = sc; best[slot] = (int)i; }
            }
            // Đủ joint chính với tên chuẩn -> không cần đọc tiếp 500 bone.
            BOOL all = YES;
            for (int slot = 0; slot < ESPBone_Count; slot++) {
                if (slot == ESPBone_Root) continue;
                if (bestScore[slot] < 90) { all = NO; break; }
            }
            if (all) break;
        }
        int missing = 0;
        for (int slot = 0; slot < ESPBone_Count; slot++) {
            if (slot == ESPBone_Root) continue;
            if (best[slot] < 0) missing++;
        }
        if (missing || resolved < 8) continue;
        if (best[ESPBone_Root] < 0) best[ESPBone_Root] = 0;
        memcpy(outMap, best, sizeof(best));
        ESPLog("bones names: tree=0x%x bones=%u resolved=%d head=%d neck=%d chest=%d pelvis=%d "
               "Lsh=%d Lel=%d Lhd=%d Rsh=%d Rel=%d Rhd=%d Lhp=%d Lkn=%d Lft=%d Rhp=%d Rkn=%d Rft=%d",
               (unsigned)off, (unsigned)count, resolved,
               best[ESPBone_Head], best[ESPBone_Neck], best[ESPBone_Chest], best[ESPBone_Pelvis],
               best[ESPBone_LShoulder], best[ESPBone_LElbow], best[ESPBone_LHand],
               best[ESPBone_RShoulder], best[ESPBone_RElbow], best[ESPBone_RHand],
               best[ESPBone_LHip], best[ESPBone_LKnee], best[ESPBone_LFoot],
               best[ESPBone_RHip], best[ESPBone_RKnee], best[ESPBone_RFoot]);
        return YES;
    }
    return NO;
}

// Dò (offset mảng xương, bảng index) trên 1 mesh player thật. Throttle 2s/lần.
// Mutex riêng: configure chạy từ queue scan nền, sample chạy từ tick 60Hz —
// mutex chỉ nhận ở đường configure (hiếm), reader chỉ snapshot (xem ESPBonesSample).
static std::mutex g_espBoneCfgMutex;
// Thử 1 offset: đọc TArray<FTransform>, validate 3 bảng index cũ + bảng tên
// xương (nếu có), nhận nếu khớp. Caller đã giữ g_espBoneCfgMutex.
static BOOL ESPBoneTryOffsetLocked(uint64_t vmMap, uint64_t mesh, uint32_t off,
                                   const int *nameMap, const int *autoMap,
                                   int autoCount, ESPVector *pts) {
    uint64_t data = 0;
    uint32_t count = 0;
    if (!ESPBoneArrayAt(vmMap, mesh, off, &data, &count)) return NO;
    int n = (int)(count < (uint32_t)ESPOff_Bone_NumMax ? count : (uint32_t)ESPOff_Bone_NumMax);
    if (n < 15) return NO;
    if (!ESPReadBoneLocals(vmMap, data, pts, n)) return NO;

    if (nameMap) {
        int need = 0;
        for (int i = 0; i < ESPBone_Count; i++) {
            if (nameMap[i] + 1 > need) need = nameMap[i] + 1;
        }
        if (need > 0 && need <= (int)count &&
            (ESPBoneMapValidateEx(pts, need, nameMap, NULL) ||
             ESPBoneMapPlausible(pts, need, nameMap, NULL))) {
            g_espBoneOff = off;
            g_espBoneComposed.store(false);
            memcpy(g_espBoneMap, nameMap, sizeof(g_espBoneMap));
            g_espBoneBadTicks.store(0);
            g_espBonesReady.store(true);
            snprintf(g_espBoneStatus, sizeof(g_espBoneStatus), "bones name 0x%x ok", (unsigned)off);
            ESPLog("bones: offset=0x%x NAME-MAP ok bones=%u need=%d", (unsigned)off, (unsigned)count, need);
            return YES;
        }
    }

    if (autoMap) {
        int need = 0;
        for (int i = 0; i < ESPBone_Count; i++) {
            if (autoMap[i] + 1 > need) need = autoMap[i] + 1;
        }
        if (need > 0 && need <= (int)count &&
            (ESPBoneMapPlausible(pts, need, autoMap, NULL) ||
             ESPBoneMapValidateEx(pts, need, autoMap, NULL))) {
            g_espBoneOff = off;
            g_espBoneComposed.store(false);
            memcpy(g_espBoneMap, autoMap, sizeof(g_espBoneMap));
            g_espBoneBadTicks.store(0);
            g_espBonesReady.store(true);
            snprintf(g_espBoneStatus, sizeof(g_espBoneStatus), "bones 0x%x auto ok", (unsigned)off);
            ESPLog("bones: offset=0x%x AUTO-MAP ok bones=%u need=%d",
                   (unsigned)off, (unsigned)count, need);
            return YES;
        }
    }

    for (int m = 0; m < ESP_BONE_MAP_COUNT; m++) {
        const int *mMap = kESPBoneMaps[m];
        int need = 0;
        for (int i = 0; i < ESPBone_Count; i++) {
            if (mMap[i] + 1 > need) need = mMap[i] + 1;
        }
        if (need > (int)count) continue;
        if (ESPBoneMapValidateEx(pts, n, mMap, NULL) ||
            ESPBoneMapPlausible(pts, n, mMap, NULL)) {
            g_espBoneOff = off;
            g_espBoneComposed.store(false);
            memcpy(g_espBoneMap, mMap, sizeof(g_espBoneMap));
            g_espBoneBadTicks.store(0);
            g_espBonesReady.store(true);
            snprintf(g_espBoneStatus, sizeof(g_espBoneStatus), "bones 0x%x map%d ok", (unsigned)off, m);
            ESPLog("bones: offset=0x%x map=%d bones=%u (auto-detect)", (unsigned)off, m, (unsigned)count);
            return YES;
        }
    }
    return NO;
}

static BOOL ESPBonesConfigure(uint64_t vmMap, uint64_t mesh, uint64_t gameBase,
                              BOOL allowNameScan) {
    if (g_espBonesReady.load()) return YES;
    if (!vmMap || !ESPIsUserPtr(mesh)) return NO;

    std::unique_lock<std::mutex> lk(g_espBoneCfgMutex, std::defer_lock);
    if (allowNameScan) lk.lock();
    else if (!lk.try_lock()) return NO;

    if (g_espBonesReady.load()) return YES;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    static int s_failTries = 0;
    double interval = 1.5;
    if (g_espBoneTryAt > 0 && now - g_espBoneTryAt < interval) return NO;
    g_espBoneTryAt = now;
    snprintf(g_espBoneStatus, sizeof(g_espBoneStatus), "bones detect");

    // qblpack: bảng index theo TÊN xương (USkeleton.BoneTree). Cache theo mesh
    // 30s để không đọc/resolve ~500 FName mỗi 2s khi bảng fail.
    static uint64_t s_nameMesh = 0;
    static CFAbsoluteTime s_nameAt = 0;
    static BOOL s_nameOK = NO;
    static int s_nameMap[ESPBone_Count];
    int nameMap[ESPBone_Count];
    BOOL haveNames = NO;
    if (mesh == s_nameMesh && now - s_nameAt < 30.0) {
        haveNames = s_nameOK;
        if (haveNames) memcpy(nameMap, s_nameMap, sizeof(nameMap));
    } else if (!allowNameScan) {
        // Queue box 4Hz: KHÔNG đọc ~500 FName ở đây (có thể chặn HUD). Chờ
        // scan nền dò xong; trong lúc đó dùng 3 bảng index cũ làm fallback.
        haveNames = NO;
    } else {
        if (ESPUNameReady(gameBase)) {
            haveNames = ESPBoneSkeletonMap(vmMap, gameBase, mesh, nameMap);
        } else {
            static CFAbsoluteTime s_noNameLog = 0;
            if (now - s_noNameLog > 10.0) {
                s_noNameLog = now;
                ESPLog("bones names: GNames chua san sang (cho scan nen)");
            }
        }
        s_nameMesh = mesh;
        s_nameAt = now;
        s_nameOK = haveNames;
        if (haveNames) memcpy(s_nameMap, nameMap, sizeof(s_nameMap));
    }

    // qblpack 2026-10-21: dựng bảng index 17 khớp từ REF POSE của chính rig
    // (RefLocalPoses + BoneTree) — không cần GNames. Cache 60s theo USkeleton:
    // dò 1 lần/rig, các lượt configure sau gần như free. Đây là đường chính
    // khi rig không khớp 4 bảng hard-code (clavicle/spine khác thứ tự).
    int autoMap[ESPBone_Count];
    int autoCount = 0;
    BOOL haveAuto = NO;
    {
        static uint64_t s_autoSkel = 0;
        static CFAbsoluteTime s_autoAt = 0;
        static BOOL s_autoOK = NO;
        static int s_autoMap[ESPBone_Count];
        static int s_autoCount = 0;
        uint64_t skelMesh = 0, skel = 0;
        if (ESPMemoryRead(vmMap, mesh + ESPOff_Mesh_SkeletalMesh, &skelMesh, 8) &&
            ESPIsUserPtr(skelMesh) &&
            ESPMemoryRead(vmMap, skelMesh + ESPOff_SkeletalMesh_Skeleton, &skel, 8) &&
            ESPIsUserPtr(skel)) {
            if (skel == s_autoSkel && s_autoAt > 0 && now - s_autoAt < 60.0) {
                haveAuto = s_autoOK;
                autoCount = s_autoCount;
                if (haveAuto) memcpy(autoMap, s_autoMap, sizeof(autoMap));
            } else {
                char whyAuto[48] = {0};
                haveAuto = ESPBoneAutoMapForMesh(vmMap, mesh, autoMap, &autoCount,
                                                 whyAuto, sizeof(whyAuto));
                if (haveAuto) {
                    ESPLog("bones automap: ok skel=0x%llx head=%d neck=%d "
                           "chest=%d pelvis=%d Lsh=%d Lhp=%d Rsh=%d Rhp=%d",
                           (unsigned long long)skel,
                           autoMap[ESPBone_Head], autoMap[ESPBone_Neck],
                           autoMap[ESPBone_Chest], autoMap[ESPBone_Pelvis],
                           autoMap[ESPBone_LShoulder], autoMap[ESPBone_LHip],
                           autoMap[ESPBone_RShoulder], autoMap[ESPBone_RHip]);
                } else {
                    static CFAbsoluteTime s_autoFailLog = 0;
                    if (now - s_autoFailLog > 10.0) {
                        s_autoFailLog = now;
                        ESPLog("bones automap: skip (%s) mesh=0x%llx skel=0x%llx",
                               whyAuto, (unsigned long long)mesh,
                               (unsigned long long)skel);
                    }
                }
                s_autoSkel = skel;
                s_autoAt = now;
                s_autoOK = haveAuto;
                s_autoCount = autoCount;
                if (haveAuto) memcpy(s_autoMap, autoMap, sizeof(s_autoMap));
            }
        }
    }

    static ESPVector pts[ESPOff_Bone_NumMax];
    // 0) Thử mảng component space trực tiếp (0xCA8, 0xCE0, 0xCD0) — nhanh,
    //    không phụ thuộc USkeleton hay compose ma trận.
    static const uint32_t kDumpOffsets[] = {
        ESPOff_Mesh_ComponentSpaceTransforms,
        ESPOff_Mesh_BoneCompSpace,
        ESPOff_Mesh_BoneBoneSpace
    };
    for (size_t i = 0; i < sizeof(kDumpOffsets) / sizeof(kDumpOffsets[0]); i++) {
        if (ESPBoneTryOffsetLocked(vmMap, mesh, kDumpOffsets[i],
                                   haveNames ? nameMap : NULL,
                                   haveAuto ? autoMap : NULL, autoCount, pts)) {
            s_failTries = 0;
            return YES;
        }
    }
    // 1) Fallback: BoneSpaceTransforms 0xC98 + tự nhân ParentIndex của USkeleton.BoneTree.
    if (ESPBoneTryComposedLocked(vmMap, mesh, haveNames ? nameMap : NULL,
                                 haveAuto ? autoMap : NULL, autoCount, pts)) {
        s_failTries = 0;
        return YES;
    }
    // Chẩn đoán mảng xương: in RAW header 0xCE0/0xCD0 + quét 0xC00..0xF00 tìm
    // TArray<FTransform> (dải fallback cũ dừng ở 0xC00 nên bỏ sót vùng này).
    {
        static CFAbsoluteTime s_probeAt = 0;
        if (now - s_probeAt > 10.0) {
            s_probeAt = now;
            uint32_t probes[2] = { ESPOff_Mesh_BoneCompSpace, ESPOff_Mesh_BoneBoneSpace };
            for (int pi = 0; pi < 2; pi++) {
                uint8_t hdr[16];
                if (!ESPMemoryRead(vmMap, mesh + probes[pi], hdr, sizeof(hdr))) {
                    ESPLog("bones probe: 0x%x read-fail mesh=0x%llx",
                           (unsigned)probes[pi], (unsigned long long)mesh);
                    continue;
                }
                uint64_t d = 0; uint32_t c = 0, m = 0;
                memcpy(&d, hdr, 8);
                memcpy(&c, hdr + 8, 4);
                memcpy(&m, hdr + 12, 4);
                ESPLog("bones probe: 0x%x data=0x%llx count=%u max=%u",
                       (unsigned)probes[pi], (unsigned long long)d,
                       (unsigned)c, (unsigned)m);
                if (ESPIsUserPtr(d) && c >= 15 && c <= 800) {
                    ESPVector pr[24];
                    int pn = (int)(c < 24 ? c : 24);
                    if (ESPReadBoneLocals(vmMap, d, pr, pn)) {
                        ESPLog("bones probe: 0x%x p0=(%.1f,%.1f,%.1f) p1=(%.1f,%.1f,%.1f) p6=(%.1f,%.1f,%.1f)",
                               (unsigned)probes[pi],
                               pr[0].x, pr[0].y, pr[0].z,
                               pr[1].x, pr[1].y, pr[1].z,
                               pr[6].x, pr[6].y, pr[6].z);
                    } else {
                        ESPLog("bones probe: 0x%x read transforms fail", (unsigned)probes[pi]);
                    }
                }
            }
            // Ứng viên TArray trong vùng USkeletalMeshComponent sau 0xC00.
            int shown = 0;
            for (uint32_t off = 0xC00; off + 16 <= 0xF00 && shown < 4; off += 8) {
                uint8_t hdr[16];
                if (!ESPMemoryRead(vmMap, mesh + off, hdr, sizeof(hdr))) continue;
                uint64_t d = 0; uint32_t c = 0, m = 0;
                memcpy(&d, hdr, 8);
                memcpy(&c, hdr + 8, 4);
                memcpy(&m, hdr + 12, 4);
                if (!ESPIsUserPtr(d) || c < 20 || c > 400 || m < c) continue;
                ESPLog("bones cand: off=0x%x data=0x%llx count=%u max=%u",
                       (unsigned)off, (unsigned long long)d, (unsigned)c, (unsigned)m);
                shown++;
            }
            if (!shown) ESPLog("bones cand: khong co TArray 20..400 trong 0xC00..0xF00");
        }
    }
    // 2) Fallback: quét dải cũ phòng bản game sau dời field.
    for (uint32_t off = ESPOff_Mesh_BoneScanStart; off + 16 <= ESPOff_Mesh_BoneScanEnd; off += 8) {
        // Quét mù vẫn dùng autoMap: nó chỉ nhận khi 17 khớp đúng tỉ lệ người
        // (đầu-hông 40..150cm, tay/chân trong khoảng, 2 vai cách 18..90cm) —
        // mảng rác gần như không thể qua. Nhờ vậy mảng xương dời offset vẫn dò ra.
        if (ESPBoneTryOffsetLocked(vmMap, mesh, off,
                                   haveNames ? nameMap : NULL,
                                   haveAuto ? autoMap : NULL, autoCount, pts)) {
            s_failTries = 0;
            return YES;
        }
    }
    // Không ứng viên nào qua validate: giữ tắt, thử lại sau (world khác có thể khác rig).
    if (s_failTries < 1000) s_failTries++;
    snprintf(g_espBoneStatus, sizeof(g_espBoneStatus), "bones no-match");
    return NO;
}

// Nhân FTransform (component -> world) rồi project 1 khớp.
static void ESPBoneWorldFromLocal(const uint8_t *c2w, const ESPVector *local, ESPVector *out) {
    float qx = 0, qy = 0, qz = 0, qw = 1;
    float tx = 0, ty = 0, tz = 0;
    float sx = 1, sy = 1, sz = 1;
    memcpy(&qx, c2w + 0x0, 4);
    memcpy(&qy, c2w + 0x4, 4);
    memcpy(&qz, c2w + 0x8, 4);
    memcpy(&qw, c2w + 0xC, 4);
    memcpy(&tx, c2w + ESPOff_Transform_Translation + 0, 4);
    memcpy(&ty, c2w + ESPOff_Transform_Translation + 4, 4);
    memcpy(&tz, c2w + ESPOff_Transform_Translation + 8, 4);
    memcpy(&sx, c2w + 0x20, 4);
    memcpy(&sy, c2w + 0x24, 4);
    memcpy(&sz, c2w + 0x28, 4);
    if (!ESPFiniteV(sx) || sx < 0.01f || sx > 100.0f) sx = 1.0f;
    if (!ESPFiniteV(sy) || sy < 0.01f || sy > 100.0f) sy = 1.0f;
    if (!ESPFiniteV(sz) || sz < 0.01f || sz > 100.0f) sz = 1.0f;
    if (!ESPFiniteV(qw)) qw = 1.0f;
    float vx = local->x * sx, vy = local->y * sy, vz = local->z * sz;
    // v' = v + 2*cross(q.xyz, cross(q.xyz, v) + q.w*v)
    float cx = qy*vz - qz*vy;
    float cy = qz*vx - qx*vz;
    float cz = qx*vy - qy*vx;
    float ux = 2.0f * (cx + qw*vx);
    float uy = 2.0f * (cy + qw*vy);
    float uz = 2.0f * (cz + qw*vz);
    out->x = vx + (qy*uz - qz*uy) + tx;
    out->y = vy + (qz*ux - qx*uz) + ty;
    out->z = vz + (qx*uy - qy*ux) + tz;
}

// Điền box->bones[] cho 1 player. Trả về số khớp project được.
// boxTopY/boxH dùng để kiểm tra chéo mép đầu (chống nhận nhầm hệ quy chiếu).
static int ESPBonesSample(uint64_t vmMap, uint64_t mesh, const ESPCamBasis *basis,
                          ESPBox2D *box, float boxTopY, float boxH) {
    if (!box) return 0;
    box->boneCount = 0;
    for (int i = 0; i < ESPBone_Count; i++) box->bones[i].ok = 0;
    if (!g_espBonesReady.load() || !g_espBonesWant.load()) return 0;
    if (!vmMap || !basis || !ESPIsUserPtr(mesh)) return 0;
    // Snapshot cấu hình (off/map) — nếu đổi world đúng lúc này thì frame này có
    // thể lệch; bounds check bên dưới chặn đọc sai, box vẫn vẽ bình thường.
    const uint32_t boneOff = g_espBoneOff;
    BOOL composed = g_espBoneComposed.load();
    int boneMap[ESPBone_Count];
    memcpy(boneMap, g_espBoneMap, sizeof(boneMap));
    ESPVector locals[ESPBone_Count];
    BOOL have[ESPBone_Count];
    memset(have, 0, sizeof(have));
    if (composed) {
        // 0xC98 là bone space: đọc cả mảng + nhân dồn parent mỗi frame.
        ESPVector pts[ESPOff_Bone_NumMax];
        int n = 0;
        const char *whyC = NULL;
        if (!ESPBoneComposeAt(vmMap, mesh, pts, &n, &whyC)) {
            // Configure đã OK mà sample fail = mảng xương bị game xoá/dời giữa
            // trận (skin/ragdoll). Log 10s/lần để log không bị im lặng.
            static CFAbsoluteTime s_sampleLogAt = 0;
            CFAbsoluteTime nowS = CFAbsoluteTimeGetCurrent();
            if (nowS - s_sampleLogAt > 10.0) {
                s_sampleLogAt = nowS;
                ESPLog("bones sample: compose fail (%s) mesh=0x%llx",
                       whyC ? whyC : "-", (unsigned long long)mesh);
            }
            return 0;
        }
        for (int i = 0; i < ESPBone_Count; i++) {
            int bi = boneMap[i];
            if (bi < 0 || bi >= n) continue;
            locals[i] = pts[bi];
            have[i] = YES;
        }
    } else {
        uint64_t data = 0;
        uint32_t count = 0;
        if (!ESPBoneArrayAt(vmMap, mesh, boneOff, &data, &count)) return 0;
        int need = 0;
        for (int i = 0; i < ESPBone_Count; i++) {
            if (boneMap[i] + 1 > need) need = boneMap[i] + 1;
        }
        if (need <= 0 || (uint32_t)need > count || need > (int)ESPOff_Bone_NumMax) return 0;
        uint8_t buf[ESPOff_Bone_NumMax * ESPOff_BoneTransformSize];
        if (!ESPMemoryRead(vmMap, data, buf, (size_t)need * ESPOff_BoneTransformSize)) return 0;
        for (int i = 0; i < ESPBone_Count; i++) {
            int bi = boneMap[i];
            if (bi < 0 || bi >= need) continue;
            memcpy(&locals[i], buf + (size_t)bi * ESPOff_BoneTransformSize + ESPOff_Transform_Translation, sizeof(ESPVector));
            if (!ESPFiniteV(locals[i].x) || !ESPFiniteV(locals[i].y) || !ESPFiniteV(locals[i].z)) continue;
            have[i] = YES;
        }
    }
    uint8_t c2w[0x30];
    if (!ESPMemoryRead(vmMap, mesh + ESPOff_Comp_ComponentToWorld, c2w, sizeof(c2w))) return 0;
    int ok = 0;
    for (int i = 0; i < ESPBone_Count; i++) {
        if (!have[i]) continue;
        ESPVector w;
        ESPBoneWorldFromLocal(c2w, &locals[i], &w);
        float sx = 0, sy = 0;
        if (!ESPCamBasisProject(basis, w, &sx, &sy, NULL)) continue;
        box->bones[i].x = sx;
        box->bones[i].y = sy;
        box->bones[i].ok = 1;
        ok++;
    }
    box->boneCount = (uint8_t)ok;
    return ok;
}

void ESPEngineSetBonesEnabled(BOOL enabled) {
    bool want = enabled ? true : false;
    bool prev = g_espBonesWant.exchange(want);
    if (want && !prev) {
        if (!g_espBonesReady.load()) {
            g_espBoneBadTicks.store(0);
            g_espBoneTryAt = 0;
            snprintf(g_espBoneStatus, sizeof(g_espBoneStatus), "bones detect");
        }
    } else if (!want) {
        snprintf(g_espBoneStatus, sizeof(g_espBoneStatus), "bones off");
    }
}

BOOL ESPEngineBonesEnabled(void) {
    return g_espBonesWant.load() ? YES : NO;
}

const char *ESPEngineBonesStatus(void) {
    return g_espBoneStatus;
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
        // Chiều cao box: extent mesh đọc 1 lần/actor/scan, dùng cho cả tracked.
        uint64_t meshComp = ESPBoxMesh(vmMap, actor, &dg, team);
        float actorH = ESPActorBoxHeight(vmMap, meshComp);
        // qblpack: KHÔNG dò xương ở đây. Đây là tick box trên main thread; dò
        // 352 offset (khi offset sai) sẽ làm giật HUD/ESP. Queue scan nền
        // (ESPBonesConfigure allowNameScan=YES) lo việc này.
        uint64_t rootComp = ESPIsUserPtr(dg.root) ? dg.root : 0;
        if (foundTracked.size() < 64) {
            ESPTrackedActor tr;
            tr.actor = actor;
            tr.root = rootComp;
            tr.fallback = (team == ESPTeam_Dummy && ESPIsUserPtr(dg.tMesh)) ? dg.tMesh : 0;
            tr.parent = 0;
            tr.mesh = meshComp;
            tr.height = actorH;
            tr.isAI = dg.ai ? 1 : 0; // qblpack: AIMarkDifferent (VTable bot/tên AI)
            tr.team = (team != ESPTeam_Dummy && team >= 0 && team <= 200000000) ? team : INT_MIN;
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
        // pos = TÂM (capsule/mesh pivot center) — box = pos ± height/2
        // (nguồn Kernel: TopBox = Pos + H/2, BottomBox = Pos - H/2).
        float halfH = actorH * 0.5f;
        ESPVector bot = pos; bot.z -= halfH;
        ESPVector top = pos; top.z += halfH;
        float bx = 0, by = 0, bd = 0, tx = 0, ty = 0, td = 0;
        BOOL okB = ESPCamBasisProject(&basis, bot, &bx, &by, &bd);
        BOOL okT = ESPCamBasisProject(&basis, top, &tx, &ty, &td);
        float topY = 0, bottomY = 0, boxH = 0, boxW = 0, centerX = sx;
        if (okB && okT) {
            topY = fminf(ty, by);
            bottomY = fmaxf(ty, by);
            boxH = bottomY - topY;
            centerX = (tx + bx) * 0.5f;
        } else {
            float tz = dist * 100.0f;
            if (tz < 10.0f) tz = 10.0f;
            boxH = (actorH / tz) * basis.k;
            topY = sy - boxH * 0.5f;
            centerX = sx;
        }
        if (boxH < 8.0f) boxH = 8.0f;
        if (boxH > screenH * 2.0f) { cH++; continue; }
        boxW = boxH * 0.5f;
        if (centerX + boxW * 0.5f < -50.0f || centerX - boxW * 0.5f > screenW + 50.0f ||
            topY > screenH + 50.0f || topY + boxH < -50.0f) {
            cW2s++; continue;
        }
        // kernrw49: nick + kind cho đường scan đầy đủ (giống RefreshBoxes).
        ESPBox2D box = { centerX - boxW*0.5f, topY, boxW, boxH, dist, ESPHPPercent(vmMap, actor, (team == ESPTeam_Dummy) ? 3 : 1), 1, actor, {0}, 0 };
        box.kind = (team == ESPTeam_Dummy) ? 3 : 1;
        // qblpack: TeamID + AI mark (giống 2 field của QBL: player.TeamID,
        // player.AIMarkDifferent).
        box.team = (box.kind == 3 || team < 0 || team > 200000000) ? INT_MIN : team;
        box.isAI = (uint8_t)(dg.ai ? 1 : 0);
        if (box.kind == 3) {
            strncpy(box.nick, "DUMMY", sizeof(box.nick) - 1);
        } else if (ESPPlayerNickName(vmMap, actor, box.nick)) {
        } else {
            strncpy(box.nick, "Unknown", sizeof(box.nick) - 1);
        }
        box.nick[sizeof(box.nick) - 1] = '\0';
        outBoxes[n++] = box;
    }
                  (unsigned)scanN, (unsigned)cEne, (unsigned)cPos,
    ESPPerfSample((tProc - tBox0) * 1000.0, (tCam - tProc) * 1000.0,
                  (CFAbsoluteTimeGetCurrent() - tCam) * 1000.0);
    if (!foundTracked.empty()) {
        std::lock_guard<std::recursive_mutex> lk(g_espClassifyMutex);
        if (g_espTracked.empty()) {
            g_espTracked = foundTracked;
            g_espTrackGen++;
        }
        ESPTrackedSnapPublishLocked();
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
    ESPVector vel;   // cm/giây, đo trên baseline >= 80ms
    ESPVector slowPos; // mốc đầu của baseline đo vận tốc
    CFAbsoluteTime slowAt;
    CFAbsoluteTime at;
    int outliers;    // số mẫu bất thường liên tiếp (để tự hồi phục)
    int hpPct;       // 0-100 cho thanh máu, -1 chưa đọc (giữ mẫu cũ giữa các lần đọc thưa)
    BOOL valid;
} ESPPosHist;
static ESPPosHist s_posHist[ESP_POS_HIST];

// --- Ring actor vừa chết/ẩn (refresh phát hiện) ---
// Bridge cố ý giữ box cũ tới 1.2s khi 1 frame hụt w2s (chống nháy khi lia
// camera). Nhưng khi địch CHẾT, engine bỏ actor khỏi danh sách box ngay từ
// tick đó, còn bridge vẫn vẽ box đứng yên ở chỗ chết thêm 1.2s — đúng kiểu
// "địch chết mà box còn hiện một lúc". Ring này để bridge biết actor đã chết
// và bỏ slot tức thì. Ghi/đọc ít (chỉ lúc chết + lúc slot stale) nên mutex
// riêng là đủ, không đụng g_espClassifyMutex của scan nền.
#define ESP_GONE_RING 64
#define ESP_GONE_TTL 5.0
static uint64_t s_goneActor[ESP_GONE_RING];
static CFAbsoluteTime s_goneAt[ESP_GONE_RING];
static int s_goneNext = 0;
static std::mutex s_goneMutex;

static void ESPMarkActorGone(uint64_t actor) {
    if (!actor) return;
    std::lock_guard<std::mutex> lk(s_goneMutex);
    s_goneActor[s_goneNext] = actor;
    s_goneAt[s_goneNext] = CFAbsoluteTimeGetCurrent();
    s_goneNext = (s_goneNext + 1) % ESP_GONE_RING;
}

BOOL ESPEngineActorGone(uint64_t actor, double withinSec) {
    if (!actor) return NO;
    if (!(withinSec > 0)) withinSec = ESP_GONE_TTL;
    std::lock_guard<std::mutex> lk(s_goneMutex);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    for (int i = 0; i < ESP_GONE_RING; i++) {
        if (s_goneActor[i] == actor && now - s_goneAt[i] <= withinSec) return YES;
    }
    return NO;
}

// Offset dự đoán = vận tốc * dt, KẸP BIÊN ĐỘ. Vận tốc đo trên baseline
// ~80ms nên đã bền với vị trí cập nhật theo bước, nhưng một cú teleport nhỏ
// dưới ngưỡng ESP_MAX_JUMP vẫn có thể cho vận tốc lớn; kẹp offset để box
// không vọt xa rồi giật lùi. 40cm lớn hơn nhiều so với bù trễ 1 frame của
// người chạy (5m/s * 16ms = 8cm) nên không cắt mất phần bù thật.
static ESPVector ESPPredictOffset(const ESPVector *vel, float dt, float maxCm) {
    if (!vel || !(dt > 0.0f)) return (ESPVector){0, 0, 0};
    float ox = vel->x * dt, oy = vel->y * dt, oz = vel->z * dt;
    float m = sqrtf(ox*ox + oy*oy + oz*oz);
    if (m > maxCm && m > 0.0f) {
        float s = maxCm / m;
        ox *= s; oy *= s; oz *= s;
    }
    return (ESPVector){ox, oy, oz};
}

static ESPPosHist *ESPPosHistSlot(uint64_t actor) {
    ESPPosHist *h = &s_posHist[(size_t)((actor >> 4) % ESP_POS_HIST)];
    if (h->valid && h->actor == actor) return h;
    // Slot của actor khác: coi như chưa có mẫu (lần này sẽ đọc thật).
    h->actor = actor;
    h->valid = NO;
    h->outliers = 0;
    h->hpPct = -1;
    h->pos = (ESPVector){0, 0, 0};
    h->vel = (ESPVector){0, 0, 0};
    h->slowPos = (ESPVector){0, 0, 0};
    h->slowAt = 0;
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
        // kernrw44: đọc ẢNH CHÉP dưới g_espSnapMutex (leaf). Không đụng
        // g_espClassifyMutex nữa: scan nền giữ nó hàng chục ms mỗi lần phân
        // loại actor -> tick refresh từng bị chặn sau lưng scan (log kernrw43:
        // cam=8.7ms = avg=8.7ms của refresh, max=716.8ms; vòng actors cùng
        // đường đọc mà không lock thì = 0.0ms -> nguyên nhân là lock).
        std::lock_guard<std::recursive_mutex> lk(g_espSnapMutex);
        tracked = g_espTrackedSnap;
        if (outGen) *outGen = g_espTrackGenSnap;
    }
    if (tracked.empty()) { ESPBoxDiagSet("R empty"); return 0; }
    CFAbsoluteTime tBox0 = CFAbsoluteTimeGetCurrent(); // perf refresh
    uint64_t vmMap = ESPProcVMMap(NULL);
    if (!vmMap) { ESPBoxDiagSet("R noVmMap"); return 0; }
    CFAbsoluteTime tProc = CFAbsoluteTimeGetCurrent();
    // kernrw46: s_lastCam nâng lên cấp hàm — dùng cả khi camera FAIL hẳn
    // (fallback bên dưới), không chỉ khi giá trị rách (jump guard).
    static ESPCamera s_lastCam = {0};
    static CFAbsoluteTime s_lastCamAt = 0;
    static BOOL s_lastCamValid = NO;
    ESPCamera cam;
    CFAbsoluteTime nowCam = CFAbsoluteTimeGetCurrent();
    if (!ESPEngineCamera(gameBase, &cam)) {
        // kernrw46: chuỗi tick camFail (POV rách lúc xoay mạnh / chain gãy lẻ)
        // trước đây return 0 -> rawCount=0 -> box đứng yên grace 1.2s rồi ẩn,
        // "đóng băng cho tới khi xoay camera". Dùng lại camera gần nhất ≤1.5s:
        // box VẪN bám địch từng tick (chậm đúng bằng tuổi mẫu), khỏi cần xoay
        // cam để "đánh thức". Hết hạn 1.5s mới fail thật (world/possess đổi).
        if (s_lastCamValid && s_lastCamAt > 0 && nowCam - s_lastCamAt <= 1.5) {
            cam = s_lastCam;
            static CFAbsoluteTime s_lastStaleLog = 0;
            if (nowCam - s_lastStaleLog >= 2.0) {
                s_lastStaleLog = nowCam;
                // kernrw52g: bỏ log camStale (I/O)
            }
        } else {
            ESPBoxDiagSet("R camFail");
            return 0;
        }
    }
    if (!(cam.aspect > 0.3 && cam.aspect < 4.0)) cam.aspect = screenW / screenH;
    // Guard camera rách (kernrw31): POV đọc bằng 1 memcpy 0x38B trong lúc game
    // đang ghi -> yaw/pitch/loc có thể nửa cũ nửa mới trong đúng 1 tick. Dấu
    // hiệu trong log kernrw30: box nhảy 130-170px/25ms rồi w2s rớt cả loạt
    // 1-1.5s (slot age 0.9-1.7s, box tắt rồi hiện lại chỗ mới = "giật giật").
    // Chặn bằng giới hạn tốc độ vật lý: flick tay ~800°/s, scope ~350°/s,
    // máy bay 100m/s. Rách -> dùng lại camera tốt gần nhất của tick này.
    //
    // kernrw47 CHỐNG LATCH khi quay camera nhanh (log của user: "quay nhanh thì
    // ESP không dính địch, phải xoay tiếp nó mới bám tiếp"): flick PUBG mobile
    // dễ vượt 1200°/s (25°/tick) và vì s_lastCam KHÔNG được update khi reject,
    // Δyaw so với cam cũ cộng dồn mỗi tick nhanh hơn phần cho phép (1200·dt)
    // -> reject NỐI TIẾP hàng chục tick -> box bám theo camera cũ/trôi lệch
    // tới khi thôi quay + dYaw tụt dưới ngưỡng (hàng trăm ms). Giờ khi mẫu
    // vượt ngưỡng: ĐỌC LẠI POV ngay trong cùng tick (~µs):
    //  - 2 lần đọc KHỚP (dYaw ≤ 2°, dLoc ≤ 0.5m) -> dữ liệu nhất quán, KHÔNG
    //    rách, là flick thật -> CHẤP NHẬN + update s_lastCam (hết latch).
    //  - cam rách nhưng POV retry tự nó vượt ngưỡng so với cam cũ (flick thật
    //    + rách cùng lúc) -> dùng camR (sạch) và update s_lastCam.
    //  - còn lại (retry cũng lệch / đọc fail) -> giữ cam cũ ĐÚNG 1 tick.
    // Torn-read (lý do guard tồn tại) vẫn bị chặn: 2 lần đọc cách nhau ~µs
    // không thể rách TRÙNG NHAU về cùng 1 giá trị lạ; 2/3-vote ở
    // ESPEngineCamera vẫn chạy trước nên camera vào guard vốn đã sạch.
    {
        CFAbsoluteTime nowC = CFAbsoluteTimeGetCurrent();
        BOOL useLast = NO;       // giữ cam cũ đúng 1 tick
        BOOL handled = NO;       // đã quyết trong nhánh flash (không nhánh accept thường)
        if (s_lastCamValid && s_lastCamAt > 0) {
            double dt = nowC - s_lastCamAt;
            if (dt > 0.001 && dt < 5.0) {
                float dYaw = fabsf(cam.rotation.yaw - s_lastCam.rotation.yaw);
                if (dYaw > 180.0f) dYaw = 360.0f - dYaw;
                float dPitch = fabsf(cam.rotation.pitch - s_lastCam.rotation.pitch);
                if (dPitch > 180.0f) dPitch = 360.0f - dPitch;
                float dx = cam.location.x - s_lastCam.location.x;
                float dy = cam.location.y - s_lastCam.location.y;
                float dz = cam.location.z - s_lastCam.location.z;
                float dLoc = sqrtf(dx*dx + dy*dy + dz*dz) / 100.0f; // mét
                float dFov = fabsf(cam.fov - s_lastCam.fov);
                float maxDeg = 1200.0f * (float)dt + 5.0f;
                float maxLoc = 600.0f * (float)dt + 2.0f;
                float maxFov = 600.0f * (float)dt + 3.0f;
                if (dYaw > maxDeg || dPitch > maxDeg || dLoc > maxLoc || dFov > maxFov) {
                    handled = YES;
                    static CFAbsoluteTime s_lastFlashOkLog = 0;
                    static CFAbsoluteTime s_lastFlashRejLog = 0;
                    ESPCamera camR;
                    if (ESPEngineCamera(gameBase, &camR)) {
                        float dYr = fabsf(cam.rotation.yaw - camR.rotation.yaw);
                        if (dYr > 180.0f) dYr = 360.0f - dYr;
                        float dPr = fabsf(cam.rotation.pitch - camR.rotation.pitch);
                        if (dPr > 180.0f) dPr = 360.0f - dPr;
                        float dxr = cam.location.x - camR.location.x;
                        float dyr = cam.location.y - camR.location.y;
                        float dzr = cam.location.z - camR.location.z;
                        float dLr = sqrtf(dxr*dxr + dyr*dyr + dzr*dzr) / 100.0f;
                        if (dYr <= 2.0f && dPr <= 2.0f && dLr <= 0.5f) {
                            // 2 lần đọc cách ~µs cho CÙNG giá trị -> POV ổn định,
                            // không rách -> flick thật -> chấp nhận ngay, update
                            // s_lastCam để tick sau so tốc độ từ điểm mới.
                            s_lastCam = cam;
                            s_lastCamAt = nowC;
                            s_lastCamValid = YES;
                            if (nowC - s_lastFlashOkLog >= 1.0) {
                                s_lastFlashOkLog = nowC;
                                // kernrw52g: bỏ log camFlash OK (I/O)
                            }
                        } else {
                            float dYraw = fabsf(camR.rotation.yaw - s_lastCam.rotation.yaw);
                            if (dYraw > 180.0f) dYraw = 360.0f - dYraw;
                            float dPraw = fabsf(camR.rotation.pitch - s_lastCam.rotation.pitch);
                            if (dPraw > 180.0f) dPraw = 360.0f - dPraw;
                            float dxraw = camR.location.x - s_lastCam.location.x;
                            float dyraw = camR.location.y - s_lastCam.location.y;
                            float dzraw = camR.location.z - s_lastCam.location.z;
                            float dLraw = sqrtf(dxraw*dxraw + dyraw*dyraw + dzraw*dzraw) / 100.0f;
                            if (dYraw <= maxDeg && dPraw <= maxDeg && dLraw <= maxLoc &&
                                fabsf(camR.fov - s_lastCam.fov) <= maxFov) {
                                // cam rách, POV retry sạch + vừa tốc độ -> dùng retry.
                                cam = camR;
                                s_lastCam = camR;
                                s_lastCamAt = nowC;
                                s_lastCamValid = YES;
                                if (nowC - s_lastFlashOkLog >= 1.0) {
                                    s_lastFlashOkLog = nowC;
                                    // kernrw52g: bỏ log camFlash reject (I/O)
                                }
                            } else {
                                useLast = YES;
                            }
                        }
                    } else {
                        useLast = YES;
                    }
                    if (useLast && nowC - s_lastFlashRejLog >= 1.0) {
                        s_lastFlashRejLog = nowC;
                        // kernrw52g: bỏ log camFlash reject detail (I/O)
                    }
                }
            }
        }
        if (handled) {
            if (useLast) cam = s_lastCam; // s_lastCam đã update trong nhánh flash nếu chấp nhận
        } else {
            s_lastCam = cam;
            s_lastCamAt = nowC;
            s_lastCamValid = YES;
        }
    }
    // Dựng basis view-projection 1 lần cho cả danh sách tracked (không trig/actor).
    ESPCamBasis basis;
    if (!ESPCamBasisBuild(&cam, screenW, screenH, &basis)) {
        return 0;
    }
    CFAbsoluteTime tCam = CFAbsoluteTimeGetCurrent();
    int n = 0;
    uint32_t cHid = 0, cPos = 0, cW2s = 0, cSelf = 0, cH = 0;
    // Đọc vị trí MỖI tick rồi project bằng camera TƯƠI của chính tick đó.
    //
    // KHÔNG còn xoay vòng 1/2 tracked như kernrw17..kernrw23: lượt nghỉ dùng
    // lại vị trí cache nên địch ĐANG CHẠY chỉ được cập nhật 20Hz trong khi
    // frame vẫn ship 40Hz -> box nhảy từng bước, kèm trễ pha tới 50ms. Ở cự ly
    // 10m, 0.3m dịch chuyển trong 50ms ~ 12pt -> đúng kiểu "giật giật, không
    // bám theo địch" (xoay camera thì vẫn mượt vì basis tươi, nên lỗi chỉ lộ
    // khi địch di chuyển).
    //
    // Chi phí đọc lại rất thấp: vùng đã map thì mỗi lần đọc chỉ là memcpy dưới
    // shared_lock (~µs, xem ESPReadSharedLocked) chứ không map lại; ~8 tracked
    // x 4 read x 40Hz vẫn không đáng kể.
    //
    // Ngoại suy/blend vận tốc vẫn KHÔNG dùng (thứ từng làm box "đứng im rồi
    // nhảy"); giờ chỉ bù ~1 frame chứ không ngoại suy cả khoảng đọc thưa.
    for (size_t i = 0; i < tracked.size() && n < maxBoxes; i++) {
        const ESPTrackedActor *tr = &tracked[i];
        CFAbsoluteTime nowF = CFAbsoluteTimeGetCurrent();
        ESPPosHist *h = ESPPosHistSlot(tr->actor);
        ESPVector pos = {0,0,0};
        // Đọc cả cờ ẩn/chết ngay tại đây (thay vì đọc mỗi frame ở đường khác).
        // bHidden ở 0xE8, bDead ở 0xE7C — cách xa nên không gộp 1 lần đọc;
        // đọc bHidden trước, ẩn/chết thì khỏi đọc bDead.
        uint8_t flags[2] = {0, 0};
        if (ESPMemoryRead(vmMap, tr->actor + ESPOff_Actor_HiddenFlag, flags, 1)) {
            if (flags[0] & 0x1) {
                // Chỉ mark lần ĐẦU (h->valid còn YES) để ring 64 slot không bị
                // một actor đã chết ghi đè 60 lần/giây.
                cHid++;
                if (h->valid) ESPMarkActorGone(tr->actor);
                h->valid = NO;
                continue;
            }
            if (tr->kind != 3) {
                if (ESPMemoryRead(vmMap, tr->actor + ESPOff_Char_Dead, flags + 1, 1)) {
                    if (flags[1] & 0x1) {
                        cHid++;
                        if (h->valid) ESPMarkActorGone(tr->actor);
                        h->valid = NO;
                        continue;
                    }
                }
            }
        }
        ESPVector fresh = {0,0,0};
        BOOL gotPos = ESPTrackedPos(vmMap, tr, &fresh);
        // Vận tốc đo trên baseline >= 80ms + EMA (xem nhánh bên dưới) để
        // triệt tiêu velocity spike làm box vọt xa rồi giật lùi (rubber-banding).
        BOOL sampleReject = NO;
        if (!gotPos) {
            // Fail 1 frame KHÔNG bỏ box nữa: bridge đang giữ box cũ nên bỏ frame
            // = box đứng im trong khi địch chạy, tới lúc đọc lại thì nhảy — đúng
            // kiểu "giật, không bám". Còn mẫu cũ < 0.15s thì dead-reckon tiếp
            // bằng vận tốc đã lọc; quá hạn mới coi như mất actor (bridge tự ẩn
            // box theo grace 1.2s).
            cPos++;
            double age = (h->valid && h->at > 0) ? (nowF - h->at) : 999.0;
            if (!h->valid || age > 0.15) {
                h->valid = NO;
                continue;
            }
            // Chỉ đuổi tối đa 50ms và kẹp 60cm để nhiễu đọc không đẩy box đi xa.
            float step = (float)((age < 0.05) ? age : 0.05);
            ESPVector off = ESPPredictOffset(&h->vel, step, 60.0f);
            pos.x = h->pos.x + off.x;
            pos.y = h->pos.y + off.y;
            pos.z = h->pos.z + off.z;
        } else {
            if (h->valid && h->at > 0) {
                double ddt = nowF - h->at;
                float dx = fresh.x - h->pos.x, dy = fresh.y - h->pos.y, dz = fresh.z - h->pos.z;
                float jump = sqrtf(dx*dx + dy*dy + dz*dz);
                if (ddt <= 0.001 || ddt >= 1.0 || jump > ESP_MAX_JUMP) {
                    // Teleport/respawn hoặc mẫu quá cũ: bỏ 1 frame rồi nhận lại,
                    // xoá vận tốc + mốc đo để không ngoại suy theo quãng teleport.
                    h->vel = (ESPVector){0, 0, 0};
                    h->slowAt = 0;
                    if (jump > ESP_MAX_JUMP && ++h->outliers < 2) {
                        sampleReject = YES;
                    } else {
                        h->outliers = 0;
                    }
                } else {
                    h->outliers = 0;
                    // Vận tốc đo trên baseline >= 80ms thay vì 2 tick liền kề.
                    // Vị trí địch do game cập nhật theo bước (dồn gói mạng) thì
                    // delta 1 tick có thể là 0 rồi 50cm -> vận tốc nhảy loạn,
                    // box vọt rồi giật lùi. Đo trên 80ms thì một bước 50cm chỉ
                    // làm vận tốc nhích nhẹ, box bám đều giữa 2 bước.
                    if (h->slowAt <= 0) {
                        h->slowPos = fresh;
                        h->slowAt = nowF;
                    } else {
                        double sdt = nowF - h->slowAt;
                        if (sdt >= 0.08) {
                            ESPVector v = { (fresh.x - h->slowPos.x) / (float)sdt,
                                            (fresh.y - h->slowPos.y) / (float)sdt,
                                            (fresh.z - h->slowPos.z) / (float)sdt };
                            float sp = sqrtf(v.x*v.x + v.y*v.y + v.z*v.z);
                            if (sp > ESP_MAX_VEL) {
                                float s = ESP_MAX_VEL / sp;
                                v.x *= s; v.y *= s; v.z *= s;
                            }
                            if (h->vel.x != 0 || h->vel.y != 0 || h->vel.z != 0) {
                                const float alphaVel = 0.5f;
                                h->vel.x = h->vel.x * (1.0f - alphaVel) + v.x * alphaVel;
                                h->vel.y = h->vel.y * (1.0f - alphaVel) + v.y * alphaVel;
                                h->vel.z = h->vel.z * (1.0f - alphaVel) + v.z * alphaVel;
                            } else {
                                h->vel = v;
                            }
                            h->slowPos = fresh;
                            h->slowAt = nowF;
                        }
                    }
                }
            } else {
                h->vel = (ESPVector){0, 0, 0};
                h->outliers = 0;
                h->slowAt = 0;
            }
            h->at = nowF;
            h->valid = YES;
            if (sampleReject) {
                pos = h->pos;      // giữ vị trí cũ cho frame này
            } else {
                h->pos = fresh;
                // Bù trễ present (xem ESP_PREDICT_LEAD): box nằm đúng chỗ địch
                // sẽ ở đó lúc frame HUD hiện ra thay vì bám sau lưng.
                ESPVector off = ESPPredictOffset(&h->vel, ESP_PREDICT_LEAD, 40.0f);
                pos.x = fresh.x + off.x;
                pos.y = fresh.y + off.y;
                pos.z = fresh.z + off.z;
            }
        }
        // HP cho thanh máu, cùng nhịp với vị trí (máu không cần ngoại suy).
        h->hpPct = ESPHPPercent(vmMap, tr->actor, tr->kind);
        float sx = 0, sy = 0, dist = 0;
        if (!ESPCamBasisProject(&basis, pos, &sx, &sy, &dist)) { cW2s++; continue; }
        if (dist < 2.0f) { cSelf++; continue; }
        // pos = TÂM (capsule center) — box = pos ± height/2 như đường scan.
        float actorH = (tr->height > 0.0f) ? tr->height : ESP_CHAR_HEIGHT_CM;
        float halfH = actorH * 0.5f;
        ESPVector bot = pos; bot.z -= halfH;
        ESPVector top = pos; top.z += halfH;
        float bx = 0, by = 0, bd = 0, tx = 0, ty = 0, td = 0;
        BOOL okB = ESPCamBasisProject(&basis, bot, &bx, &by, &bd);
        BOOL okT = ESPCamBasisProject(&basis, top, &tx, &ty, &td);
        float topY = 0, bottomY = 0, boxH = 0, boxW = 0, centerX = sx;
        if (okB && okT) {
            topY = fminf(ty, by);
            bottomY = fmaxf(ty, by);
            boxH = bottomY - topY;
            centerX = (tx + bx) * 0.5f;
        } else {
            float tz = dist * 100.0f;
            if (tz < 10.0f) tz = 10.0f;
            boxH = (actorH / tz) * basis.k;
            topY = sy - boxH * 0.5f;
            centerX = sx;
        }
        if (boxH < 8.0f) boxH = 8.0f;
        if (boxH > screenH * 2.0f) { cH++; continue; }
        boxW = boxH * 0.5f;
        if (centerX + boxW * 0.5f < -50.0f || centerX - boxW * 0.5f > screenW + 50.0f ||
            topY > screenH + 50.0f || topY + boxH < -50.0f) {
            cW2s++; continue;
        }
        // kernrw49: nickname + kind cho style Kernel (health/name/distance/line).
        // Nick là FString (pawn+0x960, cache 3s trong ESPPlayerNickName) nên đọc
        // mỗi tick gần như free; hỏng thì "Unknown" như Kernel GetPlayerName.
        ESPBox2D box = { centerX - boxW*0.5f, topY, boxW, boxH, dist, h->hpPct, 1, tr->actor, {0}, 0 };
        box.kind = (uint8_t)tr->kind;
        // qblpack: TeamID + AI mark + xương (giống RenderSnapshot của QBL).
        box.team = (tr->kind == 3) ? INT_MIN : tr->team;
        box.isAI = tr->isAI;
        if (box.kind == 3) {
            strncpy(box.nick, "DUMMY", sizeof(box.nick) - 1);
        } else if (ESPPlayerNickName(vmMap, tr->actor, box.nick)) {
            // giữ nguyên nick
        } else {
            strncpy(box.nick, "Unknown", sizeof(box.nick) - 1);
        }
        box.nick[sizeof(box.nick) - 1] = '\0';
        if (box.kind == 1 && g_espBonesWant.load()) {
            if (!g_espBonesReady.load() && tr->mesh && ESPIsUserPtr(tr->mesh)) {
                static CFAbsoluteTime s_lastFastCfg = 0;
                CFAbsoluteTime nowFast = CFAbsoluteTimeGetCurrent();
                if (nowFast - s_lastFastCfg >= 1.0) {
                    s_lastFastCfg = nowFast;
                    ESPBonesConfigure(vmMap, tr->mesh, gameBase, NO);
                }
            }
            if (g_espBonesReady.load() && tr->mesh && ESPIsUserPtr(tr->mesh)) {
                (void)ESPBonesSample(vmMap, tr->mesh, &basis, &box, box.y, box.h);
            }
        }
        outBoxes[n++] = box;
    }
    static CFAbsoluteTime s_zeroSince = 0;       // bắt đầu chuỗi 0 box (0 = đang có box)
    static CFAbsoluteTime s_lastRescueFlush = 0; // lần xả region map gần nhất
    if (tracked.size() > 0 && n == 0) {
        static CFAbsoluteTime s_lastZeroRefreshLog = 0;
        CFAbsoluteTime nowLog = CFAbsoluteTimeGetCurrent();
        if (s_zeroSince <= 0) s_zeroSince = nowLog;
        if (nowLog - s_lastZeroRefreshLog >= 1.0) {
            s_lastZeroRefreshLog = nowLog;
            // Chẩn đoán 1 dòng/giây (log này từng bị bỏ vì sợ I/O mỗi tick).
            // Khi box tắt, đây là manh mối duy nhất: trk>0 mà pos/w2s tăng =
            // lỗi đọc/lỗi chiếu; tất cả = 0 = tracked rỗng hoặc actor bị lọc.
            ESPLog("REFRESH-ZERO trk=%zu hid=%u pos=%u w2s=%u self=%u h=%u cam=%.0f/%.0f fov=%.0f",
                   tracked.size(), cHid, cPos, cW2s, cSelf, cH,
                   cam.rotation.yaw, cam.rotation.pitch, cam.fov);
            // CHỈ xả region map khi 0 box + LỖI ĐỌC VỊ TRÍ kéo dài >= 5s, tối đa
            // 1 lần/30s. Bản trước xả mỗi 2s ngay khi có 1 read fail: trên máy
            // không có task port, xả = mọi page phải map lại qua kernel trong
            // khi scan nền đang giữ read lock -> tick 135-919ms, box đứng/tắt
            // hàng chục giây (đúng log người dùng 2026-10-18).
            if (cPos > 0 && nowLog - s_zeroSince >= 5.0 && nowLog - s_lastRescueFlush >= 30.0) {
                s_lastRescueFlush = nowLog;
                ESPMemoryFlushPageCacheIfIdle();
            }
        }
    } else if (n > 0) {
        s_zeroSince = 0; // có box lại -> chuỗi 0 box kết thúc
    }
    ESPPerfSample((tProc - tBox0) * 1000.0, (tCam - tProc) * 1000.0,
                  (CFAbsoluteTimeGetCurrent() - tCam) * 1000.0);
    return n;
#endif
}

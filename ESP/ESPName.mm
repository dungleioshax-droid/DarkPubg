//
//  ESPName.mm
//  Port từ /home/dungle/Kernel/esp/unity_api/unity.mm:
//  GetGName / IsValidUName / ResolveUName / GetNameByID / GetFName,
//  đọc qua ESPMemoryRead (vmMap) thay vì task port.
//

#import "ESPName.h"
#import "ESPOffsets.h"
#import "ESPMemory.h"
#import "ESPLog.h"
#include <string>
#include <map>

extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

static const uint32_t kFNameElementsPerChunk = 16384;
static const uint32_t kFNameMaxID = 2000000;

static uint64_t s_uname = 0;
static uint64_t s_unameBase = 0;
static std::map<uint32_t, std::string> s_nameCache;

void ESPNameReset(uint64_t gameBase) {
    if (s_unameBase != gameBase) {
        s_uname = 0;
        s_unameBase = gameBase;
        s_nameCache.clear();
    }
}

static BOOL ESPReadU32At(uint64_t vmMap, uint64_t addr, uint32_t *out) {
    BOOL ok = NO;
    uint32_t v = ESPReadU32(vmMap, addr, &ok);
    if (out) *out = v;
    return ok;
}

// Đọc string C tối đa maxLen vào buf (luôn null-terminate). NO nếu fail/rỗng.
static BOOL ESPReadCString(uint64_t vmMap, uint64_t addr, char *buf, int maxLen) {
    if (!addr || !buf || maxLen <= 1) return NO;
    char tmp[256];
    int n = maxLen < 256 ? maxLen : 255;
    if (!ESPMemoryRead(vmMap, addr, tmp, (uint64_t)n)) return NO;
    tmp[n - 1] = '\0';
    int len = 0;
    while (len < n - 1 && tmp[len] != '\0') len++;
    if (len == 0) return NO;
    memcpy(buf, tmp, (size_t)len);
    buf[len] = '\0';
    return YES;
}

static uint64_t ESPGetGName(uint64_t vmMap, uint64_t gnamesStatic) {
    uint32_t raw = 0;
    uint64_t cur = 0;
    if (!ESPReadU32At(vmMap, gnamesStatic, &raw)) return 0;
    BOOL ok = NO;
    cur = ESPReadU64(vmMap, gnamesStatic + 8, &ok);
    if (!ok) return 0;
    if (raw < 100) return 0;
    unsigned int adj = raw - 100;
    unsigned int depth = adj / 3;
    if (depth == 0 || depth > 16) return 0;
    // buffer[depth-1] = cur; traverse depth-2 lần
    uint64_t buf[16] = {0};
    buf[depth - 1] = cur;
    if (adj >= 6) {
        int t = (int)depth - 2;
        while (t >= 0) {
            cur = ESPReadU64(vmMap, cur, &ok);
            if (!ok || !cur) return 0;
            buf[t] = cur;
            t--;
        }
    }
    BOOL ok2 = NO;
    uint64_t first = ESPReadU64(vmMap, buf[0], &ok2);
    if (!ok2) return 0;
    return first;
}

// Test UName candidate: ID 0 phải là None, 1 là ByteProperty (theo DUMP/Logs.txt).
static BOOL ESPIsValidUName(uint64_t vmMap, uint64_t cand, const char *why) {
    if (cand < 0x10000000ULL) return NO;
    char n0[64] = {0}, n1[64] = {0};
    // đọc trực tiếp không qua cache để tránh nhiễm
    uint32_t chunk0 = 0 / kFNameElementsPerChunk;
    uint32_t with0 = 0 % kFNameElementsPerChunk;
    BOOL ok = NO;
    uint64_t arr0 = ESPReadU64(vmMap, cand + (uint64_t)chunk0 * 8, &ok);
    if (!ok || !arr0) return NO;
    uint64_t e0 = ESPReadU64(vmMap, arr0 + (uint64_t)with0 * 8, &ok);
    if (!ok || !e0) return NO;
    if (!ESPReadCString(vmMap, e0 + 0xC, n0, sizeof(n0))) return NO;
    uint32_t chunk1 = 1 / kFNameElementsPerChunk;
    uint32_t with1 = 1 % kFNameElementsPerChunk;
    uint64_t arr1 = ESPReadU64(vmMap, cand + (uint64_t)chunk1 * 8, &ok);
    if (!ok || !arr1) return NO;
    uint64_t e1 = ESPReadU64(vmMap, arr1 + (uint64_t)with1 * 8, &ok);
    if (!ok || !e1) return NO;
    if (!ESPReadCString(vmMap, e1 + 0xC, n1, sizeof(n1))) return NO;
    BOOL valid = (strcmp(n0, "None") == 0 && strcmp(n1, "ByteProperty") == 0);
    if (!valid) {
        BOOL propOk = (strcmp(n1, "ByteProperty") == 0 || strcmp(n1, "IntProperty") == 0 ||
                       strcmp(n1, "BoolProperty") == 0 || strcmp(n1, "FloatProperty") == 0);
        valid = (propOk && n0[0] != '\0');
    }
    if (valid) ESPLog("UName ok via %s: 0x%llx (%s/%s)", why, (unsigned long long)cand, n0, n1);
    return valid;
}

uint64_t ESPResolveUName(uint64_t vmMap, uint64_t gameBase) {
    if (s_uname && s_unameBase == gameBase) return s_uname;
    ESPNameReset(gameBase);
    uint64_t gnamesStatic = ESPRuntime(gameBase, ESPDump_GNames);
    // 1) decrypt cũ
    uint64_t dec = ESPGetGName(vmMap, gnamesStatic);
    if (dec && ESPIsValidUName(vmMap, dec, "decrypt")) {
        s_uname = dec;
        return s_uname;
    }
    // 2) thử direct + deref 1 nấc (như Kernel ResolveUName)
    BOOL ok = NO;
    uint64_t direct = ESPReadU64(vmMap, gnamesStatic, &ok);
    uint64_t direct8 = ok ? ESPReadU64(vmMap, gnamesStatic + 8, &ok) : 0;
    uint64_t cands[6] = {0,0,0,0,0,0};
    cands[0] = ok ? direct : 0;
    cands[1] = ok ? direct8 : 0;
    if (direct >= 0x10000000ULL) {
        cands[2] = ESPReadU64(vmMap, direct, &ok);
        if (!ok) cands[2] = 0;
        cands[3] = ESPReadU64(vmMap, direct + 8, &ok);
        if (!ok) cands[3] = 0;
    }
    if (direct8 >= 0x10000000ULL) {
        cands[4] = ESPReadU64(vmMap, direct8, &ok);
        if (!ok) cands[4] = 0;
        cands[5] = ESPReadU64(vmMap, direct8 + 8, &ok);
        if (!ok) cands[5] = 0;
    }
    for (int i = 0; i < 6; i++) {
        if (cands[i] && ESPIsValidUName(vmMap, cands[i], "direct")) {
            s_uname = cands[i];
            return s_uname;
        }
    }
    ESPLog("UName resolve FAIL base=0x%llx dec=0x%llx", (unsigned long long)gameBase, (unsigned long long)dec);
    return 0;
}

BOOL ESPActorName(uint64_t vmMap, uint64_t uname, uint64_t actor, char outName[64]) {
    if (outName) outName[0] = '\0';
    if (!uname || !actor) return NO;
    BOOL ok = NO;
    uint32_t fid = ESPReadU32(vmMap, actor + 0x18, &ok); // NamePrivate.ComparisonIndex
    if (!ok) return NO;
    return ESPActorNameByID(vmMap, uname, fid, outName);
}

BOOL ESPActorNameByID(uint64_t vmMap, uint64_t uname, uint32_t fid, char outName[64]) {
    if (outName) outName[0] = '\0';
    if (!uname || !outName) return NO;
    if (fid >= kFNameMaxID) return NO;
    BOOL ok = NO;
    auto it = s_nameCache.find(fid);
    if (it != s_nameCache.end()) {
        const std::string &s = it->second;
        if (s.empty()) return NO;
        strncpy(outName, s.c_str(), 63);
        outName[63] = '\0';
        return YES;
    }
    uint32_t chunk = fid / kFNameElementsPerChunk;
    uint32_t within = fid % kFNameElementsPerChunk;
    uint64_t arr = ESPReadU64(vmMap, uname + (uint64_t)chunk * 8, &ok);
    if (!ok || !arr) return NO;
    uint64_t entry = ESPReadU64(vmMap, arr + (uint64_t)within * 8, &ok);
    if (!ok || !entry) return NO;
    char name[64] = {0};
    if (!ESPReadCString(vmMap, entry + 0xC, name, sizeof(name))) return NO;
    if (s_nameCache.size() > 5000) s_nameCache.clear();
    s_nameCache[fid] = name;
    strncpy(outName, name, 63);
    outName[63] = '\0';
    return YES;
}

// Hình nhân huấn luyện. Object ShootingPracticeTarget chỉ dài ~0x4F8 (field
// cuối MoveComp 0x4F0), nên không thể nhận diện bằng field (ví dụ đọc 0x510
// để check "không có skeletal Mesh" là đọc rác ngoài object). Tên thì đúng.
BOOL ESPIsTrainingDummyName(const char *name) {
    if (!name || !name[0]) return NO;
    static const char *keys[] = {
        "ShootingPracticeTarget", // Character/Target trong sân tập
        "PracticeTarget",
        "PracticeDummy",
        "TargetDummy",
        "TrainingDummy",
        "ShootingTarget",
    };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        if (strstr(name, keys[i]) != NULL) return YES;
    }
    return NO;
}

BOOL ESPIsPlayerCharacterName(const char *name) {
    if (!name || !name[0]) return NO;
    static const char *keys[] = {
        "PlayerPawn", "PlayerCharacter", "PlayerControllertSl",
        "_PlayerPawn_TPlanAI_C", "CharacterModelTaget", "FakePlayer_AIPawn",
        "STExtraPlayerCharacter", "STExtraBaseCharacter", "BP_PlayerPawn", "PlanAI",
    };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        if (strstr(name, keys[i]) != NULL) return YES;
    }
    return NO;
}

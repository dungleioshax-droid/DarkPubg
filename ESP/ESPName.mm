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
// Offset của chuỗi tên trong FNameEntry — bản game này có thể khác 0xC.
// 0 = chưa dò được (dò khi validate UName).
static uint32_t s_nameStrOffset = 0;

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

// Đọc tên ID qua chunk walk, không cache (dùng để dò layout FNameEntry).
static BOOL ESPFetchNameByID(uint64_t vmMap, uint64_t uname, uint32_t fid,
                             uint32_t strOff, char *out, int maxLen) {
    if (out && maxLen > 0) out[0] = '\0';
    BOOL ok = NO;
    uint32_t chunk = fid / kFNameElementsPerChunk;
    uint32_t within = fid % kFNameElementsPerChunk;
    uint64_t arr = ESPReadU64(vmMap, uname + (uint64_t)chunk * 8, &ok);
    if (!ok || !arr) return NO;
    uint64_t entry = ESPReadU64(vmMap, arr + (uint64_t)within * 8, &ok);
    if (!ok || !entry) return NO;
    return ESPReadCString(vmMap, entry + strOff, out, maxLen);
}

static BOOL ESPStrPrintable(const char *s) {
    if (!s || !s[0]) return NO;
    int len = 0;
    for (; s[len]; len++) {
        unsigned char c = (unsigned char)s[len];
        if (c < 0x20 || c > 0x7e) return NO;
        if (len > 64) return NO;
    }
    return len >= 2;
}

// Dò offset chuỗi tên trong FNameEntry. Log thực tế: với 0xC cứng thì
// "UName resolve FAIL dec=0x0" mọi session -> mất hết nhận diện theo tên.
static uint32_t ESPDetectNameOffset(uint64_t vmMap, uint64_t uname) {
    static const uint32_t offsets[] = {0xC, 0x10, 0x8, 0x4, 0x2, 0x14, 0x18, 0x20};
    for (size_t i = 0; i < sizeof(offsets) / sizeof(offsets[0]); i++) {
        char n0[64] = {0}, n1[64] = {0};
        if (!ESPFetchNameByID(vmMap, uname, 0, offsets[i], n0, sizeof(n0))) continue;
        if (!ESPFetchNameByID(vmMap, uname, 1, offsets[i], n1, sizeof(n1))) continue;
        if (strcmp(n0, "None") == 0 && strcmp(n1, "ByteProperty") == 0) {
            ESPLog("FName layout: strOff=0x%x (None/ByteProperty)", (unsigned)offsets[i]);
            return offsets[i];
        }
    }
    // Không khớp None/ByteProperty: nhận offset nào ra 2 tên in được liền nhau.
    for (size_t i = 0; i < sizeof(offsets) / sizeof(offsets[0]); i++) {
        char n0[96] = {0}, n1[96] = {0};
        if (!ESPFetchNameByID(vmMap, uname, 0, offsets[i], n0, sizeof(n0))) continue;
        if (!ESPFetchNameByID(vmMap, uname, 1, offsets[i], n1, sizeof(n1))) continue;
        if (ESPStrPrintable(n0) && ESPStrPrintable(n1)) {
            ESPLog("FName layout lax: strOff=0x%x name0=%s name1=%s",
                   (unsigned)offsets[i], n0, n1);
            return offsets[i];
        }
    }
    return 0;
}

// Test UName candidate: ID 0 phải là None, 1 là ByteProperty (theo DUMP/Logs.txt).
static BOOL ESPIsValidUName(uint64_t vmMap, uint64_t cand, const char *why) {
    if (cand < 0x10000000ULL) return NO;
    uint32_t off = s_nameStrOffset;
    if (!off) {
        off = ESPDetectNameOffset(vmMap, cand);
        if (!off) return NO;
        s_nameStrOffset = off;
    }
    char n0[64] = {0}, n1[64] = {0};
    if (!ESPFetchNameByID(vmMap, cand, 0, off, n0, sizeof(n0))) return NO;
    if (!ESPFetchNameByID(vmMap, cand, 1, off, n1, sizeof(n1))) return NO;
    BOOL valid = (strcmp(n0, "None") == 0 && strcmp(n1, "ByteProperty") == 0);
    if (!valid) {
        BOOL propOk = (strcmp(n1, "ByteProperty") == 0 || strcmp(n1, "IntProperty") == 0 ||
                       strcmp(n1, "BoolProperty") == 0 || strcmp(n1, "FloatProperty") == 0);
        valid = (propOk && n0[0] != '\0');
    }
    if (valid) {
        ESPLog("UName ok via %s: 0x%llx (%s/%s) strOff=0x%x",
               why, (unsigned long long)cand, n0, n1, (unsigned)off);
    }
    return valid;
}

// Chẩn đoán GNames khi resolve fail: in ra giá trị THẬT ở static + chuỗi đọc
// được từ từng candidate (xem Documents/ESP.log) để biết hỏng ở đâu: static
// rỗng (đọc __DATA fail) / pointer sai / layout FNameEntry khác.
static void ESPNameDiag(uint64_t vmMap, uint64_t gnamesStatic, uint64_t dec) {
    BOOL ok = NO;
    uint32_t raw = ESPReadU32(vmMap, gnamesStatic, &ok);
    BOOL okRaw = ok;
    uint64_t p0 = ESPReadU64(vmMap, gnamesStatic, &ok);
    BOOL ok0 = ok;
    uint64_t p8 = ESPReadU64(vmMap, gnamesStatic + 8, &ok);
    BOOL ok8 = ok;
    uint64_t p10 = ESPReadU64(vmMap, gnamesStatic + 0x10, &ok);
    BOOL ok10 = ok;
    ESPLog("uname diag static=0x%llx rawOK=%d raw32=0x%x p0OK=%d p0=0x%llx p8OK=%d p8=0x%llx p10OK=%d p10=0x%llx dec=0x%llx",
           (unsigned long long)gnamesStatic, okRaw, raw, ok0, (unsigned long long)p0,
           ok8, (unsigned long long)p8, ok10, (unsigned long long)p10, (unsigned long long)dec);
    uint64_t altStatic = gnamesStatic - 0x4FA4000ULL;
    uint64_t a0 = ESPReadU64(vmMap, altStatic, &ok);
    BOOL okA0 = ok;
    uint64_t a8 = ESPReadU64(vmMap, altStatic + 8, &ok);
    BOOL okA8 = ok;
    uint64_t a10 = ESPReadU64(vmMap, altStatic + 0x10, &ok);
    BOOL okA10 = ok;
    ESPLog("uname diag altStatic=0x%llx a0OK=%d a0=0x%llx a8OK=%d a8=0x%llx a10OK=%d a10=0x%llx",
           (unsigned long long)altStatic, okA0, (unsigned long long)a0,
           okA8, (unsigned long long)a8, okA10, (unsigned long long)a10);
    uint64_t cands[6] = { p0, p8, p10, a0, a8, a10 };
    for (int i = 0; i < 6; i++) {
        uint64_t cand = cands[i];
        if (cand < 0x10000000ULL) {
            ESPLog("uname diag cand%d=0x%llx skip (qua nho)", i, (unsigned long long)cand);
            continue;
        }
        uint64_t arr = ESPReadU64(vmMap, cand, &ok);
        if (!ok) {
            ESPLog("uname diag cand%d=0x%llx arr=READ FAIL", i, (unsigned long long)cand);
            continue;
        }
        uint64_t e0 = ESPReadU64(vmMap, arr, &ok);
        BOOL okE0 = ok;
        uint64_t e1 = ESPReadU64(vmMap, arr + 8, &ok);
        BOOL okE1 = ok;
        char s0[24] = {0}, s1[24] = {0};
        int r0 = (okE0 && ESPReadCString(vmMap, e0 + 0xC, s0, (int)sizeof(s0))) ? 1 : 0;
        int r1 = (okE1 && ESPReadCString(vmMap, e1 + 0xC, s1, (int)sizeof(s1))) ? 1 : 0;
        ESPLog("uname diag cand%d=0x%llx arr=0x%llx e0=0x%llx(%d,%s) e1=0x%llx(%d,%s)",
               i, (unsigned long long)cand, (unsigned long long)arr,
               (unsigned long long)e0, r0, s0, (unsigned long long)e1, r1, s1);
    }
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
    uint64_t cands[12] = {0,0,0,0,0,0,0,0,0,0,0,0};
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
    // +0x10: một số build để con trỏ UName ở đây.
    uint64_t direct10 = ESPReadU64(vmMap, gnamesStatic + 0x10, &ok);
    cands[6] = ok ? direct10 : 0;
    if (direct10 >= 0x10000000ULL) {
        cands[7] = ESPReadU64(vmMap, direct10, &ok);
        if (!ok) cands[7] = 0;
    }
    // Dump có 2 cách ghi địa chỉ (base 0x100000000 vs base = file offset của
    // __TEXT 0x4FA4000). Nếu cách chính trượt thì thử static dịch đi 0x4FA4000
    // và con trỏ ở +0/+8/+0x10 của nó (1 nấc).
    uint64_t altStatic = gnamesStatic - 0x4FA4000ULL;
    uint64_t alt = ESPReadU64(vmMap, altStatic, &ok);
    cands[8] = ok ? alt : 0;
    uint64_t alt8 = ESPReadU64(vmMap, altStatic + 8, &ok);
    cands[9] = ok ? alt8 : 0;
    uint64_t alt10 = ESPReadU64(vmMap, altStatic + 0x10, &ok);
    cands[10] = ok ? alt10 : 0;
    if (alt >= 0x10000000ULL) {
        cands[11] = ESPReadU64(vmMap, alt, &ok);
        if (!ok) cands[11] = 0;
    }
    for (int i = 0; i < 12; i++) {
        if (cands[i] && ESPIsValidUName(vmMap, cands[i], "direct")) {
            s_uname = cands[i];
            return s_uname;
        }
    }
    {
        static uint64_t s_diagBase = 0;
        if (s_diagBase != gameBase) {
            s_diagBase = gameBase;
            ESPNameDiag(vmMap, gnamesStatic, dec);
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
    uint32_t strOff = s_nameStrOffset ? s_nameStrOffset : 0xC;
    if (!ESPReadCString(vmMap, entry + strOff, name, sizeof(name))) return NO;
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
        // Sân tập có 2 loại: ShootingPracticeTarget (bàn/bia có MaxHealth
        // 0x4AC) và ShootingPracticeScoreTarget (hình nhân người, layout
        // ADecoratorActor — chú ý chuỗi này KHÔNG chứa "ShootingPracticeTarget").
        "ShootingPracticeTarget",
        "ShootingPracticeScoreTarget",
        "PracticeScoreTarget",
        "ScoreTarget",
        "PracticeTarget",
        "PracticeDummy",
        "TargetDummy",
        "TrainingDummy",
        "ShootingTarget",
        "Puppet", // PhotonDestructiblePuppetTarget — hình nộm trong sân tập
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

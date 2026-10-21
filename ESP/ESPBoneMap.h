//
//  ESPBoneMap.h
//  Tự dò bảng index 17 khớp từ CHÍNH skeleton của bản game — không cần GNames,
//  không phụ thuộc thứ tự xương hard-code.
//
//  Vì sao cần: 3 bảng index cũ (kESPBoneMaps) chỉ đúng khi rig trùng đúng bản
//  tác giả đoán (vd map A lấy clavicle làm vai -> khoảng cách upperarm->hand
//  ~55cm, validator loại). Rig PUBG đổi theo season/skin nên hard-code luôn có
//  lúc sai -> "bones no-match" dù offset BoneSpaceTransforms đúng.
//
//  Cách dò: đọc ref pose của USkeleton (RefLocalPoses), nhân dồn theo
//  BoneTree.ParentIndex để ra T-pose component-space, rồi nhận diện khớp bằng
//  CẤU TRÚC CÂY + hình học:
//    - pelvis = tổ tiên chung gần nhất của 2 bàn chân (2 xương thấp nhất 2 bên)
//    - hông/gối = con trên đường từ pelvis xuống bàn chân
//    - chuỗi cột sống = từ pelvis đi lên theo con có Z cao nhất
//    - ngực = đốt trên chuỗi có >= 2 nhánh tay; vai/khuỷu/tay = đi ra theo ±Y
//  Ref pose (T/A-pose) ổn định nên không phụ thuộc pose đang chơi (nằm/ngồi).
//
//  Header này chỉ dùng nội bộ engine: mọi hàm `static`, không ObjC, để build
//  được cả trên iOS (ESPEngine.mm) và harness test trên macOS/Linux.
//

#ifndef ESPBoneMap_h
#define ESPBoneMap_h

#include <stdio.h>
#include <math.h>
#include <string.h>

#include "ESPUE.h"

static inline float ESPBoneMapDist(const ESPVector &a, const ESPVector &b) {
    float dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
    return sqrtf(dx * dx + dy * dy + dz * dz);
}

static int ESPBoneMapChildCount(int parent, int n, const int *parents) {
    int c = 0;
    for (int i = 0; i < n; i++) if (parents[i] == parent) c++;
    return c;
}

static int ESPBoneMapHighestChild(int parent, int n, const int *parents,
                                  const ESPVector *p) {
    int best = -1;
    float bz = -1e30f;
    for (int i = 0; i < n; i++) {
        if (parents[i] != parent) continue;
        if (p[i].z > bz) { bz = p[i].z; best = i; }
    }
    return best;
}

// node là tổ tiên của target? (đi ngược parents, có guard chống cycle)
static int ESPBoneMapIsAncestor(int anc, int node, int n, const int *parents) {
    int guard = 0;
    while (node >= 0 && node < n && guard++ <= n) {
        if (node == anc) return 1;
        node = parents[node];
    }
    return 0;
}

// Con trực tiếp của `anc` nằm trên đường đi xuống `target` (-1 nếu không có).
static int ESPBoneMapChildOnPath(int anc, int target, int n, const int *parents) {
    int guard = 0;
    int cur = target;
    while (cur >= 0 && cur < n && guard++ <= n) {
        int par = parents[cur];
        if (par == anc) return cur;
        cur = par;
    }
    return -1;
}

static int ESPBoneMapLCA(int a, int b, int n, const int *parents) {
    int guard = 0;
    int cur = a;
    while (cur >= 0 && cur < n && guard++ <= n) {
        if (ESPBoneMapIsAncestor(cur, b, n, parents)) return cur;
        cur = parents[cur];
    }
    return -1;
}

static int ESPBoneMapInChain(const int *chain, int clen, int idx) {
    for (int i = 0; i < clen; i++) if (chain[i] == idx) return 1;
    return 0;
}

// Dựng bảng index từ ref pose (component space, cm, Z hướng lên).
// Trả YES + outMap[ESPBone_Count] khi nhận diện đủ 17 khớp và hình học hợp lý;
// NO nếu rig không phải humanoid / dữ liệu rác. `why` (tuỳ chọn) nhận lý do.
static int ESPBoneMapBuild(const ESPVector *p, int n, const int *parents,
                           int outMap[ESPBone_Count],
                           char *why, int whyCap) {
#define ESP_BM_FAIL(msg) do { \
    if (why && whyCap > 0) snprintf(why, (size_t)whyCap, "%s", msg); \
    return 0; \
} while (0)

    if (!p || !parents || !outMap || n < 18) ESP_BM_FAIL("args");

    // ParentIndex phải đứng trước con (DFS của FReferenceSkeleton). Sai thứ tự
    // = đọc nhầm offset BoneTree, không dựng cây được.
    for (int i = 0; i < n; i++) {
        if (parents[i] < -1 || parents[i] >= i) ESP_BM_FAIL("parent order");
    }

    int root = -1;
    for (int i = 0; i < n; i++) {
        if (parents[i] < 0) { root = i; break; }
    }
    if (root < 0) ESP_BM_FAIL("no root");

    // 1) 2 bàn chân = 2 LÁ (không có con) thấp nhất ở 2 phía Y khác nhau.
    //    Chỉ xét lá: root/thigh cũng nằm thấp nhưng là tổ tiên -> nếu lấy theo
    //    Z tuyệt đối sẽ nhận root (z=0) rồi LCA hỏng. Bàn chân/ngón chân luôn
    //    là lá trong ref pose, nên đây là mốc ổn định nhất.
    int a = -1, b = -1;
    for (int i = 0; i < n; i++) {
        if (ESPBoneMapChildCount(i, n, parents) != 0) continue;
        if (p[i].z < -1e8f) continue;
        if (a < 0 || p[i].z < p[a].z) a = i;
    }
    for (int i = 0; i < n; i++) {
        if (i == a) continue;
        if (ESPBoneMapChildCount(i, n, parents) != 0) continue;
        if (fabsf(p[i].y - p[a].y) < 10.0f) continue;
        if (b < 0 || p[i].z < p[b].z) b = i;
    }
    if (a < 0 || b < 0) ESP_BM_FAIL("feet");
    if (ESPBoneMapIsAncestor(a, b, n, parents) ||
        ESPBoneMapIsAncestor(b, a, n, parents)) ESP_BM_FAIL("feet related");

    // 2) pelvis = tổ tiên chung của 2 chân; hông/gối = con trên đường xuống.
    int pelvis = ESPBoneMapLCA(a, b, n, parents);
    if (pelvis < 0 || pelvis == a || pelvis == b) ESP_BM_FAIL("pelvis");
    int hipA = ESPBoneMapChildOnPath(pelvis, a, n, parents);
    int hipB = ESPBoneMapChildOnPath(pelvis, b, n, parents);
    if (hipA < 0 || hipB < 0 || hipA == hipB) ESP_BM_FAIL("hips");
    int kneeA = ESPBoneMapChildOnPath(hipA, a, n, parents);
    int kneeB = ESPBoneMapChildOnPath(hipB, b, n, parents);
    if (kneeA < 0 || kneeB < 0) ESP_BM_FAIL("knees");
    // Hông phải nằm trên pelvis (trục Z hướng lên) và gối thấp hơn hông.
    if (!(p[hipA].z < p[pelvis].z + 5.0f && p[kneeA].z < p[hipA].z + 5.0f)) {
        ESP_BM_FAIL("leg z order");
    }

    // 3) Chuỗi cột sống: từ pelvis đi lên theo con có Z cao nhất (tránh chân).
    int chain[16];
    int clen = 0;
    int cur = pelvis;
    for (int guard = 0; guard < 16; guard++) {
        int nx = ESPBoneMapHighestChild(cur, n, parents, p);
        if (nx < 0) break;
        if (nx == hipA || nx == hipB) break;
        chain[clen++] = nx;
        cur = nx;
    }
    if (clen < 3) ESP_BM_FAIL("spine chain");

    // 4) Ngực = đốt gần cổ nhất còn 2 nhánh tay (clavicle/upperarm 2 bên).
    int chestIdx = -1;
    for (int k = clen - 1; k >= 0 && chestIdx < 0; k--) {
        int node = chain[k];
        int branches = 0;
        for (int j = 0; j < n; j++) {
            if (parents[j] != node) continue;
            if (ESPBoneMapInChain(chain, clen, j)) continue;
            if (fabsf(p[j].y - p[node].y) < 3.0f) continue;
            branches++;
        }
        if (branches >= 2) chestIdx = k;
    }
    if (chestIdx < 0) chestIdx = (clen >= 4) ? clen - 3 : 0;
    int chest = chain[chestIdx];
    // Cổ = đốt kế tiếp trên chuỗi, đầu = đốt sau cổ. Lấy theo VỊ TRÍ TRÊN CHUỖI
    // thay vì 2 xương cuối: rig có hair/hat là lá trên đầu thì đuôi chuỗi là tóc,
    // không phải hộp sọ -> head dot sẽ lơ lửng trên đầu.
    int neck = (chestIdx + 1 < clen) ? chain[chestIdx + 1] : chain[clen - 1];
    int head = (chestIdx + 2 < clen) ? chain[chestIdx + 2] : chain[clen - 1];
    if (chest == head || chest == neck || neck == head) ESP_BM_FAIL("chest");

    // 5) Tay: từ ngực đi ra theo |Y| lớn nhất. Rig có clavicle -> chuỗi >= 4
    //    xương (clavicle, upperarm, lowerarm, hand) nên bỏ clavicle.
    int shL = -1, elL = -1, haL = -1, shR = -1, elR = -1, haR = -1;
    for (int j = 0; j < n; j++) {
        if (parents[j] != chest) continue;
        if (ESPBoneMapInChain(chain, clen, j)) continue;
        float sideY = p[j].y - p[chest].y;
        if (fabsf(sideY) < 3.0f) continue;
        int arm[5];
        int alen = 0;
        int c = j;
        while (alen < 5 && c >= 0) {
            arm[alen++] = c;
            int next = -1;
            float best = -1.0f;
            for (int k = 0; k < n; k++) {
                if (parents[k] != c) continue;
                if (ESPBoneMapInChain(chain, clen, k)) continue;
                float d = fabsf(p[k].y - p[chest].y);
                if (d > best) { best = d; next = k; }
            }
            c = next;
        }
        if (alen < 2) continue;
        int sh, el, hd;
        if (alen >= 4) { sh = arm[1]; el = arm[2]; hd = arm[3]; }
        else if (alen == 3) { sh = arm[0]; el = arm[1]; hd = arm[2]; }
        else { sh = arm[0]; el = arm[1]; hd = arm[1]; }
        if (sideY > 0) { shR = sh; elR = el; haR = hd; }
        else { shL = sh; elL = el; haL = hd; }
    }
    if (shL < 0 || shR < 0) ESP_BM_FAIL("arms");

    // 6) Gán trái/phải theo Y của hông (UE: trục Y ngang; quy ước không đổi hình).
    int hipL, kneeL, footL, hipR, kneeR, footR;
    if (p[hipA].y <= p[hipB].y) {
        hipL = hipA; kneeL = kneeA; footL = a;
        hipR = hipB; kneeR = kneeB; footR = b;
    } else {
        hipL = hipB; kneeL = kneeB; footL = b;
        hipR = hipA; kneeR = kneeA; footR = a;
    }

    int map[ESPBone_Count] = {
        head, neck, chest, pelvis,
        shL, elL, haL, shR, elR, haR,
        hipL, kneeL, footL, hipR, kneeR, footR,
        root
    };

    // 7) Đủ khớp (trừ Root được trùng pelvis) + hình học người thật.
    for (int i = 0; i < ESPBone_Count; i++) {
        if (map[i] < 0 || map[i] >= n) ESP_BM_FAIL("index range");
        if (i == ESPBone_Root) continue;
        for (int j = i + 1; j < ESPBone_Count; j++) {
            if (j == ESPBone_Root) continue;
            if (map[i] == map[j]) ESP_BM_FAIL("duplicate joint");
        }
    }
    float hp = ESPBoneMapDist(p[head], p[pelvis]);
    if (hp < 40.0f || hp > 150.0f) ESP_BM_FAIL("head-pelvis");
    if (ESPBoneMapDist(p[head], p[neck]) > 45.0f) ESP_BM_FAIL("head-neck");
    if (ESPBoneMapDist(p[neck], p[chest]) > 60.0f) ESP_BM_FAIL("neck-chest");
    for (int side = 0; side < 2; side++) {
        int sh = side ? shR : shL;
        int el = side ? elR : elL;
        int hd = side ? haR : haL;
        if (ESPBoneMapDist(p[sh], p[chest]) > 60.0f) ESP_BM_FAIL("shoulder");
        if (ESPBoneMapDist(p[sh], p[el]) > 55.0f) ESP_BM_FAIL("upper arm");
        if (ESPBoneMapDist(p[el], p[hd]) > 55.0f) ESP_BM_FAIL("forearm");
    }
    for (int side = 0; side < 2; side++) {
        int hpj = side ? hipR : hipL;
        int kn = side ? kneeR : kneeL;
        int ft = side ? footR : footL;
        if (ESPBoneMapDist(p[hpj], p[pelvis]) > 45.0f) ESP_BM_FAIL("hip");
        if (ESPBoneMapDist(p[hpj], p[kn]) < 15.0f ||
            ESPBoneMapDist(p[hpj], p[kn]) > 80.0f) ESP_BM_FAIL("thigh");
        if (ESPBoneMapDist(p[kn], p[ft]) < 15.0f ||
            ESPBoneMapDist(p[kn], p[ft]) > 80.0f) ESP_BM_FAIL("calf");
    }
    float sep = ESPBoneMapDist(p[shL], p[shR]);
    if (sep < 18.0f || sep > 90.0f) ESP_BM_FAIL("shoulder span");

    memcpy(outMap, map, sizeof(map));
    if (why && whyCap > 0) snprintf(why, (size_t)whyCap, "ok");
    return 1;
#undef ESP_BM_FAIL
}

#endif /* ESPBoneMap_h */

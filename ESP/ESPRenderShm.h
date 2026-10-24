//
//  ESPRenderShm.h
//  Kênh dữ liệu vẽ giữa app DarkSpeed (đọc kernel, tính box) và process
//  overlay `DarkSpeed -espgui` (ImGui + Metal).
//
//  Vì sao có file này: renderer cũ đẩy hình sang SpringBoard bằng RemoteCall
//  (CGPath/setPath/setFrame mỗi frame). Kiểu đó bắt buộc main thread của
//  SpringBoard chạy hàng chục remote call mỗi frame -> watchdog 0x8badf00d /
//  respring, và mỗi object/sel phải sống trong process khác.
//
//  Ở đây chỉ còn 1 lần memcpy mỗi frame vào vùng mmap chung:
//    - slot kép (double buffer): writer ghi slot KHÔNG phải slot đang đọc,
//      rồi publish bằng 1 store acquire/release vào `front`;
//    - không lock, không syscall trên đường nóng, không ai chờ ai;
//    - reader (renderer) đọc `front`, memcpy ra local, đọc lại `front` — nếu
//      đổi thì đọc lại (writer chỉ lật khi đã ghi xong slot mới).
//
//  File này là C++ THUẦN (chỉ mmap/open/atomic), không UIKit, để:
//    - app (ObjC++) và renderer (ObjC++ + Metal) dùng chung đúng một layout;
//    - test được trên Linux/macOS bằng g++ (xem tests/esprender_shm_test.cpp).
//
//  QUY ƯỚC TOẠ ĐỘ: commands nằm trong hệ "game landscape" (landW x landH) do
//  builder QBL sinh ra (ds_qbl_build_frame). Renderer tự map sang hệ cửa sổ
//  của nó bằng ESPRsMapPoint (cùng công thức ds_esp_map_point của app), nên
//  app không phải biết overlay đang ở orientation nào.
//

#ifndef ESPRenderShm_h
#define ESPRenderShm_h

#include <atomic>
#include <fcntl.h>
#include <new>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define ESP_RSHM_MAGIC 0x45535047u // 'ESPG'
#define ESP_RSHM_VERSION 1u
#define ESP_RSHM_SLOTS 2
#define ESP_RSHM_MAX_CMDS 256
#define ESP_RSHM_MAX_POINTS 1024
#define ESP_RSHM_TEXT_CAP 96

// Primitive — giữ đúng bộ của ESPDrawPrim (ESPOverlay.h) để app copy 1-1.
enum {
    ESPRsPrimRect = 1,
    ESPRsPrimPolyline = 2,
    ESPRsPrimCircle = 3,
    ESPRsPrimText = 4,
};

enum {
    ESP_RSHM_FLAG_VISIBLE = 1u << 0, // 0 = renderer xoá sạch frame
};

// UIInterfaceOrientation (không kéo UIKit vào header này).
enum {
    ESPRsOrientUnknown = 0,
    ESPRsOrientPortrait = 1,
    ESPRsOrientPortraitUpsideDown = 2,
    ESPRsOrientLandscapeLeft = 3,
    ESPRsOrientLandscapeRight = 4,
};

struct ESPRsPoint {
    float x, y;
};

struct ESPRsCmd {
    uint8_t prim;     // ESPRsPrim*
    uint8_t filled;   // 1 = tô (rect/circle)
    uint8_t outlined; // text: 1 = chữ có viền
    uint8_t align;    // text: 0 trái, 1 giữa, 2 phải
    uint8_t bucket;   // style bucket của builder QBL (giữ để debug)
    uint8_t closed;   // polyline: 1 = nối điểm cuối về điểm đầu
    uint8_t _pad[2];
    uint32_t color;   // 0xAARRGGBB
    float width;      // độ dày nét
    float radius;     // circle
    float rx, ry, rw, rh;
    uint16_t pointStart;
    uint16_t pointCount;
    float fontSize;
    float tx, ty; // text: điểm neo (theo align)
    char text[ESP_RSHM_TEXT_CAP];
};

// 1 frame. `viewportW/H` là hệ toạ độ của commands (landscape, pt).
struct alignas(64) ESPRsFrame {
    uint32_t magic;
    uint32_t version;
    uint32_t cmdCount;
    uint32_t pointCount;
    float viewportW;
    float viewportH;
    int32_t orientation;   // ESPRsOrient*
    uint32_t flags;        // ESP_RSHM_FLAG_*
    uint64_t frameId;      // tăng mỗi frame (debug/tuổi thọ frame)
    double publishTime;    // CFAbsoluteTime (giây) — renderer dùng làm watchdog
    uint32_t slotIndex;    // writer ghi vào slot nào (debug)
    uint32_t _pad0;
    ESPRsCmd cmds[ESP_RSHM_MAX_CMDS];
    ESPRsPoint points[ESP_RSHM_MAX_POINTS];
};

struct alignas(64) ESPRsShm {
    uint32_t magic;
    uint32_t version;
    uint32_t slotBytes;
    uint32_t totalBytes;
    // Slot "hoàn chỉnh gần nhất". Chỉ 1 store/ frame.
    std::atomic<uint32_t> front;
    // Seqlock theo từng slot: lẻ = đang ghi. `front` một mình không đủ: writer
    // có thể lật 2 slot trong lúc reader đang memcpy slot của nó (front quay
    // lại cùng parity -> không phát hiện được). Reader so seq trước/sau copy.
    std::atomic<uint32_t> slotSeq[ESP_RSHM_SLOTS];
    uint32_t _pad0;
    ESPRsFrame slots[ESP_RSHM_SLOTS];
};

static inline size_t ESPRsShmSize(void) {
    return sizeof(ESPRsShm);
}

// Mở (tạo nếu chưa có) + mmap file shm. Cả 2 process gọi hàm này với cùng path.
// Trả NULL nếu không mở/mmap được (renderer sẽ không chạy, app fallback QBL).
static inline ESPRsShm *ESPRsShmOpen(const char *path) {
    if (!path || !path[0]) return NULL;
    int fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0) return NULL;
    const size_t need = ESPRsShmSize();
    struct stat st;
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < need) {
        if (ftruncate(fd, (off_t)need) != 0) {
            close(fd);
            return NULL;
        }
    }
    void *m = mmap(NULL, need, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return NULL;
    ESPRsShm *shm = (ESPRsShm *)m;
    if (shm->magic != ESP_RSHM_MAGIC || shm->version != ESP_RSHM_VERSION ||
        shm->totalBytes != (uint32_t)need) {
        // Header chưa có/khác version: khởi tạo lại. Dùng placement-new thay
        // memset vì ESPRsShm chứa std::atomic (không trivial-copyable).
        ::new (static_cast<void *>(shm)) ESPRsShm();
        shm->magic = ESP_RSHM_MAGIC;
        shm->version = ESP_RSHM_VERSION;
        shm->slotBytes = (uint32_t)sizeof(ESPRsFrame);
        shm->totalBytes = (uint32_t)need;
        shm->front.store(0, std::memory_order_release);
    }
    return shm;
}

static inline void ESPRsShmClose(ESPRsShm *shm) {
    if (!shm) return;
    munmap(shm, ESPRsShmSize());
}

// Publish 1 frame: ghi slot kế tiếp rồi lật `front`. Writer DUY NHẤT (ESP tick).
static inline void ESPRsShmPublish(ESPRsShm *shm, const ESPRsFrame *frame) {
    if (!shm || !frame) return;
    uint32_t front = shm->front.load(std::memory_order_relaxed);
    uint32_t next = (front + 1u) % ESP_RSHM_SLOTS;
    ESPRsFrame *dst = &shm->slots[next];
    uint32_t seq = shm->slotSeq[next].load(std::memory_order_relaxed);
    seq = (seq + 1u) | 1u; // lẻ = đang ghi
    shm->slotSeq[next].store(seq, std::memory_order_release);
    memcpy((void *)dst, frame, sizeof(ESPRsFrame));
    dst->magic = ESP_RSHM_MAGIC;
    dst->version = ESP_RSHM_VERSION;
    dst->slotIndex = next;
    std::atomic_thread_fence(std::memory_order_release);
    shm->slotSeq[next].store(seq + 1u, std::memory_order_release); // chẵn = xong
    shm->front.store(next, std::memory_order_release);
}

// Đọc frame mới nhất. false = chưa có frame hợp lệ / đang bị ghi dở.
static inline bool ESPRsShmRead(ESPRsShm *shm, ESPRsFrame *out) {
    if (!shm || !out) return false;
    for (int attempt = 0; attempt < 8; attempt++) {
        uint32_t front = shm->front.load(std::memory_order_acquire);
        if (front >= ESP_RSHM_SLOTS) return false;
        uint32_t seq0 = shm->slotSeq[front].load(std::memory_order_acquire);
        if (seq0 & 1u) continue; // writer đang ghi đúng slot này
        memcpy(out, (const void *)&shm->slots[front], sizeof(ESPRsFrame));
        if (shm->slotSeq[front].load(std::memory_order_acquire) != seq0) continue;
        if (out->magic != ESP_RSHM_MAGIC || out->version != ESP_RSHM_VERSION) return false;
        return true;
    }
    return false;
}

static inline void ESPRsFrameReset(ESPRsFrame *f) {
    if (!f) return;
    memset(f, 0, sizeof(*f));
    f->magic = ESP_RSHM_MAGIC;
    f->version = ESP_RSHM_VERSION;
}

// Thêm 1 lệnh; trả index hoặc -1 nếu đầy (renderer vẫn vẽ phần đã có).
static inline int ESPRsFrameAddCmd(ESPRsFrame *f, const ESPRsCmd *cmd) {
    if (!f || !cmd || f->cmdCount >= ESP_RSHM_MAX_CMDS) return -1;
    f->cmds[f->cmdCount] = *cmd;
    return (int)f->cmdCount++;
}

static inline int ESPRsFrameAddPoints(ESPRsFrame *f, const ESPRsPoint *pts, int count) {
    if (!f || !pts || count <= 0) return -1;
    if (f->pointCount + (uint32_t)count > ESP_RSHM_MAX_POINTS) return -1;
    int start = (int)f->pointCount;
    memcpy(&f->points[start], pts, sizeof(ESPRsPoint) * (size_t)count);
    f->pointCount += (uint32_t)count;
    return start;
}

#endif /* ESPRenderShm_h */

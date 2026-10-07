//
//  ESPLog.mm
//  Breadcrumb log để debug: Documents/ESP.log, /tmp/ESP.log, os_log.
//
//  I/O: mỗi đường giữ 1 file handle MỞ MỘT LẦN (append). Trước đây MỖI dòng
//  là attributesOfItemAtPath + fileExists + open + seek + write + close ×3
//  file — vài chục dòng/giây (BOX-SUM, scan, BOX-JUMP) = hàng trăm syscall/giây
//  trên NSLock DÙNG CHUNG của mọi queue (tick 40Hz, scan nền, bridge present)
//  -> lock convoy thấy rõ: refresh bị chặn giữa chừng = box đứng rồi nhảy.
//  Giờ mỗi dòng chỉ còn write()×3 (µs). Rotation kiểm tra theo size đã track
//  thay vì stat mỗi dòng.
//

#import "ESPLog.h"
#import <stdarg.h>
#import <os/log.h>

static NSLock *s_espLogLock = nil;
static NSString *s_espLogPaths[3] = {nil, nil, nil};
static NSFileHandle *s_espLogHandles[3] = {nil, nil, nil};
static unsigned long long s_espLogSizes[3] = {0, 0, 0};
static BOOL s_espLogPathsInit = NO;

static const unsigned long long kESPLogMaxBytes = 1024 * 1024; // 1MB rotation

static void ESPLogPathsInitLocked(void) {
    if (s_espLogPathsInit) return;
    s_espLogPathsInit = YES;
    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = docs.firstObject;
    if (dir.length) {
        s_espLogPaths[0] = [dir stringByAppendingPathComponent:@"ESP.log"];
    }
    s_espLogPaths[1] = @"/tmp/ESP.log";
    s_espLogPaths[2] = @"/var/mobile/Documents/ESP.log";
}

// Mở lại handle cho đường index (file đã tồn tại thì append, chưa thì tạo).
// Gọi khi handle nil (lần đầu hoặc sau rotation/lỗi write).
static void ESPLogOpenLocked(int idx) {
    NSString *path = s_espLogPaths[idx];
    if (!path) return;
    @try {
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm fileExistsAtPath:path]) {
            [fm createFileAtPath:path contents:nil attributes:nil];
        }
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) return;
        unsigned long long size = 0;
        @try {
            size = [h seekToEndOfFile];
        } @catch (__unused NSException *e) {}
        s_espLogHandles[idx] = h;
        s_espLogSizes[idx] = size;
    } @catch (__unused NSException *e) {
        s_espLogHandles[idx] = nil;
        s_espLogSizes[idx] = 0;
    }
}

// Ghi 1 dòng (đã gồm \n) ra cả 3 đường. Gọi khi đang giữ s_espLogLock.
static void ESPLogWriteLocked(NSData *data) {
    ESPLogPathsInitLocked();
    NSFileManager *fm = NSFileManager.defaultManager;
    for (int i = 0; i < 3; i++) {
        NSString *path = s_espLogPaths[i];
        if (!path) continue;
        NSFileHandle *h = s_espLogHandles[i];
        // Rotation: vượt 1MB -> đóng, xoá, tạo mới, mở lại.
        if (h && s_espLogSizes[i] + data.length > kESPLogMaxBytes) {
            @try { [h closeFile]; } @catch (__unused NSException *e) {}
            s_espLogHandles[i] = nil;
            s_espLogSizes[i] = 0;
            @try { [fm removeItemAtPath:path error:nil]; } @catch (__unused NSException *e) {}
            h = nil;
        }
        if (!h) {
            ESPLogOpenLocked(i);
            h = s_espLogHandles[i];
            if (!h) continue;
        }
        @try {
            [h writeData:data];
            s_espLogSizes[i] += data.length;
        } @catch (__unused NSException *e) {
            // Handle hỏng (đĩa đầy/vùng sandbox) -> đóng để lần sau mở lại.
            @try { [h closeFile]; } @catch (__unused NSException *e2) {}
            s_espLogHandles[i] = nil;
            s_espLogSizes[i] = 0;
        }
    }
}

void ESPLogReset(void) {
    @try {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ s_espLogLock = [NSLock new]; });
        [s_espLogLock lock];
        @try {
            for (int i = 0; i < 3; i++) {
                if (s_espLogHandles[i]) {
                    @try { [s_espLogHandles[i] closeFile]; } @catch (__unused NSException *e) {}
                    s_espLogHandles[i] = nil;
                    s_espLogSizes[i] = 0;
                }
            }
            if (!s_espLogPathsInit) ESPLogPathsInitLocked();
            NSFileManager *fm = NSFileManager.defaultManager;
            for (int i = 0; i < 3; i++) {
                if (s_espLogPaths[i]) [fm removeItemAtPath:s_espLogPaths[i] error:nil];
            }
        } @finally {
            [s_espLogLock unlock];
        }
    } @catch (__unused NSException *e) {}
}

void ESPLog(const char *fmt, ...) {
    if (!fmt || !fmt[0]) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:@(fmt) arguments:args];
    va_end(args);
    if (!msg) return;

    os_log(OS_LOG_DEFAULT, "[DarkESP] %{public}@", msg);

    static dispatch_once_t once;
    dispatch_once(&once, ^{ s_espLogLock = [NSLock new]; });
    [s_espLogLock lock];
    @try {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", NSDate.date, msg];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) return;
        ESPLogWriteLocked(data);
    } @finally {
        [s_espLogLock unlock];
    }
}

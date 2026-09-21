//
//  ESPLog.mm
//  Breadcrumb log để debug không cần máy: Documents/ESP.log, tối đa 256KB.
//

#import "ESPLog.h"
#import <stdarg.h>

static NSString *ESPLogPath(void) {
    NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = docs.firstObject;
    if (!dir.length) return nil;
    return [dir stringByAppendingPathComponent:@"ESP.log"];
}

void ESPLog(const char *fmt, ...) {
    if (!fmt || !fmt[0]) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:@(fmt) arguments:args];
    va_end(args);
    if (!msg) return;
    // Ghi log từ nhiều threads (scan queue, bridge queue, esp worker) — lock
    // để seek+write không xé dòng lẫn nhau. @finally nhả lock trên mọi return.
    static NSLock *s_lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s_lock = [NSLock new]; });
    [s_lock lock];
    @try {
        NSString *path = ESPLogPath();
        if (!path) return;
        @try {
            NSFileManager *fm = NSFileManager.defaultManager;
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
            unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
            if (size > 256 * 1024) {
                [fm removeItemAtPath:path error:nil];
            }
            NSString *line = [NSString stringWithFormat:@"%@ %@\n", NSDate.date, msg];
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (!data) return;
            if (![fm fileExistsAtPath:path]) {
                [data writeToFile:path options:NSDataWritingAtomic error:nil];
                return;
            }
            NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!h) return;
            @try {
                [h seekToEndOfFile];
                [h writeData:data];
            } @finally {
                [h closeFile];
            }
        } @catch (__unused NSException *e) {
        }
    } @finally {
        [s_lock unlock];
    }
}

//
//  ESPLog.mm
//  Breadcrumb log để debug: Documents/ESP.log, /tmp/ESP.log, os_log.
//

#import "ESPLog.h"
#import <stdarg.h>
#import <os/log.h>

static void WriteLogToFile(NSString *path, NSData *data) {
    if (!path || !data) return;
    @try {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        if (size > 1024 * 1024) { // 1MB max rotation
            [fm removeItemAtPath:path error:nil];
        }
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
    } @catch (__unused NSException *e) {}
}

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

    os_log(OS_LOG_DEFAULT, "[DarkESP] %{public}@", msg);

    static NSLock *s_lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s_lock = [NSLock new]; });
    [s_lock lock];
    @try {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", NSDate.date, msg];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) return;
        NSString *docPath = ESPLogPath();
        if (docPath) WriteLogToFile(docPath, data);
        WriteLogToFile(@"/tmp/ESP.log", data);
        WriteLogToFile(@"/var/mobile/Documents/ESP.log", data);
    } @finally {
        [s_lock unlock];
    }
}

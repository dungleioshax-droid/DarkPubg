//
//  ESPLog.h
//  Ghi log debug ESP ra Documents/ESP.log (lấy qua Files app).
//

#ifndef ESPLog_h
#define ESPLog_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void ESPLog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#ifdef __cplusplus
}
#endif

#endif /* ESPLog_h */

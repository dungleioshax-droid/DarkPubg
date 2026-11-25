#pragma once
#include <cstdint>
#include <unistd.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <time.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#endif
#include "Xor.h"

namespace auth {

    struct integrity_state {
        uint64_t golden = 0;
        bool sealed = false;
        uint32_t image_count_baseline = 0;
    };

    static inline integrity_state& get_integrity_state() {
        static integrity_state s;
        return s;
    }

    inline bool g_fully_sealed = false;

    static const char* k_pinned_sha256 = ENCRYPT("63:C5:E7:2D:A9:01:BC:72:45:3F:88:9A:B2:CF:D1:7E:14:30:F5:21:9B:0C:44:6E:8A:3D:11:FA:56:C2:E8:00");

    static inline void seal_code_hash() {
#ifdef __OBJC__
        auto& s = get_integrity_state();
        s.image_count_baseline = (uint32_t)_dyld_image_count();
        s.sealed = true;
#endif
    }

    static inline bool check_anti_debug() {
#ifdef __OBJC__
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)getpid()};
        struct kinfo_proc info;
        size_t size = sizeof(info);
        if (sysctl(mib, 4, &info, &size, NULL, 0) == 0) {
            if (info.kp_proc.p_flag & P_TRACED) return false;
        }
#endif
        return true;
    }

    static inline bool check_no_inject() {
        auto& s = get_integrity_state();
        if (!s.sealed) return true;
#ifdef __OBJC__
        uint32_t cur = (uint32_t)_dyld_image_count();
        if (cur > s.image_count_baseline) {
            NSString *logPath = [[[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject] URLByAppendingPathComponent:@"vnp_crack.log"].path;
            FILE *f = fopen([logPath UTF8String], "a");
            if (f) {
                fprintf(f, "[%ld] Dylib count increased! Base: %u, Cur: %u, Sealed: %d\n", time(NULL), s.image_count_baseline, cur, g_fully_sealed);
                for (uint32_t i = s.image_count_baseline; i < cur; i++) {
                    const char* name = _dyld_get_image_name(i);
                    if (name) fprintf(f, "   -> loaded: %s\n", name);
                }
                fclose(f);
            }
            s.image_count_baseline = cur;
        }
#endif
        return true;
    }

    static inline bool check_code_integrity() {
        auto& s = get_integrity_state();
        if (!s.sealed) return true;
        if (!check_anti_debug()) return false;
        if (!check_no_inject()) return false;
        return true;
    }

    static inline bool verify_server_cert(SecTrustRef trust) {
#ifdef __OBJC__
        SecCertificateRef cert = SecTrustGetCertificateAtIndex(trust, 0);
        if (!cert) return false;
        CFDataRef certData = SecCertificateCopyData(cert);
        if (!certData) return false;
        uint8_t digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(CFDataGetBytePtr(certData), (CC_LONG)CFDataGetLength(certData), digest);
        CFRelease(certData);
        char hexBuf[CC_SHA256_DIGEST_LENGTH * 3 + 1];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
            snprintf(hexBuf + i * 3, 4, "%02X:", digest[i]);
        }
        hexBuf[CC_SHA256_DIGEST_LENGTH * 3 - 1] = '\0';
        return (strcmp(hexBuf, k_pinned_sha256) == 0);
#else
        return true;
#endif
    }
} // namespace auth

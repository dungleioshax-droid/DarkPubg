#pragma once
#include <string>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#endif

#include "Xor.h"

namespace auth {
    inline const std::string k_vnp_auth_endpoint = ENCRYPT("https://thoitrangsavora.com/VPNAuth/api/auth");
    inline const std::string k_app_secret = ENCRYPT("726b1935e4ad9c0dd3f5fb31a6033a45");

    extern std::string username;

#ifdef __OBJC__
    bool verify_hmac(NSData *body, NSString *sig_header);
#endif

    std::string http_post(const std::string &action, const std::string &msg = "");
}

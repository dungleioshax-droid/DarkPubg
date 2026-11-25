#import "auth_network.h"
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>

@interface VNPAuthSessionDelegate : NSObject <NSURLSessionDelegate>
@end

@implementation VNPAuthSessionDelegate
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential * _Nullable credential))completionHandler {
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}
@end

namespace auth {

bool verify_hmac(NSData *body, NSString *sig_header) {
    if (!sig_header || [sig_header length] == 0) return false;
    const char *secret_c_str = k_app_secret.c_str();
    size_t secret_len = strlen(secret_c_str);
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, secret_c_str, secret_len, [body bytes], [body length], digest);
    char hex_out[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        snprintf(hex_out + i * 2, 3, "%02x", digest[i]);
    }
    hex_out[CC_SHA256_DIGEST_LENGTH * 2] = '\0';
    const char *sig_c_str = [sig_header UTF8String];
    if (!sig_c_str || strlen(sig_c_str) != CC_SHA256_DIGEST_LENGTH * 2) return false;
    volatile int diff = 0;
    for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH * 2; i++) {
        diff |= (hex_out[i] ^ sig_c_str[i]);
    }
    return diff == 0;
}

std::string http_post(const std::string &action, const std::string &msg) {
    @autoreleasepool {
        NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:k_vnp_auth_endpoint.c_str()]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        [request setHTTPMethod:@"POST"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        NSString *hwid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
        NSDictionary *body = @{
            [NSString stringWithUTF8String:ENCRYPT("type")]: [NSString stringWithUTF8String:action.c_str()],
            [NSString stringWithUTF8String:ENCRYPT("key")]: [NSString stringWithUTF8String:auth::username.c_str()],
            [NSString stringWithUTF8String:ENCRYPT("app_secret")]: [NSString stringWithUTF8String:k_app_secret.c_str()],
            [NSString stringWithUTF8String:ENCRYPT("hwid")]: hwid,
            [NSString stringWithUTF8String:ENCRYPT("message")]: [NSString stringWithUTF8String:msg.c_str()]
        };
        NSError *error = nil;
        NSData *post_data = [NSJSONSerialization dataWithJSONObject:body options:0 error:&error];
        if (!post_data) return "";
        [request setHTTPBody:post_data];
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block std::string resp_str = "";
        VNPAuthSessionDelegate *sessionDelegate = [[VNPAuthSessionDelegate alloc] init];
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 10.0;
        cfg.timeoutIntervalForResource = 12.0;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:sessionDelegate delegateQueue:nil];
        NSURLSessionDataTask *data_task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *connErr) {
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                NSHTTPURLResponse *http_resp = (NSHTTPURLResponse*)response;
                if ((http_resp.statusCode == 200 || http_resp.statusCode == 400 || http_resp.statusCode == 403 || http_resp.statusCode == 429) && data) {
                    NSString *sig = [http_resp.allHeaderFields objectForKey:@"X-VNP-Sig"];
                    if (!sig) sig = [http_resp.allHeaderFields objectForKey:@"x-vnp-sig"];
                    if (sig && sig.length > 0) {
                        if (verify_hmac(data, sig)) {
                            resp_str = std::string((char*)[data bytes], [data length]);
                        }
                    } else if (data && data.length > 0) {
                        resp_str = std::string((char*)[data bytes], [data length]);
                    }
                }
            }
            dispatch_semaphore_signal(sema);
        }];
        [data_task resume];
        dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC));
        [session finishTasksAndInvalidate];
        return resp_str;
    }
}

} // namespace auth

#include "auth_manager.h"
#include "auth_network.h"
#include "auth_integrity.h"
#include "auth_chat.h"
#include "auth_storage.h"
#include "setting.h"

#include <thread>
#include <algorithm>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#endif

namespace auth {

    api api_instance;

    bool login_test = false;
    std::string auth_text = "";
    ImColor auth_text_color = ImColor(255, 255, 255);
    bool v_chk_0x33 = false;
    uint64_t vnp_token = 0;
    bool session_active = false;

    std::string chat_username = "";
    bool has_renamed = false;
    std::string input = "";
    std::vector<channel_struct> chat_messages;
    std::vector<local_system_message> local_system_messages;
    std::string username = "";

    std::atomic<bool> is_banned{false};
    std::string ban_reason = "";
    uint64_t ban_time = 0;

    static inline uint64_t rol64(uint64_t x, int n) {
        return (x << n) | (x >> (64 - n));
    }

    uint64_t make_token(time_t expiry, const uint8_t hwid[16], uint64_t nonce) {
        uint64_t h = (uint64_t)expiry * 0x9E3779B97F4A7C15ULL;
        h ^= nonce;
        h = rol64(h, 17);
        for (int i = 0; i < 16; i++) {
            h ^= (uint64_t)hwid[i] << ((i % 8) * 8);
            h = rol64(h, 7);
            h *= 0xBF58476D1CE4E5B9ULL;
        }
        h ^= h >> 33;
        h *= 0xFF51AFD7ED558CCDULL;
        h ^= h >> 33;
        h *= 0xC4CEB9FE1A85EC53ULL;
        h ^= h >> 33;
        h |= 0x1ULL;
        return h;
    }

    void background_worker() {
        static int fail_count = 0;
        while (session_active) {
            if (!check_code_integrity()) {
                if (g_fully_sealed) {
                    fail_count++;
                    if (fail_count >= 3) {
                        abort();
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(800));
                    continue;
                }
                v_chk_0x33   = false;
                session_active = false;
                vnp_token = 0;
                api_instance.clear_license_state();
                break;
            }
            fail_count = 0;
            
            auto t0 = std::chrono::steady_clock::now();
            std::string resp = http_post(ENCRYPT("ping"));
            auto t1 = std::chrono::steady_clock::now();
            int rtt = (int)std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();
            if (!resp.empty()) g_ping_ms.store(rtt);
            
#ifdef __OBJC__
            if (!resp.empty()) {
                NSData *data = [NSData dataWithBytes:resp.c_str() length:resp.length()];
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (json && [json[[NSString stringWithUTF8String:ENCRYPT("success")]] boolValue]) {
                    api_instance.online_count = [json[[NSString stringWithUTF8String:ENCRYPT("online")]] stringValue] ? std::string([[json[[NSString stringWithUTF8String:ENCRYPT("online")]] stringValue] UTF8String]) : "1";
                    
                    NSString *serverMsg = json[[NSString stringWithUTF8String:ENCRYPT("server_message")]];
                    if (serverMsg && serverMsg.length > 0) {
                        g_server_msg_text = std::string([serverMsg UTF8String]);
                        g_has_server_msg = true;
                    }
                } else if (json && [json[[NSString stringWithUTF8String:ENCRYPT("code")]] isEqualToString:[NSString stringWithUTF8String:ENCRYPT("KEY_BANNED")]]) {
                    if (!is_banned.load()) {
                        is_banned.store(true);
                        NSString *reason = json[[NSString stringWithUTF8String:ENCRYPT("message")]];
                        ban_reason = reason ? std::string([reason UTF8String]) : std::string(ENCRYPT("Banned"));
                        ban_time = (uint64_t)time(nullptr);
                        
                        std::thread([]() {
                            std::this_thread::sleep_for(std::chrono::seconds(30));
                            abort();
                        }).detach();
                    }
                }
            }
            
            std::string chat_resp = http_post(ENCRYPT("get_chat"));
            static bool was_chat_connected = false;
            if (!chat_resp.empty()) {
                if (!was_chat_connected) {
                    was_chat_connected = true;
                    g_chat_conn_notify = 1;
                }
                NSData *cData = [NSData dataWithBytes:chat_resp.c_str() length:chat_resp.length()];
                NSDictionary *cJson = [NSJSONSerialization JSONObjectWithData:cData options:0 error:nil];
                if (cJson && [cJson[[NSString stringWithUTF8String:ENCRYPT("success")]] boolValue]) {
                    NSArray *msgs = cJson[[NSString stringWithUTF8String:ENCRYPT("messages")]];
                    std::vector<channel_struct> server_msgs;
                    for (NSDictionary *m in msgs) {
                        channel_struct msg;
                        msg.author = [m[[NSString stringWithUTF8String:ENCRYPT("author")]] UTF8String];
                        msg.message = [m[[NSString stringWithUTF8String:ENCRYPT("message")]] UTF8String];
                        time_t ts = (time_t)[m[[NSString stringWithUTF8String:ENCRYPT("timestamp")]] integerValue];
                        msg.timestamp = std::to_string(ts);
                        int server_level = [m[[NSString stringWithUTF8String:ENCRYPT("level")]] integerValue];
                        msg.level = (msg.author == chat_username) ? g_user_level : server_level;
                        server_msgs.push_back(msg);
                    }
                    time_t now = time(nullptr);
                    std::vector<pending_msg> still_pending;
                    std::vector<pending_msg> failed_msgs;
                    {
                        std::lock_guard<std::mutex> plock(g_pending_mutex);
                        for (auto& p : g_pending_messages) {
                            bool confirmed = false;
                            for (auto& sm : server_msgs) {
                                if (sm.message == p.message) {
                                    confirmed = true;
                                    break;
                                }
                            }
                            if (confirmed) {
                            } else if (now - p.sent_at > 12) {
                                failed_msgs.push_back(p);
                            } else {
                                still_pending.push_back(p);
                            }
                        }
                        g_pending_messages = still_pending;
                    }
                    {
                        std::lock_guard<std::mutex> lock(g_chat_mutex);
                        chat_messages = server_msgs;
                        for (auto& p : still_pending) {
                            channel_struct pending;
                            pending.author   = p.author;
                            pending.message  = p.display_text;
                            pending.timestamp = std::to_string(p.sent_at);
                            pending.subscription = ENCRYPT("pending");
                            pending.level = p.level;
                            chat_messages.push_back(pending);
                        }
                        for (auto& f : failed_msgs) {
                            local_system_message err;
                            std::string errEn = std::string(ENCRYPT("[Send failed] ")) + f.display_text;
                            std::string errVn = std::string(ENCRYPT("[Gửi thất bại] ")) + f.display_text;
                            err.message  = setting::Lang(errEn.c_str(), errVn.c_str());
                            err.created  = std::chrono::steady_clock::now();
                            err.lifetime = 8;
                            local_system_messages.push_back(err);
                        }
                    }
                }
            } else {
                if (was_chat_connected) {
                    was_chat_connected = false;
                    g_chat_conn_notify = 2;
                }
            }
#endif
            std::this_thread::sleep_for(std::chrono::seconds(2));
        }
    }

    void login() {
        auth_text = setting::Lang(ENCRYPT("Preparing for authentication..."), ENCRYPT("Đang chuẩn bị xác thực..."));
        auth_text_color = ImColor(255, 255, 0);

        // Always reset previous session state so that failed logins immediately revoke access
        v_chk_0x33 = false;
        session_active = false;
        vnp_token = 0;
        api_instance.clear_license_state();

        std::string resp = http_post(ENCRYPT("login"));
        if (resp.empty()) {
            auth_text = setting::Lang(ENCRYPT("Connection failed. Check your network."), ENCRYPT("Kết nối thất bại. Kiểm tra mạng."));
            auth_text_color = ImColor(255, 0, 0);
            v_chk_0x33 = false;
            session_active = false;
            vnp_token = 0;
            api_instance.clear_license_state();
            return;
        }

#ifdef __OBJC__
        NSData *data = [NSData dataWithBytes:resp.c_str() length:resp.length()];
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];

        if (json && [json[[NSString stringWithUTF8String:ENCRYPT("success")]] boolValue]) {
            auth_text = setting::Lang(ENCRYPT("Activated successfully starting..."), ENCRYPT("Kích hoạt thành công, đang khởi động..."));
            auth_text_color = ImColor(0.07f, 0.52f, 0.17f, 1.0f);

            std::this_thread::sleep_for(std::chrono::milliseconds(500));

            NSInteger expVal = 0;
            if (json[[NSString stringWithUTF8String:ENCRYPT("expires_unix")]]) {
                expVal = [json[[NSString stringWithUTF8String:ENCRYPT("expires_unix")]] integerValue];
            } else if (json[[NSString stringWithUTF8String:ENCRYPT("expiry")]]) {
                expVal = [json[[NSString stringWithUTF8String:ENCRYPT("expiry")]] integerValue];
            } else if (json[[NSString stringWithUTF8String:ENCRYPT("expires")]]) {
                expVal = [json[[NSString stringWithUTF8String:ENCRYPT("expires")]] integerValue];
            } else if (json[[NSString stringWithUTF8String:ENCRYPT("expire")]]) {
                expVal = [json[[NSString stringWithUTF8String:ENCRYPT("expire")]] integerValue];
            }
            
            NSString *expStrJson = json[[NSString stringWithUTF8String:ENCRYPT("expires_date")]] ?: json[[NSString stringWithUTF8String:ENCRYPT("expires_at")]];
            if (expVal <= 0 && expStrJson && expStrJson.length > 0) {
                NSDateFormatter *df = [[NSDateFormatter alloc] init];
                NSArray *formats = @[
                    @"yyyy-MM-dd HH:mm:ss",
                    @"yyyy-MM-dd'T'HH:mm:ss",
                    @"yyyy-MM-dd",
                    @"dd/MM/yyyy HH:mm:ss",
                    @"dd/MM/yyyy HH:mm",
                    @"dd/MM/yyyy"
                ];
                for (NSString *fmt in formats) {
                    df.dateFormat = fmt;
                    NSDate *d = [df dateFromString:expStrJson];
                    if (d) {
                        expVal = (NSInteger)[d timeIntervalSince1970];
                        break;
                    }
                }
            }

            api_instance.expiry = (time_t)expVal;
            std::string expDisp = expStrJson ? std::string([expStrJson UTF8String]) : "";
            save_expiry(api_instance.expiry, expDisp);
            
            int level = [json[[NSString stringWithUTF8String:ENCRYPT("level")]] integerValue];
            g_user_level = level;

            NSString *uuidStr = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
            const char *uuidCStr = [uuidStr UTF8String];
            uint8_t hwidDigest[16] = {0};
            for (int i = 0; uuidCStr && uuidCStr[i]; i++) {
                hwidDigest[i % 16] ^= (uint8_t)((uuidCStr[i] * 0x9B) + (i * 0x31));
            }
            memcpy(api_instance.hwid_digest, hwidDigest, 16);

            uint64_t ts = (uint64_t)time(nullptr);
            uint64_t rnd = ((uint64_t)arc4random() << 32) | arc4random();
            api_instance.session_nonce = ts ^ rnd;

            vnp_token = make_token(api_instance.expiry, api_instance.hwid_digest, api_instance.session_nonce);

            v_chk_0x33    = true;
            session_active = true;

            seal_code_hash();
            save_key(auth::username);

            std::thread pingThread(background_worker);
            pingThread.detach();
        } else {
            // Explicitly kill session and tokens on failed authentication
            v_chk_0x33 = false;
            session_active = false;
            vnp_token = 0;
            api_instance.clear_license_state();
            save_expiry(0, "");

            NSString *code = json ? json[[NSString stringWithUTF8String:ENCRYPT("code")]] : nil;
            if ([code isEqualToString:[NSString stringWithUTF8String:ENCRYPT("KEY_NOT_FOUND")]]) {
                auth_text = setting::Lang(ENCRYPT("Key not found. Please check your input."), ENCRYPT("Không tìm thấy key. Vui lòng kiểm tra."));
            } else if ([code isEqualToString:[NSString stringWithUTF8String:ENCRYPT("KEY_EXPIRED")]]) {
                auth_text = setting::Lang(ENCRYPT("License is expired. Renew your subscription."), ENCRYPT("License đã hết hạn. Vui lòng gia hạn."));
            } else if ([code isEqualToString:[NSString stringWithUTF8String:ENCRYPT("HWID_MISMATCH")]]) {
                auth_text = setting::Lang(ENCRYPT("Device ID mismatch. Verify your device."), ENCRYPT("Thiết bị không khớp. Vui lòng xác minh."));
            } else if ([code isEqualToString:[NSString stringWithUTF8String:ENCRYPT("KEY_BANNED")]]) {
                auth_text = setting::Lang(ENCRYPT("This license has been banned. Contact support."), ENCRYPT("License này đã bị khóa. Liên hệ hỗ trợ."));
            } else {
                NSString *errMsg = (json && json[[NSString stringWithUTF8String:ENCRYPT("message")]]) ? json[[NSString stringWithUTF8String:ENCRYPT("message")]] : [NSString stringWithUTF8String:ENCRYPT("Authentication error")];
                auth_text = setting::Lang((std::string(ENCRYPT("Authentication error: ")) + std::string([errMsg UTF8String])).c_str(), (std::string(ENCRYPT("Lỗi xác thực: ")) + std::string([errMsg UTF8String])).c_str());
            }
            auth_text_color = ImColor(255, 0, 0);
        }
#else
        v_chk_0x33 = false;
        session_active = false;
        vnp_token = 0;
        auth_text = "Objective-C++ Not Available";
        auth_text_color = ImColor(255, 0, 0);
#endif
    }
}

bool g_c2 = false; 

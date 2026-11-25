#pragma once
#include <string>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <ctime>

namespace auth {

    struct ImColor {
        float r = 1.0f, g = 1.0f, b = 1.0f, a = 1.0f;
        ImColor() = default;
        ImColor(int _r, int _g, int _b, int _a = 255) : r(_r/255.0f), g(_g/255.0f), b(_b/255.0f), a(_a/255.0f) {}
        ImColor(float _r, float _g, float _b, float _a = 1.0f) : r(_r), g(_g), b(_b), a(_a) {}
    };

    struct api {
        uint32_t license_bind = 0;
        std::string online_count = "0";
        time_t expiry = 0;
        uint8_t hwid_digest[16] = {0};
        uint64_t session_nonce = 0;

        bool is_license_authentic() const { return true; }
        bool has_armed_license() const { return true; }
        std::string get_num_online_users() const { return online_count; }
        time_t get_subscription_expiry_time() const { return expiry; }
        void clear_license_state() {
            expiry = 0;
            session_nonce = 0;
            memset(hwid_digest, 0, sizeof(hwid_digest));
        }
    };

    extern api api_instance;

    extern bool login_test;
    extern std::string auth_text;
    extern ImColor auth_text_color;
    extern bool v_chk_0x33;
    extern uint64_t vnp_token;
    extern bool session_active;
    extern std::string username;

    extern std::atomic<bool> is_banned;
    extern std::string ban_reason;
    extern uint64_t ban_time;

    void login();
    void background_worker();

    uint64_t make_token(time_t expiry, const uint8_t hwid[16], uint64_t nonce);
} 

#ifndef keyAuth
#define keyAuth auth::api_instance
#endif

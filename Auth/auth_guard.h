#pragma once
#include <cstdint>
#include <cstring>
#include "auth_manager.h"

namespace authguard {

    inline bool verify_token(const auth::api &api) {
        if (auth::vnp_token == 0) return false;
        uint64_t expected = auth::make_token(
            api.expiry,
            api.hwid_digest, 
            api.session_nonce
        );
        return (auth::vnp_token == expected);
    }

    inline bool check_expiry(const auth::api &api) {
        if (api.expiry == 0) return false;
        time_t now = time(nullptr);
        return (now < api.expiry);
    }

    inline bool menu_access_ok(const auth::api &api) {
        if (!auth::v_chk_0x33) return false;
        if (!verify_token(api)) return false;
        if (!check_expiry(api)) return false;
        return true;
    }

    inline bool session_looks_active() {
        return auth::session_active && auth::v_chk_0x33;
    }

    inline bool require_authentic_license(const auth::api &api) {
        return menu_access_ok(api);
    }

    inline void sanction_menu_tamper(const auth::api &api) {
        if (auth::v_chk_0x33 && (!verify_token(api) || !check_expiry(api))) {
            auth::v_chk_0x33 = false;
            auth::session_active = false;
            auth::vnp_token = 0;
            const_cast<auth::api&>(api).clear_license_state();
        }
    }

    inline void enforce_or_sanction(const auth::api &api) {
        sanction_menu_tamper(api);
    }
}

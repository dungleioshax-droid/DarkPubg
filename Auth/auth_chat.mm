#include "auth_chat.h"
#include "auth_manager.h"
#include "auth_network.h"
#include "auth_storage.h"
#include "setting.h"
#include <thread>
#include <algorithm>
#include "Xor.h"

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

namespace auth {

    void send_chat_message() {
        if (input.empty() || !auth::session_active) return;

        std::string cmd = input;
        if (cmd.find("/rename ") == 0 || cmd.find("/doiten ") == 0) {
            std::string new_name = cmd.substr(cmd.find(" ") + 1);
            if (!new_name.empty()) {
                if (new_name.length() > 20) {
                    local_system_message sys_msg;
                    sys_msg.message = setting::Lang(ENCRYPT("Error: name too long (max 20 chars)"), ENCRYPT("Lỗi: Tên quá dài (tối đa 20 ký tự)"));
                    sys_msg.created = std::chrono::steady_clock::now();
                    sys_msg.lifetime = 10;
                    local_system_messages.push_back(sys_msg);
                } else if (has_renamed) {
                    local_system_message sys_msg;
                    sys_msg.message = setting::Lang(ENCRYPT("Error: You can only rename once per key!"), ENCRYPT("Lỗi: Bạn chỉ được đổi tên 1 lần duy nhất!"));
                    sys_msg.created = std::chrono::steady_clock::now();
                    sys_msg.lifetime = 10;
                    local_system_messages.push_back(sys_msg);
                } else {
                    chat_username = new_name;
                    has_renamed = true;
                    local_system_message sys_msg;
                    sys_msg.message = setting::Lang(ENCRYPT("name changed to: "), ENCRYPT("Đã đổi tên thành: ")) + chat_username;
                    sys_msg.created = std::chrono::steady_clock::now();
                    sys_msg.lifetime = 5;
                    local_system_messages.push_back(sys_msg);
#ifdef __OBJC__
                    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                    [defaults setObject:[NSString stringWithUTF8String:chat_username.c_str()] forKey:[NSString stringWithUTF8String:ENCRYPT("VNP_ChatName")]];
                    [defaults setBool:YES forKey:[NSString stringWithUTF8String:ENCRYPT("VNP_HasRenamed")]];
                    [defaults synchronize];
#endif
                }
                input = "";
                return;
            }
        }

        if (!has_renamed) {
            local_system_message sys_msg;
            sys_msg.message = setting::Lang(ENCRYPT("You must rename before chatting. Use /rename <name>"), ENCRYPT("Bạn phải đổi tên trước khi chat. Dùng /rename <tên>"));
            sys_msg.created = std::chrono::steady_clock::now();
            sys_msg.lifetime = 10;
            local_system_messages.push_back(sys_msg);
            input = "";
            return;
        }

        std::string final_message = "[" + chat_username + "]: " + input;
        std::string raw_input = input;

        {
            pending_msg pm;
            pm.author      = chat_username;
            pm.message     = raw_input;
            pm.display_text = final_message;
            pm.sent_at      = time(nullptr);
            pm.retries     = 0;
            pm.level       = g_user_level;
            std::lock_guard<std::mutex> plock(g_pending_mutex);
            g_pending_messages.push_back(pm);
        }

        {
            std::lock_guard<std::mutex> lock(g_chat_mutex);
            channel_struct local_msg;
            local_msg.author      = chat_username;
            local_msg.message     = raw_input;
            local_msg.timestamp   = std::to_string(time(nullptr));
            local_msg.subscription = ENCRYPT("pending");
            local_msg.level       = g_user_level;
            chat_messages.push_back(local_msg);
        }

        std::thread([final_message]() {
            std::string r = http_post(ENCRYPT("send_chat"), final_message);
            (void)r;
        }).detach();

        input = "";
    }

    void clear_expired_messages() {
        auto now = std::chrono::steady_clock::now();
        local_system_messages.erase(
            std::remove_if(local_system_messages.begin(), local_system_messages.end(),
                           [now](const local_system_message &msg) {
                               if (msg.lifetime == 0)
                                   return false;
                               auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - msg.created).count();
                               return elapsed >= msg.lifetime;
                           }),
            local_system_messages.end());
    }

    int get_ping_ms() {
        return g_ping_ms.load();
    }

} // namespace auth

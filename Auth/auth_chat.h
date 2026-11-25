#pragma once
#include <string>
#include <vector>
#include <mutex>
#include <atomic>
#include "auth_types.h"

namespace auth {

    extern std::string chat_username;
    extern std::string input;
    extern std::vector<channel_struct> chat_messages;
    extern std::vector<local_system_message> local_system_messages;
    
    inline std::mutex g_chat_mutex;
    inline std::mutex g_pending_mutex;
    inline std::atomic<int> g_chat_conn_notify{0};
    inline std::atomic<bool> g_has_server_msg{false};
    inline std::string g_server_msg_text = "";
    inline std::vector<pending_msg> g_pending_messages;
    inline int g_user_level = 1;
    inline std::atomic<int> g_ping_ms{-1};

    void send_chat_message();
    void clear_expired_messages();
    int get_ping_ms();
}

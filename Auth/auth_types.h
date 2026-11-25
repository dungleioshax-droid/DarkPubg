#pragma once
#include <string>
#include <vector>
#include <chrono>
#include <ctime>

namespace auth {

struct channel_struct {
  std::string author;
  std::string message;
  std::string timestamp;
  std::string subscription;
  int level;
  std::string avatar;
};

struct pending_msg {
    std::string author;
    std::string message;
    std::string display_text;
    time_t sent_at;
    int retries;
    int level;
};

struct local_system_message {
  std::string message;
  std::chrono::steady_clock::time_point created;
  int lifetime;
  bool is_welcome_msg;
};

inline std::string tm_to_readable_time(std::tm ctx) {
  return "";
}

static inline std::time_t string_to_timet(const std::string& timestamp) {
  auto cv = strtol(timestamp.c_str(), NULL, 10);
  return static_cast<time_t>(cv);
}

} // namespace auth

#pragma once
#include "Xor.h"
#include <dlfcn.h>
#include <stdint.h>

#define STEALTH_CALL(func_ptr, ...)                                            \
  ([&]() {                                                                     \
    volatile uintptr_t _0x_addr = (uintptr_t)func_ptr;                         \
    return ((decltype(func_ptr))(_0x_addr))(__VA_ARGS__);                      \
  })()

#define DYNAMIC_CALL(func_name, return_type, ...)                              \
  ({                                                                           \
    static return_type (*dyn_ptr)(__VA_ARGS__) = nullptr;                      \
    if (!dyn_ptr) {                                                            \
      dyn_ptr = (return_type(*)(__VA_ARGS__))dlsym(RTLD_DEFAULT,               \
                                                   ENCRYPT(#func_name));       \
    }                                                                          \
    dyn_ptr;                                                                   \
  })

__attribute__((always_inline)) inline uint64_t _0x_parse_hex(const char *s) {
  uint64_t res = 0;
  if (!s)
    return 0;
  if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
    s += 2;
  while (*s) {
    uint8_t byte = *s;
    if (byte >= '0' && byte <= '9')
      byte = byte - '0';
    else if (byte >= 'a' && byte <= 'f')
      byte = byte - 'a' + 10;
    else if (byte >= 'A' && byte <= 'F')
      byte = byte - 'A' + 10;
    else
      break;
    res = (res << 4) | (byte & 0xF);
    s++;
  }
  return res;
}

#define SECURE_OFFSET(Str) _0x_parse_hex(ENCRYPT(Str))

extern "C" __attribute__((visibility("default"))) void IntFunc_7();

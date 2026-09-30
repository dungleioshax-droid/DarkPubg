// DSPortHelper: helper process tách (kiểu DSGames ExternalESPReader).
// Làm kernel exploit + fabricate fake task port, trả send right về app qua
// XPC. App chính chỉ syscall nên không bao giờ panic vì kernel writes.
// Build bằng clang trực tiếp trong CI (không đụng project chính), nhúng vào
// DarkSpeed.app/XPCServices/. Esign sign recursive như dylibs.

#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import <mach/mach.h>
#import <string.h>

#import "ESPTask.h"
#import "darksword.h"
#import "offsets.h"
#import "utils.h"

#define HELPER_SERVICE "com.huami.darkspeed.porthelper"
#define K_CMD "cmd"
#define CMD_PORT "port"
#define K_PID "pid"
#define K_PORT "port"
#define K_ERROR "error"

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        // Init KRW y hệt app (DSBridgeBootstrap, bản minimal không HUD).
        init_offsets();
        offsets_init();
        install_builtin_kernel_symbol_offsets();
        int r = ds_run();
        if (r != 0 || !ds_is_ready()) {
            NSLog(@"[DSPortHelper] exploit failed (%d) — serving errors", r);
        } else {
            NSLog(@"[DSPortHelper] KRW ready");
        }
        xpc_main(^(xpc_connection_t peer) {
            xpc_connection_set_event_handler(peer, ^(xpc_object_t ev) {
                if (xpc_get_type(ev) != XPC_TYPE_DICTIONARY) return;
                const char *cmd = xpc_dictionary_get_string(ev, K_CMD);
                xpc_object_t reply = xpc_dictionary_create_reply(ev);
                if (!cmd || strcmp(cmd, CMD_PORT) != 0) {
                    xpc_dictionary_set_string(reply, K_ERROR, "bad-cmd");
                } else if (!ds_is_ready()) {
                    xpc_dictionary_set_string(reply, K_ERROR, "no-krw");
                } else {
                    pid_t want = (pid_t)xpc_dictionary_get_int64(ev, K_PID);
                    uint64_t proc = ESPTaskResolveGameProc();
                    pid_t have = (proc && off_proc_p_pid)
                        ? (pid_t)ds_kread32(proc + off_proc_p_pid) : 0;
                    mach_port_t port = MACH_PORT_NULL;
                    if (proc && want > 0 && have == want) {
                        port = ESPTaskFabricatePortForProc(proc, want);
                    }
                    pid_t check = 0;
                    if (port != MACH_PORT_NULL &&
                        pid_for_task(port, &check) == KERN_SUCCESS &&
                        check == want) {
                        xpc_dictionary_set_mach_send(reply, K_PORT, port);
                        // KHÔNG deallocate: quyền đã vào message, giữ lại
                        // tránh deallocate nhầm tên port tái sử dụng.
                        // Leak 1 port/request trong helper — không đáng kể
                        // (1 request / 1 lần mở game).
                    } else {
                        if (port != MACH_PORT_NULL) {
                            mach_port_destroy(mach_task_self(), port);
                        }
                        xpc_dictionary_set_string(reply, K_ERROR, "no-port");
                    }
                }
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            });
            xpc_connection_resume(peer);
        });
    }
    return 0;
}

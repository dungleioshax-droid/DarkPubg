//
//  ESPTask.mm
//  STUB: task port game đã xoá hẳn (fabrication không qua được SMR/PAC trên
//  kernel này; iOS SDK cấm XPC port-transfer nên không tách helper được).
//  ESP đọc game DUY NHẤT qua kernel region-map (ESPMemory.mm). File này chỉ
//  giữ API cho code cũ gọi không crash: mọi hàm trả NO/NULL.
//  Lịch sử đầy đủ trong tag old-esp-fabrication.
//

#import "ESPTask.h"

mach_port_t ESPGameTaskPort(void) {
    return MACH_PORT_NULL;
}

BOOL ESPGameTaskEnsure(void) {
    return NO;
}

void ESPGameTaskReset(void) {
}

BOOL ESPTaskRead(uint64_t remoteAddr, void *buf, uint64_t len) {
    (void)remoteAddr; (void)buf; (void)len;
    return NO;
}

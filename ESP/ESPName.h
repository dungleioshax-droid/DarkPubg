//
//  ESPName.h
//  Đọc FName qua GNames như Kernel (unity.mm): actor+0x18 -> ID,
//  chunk walk -> string. So VTable với ASTExtraPlayerCharacter đã biết.
//

#ifndef ESPName_h
#define ESPName_h

#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

// Giải mã UName từ GNames static (cache theo gameBase). 0 nếu fail.
uint64_t ESPResolveUName(uint64_t vmMap, uint64_t gameBase);

// Đọc tên instance của actor vào outName (tối đa 63 ký tự + null).
// NO nếu fail. Dùng cache theo ID nên lần sau rẻ.
BOOL ESPActorName(uint64_t vmMap, uint64_t uname, uint64_t actor, char outName[64]);

// Như ESPActorName nhưng nhận sẵn FName ID (actor+0x18) — dùng khi đã đọc
// sẵn cửa sổ actor, khỏi tốn thêm 1 lần map page.
BOOL ESPActorNameByID(uint64_t vmMap, uint64_t uname, uint32_t fid, char outName[64]);

// So tên với list class player của Kernel (STExtraPlayerCharacter...).
BOOL ESPIsPlayerCharacterName(const char *name);

// So tên với list hình nhân huấn luyện (ShootingPracticeTarget...).
BOOL ESPIsTrainingDummyName(const char *name);

// Xoá cache khi đổi base/world.
void ESPNameReset(uint64_t gameBase);

NS_ASSUME_NONNULL_END

#endif /* ESPName_h */

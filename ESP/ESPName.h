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

// qblpack: bot/AI pawn (AIMarkDifferent của QBL). Chỉ dùng để ĐỔI MÀU/mark —
// actor vẫn được coi là player (đúng hành vi cũ); danh sách ca từ khoá chắc
// chắn nằm trong tên class bot (TPlanAI/FakePlayer_AIPawn...).
BOOL ESPNameIsAIPawn(const char *name);

// kernrw49: nickname người chơi — Character+0x960 (FString PlayerName, đường
// Kernel kPlayerName), fallback Pawn→APlayerState (0x4D0) → 0x4B8 FString.
// Đọc UTF-16LE → UTF-8 (do FString là UTF-16, nickname tiếng Việt/Trung
// đứng được). Cache theo pawn, TTL 3s (nick hiếm khi đổi giữa trận).
// NO nếu đọc fail (caller hiển thị "Unknown" như Kernel).
BOOL ESPPlayerNickName(uint64_t vmMap, uint64_t pawn, char outNick[64]);

// Xoá cache khi đổi base/world.
void ESPNameReset(uint64_t gameBase);

NS_ASSUME_NONNULL_END

#endif /* ESPName_h */

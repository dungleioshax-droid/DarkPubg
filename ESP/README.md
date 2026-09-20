# ESP — PUBG Mobile (ShadowTrackerExtra) Box ESP

Folder riêng cho ESP, không loạn dự án chính. Phase 1 đọc memory + đếm actors, HUD hiện text. Phase 2 vẽ box.

## Cấu trúc
- `ESPOffsets.h` — RVA từ DUMP.zip (UEPointers + UWorld/ULevel/Actor). Công thức runtime: `addr = gameBase + (dumpPtr - 0x100000000)`.
- `ESPMemory.h/.mm` — đọc memory game qua kernel (`vmmapremotepage` từng page, giống `decrypt.m`). Không dùng `task_for_pid`.
- `ESPUE.h` — struct UE tối thiểu (`FVector`, `TArray`, `FName`) + helper GNames/GUObject.
- `ESPEngine.h/.mm` — quét `GUObject` tìm `World`, vào `PersistentLevel -> ActorCluster -> Actors`, đếm + lọc `STExtraBaseCharacter`. Trả về count + status string cho HUD.
- `ESPOverlay.h/.mm` — stub vẽ box trên SpringBoard bằng RemoteCall `UIView` (phase 2). Phase 1 chỉ trả về text.
- `ESPConfig.h` — tên process, bật/tắt.

## DUMP đang dùng
- `BaseAddress: 0x4FA4000`, `__TEXT: 0x104FA4000-0x10D368000`
- `GNames [<Base>+0x10D492AC0]=0x112436AC0`, `GUObject [<Base>+0x10A692D18]=0x10F636D18`, `GEngine [<Base>+0x10A8AA8A0]=0x10F84E8A0`
- `UWorld::PersistentLevel 0x30`, `OwningGameInstance 0x470`
- `ULevel::ActorCluster 0xE0` → `ULevelActorContainer::Actors 0x28` (TArray)
- `AActor::RootComponent 0x208`, `USceneComponent::RelativeLocation 0x1E4`
- `GWorld` không có trong dump → tìm qua `GUObject` enumeration (Class `Engine.World`).

## Cách bật
1. Setting → `Base Game` ON (để có base).
2. Setting → `ESP Box` ON.
3. Mở game, bật HUD. HUD SpringBoard hiện thêm:
   - `Base: 0x...`
   - `ESP: N actors / M players` hoặc `ESP: --`.

## Nhận diện actor (khi GNames hỏng)
`uname=0x0` trên log nghĩa là GNames chưa giải được, nên nhận diện dựa vào VTable và chữ ký field:

- **PersistentLevel**: Quét trực tiếp `PersistentLevel` (offset `0x30`), nơi chứa toàn bộ player, bot và hình nhân (`AShootingPracticeTarget`). Không quét streaming levels vì streaming levels chỉ chứa địa hình/cây cối tĩnh, làm phình số actors lên 830 và gây lag/nhận diện nhầm.
- **Player**: Học VTable từ pawn của chính mình (`localPlayer`). Mọi player/bot cùng class `ASTExtraPlayerCharacter` đều có chung VTable này. Khi fallback heuristic, yêu cầu `VTable` khớp (nếu đã học) và `HealthMax` trong khoảng 50..2000.
- **Hình nhân huấn luyện** (`AShootingPracticeTarget : AActor`):
  - `StaticMeshComp` (0x4E8) hợp lệ, `RootComponent` (0x208) hợp lệ.
  - Không có `SkeletalMesh` (0x510).
  - `MaxHealth` (0x4AC) trong khoảng 50..2000, `CurHealth` (0x4D0) trong khoảng 0..MaxHealth.

## Log chẩn đoán
`Documents/ESP.log` (lấy qua Files app / Filza). Mỗi world mới ghi 2 lượt chi tiết:

- `scan start actors=<số actor PersistentLevel> level=0x.. base=0x..`
- `diag pawn=0x.. inList=.. vTable=.. mesh=.. hp=..` — field của pawn mình.
- `a[i] 0x.. r=<rule> w=<window OK> ...` — 24 actor đầu: rule 1=vtable 2=tên player 3=tên hình nhân 4=chữ ký character 5=chữ ký target.
- `diag vtHist(..) 0x..:n ...` — histogram VTable.
- `scan done enemies=.. dummy=.. win=../.. vt=.. nm=.. dnm=.. ch=.. dm=.. no=..`

## Phase 2 (chưa làm, để sẵn stub)
- `ESPOverlay` sẽ tạo `UIWindow` full-screen trong SpringBoard + pool `UIView` viền box (4 view mỏng/box) + `UILabel` khoảng cách. Tính `WorldToScreen` từ `PlayerCameraManager::CameraCache (FMinimalViewInfo)`.
- Cần thêm offsets: `PlayerController->PlayerCameraManager 0x...`, `CameraCacheEntry::POV`, `FMinimalViewInfo::{Location,Rotation,FOV}`, `ViewMatrix`. Lấy từ `SDK/Engine.hpp` khi cần.

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
`uname=0x0` trên log nghĩa là GNames chưa giải được, nên nhận diện phải dựa vào
chữ ký field. Các lớp hình nhân trong sân tập:

| Lớp | Cha | Field nhận diện |
|---|---|---|
| `AShootingPracticeTarget` | `AActor` | MaxHealth `0x4AC`, CurHealth `0x4D0`, bIsUp `0x4D4`, StaticMeshComp `0x4E8` (object chỉ dài ~0x508) |
| `AShootingPracticeScoreTarget` | `ADecoratorActor` | MoveRoot `0x660`, CurrentWave `0x6B8`, bIsUp `0x6BC`, bIsRotating `0x6BD` (~0x710) |

Hai lớp này **không** dùng chung layout: hình nhân người (ScoreTarget) không có
MaxHealth/CurHealth ở 0x4AC/0x4D0, nên check theo field của lớp kia luôn trượt.

## Log chẩn đoán
`Documents/ESP.log` (lấy qua Files app / Filza). Mỗi world mới ghi 2 lượt chi tiết:

- `levels cands=.. ok=.. cand0act=..` — số level và actor từng level.
- `scan start actors=<level lớn nhất> union=<tổng mọi level> levels=..`
- `uname diag ...` — giá trị thật ở static GNames + chuỗi đọc được từ từng candidate.
- `diag pawn=0x.. inList=.. vTable=.. mesh=.. hp=..` — field của pawn mình, và nó
  có nằm trong mảng actors không (kiểm tra chéo offset + mảng actors).
- `a[i] 0x.. r=<rule> w=<window OK> ...` — 24 actor đầu: rule 1=vtable 2=tên
  player 3=tên hình nhân 4=chữ ký character 5=chữ ký target 6=chữ ký hình nhân người.
- `diag vtHist(..) 0x..:n ...` — histogram VTable (player/hình nhân mỗi lớp 1 VTable).
- `scan done enemies=.. dummy=.. win=../.. vt=.. nm=.. dnm=.. ch=.. dm=.. sc=.. no=..`

## Phase 2 (chưa làm, để sẵn stub)
- `ESPOverlay` sẽ tạo `UIWindow` full-screen trong SpringBoard + pool `UIView` viền box (4 view mỏng/box) + `UILabel` khoảng cách. Tính `WorldToScreen` từ `PlayerCameraManager::CameraCache (FMinimalViewInfo)`.
- Cần thêm offsets: `PlayerController->PlayerCameraManager 0x...`, `CameraCacheEntry::POV`, `FMinimalViewInfo::{Location,Rotation,FOV}`, `ViewMatrix`. Lấy từ `SDK/Engine.hpp` khi cần.

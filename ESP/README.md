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

### Fast path PlayerArray (kernrw63-fastscan)
Quét 8000 actor để tìm player rất chậm khi page cache lạnh (mỗi actor 1 cửa sổ
`0xF00`, map budget 16/100ms). Từ kernrw63 lấy thẳng danh sách player/bot:

- `UWorld::GameState` `0x428` → `AGameStateBase::PlayerArray` `0x4C8`
  (`TArray<APlayerState*>`, Num ở `+8`) → `APlayerState::PawnPrivate` `0x528`.
  Fallback khi `GameState` null: `UWorld::AuthorityGameMode` `0x420` →
  `AGameModeBase::GameState` `0x508` (mode listen/training).
- `APlayerState::bIsABot` là **bit 2** của byte `0x4DC` (cùng byte với
  `bIsSpectator` bit 0, `bOnlySpectator` bit 1) — dùng cho AIMark.
- Scan phân loại player từ PlayerArray **trước**, rồi chỉ quét lát 2048 actor/lượt
  của actor array để bắt hình nhân (`kind 3`). PlayerArray rỗng/hỏng → quay lại
  full scan cũ (không mất box).
- Discover cũng có Pass 0 trên PlayerArray (~250ms–1s) nên player mới/unhide vào
  tracked nhanh, không phụ thuộc vị trí trong actor array.
- Log xác nhận: `fast players: N via PlayerArray` (mỗi world) và
  `scan stat: ms=.. actors=.. scanned=.. enemies=.. tracked=.. fast=N` (5s/lần).
- Nếu `fast=0` mãi: log `fast diag:` + `fast diag[0/1]:` (1 lần/world) in raw
  `world/gs/gm/gs2/data/count/ps0/pawn0/bot` để biết chết ở GameState hay
  PlayerArray/PawnPrivate. Không đoán offset.

## Log chẩn đoán
`Documents/ESP.log` (lấy qua Files app / Filza). Các dòng chính:

- `scan stat: ms=<thời gian quét> actors=<số actor PersistentLevel> scanned=<đã phân loại> enemies=.. dummies=.. tracked=.. fast=<pawn từ PlayerArray>` — 5s/lần.
- `fast players: <N> via PlayerArray` — fast path hoạt động (N = số pawn đọc được).
- `qbl present: ... work=..ms` / `box perf ...` — nhịp render.
- Các log cũ `scan start`, `a[i]`, `diag vtHist`, `scan done` đã bỏ vì I/O mỗi scan (xem `0f50598`).

## Phase 2 (đã làm)
`ESPOverlay` tạo `UIWindow` full-screen trong SpringBoard + pool view/label; `WorldToScreen`
tính từ `PlayerCameraManager::CameraCache (FMinimalViewInfo)` — xem `ESPEngine.mm`
(`ESPCamBasisBuild` / `ESPCamBasisProject`).

## QBL render pack (port từ QBL-ESP-PUBGM-DS)

Bộ tính năng + cách render lấy cảm hứng/kiến trúc từ QBL (app bundle
`quangblue.QBL-ESP-PUBGM-DS`), **không dùng lại offset của QBL** (symbol debug của
QBL có value 0) — mọi offset trong repo vẫn là offset của dump đang dùng.

### Tính năng thêm (Setting → mục ESP)

| Toggle | Pref key | Mặc định | Mô tả |
|---|---|---|---|
| ESP Team ID | `espShowTeamID` | ON | `T<id>` trên đỉnh box (chỉ player, không vẽ cho hình nhân) |
| ESP Head Dot | `espShowHeadDot` | ON | Chấm tròn ở đầu — khớp xương đầu nếu Bones ON |
| ESP AI Mark | `espShowAIMark` | ON | Bot/AI: box viền vàng đậm hơn + tam giác trên đầu + chữ vàng |
| ESP Xương (Bones) | `espShowBones` | **OFF** | Skeleton ESP (xem dưới) |
| ESP Scale | `espESPScale` | **OFF** | Phóng box +15% quanh tâm (như `player.ESPScale` của QBL) |

Bones/Scale mặc định OFF vì đọc thêm bộ nhớ mỗi tick.

### Kiến trúc render kiểu QBL (frame + command list)

Trước đây mỗi box = 4 view viền + label + HP + path riêng (hàng trăm remote call/frame).
Giờ theo đúng luồng QBLDrawList → `DSOverlay::PresentFrame`:

1. **Builder** (`ds_qbl_build_frame` trong `darksword/DSBridge.mm`) gom tất cả
   primitive của 1 frame vào draw list CPU (`ESPOverlay.mm`, 128 lệnh + 1024 điểm,
   0 remote call): box, thanh máu (nền + fill), head dot, tam giác AI, snapline
   (1 polyline dùng chung), xương (1 polyline/player), text.
2. **Presenter** (`ds_qbl_present`) bắn sang SpringBoard theo batch:
   - mỗi style = 1 `CAShapeLayer` tái sử dụng (box trắng, box AI vàng, snapline,
     xương xanh, head dot, AI mark, HP nền/đỏ/vàng/xanh = 10 layer, `speed=1000` để
     không animate khi đổi path), **tạo lazy** khi frame đầu tiên cần tới;
   - rect gom 1 lần bằng `CGPathAddRects`, polyline bằng `CGPathAddLines`
     (pointer + count — tham số an toàn qua RemoteCall); points/rects nằm trong
     **1 buffer remote** (`malloc` 1 lần, giữ giữa các frame) → 2 `remote_write`/frame;
   - text dùng pool 16 `UILabel` (2/box): setText **chỉ khi text đổi**, setFrame tối đa
     30Hz + ngưỡng 0.5pt; viền chữ kiểu QBL (`AddOutlinedText`) xấp xỉ bằng
     `UILabel.shadowColor` đen + `shadowOffset` 0 set **1 lần** lúc tạo (0 chi phí
     mỗi frame).
   - frame trùng hash (không có gì đổi) → bỏ qua toàn bộ remote call.
3. Tất cả nằm trong 1 `UIView` gốc (`g_qblRoot`) là con của container cũ → hide/show
   1 call, window cleanup cũ giữ nguyên.

#### Thứ tự vẽ box/label + tạo label nhanh (kernrw65-labelbatch)

- Presenter vẽ geometry (box/snapline/bone/HP) **trước**, label pass chạy **sau**.
  Trước đây label pass chạy trước nên khi có nhiều địch mới, việc tạo label
  (nhiều remote call) chặn box xuất hiện → box/label hiện lần lượt.
- Label tạo bằng `initWithFrame:` (bỏ `init` + `setFrame:`), không set
  `hidden`/`userInteractionEnabled`/`backgroundColor` thừa; shadow chuyển từ
  `CALayer` (radius 1.2, ~5 call) sang `UILabel.shadowColor/shadowOffset`
  (~2 call).
- Invocation cache thêm nhánh **cold selector** (chỉ set 1 lần lúc tạo:
  `setNumberOfLines:`/`setTextAlignment:`/`setShadowOffset:`/...): dùng 1
  invocation theo selector + `setTarget:` thay vì dựng lại invocation cho từng
  label. Setter nóng (`setFrame:`/`setHidden:`/`setText:`/`setPath:`/...) vẫn
  cache theo `(target,selector)` để không thêm call mỗi frame.
- Kết quả: box của tất cả địch hiện ngay trong frame đầu; label hiện nhanh hơn
  nhiều nhưng vẫn lần lượt 1 label/tick (giữ budget để tránh dồn remote call
  làm treo SpringBoard).

#### Ổn định (bản sửa lỗi HUD đứng / ESP không hiện)

Ba lỗi gốc của bản cmdlist đầu tiên:

1. **ESP không bao giờ hiện**: nhánh QBL `return YES` sớm trước đoạn
   `addSubview:container` + `setHidden:0` của window → `g_espWindow` đã khác 0 nên
   `ds_esp_overlay_ensure` không bao giờ chạy lại. Giờ chỉ compile-out phần tạo
   view per-box; đoạn attach/show window dùng chung, luôn chạy.
2. **HUD đứng + bật lại đè HUD + kill app respring**: bản đầu tạo 10 shape layer +
   16 label (~350 remote call) trong **một tick** ngay sau khi HUD attach. Chỉ cần
   1 call timeout là `RemoteCall` tự `destroyRemoteCall` (trojanMem=0) → HUD không
   ẩn/không cập nhật được nữa. Giờ:
   - window ensure chỉ tạo window + container (bỏ 8 bộ view per-box ≈ 150 call);
   - shape/label **tạo lazy, tối đa 1 shape + 1 label mỗi tick**
     (`kQBLShapeBudgetPerTick` / `kBQLLabelBudgetPerTick`);
   - geometry có **hash riêng từng bucket** + quantize 0.5pt → bucket không đổi thì
     không `setPath:`; frame đứng yên = 0 remote call;
   - label pass 30Hz tách riêng, chạy cả khi geometry skip (không mất update);
   - pid SpringBoard đổi (respring) → tự reset cache và dựng lại overlay;
   - nếu disable không ẩn được window (session chết), địa chỉ HUD/ESP được giữ
     lại và enable sau ẩn bằng session mới (guard pid) → không đè 2 HUD/ESP;
   - log `ESP.log`: `qbl ensure ok`, `qbl shape/label created`, `qbl present: frames/skips`,
     `qbl: RemoteCall session died during present err=...`, `hud hide skipped/done`.

3. **Session chết ngay trong lúc tạo style (log 12:00:28)**: `ds_qbl_style_ready`
   từng tạo màu bằng `+[UIColor colorWithRed:green:blue:alpha:]` rồi `retain` ở
   một remote call **kế tiếp**. Object trả về là autoreleased trong SpringBoard;
   pool của SB có thể giải phóng nó trước khi `retain` chạm tới → `objc_msgSend`
   fault → `RemoteCall` gọi `destroyRemoteCall` (`trojanMem=0`) → disable không
   hide được HUD (`session=-1`), present treo 2×10s timeout.
   - Style giờ **chỉ dùng màu singleton** (`+clearColor/+whiteColor/+blackColor/
     +redColor/+yellowColor/+greenColor`) — đúng pattern renderer cũ đã chạy ổn;
   - font **tạo riêng** 13pt (tên + mét) / 11pt (TeamID) qua
     `+[UIFont monospacedDigitSystemFontOfSize:weight:]`; chỉ fallback font HUD khi
     tạo font lỗi;
   - `g_qblStyleOK` / `g_qblDead`: style fail 3 lần → bỏ QBL trong session đó để
     **giữ session cho HUD**, không retry vô hạn;
   - `ds_remove_springboard_hud`: nếu session đã chết, **mở session mới chỉ để
     hide** HUD/ESP rồi destroy → tắt HUD luôn có tác dụng, không cần respring;
   - log thêm `process.lastError` (tên call bị fault) vào `ESP.log`.

#### Ổn định lần 3 (respring khi ESP chạy + chữ to)

- **Chữ to**: QBL từng mượn font HUD (24pt, custom 14..40) cho rect 180×32/84×15 →
  tràn + nhoè. Giờ style tạo font riêng 13pt/11pt (retained, không factory color);
  HUD font chỉ còn là fallback. Log `qbl style ok ... font=... small=...`.
- **Khởi động chậm ~10s**: log cho thấy `ESPResolveUName` quét `__DATA` tìm GNames
  tốn ~5s, làm provider reset task port (`PROVIDER degraded fails=32`) → mọi read
  đứng hình, label/style không chạy. Build này GNames vốn không resolve được nên
  quét là vô ích:
  - **Tắt mặc định** bước quét `__DATA` (`ESPNameSetScanEnabled`, mặc định NO);
  - fail UName được **nghi 60s** (không quét/đọc lại mỗi 2s);
  - đường dò xương **không còn gọi `ESPResolveUName`** (trước đây chính nó kích
    hoạt quét 5s dù đã có địch).
- **Giật**: geometry/label từng bị hạ 30/15Hz nên box/chữ trượt rõ. Log sau khi
  ổn định cho thấy present chỉ 0.3..5ms, nên trả lại **geometry 60Hz, label 30Hz**;
  cull/clamp/NaN vẫn giữ để chống path khổng lồ.
- **Object mới**: vẫn **1 shape + 1 label/tick**, root tạo tick riêng trước style.
- **Đo tải**: stat 5s thêm `work=...ms` (thời gian batch present trước) để biết
  khi nào thật sự cần hạ tần số.
- **Log phase**: `qbl phase: root create/style/shape N/label N`.

#### Ổn định lần 4 (respring sau ~30s khi ESP chạy) — kernrw72

- Log 2026-10-22 08:08 kết thúc đột ngột ở dòng `scan stat`, không có
  `ESP present failed`/`task port unavailable`; đúng kiểu app chết vì
  `SIGSEGV`/mapping chết chứ không phải exception Objective-C.
- **Root cause tìm được:** `ESPLocalRangeCheck()` khai báo
  `mach_vm_region_recurse()` **9 tham số** trong khi API thật chỉ có 6:
  `(task, &address, &size, &nesting_depth, info, &info_cnt)`.
  Các tham số bị lệch nên kernel đọc `info_cnt` từ `&objName` (= 0) và trả
  `KERN_INVALID_ARGUMENT (kr=4)`. Vì vậy **check mapping chết chưa bao giờ
  chạy**; log `ESP region check err kr=4 (x3)` chính là bằng chứng.
  Khi game free một `vm_object` (actor chết/world đổi), mapping cũ trong app
  vẫn được `memcpy` → `SIGSEGV`/panic, HUD mất và người dùng thấy như respring.
- **Fix:** khai báo đúng ABI 6 tham số, truyền `nesting_depth = 0`; thêm
  fallback `mach_vm_read_overwrite()` đọc thử 1 byte từ mapping của app — syscall
  trả lỗi thay vì `SIGSEGV` nếu mapping đã chết. Vùng chết giờ được đánh dấu,
  purge và map lại thay vì đọc con trỏ rác.
- Build tag: `kernrw73-respringfix`. Kỳ vọng log **không còn**
  `ESP region check err kr=4`; nếu game free vùng, có thể thấy
  `ESP region purged ...` nhưng app/HUD vẫn sống.
- **Tối ưu xương & label (SpringBoard IPC):**
  - Gộp 5 đường xương (spine, 2 tay, 2 chân) thành 1 đường polyline liên tục
    (DFS traversal với retrace), giảm 80% số RemoteCall lên SpringBoard mỗi frame.
  - Làm tròn toạ độ label (`roundf`) và nâng ngưỡng thay đổi vị trí lên `1.0pt`,
    cùng gate tần số 30Hz: triệt tiêu hiện tượng chữ rung giật (subpixel text jitter)
    khi xoay camera/di chuyển, giảm hơn 60% tải IPC `setFrame:` lên SpringBoard main thread.

#### Ổn định lần 5 (respring/đứng HUD khi ESP chạy) — kernrw80

Đây là lớp bảo vệ thứ hai, sau fix ABI region-check ở lần 4. Lần 4 đã sửa
`mach_vm_region_recurse` nhưng vẫn còn một cửa sổ race: check mapping chỉ chạy
tối đa 250ms/lần, nên game có thể free `vm_object` ngay sau check rồi kernel
huỷ mapping trước `memcpy`. Khi đó app đọc trang đã unmap → `SIGSEGV` (không có
exception Objective-C, log dừng đột ngột), người dùng thấy như respring.

- **Copy an toàn:** mọi lần copy từ region-map (`ESPReadSharedLocked`,
  `ESPReadCachedLocked`, `ESPMemoryReadCached`), 2 chỗ đọc trực tiếp trong
  `ESPGameBaseViaKernel` và mapping tạm trong `ESPWorldViaViewport`
  (`ESPEngine.mm`) đã chuyển sang
  `mach_vm_read_overwrite(mach_task_self(), ...)`. Nếu mapping chết giữa chừng,
  syscall trả `KERN_INVALID_ADDRESS`/đọc thiếu; vùng được đánh dấu `dead` ngay
  và purge/map lại, **không còn SIGSEGV trong `memcpy`/deref trực tiếp**.
- **Giảm tải SpringBoard:** geometry QBL (`CGPathCreate/AddLines/setPath`) và
  label pass hạ từ 60Hz xuống **30Hz** (`ESP_QBL_GEOMETRY_HZ` /
  `ESP_QBL_LABEL_HZ`). Present tick vẫn 60Hz; frame không đổi hình học chỉ còn
  label pass 30Hz. Các snapline được gộp vào **một polyline** (start→top1→start→top2…)
  nên bucket Line chỉ còn 1 `CGPathAddLines` thay vì N call.
- **Watchdog guard:** nếu một present vượt `ESP_PRESENT_OVERLOAD_MS` (8ms), bridge
  tạm bỏ các frame box tiếp theo 50ms rồi tăng dần tối đa 400ms
  (`esp present overload` trong log). Lệnh hide/clear (`count <= 0`) luôn được
  xử lý ngay, nên tắt ESP/địch biến mất không bị kẹt box ma. Đây là backoff có
  kiểm soát, không phải bỏ frame vô hạn như bản 25ms cũ.
- **Build tag:** `kernrw80-saferead-30hz-watchdog`.

Kỳ vọng log khi chạy ổn: không còn `ESP region check err kr=4`; nếu game free
vùng có thể thấy `ESP region purged ...` nhưng app/HUD vẫn sống; nếu máy yếu có
thể thấy `esp present overload` thay vì respring. 30Hz là mức an toàn đã từng
ổn định; sau khi có log mới xác nhận không còn crash mới cân nhắc nâng lại
geometry 60Hz.

Tắt xương/snapline/... chỉ đổi builder, presenter không đổi. Có thể quay lại
renderer per-box cũ bằng `#define DS_ESP_RENDER_COMMANDLIST 0` trong `DSBridge.mm`
(code cũ vẫn còn nguyên, chỉ bị compile-out ở nhánh `#if`).

### Bones (skeleton) — component-space live + tự dò/validate ở runtime

`ComponentToWorld` = `0x208` (ngay sau `RelativeScale3D` `0x1FC`; SDK không liệt kê
field transient này nhưng đúng thứ tự UE4 và khớp khoảng trống tới `ComponentVelocity`
`0x2C0`). Engine vẫn **validate runtime** trước khi dùng.

Các mảng xương đã biết (log kernrw63 ngày 2026-10-21):

| Offset | Field / nguồn | Hệ quy chiếu |
|---|---|---|
| `0xA30/0xA40` | `ComponentSpaceTransformsArray[0/1]` (private UE4) | component space đầy đủ, double buffer; **0xA30 đã xác nhận runtime 2026-10-22** (count=67, map G pass) |
| `0xA74` / `0xA78` | `CurrentReadComponentTransforms` (`int32`, suy ra từ layout UE4) | `0/1` chọn buffer đọc; `0xA74` là field chính, `0xA78` là ứng viên fallback/log |
| `0xE18/0xE28` | 2 `TArray<FTransform>` Num=67 (eval-context) | component-space fallback |
| `0xC98` | `BoneSpaceTransforms` (transient, DUMP không liệt kê) | bone/parent space, Num=67 |
| `0xCD0/0xCE0` | `CachedBoneSpaceTransforms` / `CachedComponentSpaceTransforms` | DUMP; game xoá sau skin (`count=0`) |
| `0xCA8` | `RequiredBones`/compact component-space subset | **không dùng** — Num=44, index không khớp skeleton |

`0xA30/0xA40` được suy ra từ layout `USkinnedMeshComponent` (ngay sau
`MasterPoseComponent` `0xA28`, trước `bUseBoundsFromMasterPoseComponent` `0xAE0`)
nên vẫn là **ứng viên chưa xác nhận runtime**; engine chỉ nhận khi đọc được
`TArray<FTransform>` và 17 khớp qua validator hình học. Nếu `0xA30/0xA40` rỗng
hoặc không phải transform, engine tự rơi xuống `0xE18/0xE28`, rồi `0xC98`.
`0xE18/0xE28` có thể là buffer eval tạm/stale; vì vậy chúng chỉ là fallback sau
`0xA30/0xA40`, không phải nguồn duy nhất.

Thứ tự đọc trực tiếp trong `ESPBonesConfigure`:

1. Buffer `CurrentRead` của `0xA30/0xA40` trước, buffer còn lại sau.
2. `0xE18`, rồi `0xE28` (fallback eval-context).
3. Chỉ khi các mảng trên fail mới compose `0xC98` (bone space + `BoneTree.ParentIndex`).
4. Cuối cùng mới quét mù `mesh+[0x400..0xF00)` bước 8 để chịu được build dời field.
   `0xCA8` bị bỏ khỏi cả direct lẫn blind scan vì là mảng compact `RequiredBones`.

Khi đọc trực tiếp `0xA30/0xA40`, engine đọc `CurrentReadComponentTransforms`
(`0xA74`) **mỗi frame sample** để lấy buffer game đang đọc, tránh đọc trúng buffer
đang ghi (pose bị xé). Nếu `0xA74` không đọc được hoặc không phải `0/1`, engine
thử `0xA78` (có thể là `CurrentRead` thật nếu `0xA74` là `CurrentEditable`), rồi
mới quay lại buffer đã validate lúc configure. Log chẩn đoán in cả hai field;
mọi lần đọc đều là `ESPMemoryRead` có kiểm tra `BOOL`.

**Bảng index:**

- **Bảng theo TÊN xương** (qblpack): đọc `mesh+0xA20` → `SkeletalMesh`,
  `+0x48` → `USkeleton`, `+0x30` → `BoneTree` (`TArray<FBoneNode>`, stride `0x10`),
  resolve FName qua GNames và khớp 17 khớp (`head`, `neck`, `spine_03`, `pelvis`,
  `upperarm_l/r`, `lowerarm_l/r`, `hand_l/r`, `thigh_l/r`, `calf_l/r`, `foot_l/r`).
  Hỗ trợ cả tên kiểu `Bip01 L UpperArm`. Chỉ nhận khi **đủ 17 khớp** và validate
  hình học; fail mới fallback bảng tự dò/index. **Lưu ý:** build hiện tại GNames
  không resolve được nên nhánh tên tự bỏ qua.
- **Bảng tự dò từ ref pose (`ESPBoneMap.h`):** `USkeleton.RefLocalPoses`
  (`0x40`, TArray<FTransform>) → nhân dồn theo `ParentIndex` → T/A-pose component
  space, rồi nhận diện 17 khớp bằng **cấu trúc cây + hình học**: pelvis = tổ tiên
  chung của 2 chân (2 lá thấp nhất 2 phía Y), hông/gối = con trên đường xuống,
  cột sống = đi lên theo con có Z cao nhất, ngực = đốt còn 2 nhánh tay, tay =
  đi ra theo ±Y (bỏ clavicle khi chuỗi >= 4 xương). Dùng ref pose nên **không
  phụ thuộc pose đang chơi** và **không cần GNames**; cache 60s theo `USkeleton`.
- **Ref pose đa-offset:** `ESPBoneReadRefPose` thử `USkeleton.RefLocalPoses`
  (nới lỏng count), quét `kSkelScan[]` quanh nó — ứng viên chỉ accept khi **đúng
  số xương của BoneTree** (lệch là TArray khác như notifies/sockets) — rồi quét
  tiếp trên **USkeletalMesh asset** (`FReferenceSkeleton.RefPose` nằm ở asset,
  không ở component).
- **Fallback LIVE-POSE:** nếu ref pose vẫn không đọc được (build bị xoá/dời như
  `0xCD0/0xCE0`) thì `ESPBoneAutoMapFromLive` dựng bảng index từ **pose hiện
  tại**: thử trực tiếp `0xA30/0xA40` (theo `CurrentRead`), `0xE18/0xE28`, rồi
  mới compose `0xC98`; dùng `ESPBoneMapBuild` + validator tỉ lệ
  `ESPBoneMapPlausible` (chỉ độ dài xương, bỏ thứ tự Z nên đứng/đi/chạy đều pass;
  nằm/ngồi xổm có thể fail). Cache thành công 60s, thất bại chỉ 8s để lần configure
  sau cơ hội gặp pose đứng. Log:
  `bones automap: LIVE-POSE ok skel=0x… n=… head=…` hoặc
  `bones automap: skip (<refpose> | live <lý do>)`.
- **Composed path:** đọc `0xC98` (bone space) + `BoneTree.ParentIndex`
  (int32 @ `+8`), nhân dồn `parent * local` bằng quaternion/translation/scale
  (UE `FTransform::Multiply`) rồi validate bảng tự dò / bảng tên / các bảng index.
  BoneTree được thử `0x30/0x68/0x78/0x28`; chỉ nhận khi `parent < index`.
- **Các bảng index hard-code:** A/B/C cũ + **D = UE4 mannequin đủ clavicle**
  (`7/8/9/10` vai-khuỷu-tay). Map A dùng `7/8/10` (clavicle/upperarm/hand) nên
  `upperarm→hand` ~55cm > 45cm → validator loại; đây là lý do phổ biến của
  `bones no-match` khi rig không khớp bảng.
- **Map G (tham chiếu source Troll / ShadowTrackerExtra):** head `8`, neck `5`,
  chest `4`, pelvis `1`; tay phải `13/15/16`, tay trái `34/36/37`; chân phải
  `55/56/57`, chân trái `59/60/61`. Đây là rig có finger/twist bone chen giữa,
  khác hẳn map D. **Runtime 2026-10-22 (kernrw71):** `0xA30` count=67, map=6
  pass validator; ref/live auto-map fail ở `feet` nhưng map G cứu được. Vẫn giữ
  validator hình học vì index có thể đổi theo build/skin.
- **Chỉ player/bot thật:** configure và sample xương chỉ chạy với `kind == 1`.
  Hình nhân `kind == 3` không sample xương; bridge cũng không vẽ skeleton và
  không kéo snapline cho `kind == 3`, tránh rig hình nhân làm hỏng map cache.
- **Throttle:** configure tối đa 1.5s/lượt, chạy trên queue nền + mutex riêng
  (`try_lock` ở tick 60Hz) nên không chặn HUD. Khi chưa dò được, engine giữ
  `bones off`; không đọc offset mỗi frame.
- **Auto-off:** mỗi tick kiểm tra chéo đầu phải quanh mép trên box; lệch liên tục
  ~600 tick (~10s) thì tự tắt (`bones auto-off`) để không vẽ rác.
- Trạng thái: `bones off` / `bones detect` / `bones 0xc98 auto ok` (bảng tự dò) /
  `bones 0xa30 map6 ok` (map G, runtime 2026-10-22) / `bones no-match` /
  `bones auto-off`.
- Log chẩn đoán (10s/lần): `bones readidx: 0xa74 ok=… value=…; 0xa78 ok=… value=…`;
  `bones probe: 0xa30/0xa40/0xe18/0xe28/0xce0/0xcd0 data=… count=… max=…` và
  `p0/p1/p6`; `bones automap: ok…` / `LIVE-POSE ok…` / `skip…`;
  `bones: offset=0xa30 AUTO-MAP ok…`; `bones cand: off=…`;
  `bones compose: 0xc98 fail (…)`; `bones sample: compose fail (…)`.
- Bật/tắt toggle Bones là engine bật/tắt đọc xương ngay tick sau (không reset app).

**Lưu ý:** nếu `bones no-match`, xem các dòng chẩn đoán (10s/lần):
- `bones readidx` và `bones probe` cho biết `0xA30/0xA40/0xE18/0xE28` có phải
  `TArray<FTransform>` không (`data != 0`, `count/max` hợp lệ, `p0/p1/p6` có toạ độ
  người thật). `0xCE0/0xCD0` `count=0` là bình thường sau skin.
- `bones: offset=...` cho biết offset nào được nhận; `AUTO-MAP`/`mapN` cho biết
  bảng index. `bones automap: skip (...)` cho biết ref/live fail ở bước nào.
- `bones cand: off=...` là TArray 20..400 tìm thấy trong `0xC00..0xF00` (offset mới).
- `bones compose: 0xc98 fail` = không đọc được bone-space / `BoneTree` hoặc parent
  không hợp lệ. `bones sample: compose fail` = mảng bị xoá/dời giữa trận.
- Nếu offset đúng nhưng skeleton lệch box, kiểm tra `ComponentToWorld` `0x208` và
  xem `p0/p1/p6` có cùng hệ quy chiếu component-space (cm, Z hướng lên) không.

### Chiều cao box

`ESPActorBoxHeight` đọc `USkinnedMeshComponent::CachedLocalBounds.BoxExtent.Z`
(`0xB8C + 0x14 = 0xBA0`, DUMP xác nhận qua field kế tiếp `bCachedLocalBoundsUpToDate`
`0xBA8`) × 2. Giá trị ngoài khoảng 30..200cm → fallback `ESP_CHAR_HEIGHT_CM`.
StaticMesh của hình nhân không có `CachedLocalBounds` nên luôn dùng fallback.

### Snapline

Giống bản cũ (Kernel): từ `(W/2, 25)` → đỉnh box, **chỉ player** (`kind==1`), nhưng gộp
tất cả vào 1 polyline `start→box1→start→box2…` → 1 `CGPathAddLines` cho cả frame.

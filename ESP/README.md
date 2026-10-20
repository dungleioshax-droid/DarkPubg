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
     30Hz + ngưỡng 0.5pt; viền chữ kiểu QBL (`AddOutlinedText`) xấp xỉ bằng shadow đen
     radius 1.2 set **1 lần** lúc tạo (0 chi phí mỗi frame).
   - frame trùng hash (không có gì đổi) → bỏ qua toàn bộ remote call.
3. Tất cả nằm trong 1 `UIView` gốc (`g_qblRoot`) là con của container cũ → hide/show
   1 call, window cleanup cũ giữ nguyên.

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
   - shape/label **tạo lazy, tối đa 2 shape + 2 label mỗi tick**
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
   - font **mượn từ label HUD** (`font` getter, UILabel giữ retain), không factory;
   - `g_qblStyleOK` / `g_qblDead`: style fail 3 lần → bỏ QBL trong session đó để
     **giữ session cho HUD**, không retry vô hạn;
   - `ds_remove_springboard_hud`: nếu session đã chết, **mở session mới chỉ để
     hide** HUD/ESP rồi destroy → tắt HUD luôn có tác dụng, không cần respring;
   - log thêm `process.lastError` (tên call bị fault) vào `ESP.log`.

Tắt xương/snapline/... chỉ đổi builder, presenter không đổi. Có thể quay lại
renderer per-box cũ bằng `#define DS_ESP_RENDER_COMMANDLIST 0` trong `DSBridge.mm`
(code cũ vẫn còn nguyên, chỉ bị compile-out ở nhánh `#if`).

### Bones (skeleton) — offset DUMP + tự dò/validate ở runtime

DUMP/SDK (`USkeletalMeshComponent`) xác nhận 2 mảng transform:

| Offset | Field | Hệ quy chiếu |
|---|---|---|
| `0xCE0` | `CachedComponentSpaceTransforms` | component space (dùng cho ESP) |
| `0xCD0` | `CachedBoneSpaceTransforms` | bone/parent space |

`ComponentToWorld` = `0x208` (ngay sau `RelativeScale3D` `0x1FC`; SDK không liệt kê
field transient này nhưng đúng thứ tự UE4 và khớp khoảng trống tới `ComponentVelocity`
`0x2C0`). Engine vẫn **validate runtime** trước khi dùng:

- Thử lần lượt `0xCE0` → `0xCD0`; nếu không khớp mới quét dải cũ
  `mesh+[0x480..0xC00)` bước 8 làm fallback (`ESPOff_Mesh_BoneScanStart/End`).
  Stride `0x30` (`ESPOff_BoneTransformSize`).
- Với mỗi ứng viên thử 3 bảng index khớp phổ biến (UE4 mannequin + 2 biến thể rig)
  và **validate bằng tỉ lệ cơ thể thật**: đầu>cổ>ngực>hông, tay 15..45cm, chân
  25..70cm, bàn chân thấp hơn hông, 2 vai ngược hướng + cách nhau 20..80cm.
  `0xCD0` (bone space) sẽ bị loại ở bước này vì toạ độ quá nhỏ.
- Mỗi tick kiểm tra chéo: đầu phải quanh mép trên box → lệch liên tục ~600 tick
  (~10s) thì **tự tắt** (`bones auto-off`) để không vẽ rác.
- Trạng thái hiện ở dòng status: `bones off` / `bones detect` / `bones 0x<off> ok` /
  `bones no-match` / `bones auto-off`.
- Bật/tắt toggle Bones là engine bật/tắt đọc xương ngay tick sau (không reset app).
- Rig khác? Thêm bảng index vào `kESPBoneMaps` (`ESPEngine.mm`) — validate sẽ tự chọn.

**Lưu ý:** log `bones: offset=0xce0 ...` là kỳ vọng đúng với DUMP hiện tại. Nếu toàn
`bones no-match` thì rig khác bảng index (gửi log để thêm bảng mới); `bones auto-off`
thì offset/map sai (engine tự tắt, các tính năng khác không ảnh hưởng).

### Chiều cao box

`ESPActorBoxHeight` đọc `USkinnedMeshComponent::CachedLocalBounds.BoxExtent.Z`
(`0xB8C + 0x14 = 0xBA0`, DUMP xác nhận qua field kế tiếp `bCachedLocalBoundsUpToDate`
`0xBA8`) × 2. Giá trị ngoài khoảng 30..200cm → fallback `ESP_CHAR_HEIGHT_CM`.
StaticMesh của hình nhân không có `CachedLocalBounds` nên luôn dùng fallback.

### Snapline

Giống bản cũ (Kernel): từ `(W/2, 25)` → đỉnh box, **chỉ player** (`kind==1`), nhưng gộp
tất cả vào 1 polyline `start→box1→start→box2…` → 1 `CGPathAddLines` cho cả frame.

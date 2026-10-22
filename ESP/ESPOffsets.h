//
//  ESPOffsets.h
//  ESP isolated module — offsets from DUMP.zip (ShadowTrackerExtra)
//

#ifndef ESPOffsets_h
#define ESPOffsets_h

#import <Foundation/Foundation.h>
#include <stdint.h>

// Dump info: BaseAddress 0x4FA4000, __TEXT 0x104FA4000-0x10D368000
// UEPointers trong dump là absolute với base 0x100000000 (slide 0).
// Runtime: addr = gameBase + (dumpPtr - 0x100000000)
// gameBase lấy từ DSBridgeGameBase() (== __TEXT start hiện tại).

static const uint64_t ESPDumpBaseText = 0x104FA4000ULL;
static const uint64_t ESPDumpBaseZero = 0x100000000ULL;

static inline uint64_t ESPRVA(uint64_t dumpPtr) {
    return dumpPtr >= ESPDumpBaseZero ? (dumpPtr - ESPDumpBaseZero) : dumpPtr;
}
static inline uint64_t ESPRuntime(uint64_t gameBase, uint64_t dumpPtr) {
    return gameBase + ESPRVA(dumpPtr);
}

// UEPointers (từ DUMP/Offsets.hpp + Logs.txt)
static const uint64_t ESPDump_GNames        = 0x10d492ac0ULL; // [<Base>+0x10D492AC0]=0x112436AC0
static const uint64_t ESPDump_GUObjectArray = 0x10a692d18ULL; // ObjObjects Num 206445
static const uint64_t ESPDump_ObjObjects    = 0x10a692d28ULL;
static const uint64_t ESPDump_GEngine       = 0x10a8aa8a0ULL;
static const uint64_t ESPDump_ProcessEvent  = 0x10516ec34ULL;
static const int32_t  ESPDump_ProcessEventIndex = 76;

// UWorld (Engine.World, size 0xE38)
static const uint32_t ESPOff_UWorld_PersistentLevel    = 0x30;
static const uint32_t ESPOff_UWorld_OwningGameInstance = 0x470;
static const uint32_t ESPOff_UWorld_Levels             = 0x440; // TArray<ULevel*>, fallback

// --- Fast player path: UWorld.GameState -> PlayerArray -> PlayerState.Pawn ---
// DUMP/SDK.txt (Engine.World, GameStateBase, PlayerState):
//   World.GameState              @ 0x428  (AGameStateBase*)
//   GameStateBase.PlayerArray    @ 0x4C8  (TArray<APlayerState*>; Data 0x4C8, Num 0x4D0)
//   PlayerState.PawnPrivate      @ 0x528  (APawn*)
//   PlayerState.bIsABot          @ 0x4DC  (byte bitfield: bIsABot = bit2)
// Quét 8000 actor để tìm player rất chậm khi page cache lạnh; PlayerArray chỉ
// ~100 phần tử nên có box trong <1s. Actor array vẫn được quét lát để bắt
// hình nhân huấn luyện (kind 3) và làm fallback khi PlayerArray hỏng.
static const uint32_t ESPOff_UWorld_GameState        = 0x428;
static const uint32_t ESPOff_UWorld_AuthorityGameMode = 0x420; // fallback: GameMode->GameState
static const uint32_t ESPOff_GameMode_GameState       = 0x508; // AGameModeBase::GameState
static const uint32_t ESPOff_GameState_PlayerArray   = 0x4C8;
static const uint32_t ESPOff_PlayerState_PawnPrivate = 0x528;
static const uint32_t ESPOff_PlayerState_IsABot      = 0x4DC;

// UEngine / UGameEngine
static const uint32_t ESPOff_Engine_GameViewport = 0x810; // UEngine->GameViewport
static const uint32_t ESPOff_GameEngine_GameInstance = 0xE20; // UGameEngine->GameInstance

// UGameViewportClient
static const uint32_t ESPOff_Viewport_World = 0x78; // UWorld* trực tiếp, chain ngắn nhất
static const uint32_t ESPOff_Viewport_GameInstance = 0x80;

// ULevel (size 0x4B8)
// Actors THẬT theo source Kernel/esp/drawing_view (đã chạy được):
//   Level+0xA0 = TArray Actors (nếu !=0 dùng luôn)
//   Level+0x448 = TArray mã hoá (nếu !=0 dùng luôn)
//   còn lại giải mã qua struct ở Level+0x448+0x10 (xem DecryptActorsArray)
// ActorCluster 0xE0 ở bản này trống (E62) — giữ lại để tham khảo.
static const uint32_t ESPOff_ULevel_Actors = 0xA0;
static const uint32_t ESPOff_ULevel_EncryptedActors = 0x448;
static const uint32_t ESPOff_ULevel_ActorCluster = 0xE0; // ULevelActorContainer* (trống ở bản này)
static const uint32_t ESPOff_ULevel_OwningWorld = 0xC0; // ULevel->OwningWorld (check chéo)
static const uint32_t ESPOff_ActorCluster_Actors = 0x28; // TArray<AActor*>

// AActor
static const uint32_t ESPOff_Actor_RootComponent = 0x208;
static const uint32_t ESPOff_Actor_ReplicatedMovement = 0x110; // FRepMovement
static const uint32_t ESPOff_RepMovement_Location = 0x18;      // +0x110 = Actor+0x128 FVector world
static const uint32_t ESPOff_Actor_HiddenFlag = 0xE8; // bHidden bit0 (mask 0x1)

// Character (ASTExtraBaseCharacter, từ Kernel/esp/unity_api/offset.h)
static const uint32_t ESPOff_Char_Mesh = 0x510; // USkeletalMeshComponent*
static const uint32_t ESPOff_Char_Health = 0xE60; // float
static const uint32_t ESPOff_Char_HealthMax = 0xE64; // float
static const uint32_t ESPOff_Char_Dead = 0xE7C; // bit0 mask 0x1
static const uint32_t ESPOff_Char_Team = 0x998; // int
static const int32_t ESPTeam_Dummy = 100000005; // hình nhân, luôn hiện

// Hình nhân huấn luyện AShootingPracticeTarget : AActor (từ offset.h)
// (object chỉ dài ~0x508 — đọc quá mốc đó là rác heap của object kế bên)
static const uint32_t ESPOff_Target_CurHealth = 0x4D0; // float
static const uint32_t ESPOff_Target_MaxHealth = 0x4AC; // float
static const uint32_t ESPOff_Target_Mesh = 0x4E8; // UStaticMeshComponent*
static const uint32_t ESPOff_Target_IsUp = 0x4D4; // bool 0/1

// USceneComponent — đối chiếu DUMP/SDK/Engine.hpp (bản game hiện tại):
//   AttachParent 0x188, AttachChildren 0x198, ClientAttachedChildren 0x1A8,
//   RelativeLocation 0x1E4, RelativeRotation 0x1F0, RelativeScale3D 0x1FC.
// ComponentToWorld không được SDK liệt kê (transient) nhưng theo đúng thứ tự
// UE4 thì nó nằm ngay sau RelativeScale3D: 0x1FC + 0xC = 0x208 (FTransform
// 0x30 -> hết 0x238, khớp khoảng trống trước ComponentVelocity 0x2C0).
// 0x1D0 (offset cũ từ source Kernel của build khác) rơi vào vùng đệm ngay
// trước RelativeLocation -> đọc ra rác, xương luôn sai vị trí.
static const uint32_t ESPOff_Scene_RelativeLocation = 0x1E4; // FVector
static const uint32_t ESPOff_Scene_AttachedParent = 0x188; // USceneComponent* (location = mình + parent)
static const uint32_t ESPOff_Comp_ComponentToWorld = 0x208; // FTransform
static const uint32_t ESPOff_Transform_Translation = 0x10;   // FQuat 0x0 + FVector 0x10

// Chiều cao box — chỉ đúng cho SkeletalMesh của nhân vật:
// USkinnedMeshComponent::CachedLocalBounds (FBoxSphereBounds) @ 0xB8C
//   Origin 0xB8C, BoxExtent 0xB98 -> BoxExtent.Z @ 0xBA0.
// DUMP xác nhận: field kế tiếp bCachedLocalBoundsUpToDate @ 0xBA8
// (= 0xB8C + 0x1C đúng sizeof(FBoxSphereBounds)).
// Đây là local bounds (scale mesh ~1) nên *2 ra chiều cao ~176cm.
// Giá trị ngoài 30..200cm -> ESPActorBoxHeight fallback ESP_CHAR_HEIGHT_CM.
// (StaticMesh của hình nhân không có CachedLocalBounds -> luôn fallback.)
static const uint32_t ESPOff_Mesh_BoxExtentZ = 0xBA0;

// Camera chain (PUBG UE4 — theo source Kernel ĐANG CHẠY ĐƯỢC, unity_api/offset.h)
// UWorld 0x470 OwningGameInstance -> UGameInstance 0x48 LocalPlayers[TArray]
// -> ULocalPlayer (UPlayer) 0x30 PlayerController
// -> APlayerController 0x548 PlayerCameraManager
// -> APlayerCameraManager 0x10A0 ViewTarget (FTViewTarget)
//    -> +0x10 POV (FMinimalViewInfo)
//    POV: Location 0x0 (FVector), Rotation 0x18 (FRotator), FOV 0x24 (float), Aspect 0x34 (float)
// CameraCache 0x520 bị loại: bản game này camera thật nằm ở ViewTarget —
// nguồn Kernel đọc POV = PCM + 0x10A0 + 0x10 và ESP box của nó vẽ đúng.
static const uint32_t ESPOff_GameInstance_LocalPlayers = 0x48;
static const uint32_t ESPOff_Player_PlayerController   = 0x30;
static const uint32_t ESPOff_PC_CameraManager          = 0x548;
static const uint32_t ESPOff_CamMgr_ViewTarget         = 0x10A0; // FTViewTarget
static const uint32_t ESPOff_ViewTarget_POV            = 0x10;
static const uint32_t ESPOff_POV_Location              = 0x0;
static const uint32_t ESPOff_POV_Rotation              = 0x18;
static const uint32_t ESPOff_POV_FOV                   = 0x24;
static const uint32_t ESPOff_POV_Aspect                = 0x34;

// Local pawn chain (từ Kernel/esp/drawing_view/esp.mm)
// GWorld +0x38 NetDriver -> +0x78 ServerConnection -> +0x30 LocalPC -> +0x28D8 LocalPawn
static const uint32_t ESPOff_World_NetDriver = 0x38;
static const uint32_t ESPOff_NetDriver_ServerConn = 0x78;
static const uint32_t ESPOff_Conn_LocalPC = 0x30;
static const uint32_t ESPOff_PC_LocalPawn = 0x28D8; // ASTExtraPlayerController->STExtraBaseCharacter

// --- Xương / skeleton (port hướng QBL getBoneWithRotationFast) ---
// DUMP/SDK xác nhận 2 mảng transform trong USkeletalMeshComponent:
//   0xCD0 = CachedBoneSpaceTransforms      (TArray<FTransform>, bone/parent space)
//   0xCE0 = CachedComponentSpaceTransforms (TArray<FTransform>, component space)
// ESP cần COMPONENT SPACE rồi nhân ComponentToWorld -> ưu tiên 0xCE0; 0xCD0
// thử sau (validator tỉ lệ cơ thể sẽ tự loại vì toạ độ bone-space quá nhỏ).
// Dải quét cũ vẫn giữ làm fallback nếu bản game sau dời field.
static const uint32_t ESPOff_Mesh_BoneCompSpace = 0xCE0; // DUMP: CachedComponentSpaceTransforms
static const uint32_t ESPOff_Mesh_BoneBoneSpace = 0xCD0; // DUMP: CachedBoneSpaceTransforms
// qblpack (log 2026-10-21): trên build đang chạy, 0xCD0/0xCE0 có Num=0
// (Max=67) — game xoá sau khi skin. Hai mảng transient nằm trong khoảng trống
// DUMP không liệt kê (0xC98..0xCD0), đúng thứ tự UE4:
//   0xC98 = BoneSpaceTransforms      (Num=67, local/parent space)
//   0xCA8 = RequiredBones / compact component-space subset (Num=44)
// Vì 0xCA8 bị compact theo RequiredBones nên index không khớp skeleton.
static const uint32_t ESPOff_Mesh_BoneSpaceTransforms = 0xC98;
static const uint32_t ESPOff_Mesh_ComponentSpaceTransforms = 0xCA8;
// kernrw70: USkinnedMeshComponent giữ 2 buffer ComponentSpaceTransformsArray[2].
// Theo layout UE4, hai TArray này nằm ngay sau MasterPoseComponent (0xA28) và
// trước bUseBoundsFromMasterPoseComponent (0xAE0), nên ứng viên là 0xA30/0xA40.
// Đây là buffer đọc/ghi component-space live, đủ skeleton (không compact).
static const uint32_t ESPOff_Mesh_CompSpaceRead0 = 0xA30;
static const uint32_t ESPOff_Mesh_CompSpaceRead1 = 0xA40;
// int32 CurrentReadComponentTransforms nằm sau 2 buffer + các field private
// (0xA50 PreviousBoneVisibilityStates, 0xA60 PreviousComponentSpace..., 0xA70
// CurrentEditable). Chỉ dùng để CHỌN buffer đọc; nếu giá trị không phải 0/1 thì
// fallback thử lần lượt cả 2 buffer, không tin mù offset này.
// Có khả năng 0xA74 là CurrentEditable và 0xA78 mới là CurrentRead (bool/padding
// giữa hai int32). Vì vậy đọc thêm 0xA78: chỉ dùng khi 0xA74 không hợp lệ, và
// luôn log cả hai để lần chạy thật xác nhận; không đổi buffer nếu 0xA74 đã 0/1.
static const uint32_t ESPOff_Mesh_CompSpaceReadIdx = 0xA74;
static const uint32_t ESPOff_Mesh_CompSpaceReadIdx2 = 0xA78;
// Log kernrw63 thấy thêm 2 TArray<FTransform> Num=67 ở 0xE18/0xE28. Có thể là
// FAnimationEvaluationContext (eval song song); buffer này có thể stale, nên chỉ
// dùng làm fallback sau 0xA30/0xA40 và chỉ nhận khi validator hình học pass.
static const uint32_t ESPOff_Mesh_CompSpaceLive0 = 0xE18;
static const uint32_t ESPOff_Mesh_CompSpaceLive1 = 0xE28;
static const uint32_t ESPOff_Mesh_BoneScanStart = 0x400; // fallback: đầu vùng nghi TArray<FTransform>
static const uint32_t ESPOff_Mesh_BoneScanEnd   = 0xF00; // qblpack: phủ cả 0xCD0/0xCE0 và field dời sau đó
static const uint32_t ESPOff_BoneTransformSize  = 0x30;  // sizeof(FTransform) = 16 quat + 16 trans + 16 scale
static const uint32_t ESPOff_Bone_NumMax        = 256;   // skeleton thật có thể >40 khớp (tên xương)

// qblpack: chuỗi lấy TÊN xương từ USkeleton (DUMP-verified):
//   USkeletalMeshComponent.SkeletalMesh @ 0xA20
//   USkeletalMesh.Skeleton             @ 0x48
//   USkeleton.BoneTree (TArray<FBoneNode>) @ 0x30
// FBoneNode: FName @ 0x0 (ComparisonIndex + Number) + ParentIndex @ 0x8
//            + TranslationRetargetingMode @ 0xC + pad 3 => stride 0x10.
static const uint32_t ESPOff_Mesh_SkeletalMesh   = 0xA20;
static const uint32_t ESPOff_SkeletalMesh_Skeleton = 0x48;
// USkeleton.RefLocalPoses (TArray<FTransform>, DUMP 0x40): ref pose của rig
// (T/A-pose). Đây là mốc ỔN ĐỊNH để nhận diện khớp — người chơi đang nằm/ngồi
// không làm sai hình học của ref pose.
static const uint32_t ESPOff_Skeleton_RefLocalPoses = 0x40;
static const uint32_t ESPOff_Skeleton_BoneTree   = 0x30;
static const uint32_t ESPOff_BoneNodeSize        = 0x10;


// TArray layout (UE4)
typedef struct {
    uint64_t data; // pointer
    uint32_t count;
    uint32_t max;
} ESPTArray;

#endif /* ESPOffsets_h */

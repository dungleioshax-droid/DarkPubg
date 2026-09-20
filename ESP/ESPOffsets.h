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

// USceneComponent
static const uint32_t ESPOff_Scene_RelativeLocation = 0x1E4; // FVector
static const uint32_t ESPOff_Scene_AttachedParent = 0x188; // USceneComponent* (location = mình + parent)
static const uint32_t ESPOff_Comp_ComponentToWorld = 0x1D0; // FTransform
static const uint32_t ESPOff_Transform_Translation = 0x10;   // FQuat 0x0 + FVector 0x10

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

// TArray layout (UE4)
typedef struct {
    uint64_t data; // pointer
    uint32_t count;
    uint32_t max;
} ESPTArray;

#endif /* ESPOffsets_h */

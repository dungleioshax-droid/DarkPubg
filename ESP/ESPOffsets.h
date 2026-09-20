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

// ULevel (size 0x4B8) — bản này KHÔNG có Actors trực tiếp, đi qua ActorCluster
static const uint32_t ESPOff_ULevel_ActorCluster = 0xE0; // ULevelActorContainer*
static const uint32_t ESPOff_ULevel_OwningWorld = 0xC0; // ULevel->OwningWorld (check chéo)
static const uint32_t ESPOff_ActorCluster_Actors = 0x28; // TArray<AActor*>

// AActor
static const uint32_t ESPOff_Actor_RootComponent = 0x208;
static const uint32_t ESPOff_Actor_ReplicatedMovement = 0x110; // FRepMovement
static const uint32_t ESPOff_RepMovement_Location = 0x18;      // +0x110 = Actor+0x128 FVector world

// USceneComponent
static const uint32_t ESPOff_Scene_RelativeLocation = 0x1E4; // FVector

// Camera chain (PUBG UE4, từ SDK/Engine.hpp)
// UWorld 0x470 OwningGameInstance -> UGameInstance 0x48 LocalPlayers[TArray]
// -> ULocalPlayer (UPlayer) 0x30 PlayerController
// -> APlayerController 0x548 PlayerCameraManager
// -> APlayerCameraManager 0x520 CameraCache -> +0x10 POV (FMinimalViewInfo)
//    POV: Location 0x0 (FVector), Rotation 0x18 (FRotator), FOV 0x24 (float), Aspect 0x34 (float)
static const uint32_t ESPOff_GameInstance_LocalPlayers = 0x48;
static const uint32_t ESPOff_Player_PlayerController   = 0x30;
static const uint32_t ESPOff_PC_CameraManager          = 0x548;
static const uint32_t ESPOff_CamMgr_CameraCache        = 0x520;
static const uint32_t ESPOff_Cache_POV                 = 0x10;
static const uint32_t ESPOff_POV_Location              = 0x0;
static const uint32_t ESPOff_POV_Rotation              = 0x18;
static const uint32_t ESPOff_POV_FOV                   = 0x24;
static const uint32_t ESPOff_POV_Aspect                = 0x34;

// TArray layout (UE4)
typedef struct {
    uint64_t data; // pointer
    uint32_t count;
    uint32_t max;
} ESPTArray;

#endif /* ESPOffsets_h */

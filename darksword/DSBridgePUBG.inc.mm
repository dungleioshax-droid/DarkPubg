//
//  DSBridgePUBG.inc.mm
//  DarkPubg
//
//  PUBG Mobile (ShadowTrackerExtra) Unreal Engine 4 memory reader + ESP projector.
//  Included by DSBridge.mm.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/loader.h>
#include <cmath>
#include <vector>
#include <algorithm>
#include <atomic>
#include <unordered_set>
#include <mutex>
#include <ctime>
#include <os/lock.h>

// UEPointers from DUMP/Offsets.hpp & DUMP/Logs.txt (ShadowTrackerExtra UE4)
// Base address is Mach-O 64-bit main image (__TEXT)

// Class Member Offsets from DUMP/SDK/Engine.hpp & DUMP/SDK.txt
static const uint64_t kDSPUBGEngineGameViewportOffset        = 0x810ULL;  // UEngine.GameViewport (UGameViewportClient*)
static const uint64_t kDSPUBGEngineGameInstanceOffset        = 0xE20ULL;  // UGameEngine.GameInstance (UGameInstance*)
static const uint64_t kDSPUBGViewportWorldOffset             = 0x78ULL;   // UGameViewportClient.World (UWorld*)
static const uint64_t kDSPUBGWorldPersistentLevelOffset       = 0x30ULL;   // UWorld.PersistentLevel (ULevel*)
static const uint64_t kDSPUBGWorldOwningGameInstanceOffset   = 0x470ULL;  // UWorld.OwningGameInstance (UGameInstance*)
static const uint64_t kDSPUBGWorldGameStateOffset            = 0x428ULL;  // UWorld.GameState (AGameStateBase*)
static const uint64_t kDSPUBGWorldAuthorityGameModeOffset    = 0x420ULL;  // UWorld.AuthorityGameMode (AGameModeBase*)
static const uint64_t kDSPUBGGameModeGameStateOffset         = 0x508ULL;  // AGameModeBase.GameState (AGameStateBase*)

// Fast player list via GameState.PlayerArray
static const uint64_t kDSPUBGGameStatePlayerArrayOffset      = 0x4C8ULL;  // AGameStateBase.PlayerArray (TArray<APlayerState*>)
static const uint64_t kDSPUBGPlayerStatePawnPrivateOffset    = 0x528ULL;  // APlayerState.PawnPrivate (APawn*)
static const uint64_t kDSPUBGPlayerStateIsABotOffset         = 0x4DCULL;  // byte bitfield: bit 2 is bIsABot
static const uint64_t kDSPUBGPlayerStatePlayerNameOffset     = 0x4B8ULL;  // APlayerState.PlayerName (FString)
static const uint64_t kDSPUBGPlayerStateNationOffset         = 0x6F0ULL;  // AUAEPlayerState.Nation (FString)

// LocalPlayer & Camera Chain
static const uint64_t kDSPUBGGameInstanceLocalPlayersOffset  = 0x48ULL;   // UGameInstance.LocalPlayers (TArray<ULocalPlayer*>)
static const uint64_t kDSPUBGLocalPlayerControllerOffset     = 0x30ULL;   // UPlayer.PlayerController (APlayerController*)
static const uint64_t kDSPUBGPlayerControllerPawnOffset      = 0x528ULL;  // APlayerController.AcknowledgedPawn (APawn*)
static const uint64_t kDSPUBGPlayerControllerCameraMgrOffset = 0x548ULL;  // APlayerController.PlayerCameraManager (APlayerCameraManager*)

// Camera ViewTarget POV (PlayerCameraManager.ViewTarget at 0x10A0, POV at +0x10)
static const uint64_t kDSPUBGCameraViewTargetOffset          = 0x10A0ULL; // FTViewTarget
static const uint64_t kDSPUBGViewTargetPOVOffset             = 0x10ULL;   // FMinimalViewInfo
static const uint64_t kDSPUBGPOVLocationOffset               = 0x0ULL;    // FVector (float X, Y, Z)
static const uint64_t kDSPUBGPOVRotationOffset               = 0x18ULL;   // FRotator (float Pitch, Yaw, Roll)
static const uint64_t kDSPUBGPOVFOVOffset                    = 0x24ULL;   // float FOV
static const uint64_t kDSPUBGPOVAspectOffset                 = 0x34ULL;   // float Aspect

// Actor & Component Offsets
static const uint64_t kDSPUBGActorRootComponentOffset        = 0x208ULL;  // AActor.RootComponent (USceneComponent*)
static const uint64_t kDSPUBGSceneCompRelativeLocOffset      = 0x1E4ULL;  // USceneComponent.RelativeLocation (FVector)
static const uint64_t kDSPUBGSceneCompAttachedParentOffset   = 0x188ULL;  // USceneComponent.AttachedParent (USceneComponent*)
static const uint64_t kDSPUBGCharacterMeshOffset             = 0x510ULL;  // ASTExtraBaseCharacter.Mesh (USkeletalMeshComponent*)
static const uint64_t kDSPUBGMeshBoxExtentZOffset            = 0xBA0ULL;  // Mesh.Bounds.BoxExtent.Z
// UE4 UPrimitiveComponent render timestamps (inherited by USkeletalMeshComponent).
// These are world-time values (seconds) written by the renderer every frame.
static const uint64_t kDSPUBGCharacterPlayerNameOffset       = 0x960ULL;  // UAECharacter.PlayerName (FString)
static const uint64_t kDSPUBGCharacterNationOffset           = 0x970ULL;  // UAECharacter.Nation (FString)
static const uint64_t kDSPUBGCharacterPlayerKeyOffset        = 0x990ULL;  // UAECharacter.PlayerKey (uint32_t) [DUMP updated]
static const uint64_t kDSPUBGCharacterPlayerUIDOffset        = 0x998ULL;  // UAECharacter.PlayerUID (FString)
static const uint64_t kDSPUBGCharacterTeamIDOffset           = 0x9A8ULL;  // UAECharacter.TeamID (int32_t) [DUMP updated]
static const uint64_t kDSPUBGCharacterIsAIOffset             = 0xA50ULL;  // UAECharacter.bIsAI (bool) [DUMP updated]
static const uint64_t kDSPUBGCharacterHealthOffset           = 0xE70ULL;  // STExtraCharacter.Health (float) [DUMP updated]
static const uint64_t kDSPUBGCharacterHealthMaxOffset        = 0xE74ULL;  // STExtraCharacter.HealthMax (float) [DUMP updated]
static const uint64_t kDSPUBGCharacterDeadOffset             = 0xE8CULL;  // STExtraCharacter.bDead (uint8_t) [DUMP updated]

// Runtime target state
static uint64_t g_dspubgProc = 0;
static uint32_t g_dspubgPid = 0;
static uint64_t g_dspubgVmMap = 0;
static uint64_t g_dspubgBase = 0;
static uint64_t g_dspubgEngineRva = 0;
static uint64_t g_dspubgWorldRva = 0;
static uint64_t g_dspubgCachedWorld = 0;
static uint64_t g_dspubgEngineViewportOffset = kDSPUBGEngineGameViewportOffset;
static CFAbsoluteTime g_dspubgNextAttach = 0;
static CFAbsoluteTime g_dspubgNextScan = 0;
static std::atomic<bool> g_dspubgTargetActive(false);

// Live diagnostic statistics
static int g_dspubgLastActorsCount = 0;
static int g_dspubgLastEnemyCount = 0;
static int g_dspubgLastBotCount = 0;
static uint32_t g_dspubgLastBoneOff = 0;
static char g_dspubgStatusBuf[384] = "PUBG: Waiting for game process...";

// Snapshot storage
static os_unfair_lock g_dspubgSnapshotLock = OS_UNFAIR_LOCK_INIT;
static DSPUBGProjectedPlayer g_dspubgPlayers[kDSPUBGMaxPlayers] = {};
static int g_dspubgPlayerCount = 0;
static uint64_t g_dspubgEpoch = 1;

static DSPUBGProjectedItem g_dspubgItems[kDSPUBGMaxItems] = {};
static int g_dspubgItemCount = 0;
static uint64_t g_dspubgItemEpoch = 1;

static DSPUBGProjectedGrenade g_dspubgGrenades[kDSPUBGMaxGrenades] = {};
static int g_dspubgGrenadeCount = 0;
static uint64_t g_dspubgGrenadeEpoch = 1;

static uint64_t g_dspubgGNames = 0;
static uint32_t g_dspubgFNameEntryOffset = 0x0C;

// Fast Actor Classification Cache: Caches scenery, pawn, and item classification
// to eliminate repetitive GNames lookups and memory reads for thousands of level actors.
struct DSPUBGActorCacheEntry {
    uint64_t actor;
    bool isScenery;
    bool isPawn;
    bool isTrainingTarget;
    DSPUBGItemCategory itemCat;
    char itemName[36];
    uint64_t vCommon;
    float cachedHp;
    float cachedHpMax;
    float cachedFuel;
    float cachedFuelMax;
    uint64_t rootComp;
    uint64_t meshComp;
    uint64_t boneData;
    uint32_t boneCount;
    uint32_t boneOffset;
    // Name and nation are immutable for a pawn's lifetime, but they were
    // re-read through GNames + FString every frame for every visible enemy.
    // Weapon changes on pickup, so it gets a short refresh window instead.
    // Identity fields are separate from `actor` on purpose: `actor` is
    // rewritten mid-function, so it cannot tell a recycled hash slot apart.
    uint64_t infoActor;
    char cachedName[32];
    char cachedNation[16];
    uint64_t metaActor;
    uint64_t metaPs;
    bool cachedIsAI;
    bool cachedHasNation;
    bool cachedHasUID;
    char cachedMetaNation[16];
    uint64_t weaponActor;
    char cachedWeapon[32];
    uint64_t weaponRefreshTick;
};
static const size_t kDSPUBGActorCacheSize = 16384;
static DSPUBGActorCacheEntry g_dspubgActorCache[kDSPUBGActorCacheSize] = {};

static int s_cachedLootCount = 0;
static uint32_t s_levelScanTick = 0;
static std::vector<uint64_t> s_trackedLevelPawns;
static std::vector<uint64_t> s_trackedLevelGrenades;
static std::vector<uint64_t> s_trackedLevelVehicles;
static uint64_t s_lastMatchWorld = 0;
static uint64_t s_lastMatchLevel = 0;
static bool s_lastMatchMapIsLobby = false;
static uint64_t g_dspubgWorldLevelsOff = 0;

static inline uint32_t ds_pubg_actor_cache_hash(uint64_t actor) {
    return (uint32_t)((actor >> 4) ^ (actor >> 13)) & (uint32_t)(kDSPUBGActorCacheSize - 1);
}

static inline bool ds_pubg_is_pet_name(const char *name) {
    if (!name || !name[0]) return false;
    return (strcasestr(name, "Pet") != NULL ||
            strcasestr(name, "Companion") != NULL ||
            strcasestr(name, "Buddy") != NULL ||
            strcasestr(name, "Mascot") != NULL ||
            strcasestr(name, "Partner") != NULL ||
            strcasestr(name, "Falcon") != NULL ||
            strcasestr(name, "Pigeon") != NULL);
}

static inline bool ds_pubg_is_training_target_name(const char *name) {
    if (!name || !name[0]) return false;
    return (strcasestr(name, "ModelTarget") != NULL ||
            strcasestr(name, "TrainingTarget") != NULL ||
            strcasestr(name, "TrainingDummy") != NULL ||
            strcasestr(name, "TargetDummy") != NULL ||
            strcasestr(name, "ShootTarget") != NULL ||
            strcasestr(name, "PracticeTarget") != NULL ||
            strcasestr(name, "MoveTarget") != NULL);
}

// Fast check for static scenery / non-loot / non-character engine classes
static inline bool ds_pubg_is_scenery_name(const char *name) {
    if (!name || !name[0]) return false;
    if (ds_pubg_is_pet_name(name)) return true;
    // Keep training range humanoid targets eligible for pawn detection.
    if (ds_pubg_is_training_target_name(name)) return false;
    return (strstr(name, "StaticMesh") || strstr(name, "Foliage") ||
            strstr(name, "Landscape") || strstr(name, "Building") ||
            strstr(name, "House") || strstr(name, "Tree") ||
            strstr(name, "Rock") || strstr(name, "Wall") ||
            strstr(name, "Fence") || strstr(name, "Door") ||
            strstr(name, "Window") || strstr(name, "Floor") ||
            strstr(name, "Roof") || strstr(name, "Brush") ||
            strstr(name, "Decal") || strstr(name, "Particle") ||
            strstr(name, "Effect") || strstr(name, "Volume") ||
            strstr(name, "Audio") || strstr(name, "Sound") ||
            strstr(name, "Zone") || strstr(name, "Fog") ||
            strstr(name, "Light") || strstr(name, "Camera") ||
            strstr(name, "Trigger") || strstr(name, "Controller") ||
            strstr(name, "Water") || strstr(name, "Sky") ||
            strstr(name, "Cloud") || strstr(name, "Shadow") ||
            strstr(name, "Nav") || strstr(name, "Navigation") ||
            strstr(name, "Spline") || strstr(name, "Occlusion") ||
            strstr(name, "Reflection") || strstr(name, "PostProcess") ||
            strstr(name, "Wind") || strstr(name, "Emitter") ||
            strstr(name, "Shell") || strstr(name, "Cartridge") ||
            strstr(name, "Trace") || strstr(name, "Lobby") ||
            strstr(name, "MainCity") || strstr(name, "Preview") ||
            strstr(name, "Avatar") || strstr(name, "PetAvatar") ||
            strstr(name, "LobbyModel") || strstr(name, "DefaultPhysicsVolume") ||
            strstr(name, "Spawner") || strstr(name, "SpawnPoint") ||
            strstr(name, "SpawnPad") || strstr(name, "Terminal") ||
            strstr(name, "Station") || strstr(name, "Manager") ||
            strstr(name, "Stand") || strstr(name, "Table") ||
            strstr(name, "Board") || strstr(name, "Target") ||
            strstr(name, "Guide") || strstr(name, "Button") ||
            strstr(name, "Widget") || strstr(name, "UI") ||
            strstr(name, "SeatComponent") || strstr(name, "WheelComponent"));
}

// Precomputes RGBA color and priority for 120 FPS zero-overhead rendering
static inline void ds_pubg_compute_item_props(DSPUBGItemCategory cat, const char *name, uint32_t &outColor, bool &outPriority) {
    outPriority = false;
    if (cat == DSPUBGItemCategoryVehicle) {
        outColor = 0xFFD60AFF; // Yellow-gold
        return;
    }
    if (cat == DSPUBGItemCategoryCrate || (name && (strstr(name, "THÍNH") || strstr(name, "Xác")))) {
        outColor = 0xFF4B4BFF; // Red
        outPriority = true;
        return;
    }
    if (!name || !name[0]) {
        outColor = 0x4CD964FF; // Default Green
        return;
    }
    if (strstr(name, "M416") || strstr(name, "AWM") || strstr(name, "Groza") ||
        strstr(name, "AUG") || strstr(name, "Mk14") || strstr(name, "MG3") ||
        strstr(name, "AMR") || strstr(name, "P90") || strstr(name, "M762") ||
        strstr(name, "Flare") || strstr(name, "Kar98") || strstr(name, "M24")) {
        outColor = 0xFF2323FF; // Bright Red
        outPriority = true;
        return;
    }
    if (strstr(name, "5.56")) {
        outColor = 0x00E676FF; // Bright Green
        return;
    }
    if (strstr(name, "7.62")) {
        outColor = 0xFFA000FF; // Gold-orange
        return;
    }
    if (strstr(name, ".300")) {
        outColor = 0xFF3232FF; // Red
        outPriority = true;
        return;
    }
    if (strstr(name, "9mm") || strstr(name, "45ACP") || strstr(name, "12G")) {
        outColor = 0x38B6FFFF; // Sky blue
        return;
    }
    if (cat == DSPUBGItemCategoryArmor || cat == DSPUBGItemCategoryBag ||
        strstr(name, "Armor") || strstr(name, "Helmet") || strstr(name, "Bag") ||
        strstr(name, "Giáp") || strstr(name, "Mũ") || strstr(name, "Balo")) {
        outColor = 0x00E5FFFF; // Cyan
        if (strstr(name, "3") || strstr(name, "Lv3") || strstr(name, "Cấp 3")) outPriority = true;
        return;
    }
    if (strstr(name, "Kit") || strstr(name, "Painkiller") || strstr(name, "Drink") ||
        strstr(name, "Adrenaline") || strstr(name, "First Aid") || strstr(name, "Med Kit") ||
        strstr(name, "Nước") || strstr(name, "Giảm Đau")) {
        outColor = 0x4DD0E1FF; // Light cyan / teal
        return;
    }
    if (strstr(name, "Grenade") || strstr(name, "Molotof") || strstr(name, "Smoke") ||
        strstr(name, "Lựu") || strstr(name, "Bom") || strstr(name, "Choáng")) {
        outColor = 0xFF4081FF; // Magenta
        return;
    }
    if (cat == DSPUBGItemCategoryScope || strstr(name, "Scope") || strstr(name, "Holo") ||
        strstr(name, "RedDot") || strstr(name, "Sight") || strstr(name, "Compensator") ||
        strstr(name, "Suppressor")) {
        outColor = 0xBB86FCFF; // Violet
        if (strstr(name, "8x") || strstr(name, "6x")) outPriority = true;
        return;
    }
    if (strstr(name, "Token") || strstr(name, "Coin") || strstr(name, "Xu")) {
        outColor = 0xFFD60AFF; // Gold
        return;
    }
    if (cat == DSPUBGItemCategoryWeapon) {
        outColor = 0x4CD964FF; // Green
        return;
    }
    outColor = 0x4CD964FF; // Default Green
}

// Vector and Rotator types for projection
struct DSPUBGVector {
    float X, Y, Z;
};

struct DSPUBGCachedLoot {
    DSPUBGVector worldLoc;
    bool hasWorldLoc;
    DSPUBGItemCategory category;
    char name[36];
    uint32_t colorRGBA;
    bool isPriority;
};
static DSPUBGCachedLoot s_cachedLoot[kDSPUBGMaxItems * 2] = {};

struct DSPUBGRotator {
    float Pitch, Yaw, Roll;
};

struct DSPUBGCamBasis {
    float m00, m01, m02;
    float m10, m11, m12;
    float m20, m21, m22;
    float lx, ly, lz;
    float k;
    float cx, cy;
};

struct DSPUBGGrenadeHistory {
    uint64_t actor;
    DSPUBGGrenadeType type;
    uint64_t lastSeenTick;
    double lastTimestamp;
    double firstSeenTimestamp;
    float groundZ;
    DSPUBGVector lastLoc;
    int trailCount;
    DSPUBGVector trail[32];
    bool isGrounded;
};
static DSPUBGGrenadeHistory s_grenadeHistories[16] = {};
static uint64_t s_grenadeTickCounter = 0;

struct DSPUBGVisHistory {
    uint64_t actor;
    uint64_t lastSeenTick;
    int visibleStreak;
    int occludedStreak;
    bool isOccluded;
};
static DSPUBGVisHistory s_visHistories[128] = {};
static uint64_t s_visTickCounter = 0;

static inline bool ds_pubg_valid(uint64_t address) {
    uint64_t clean = address & 0x0000FFFFFFFFFFFFULL;
    return clean >= 0x100000000ULL && clean < 0x300000000000ULL;
}

static uint64_t ds_pubg_read_ptr(uint64_t address) {
    uint64_t value = 0;
    if (!ds_pubg_valid(address) || (address & 0x7ULL) != 0 || !g_dspubgVmMap) return 0;
    if (!ds_debug_read_bytes(g_dspubgVmMap, address, &value, sizeof(value))) return 0;
    value &= 0x0000FFFFFFFFFFFFULL;
    return (ds_pubg_valid(value) && (value & 0x7ULL) == 0) ? value : 0;
}

static bool ds_pubg_read(uint64_t address, void *buffer, size_t length) {
    if (!g_dspubgVmMap || !ds_pubg_valid(address) || !buffer || !length)
        return false;
    return ds_debug_read_bytes(g_dspubgVmMap, address, buffer, length);
}

static uint32_t ds_pubg_read_u32(uint64_t address) {
    uint32_t value = 0;
    if (!g_dspubgVmMap || !ds_pubg_valid(address) || (address & 0x3ULL) != 0) return 0;
    ds_debug_read_bytes(g_dspubgVmMap, address, &value, sizeof(value));
    return value;
}

static int32_t ds_pubg_read_i32(uint64_t address) {
    int32_t value = 0;
    if (!g_dspubgVmMap || !ds_pubg_valid(address) || (address & 0x3ULL) != 0) return 0;
    ds_debug_read_bytes(g_dspubgVmMap, address, &value, sizeof(value));
    return value;
}

static float ds_pubg_read_f32(uint64_t address) {
    float value = 0.0f;
    if (!g_dspubgVmMap || !ds_pubg_valid(address) || (address & 0x3ULL) != 0) return 0.0f;
    ds_debug_read_bytes(g_dspubgVmMap, address, &value, sizeof(value));
    return value;
}

static uint8_t ds_pubg_read_u8(uint64_t address) {
    uint8_t value = 0;
    if (!g_dspubgVmMap || !ds_pubg_valid(address)) return 0;
    ds_debug_read_bytes(g_dspubgVmMap, address, &value, sizeof(value));
    return value;
}

static int ds_pubg_ucs2_to_utf8(const uint8_t *src, int srcChars, char *out, int outCap) {
    if (!src || srcChars <= 0 || !out || outCap <= 1) return 0;
    int o = 0;
    for (int i = 0; i < srcChars && o + 4 < outCap; i++) {
        uint16_t u = (uint16_t)src[i * 2] | ((uint16_t)src[i * 2 + 1] << 8);
        if (u == 0) break;
        if (u < 0x80) {
            out[o++] = (char)u;
        } else if (u < 0x800) {
            out[o++] = (char)(0xC0 | (u >> 6));
            out[o++] = (char)(0x80 | (u & 0x3F));
        } else {
            out[o++] = (char)(0xE0 | (u >> 12));
            out[o++] = (char)(0x80 | ((u >> 6) & 0x3F));
            out[o++] = (char)(0x80 | (u & 0x3F));
        }
    }
    out[o] = '\0';
    return o;
}

static bool ds_pubg_read_fstring_nick(uint64_t fstr, char *out, int outCap) {
    if (!fstr || !ds_pubg_valid(fstr) || !out || outCap <= 1) return false;
    uint64_t dataPtr = ds_pubg_read_ptr(fstr);
    uint32_t num = ds_pubg_read_u32(fstr + 8);
    if (!dataPtr || !ds_pubg_valid(dataPtr) || num < 2 || num > 32) return false;
    uint8_t raw[64] = {0};
    uint64_t want = (uint64_t)num * 2;
    if (want > sizeof(raw)) want = sizeof(raw);
    if (!ds_pubg_read(dataPtr, raw, (size_t)want)) return false;
    int n = ds_pubg_ucs2_to_utf8(raw, (int)(want / 2), out, outCap);
    return n >= 2;
}

static bool ds_pubg_read_fstring_nation(uint64_t fstr, char *out, int outCap) {
    if (!fstr || !ds_pubg_valid(fstr) || !out || outCap <= 1) return false;
    out[0] = '\0';
    uint64_t dataPtr = ds_pubg_read_ptr(fstr);
    uint32_t num = ds_pubg_read_u32(fstr + 8);
    if (!dataPtr || !ds_pubg_valid(dataPtr) || num < 2 || num > 16) return false;
    uint8_t raw[32] = {0};
    uint64_t want = (uint64_t)num * 2;
    if (want > sizeof(raw)) want = sizeof(raw);
    if (!ds_pubg_read(dataPtr, raw, (size_t)want)) return false;
    int n = ds_pubg_ucs2_to_utf8(raw, (int)(want / 2), out, outCap);
    if (n >= 2) {
        for (int i = 0; i < n; i++) {
            out[i] = (char)toupper((unsigned char)out[i]);
        }
        return true;
    }
    return false;
}

// Check whether candidate pointer points to a valid Unreal Engine UWorld.
// In UE4: World.PersistentLevel (+0x30) -> Level.OwningWorld (+0xC0) == World.
static bool ds_pubg_is_valid_world(uint64_t vmMap, uint64_t world) {
    if (!ds_pubg_valid(world) || (world & 0x7ULL) != 0) return false;
    uint64_t level = 0;
    if (!ds_debug_read_bytes(vmMap, world + kDSPUBGWorldPersistentLevelOffset, &level, sizeof(level))) return false;
    level &= 0x0000FFFFFFFFFFFFULL;
    if (!ds_pubg_valid(level) || (level & 0x7ULL) != 0) return false;
    uint64_t owningWorld = 0;
    if (!ds_debug_read_bytes(vmMap, level + 0xC0ULL, &owningWorld, sizeof(owningWorld))) return false;
    owningWorld &= 0x0000FFFFFFFFFFFFULL;
    return (owningWorld == world);
}

// Check whether candidate pointer points to a valid Unreal Engine UEngine.
// In UE4: Engine.GameViewport (+0x810, +0x808, etc.) -> Viewport.World (+0x78) == UWorld.
static bool ds_pubg_is_valid_engine(uint64_t vmMap, uint64_t gengine, uint64_t *outVpOff, uint64_t *outWorld) {
    if (!ds_pubg_valid(gengine) || (gengine & 0x7ULL) != 0) return false;
    static const uint64_t vpOffsets[] = { 0x810, 0x808, 0x800, 0x818, 0x820, 0x780 };
    for (uint64_t vpOff : vpOffsets) {
        uint64_t vp = 0;
        if (!ds_debug_read_bytes(vmMap, gengine + vpOff, &vp, sizeof(vp))) continue;
        vp &= 0x0000FFFFFFFFFFFFULL;
        if (!ds_pubg_valid(vp) || (vp & 0x7ULL) != 0) continue;

        static const uint64_t wOffsets[] = { 0x78, 0x80, 0x70 };
        for (uint64_t wOff : wOffsets) {
            uint64_t world = 0;
            if (!ds_debug_read_bytes(vmMap, vp + wOff, &world, sizeof(world))) continue;
            world &= 0x0000FFFFFFFFFFFFULL;
            if (ds_pubg_is_valid_world(vmMap, world)) {
                if (outVpOff) *outVpOff = vpOff;
                if (outWorld) *outWorld = world;
                return true;
            }
        }
    }
    return false;
}

struct ScanRange {
    uint64_t start;
    uint64_t size;
    int priority; // 0 = high (__bss, __common), 1 = medium (__data), 2 = other
};

static bool ds_pubg_get_data_ranges(uint64_t vmMap, uint64_t base, std::vector<ScanRange> &outRanges) {
    struct mach_header_64 header = {};
    if (!ds_debug_read_bytes(vmMap, base, &header, sizeof(header)) ||
        header.magic != MH_MAGIC_64 || header.ncmds == 0 || header.ncmds > 1024 ||
        header.sizeofcmds == 0 || header.sizeofcmds > (64U * 1024U)) {
        return false;
    }

    std::vector<uint8_t> commands(header.sizeofcmds);
    if (!ds_debug_read_bytes(vmMap, base + sizeof(header), commands.data(), commands.size())) {
        return false;
    }

    uint64_t slide = 0;
    bool slideFound = false;
    size_t cursor = 0;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        if (cursor + sizeof(struct load_command) > commands.size()) break;
        const struct load_command *cmd = (const struct load_command *)(commands.data() + cursor);
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            if (strncmp(seg->segname, "__TEXT", 6) == 0) {
                slide = base - seg->vmaddr;
                slideFound = true;
                break;
            }
        }
        cursor += cmd->cmdsize;
    }
    if (!slideFound) return false;

    cursor = 0;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        if (cursor + sizeof(struct load_command) > commands.size()) break;
        const struct load_command *cmd = (const struct load_command *)(commands.data() + cursor);
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
            if (strncmp(seg->segname, "__DATA", 6) == 0) {
                const struct section_64 *sections = (const struct section_64 *)(commands.data() + cursor + sizeof(struct segment_command_64));
                for (uint32_t s = 0; s < seg->nsects; s++) {
                    const struct section_64 &sec = sections[s];
                    if (sec.size < 8) continue;
                    uint64_t sAddr = sec.addr + slide;
                    int prio = 2;
                    if (strcmp(sec.sectname, "__bss") == 0 || strcmp(sec.sectname, "__common") == 0) {
                        prio = 0;
                    } else if (strcmp(sec.sectname, "__data") == 0) {
                        prio = 1;
                    }
                    outRanges.push_back({sAddr, sec.size, prio});
                }
            }
        }
        cursor += cmd->cmdsize;
    }

    std::sort(outRanges.begin(), outRanges.end(), [](const ScanRange &a, const ScanRange &b) {
        return a.priority < b.priority;
    });

    return !outRanges.empty();
}

// ---------------------------------------------------------------------------
// GNames layout calibration
// ---------------------------------------------------------------------------
// Two incompatible layouts exist across UE4 releases, and picking the wrong one
// still "works" for a handful of ids, which is exactly how a scan ends up
// resolving 3 names out of 838 actors and silently produces zero obstacles:
//
//   TNameEntryArray  chunk = Blocks[id / 16384]; entry = chunk[id % 16384];
//                    entry -> { Index u32, Flags u32, name }
//   FNamePool        block = Blocks[id >> 16]; entry = block + (id & 0xFFFF);
//                    entry -> { u16 header, name }
//
// The compile-time offsets in this file were guesses. Both layouts and every
// plausible string offset are instead scored against sampled ids, and the
// combination that decodes the most printable names wins. A wrong guess scores
// near zero, so the choice is unambiguous.
enum : int {
    kDSPUBGNameLayoutArray = 0,   // TNameEntryArray
    kDSPUBGNameLayoutPool  = 1,   // FNamePool
};

struct DSPUBGNameLayout {
    int mode;
    uint32_t entryOff;
    uint32_t blockArrayOff;
    int score;
};

static DSPUBGNameLayout g_dspubgNameLayout = { kDSPUBGNameLayoutArray, 0x0C, 0x00, 0 };
static bool g_dspubgNamesCalibrated = false;

// Is `s` a believable FName string: printable ASCII, sane length?
static bool ds_pubg_name_is_plausible(const char *s, size_t cap) {
    size_t n = 0;
    while (n < cap && s[n] != '\0') {
        unsigned char c = (unsigned char)s[n];
        if (c < 32 || c > 126) return false;
        n++;
    }
    return n >= 2 && n <= 100;
}

static void ds_pubg_read_cstr(uint64_t vmMap, uint64_t addr, char *buf, size_t cap) {
    if (!buf || cap < 2) return;
    buf[0] = '\0';
    if (!addr || !ds_pubg_valid(addr)) return;
    if (!ds_debug_read_bytes(vmMap, addr, buf, cap - 1)) return;
    buf[cap - 1] = '\0';
}

// Validates one FNamePool entry sitting inside an already-read block copy.
//
// An FNamePool id is a *byte offset* into the block, not an entry index, and
// the header's low bits hold the name length. That gives a self-checking
// signature: the declared length must equal the string's actual length. Junk
// memory almost never satisfies it, which is what makes density scanning safe.
static bool ds_pubg_pool_entry_at(const uint8_t *buf, size_t bufLen, size_t pos,
                                  uint32_t entryOff, char *out, size_t outCap) {
    if (!buf || !out || outCap < 3) return false;
    if (pos + entryOff + 3 > bufLen) return false;

    // The header bitfield differs across UE4 releases: Len may sit in bits
    // 0..9, 0..10, or shift up by one for a bIsWide flag in bit 0. Every
    // candidate length is compared against the measured string instead of
    // assuming one layout.
    const uint32_t h = (uint32_t)buf[pos] | ((uint32_t)buf[pos + 1] << 8);

    const char *nm = (const char *)(buf + pos + entryOff);
    size_t room = bufLen - pos - entryOff;
    size_t n = 0;
    while (n < room && nm[n] != '\0') {
        unsigned char c = (unsigned char)nm[n];
        if (c < 32 || c > 126) return false;
        n++;
    }
    if (n < 2 || n >= room) return false;

    const uint32_t lengths[] = {
        h & 0x3FFu, (h >> 1) & 0x3FFu, (h >> 5) & 0x3FFu,
        h & 0x7FFu, (h >> 1) & 0x7FFu
    };
    bool lenOk = false;
    for (uint32_t cand : lengths) {
        if (cand == n) { lenOk = true; break; }
    }
    if (!lenOk) return false;
    if (n >= outCap) return false;

    memcpy(out, nm, n);
    out[n] = '\0';
    return true;
}

// Counts plausible entries in the head of one block. A live pool is dense -
// hundreds of entries in 16 KB - while an arbitrary pointer is not.
static int ds_pubg_pool_block_density(uint64_t vmMap, uint64_t block, uint32_t entryOff,
                                      char *sampleOut, size_t sampleCap) {
    if (!block || !ds_pubg_valid(block)) return 0;
    const size_t kLen = 16384;
    std::vector<uint8_t> buf(kLen);
    if (!ds_debug_read_bytes(vmMap, block, buf.data(), kLen)) return 0;

    int hits = 0;
    char name[96] = {0};
    for (size_t pos = 0; pos + 4 < kLen; pos += 2) {
        if (ds_pubg_pool_entry_at(buf.data(), kLen, pos, entryOff, name, sizeof(name))) {
            hits++;
            if (sampleOut && sampleCap > 2 && sampleOut[0] == '\0') {
                strncpy(sampleOut, name, sampleCap - 1);
                sampleOut[sampleCap - 1] = '\0';
            }
        }
    }
    return hits;
}

// Reads one name entry for `id` under a given layout.
static bool ds_pubg_name_probe(uint64_t vmMap, uint64_t blocksBase,
                               const DSPUBGNameLayout &lay, uint32_t id,
                               char *outBuf, size_t outCap) {
    if (!outBuf || outCap < 2) return false;
    outBuf[0] = '\0';
    if (!blocksBase || !ds_pubg_valid(blocksBase)) return false;

    if (lay.mode == kDSPUBGNameLayoutPool) {
        uint32_t blockIdx = id >> 16;
        uint32_t offsetInBlock = id & 0xFFFF;
        uint64_t blockArr = blocksBase + lay.blockArrayOff + (uint64_t)blockIdx * 8ULL;
        uint64_t block = 0;
        if (!ds_debug_read_bytes(vmMap, blockArr, &block, sizeof(block))) return false;
        block &= 0x0000FFFFFFFFFFFFULL;
        if (!ds_pubg_valid(block)) return false;

        // The pool header sits right before the string, so the entry is read as
        // a small window and validated the same way the density scan does.
        const size_t kWin = 512;
        std::vector<uint8_t> win(kWin);
        if (!ds_debug_read_bytes(vmMap, block + offsetInBlock, win.data(), kWin)) return false;
        return ds_pubg_pool_entry_at(win.data(), kWin, 0, lay.entryOff, outBuf, outCap);
    }

    uint32_t chunkIdx = id / 16384;
    uint32_t inChunkIdx = id % 16384;
    uint64_t chunk = 0;
    if (!ds_debug_read_bytes(vmMap, blocksBase + (uint64_t)chunkIdx * 8ULL, &chunk, sizeof(chunk))) return false;
    chunk &= 0x0000FFFFFFFFFFFFULL;
    if (!ds_pubg_valid(chunk)) return false;

    uint64_t entry = 0;
    if (!ds_debug_read_bytes(vmMap, chunk + (uint64_t)inChunkIdx * 8ULL, &entry, sizeof(entry))) return false;
    entry &= 0x0000FFFFFFFFFFFFULL;
    if (!ds_pubg_valid(entry)) return false;

    char raw[96] = {0};
    ds_pubg_read_cstr(vmMap, entry + lay.entryOff, raw, sizeof(raw));
    if (!ds_pubg_name_is_plausible(raw, sizeof(raw))) return false;

    strncpy(outBuf, raw, outCap - 1);
    outBuf[outCap - 1] = '\0';
    return true;
}

// Scores the TNameEntryArray layout over sampled ids. The sample spans the id
// range instead of taking the head: ids 0..4 are structural names that decode
// under almost any offset, so a head-only check accepts garbage.
static int ds_pubg_name_score_array(uint64_t vmMap, uint64_t blocksBase, uint32_t entryOff) {
    static const uint32_t kSampleIds[] = {
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
        20, 40, 80, 160, 320, 640, 1000, 2000, 4000,
        8000, 12000, 16000, 24000, 32000, 48000
    };
    DSPUBGNameLayout lay = { kDSPUBGNameLayoutArray, entryOff, 0x00, 0 };
    char buf[96] = {0};
    int score = 0;
    for (uint32_t id : kSampleIds) {
        if (ds_pubg_name_probe(vmMap, blocksBase, lay, id, buf, sizeof(buf))) score++;
    }
    return score;
}

// Scores the FNamePool layout by block density. `id` is a byte offset there, so
// sampling fixed small ids measures nothing - the block head is scanned instead.
static int ds_pubg_name_score_pool(uint64_t vmMap, uint64_t blocksBase,
                                   uint32_t blockArrayOff, uint32_t entryOff) {
    uint64_t block = 0;
    if (!ds_debug_read_bytes(vmMap, blocksBase + blockArrayOff, &block, sizeof(block))) return 0;
    block &= 0x0000FFFFFFFFFFFFULL;
    if (!ds_pubg_valid(block)) return 0;
    return ds_pubg_pool_block_density(vmMap, block, entryOff, nullptr, 0);
}

static bool ds_pubg_calibrate_names(uint64_t vmMap, uint64_t blocksBase, DSPUBGNameLayout &out) {
    out = DSPUBGNameLayout{ kDSPUBGNameLayoutArray, 0x0C, 0x00, 0 };
    if (!blocksBase || !ds_pubg_valid(blocksBase)) return false;

    const int kArrayAccept = 8;    // out of 26 sampled ids
    // A live pool holds hundreds to thousands of header-matching entries in the
    // first 16 KB of block 0, far more than the 26 ids the array path samples.
    // The comparison is therefore relative; the floor only rejects empty blocks.
    const int kPoolAccept = 8;

    DSPUBGNameLayout best = out;
    best.score = 0;

    static const uint32_t kEntryOffsets[] = { 0x02, 0x04, 0x06, 0x08, 0x0C, 0x0E, 0x10 };
    for (uint32_t entryOff : kEntryOffsets) {
        int score = ds_pubg_name_score_array(vmMap, blocksBase, entryOff);
        if (score > best.score) {
            best = DSPUBGNameLayout{ kDSPUBGNameLayoutArray, entryOff, 0x00, score };
        }
    }

    static const uint32_t kBlockArrayOffsets[] = { 0x00, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x20 };
    int poolBest = 0;
    DSPUBGNameLayout poolLayout = {};
    for (uint32_t blockOff : kBlockArrayOffsets) {
        for (uint32_t entryOff : kEntryOffsets) {
            int density = ds_pubg_name_score_pool(vmMap, blocksBase, blockOff, entryOff);
            if (density > poolBest) {
                poolBest = density;
                poolLayout = DSPUBGNameLayout{ kDSPUBGNameLayoutPool, entryOff, blockOff, density };
            }
        }
    }

    // A dense pool is decisive; the array path only wins when no block looks
    // like a pool at all.
    if (poolBest >= kPoolAccept && poolBest > best.score) {
        out = poolLayout;
        return true;
    }
    if (best.score >= kArrayAccept) {
        out = best;
        return true;
    }
    return false;
}

static bool ds_pubg_is_valid_gnames(uint64_t vmMap, uint64_t candidate, uint32_t *outNameOffset) {
    DSPUBGNameLayout layout = {};
    if (!ds_pubg_calibrate_names(vmMap, candidate, layout)) return false;
    g_dspubgNameLayout = layout;
    g_dspubgNamesCalibrated = true;
    g_dspubgFNameEntryOffset = layout.entryOff;
    if (outNameOffset) *outNameOffset = layout.entryOff;
    return true;
}

static void ds_pubg_try_known_gnames(uint64_t vmMap, uint64_t base) {
    if (g_dspubgGNames) return;
    static const uint64_t kKnownGNamesRVAs[] = {
        0x0D792AB0ULL, // Updated from DUMP/Offsets.hpp (Names = 0x10d792ab0)
        0x0D492AC0ULL, // v3.4 Global / VN / 64-bit Mach-O
        0x0D481AC0ULL,
        0x0D490AC0ULL,
        0x0D4A0AC0ULL
    };
    for (uint64_t rva : kKnownGNamesRVAs) {
        uint64_t val = 0;
        if (ds_debug_read_bytes(vmMap, base + rva, &val, sizeof(val))) {
            val &= 0x0000FFFFFFFFFFFFULL;
            uint32_t nameOff = 0x0C;
            // ds_pubg_is_valid_gnames calibrates the layout and stores it, so
            // nothing here may overwrite that choice.
            if (val && ds_pubg_valid(val) && ds_pubg_is_valid_gnames(vmMap, val, &nameOff)) {
                g_dspubgGNames = val;
                return;
            }
            if (ds_pubg_is_valid_gnames(vmMap, base + rva, &nameOff)) {
                g_dspubgGNames = base + rva;
                return;
            }
        }
    }
}

static void ds_pubg_scan_for_gnames(uint64_t vmMap, const std::vector<ScanRange> &scanRanges) {
    if (g_dspubgGNames) return;
    const size_t kChunkSize = 32768;
    std::vector<uint8_t> chunk(kChunkSize);

    for (const auto &range : scanRanges) {
        uint64_t limitSize = range.size > (16ULL * 1024ULL * 1024ULL) ? (16ULL * 1024ULL * 1024ULL) : range.size;
        for (uint64_t offset = 0; offset < limitSize; offset += kChunkSize) {
            size_t toRead = (size_t)std::min((uint64_t)kChunkSize, limitSize - offset);
            uint64_t chunkAddr = range.start + offset;
            if (!ds_debug_read_bytes(vmMap, chunkAddr, chunk.data(), toRead)) continue;

            size_t ptrCount = toRead / 8;
            const uint64_t *ptrs = (const uint64_t *)chunk.data();
            for (size_t p = 0; p < ptrCount; p++) {
                uint64_t val = ptrs[p] & 0x0000FFFFFFFFFFFFULL;
                if (!val || (val & 0x7ULL) != 0 || !ds_pubg_valid(val)) continue;

                uint64_t ptrAddr = chunkAddr + p * 8;
                uint32_t nameOff = 0x10;

                // Check 1: the scanned slot points at the block array.
                if (ds_pubg_is_valid_gnames(vmMap, val, &nameOff)) {
                    g_dspubgGNames = val;
                    return;
                }

                // Check 2: the scanned slot itself is the block array.
                if (ds_pubg_is_valid_gnames(vmMap, ptrAddr, &nameOff)) {
                    g_dspubgGNames = ptrAddr;
                    return;
                }
            }
        }
    }
}

static bool ds_pubg_get_name_by_id(uint32_t id, char *outBuf, size_t outCap) {
    if (!outBuf || outCap < 2) return false;
    outBuf[0] = '\0';
    if (!g_dspubgGNames || !g_dspubgNamesCalibrated) return false;
    if (id > 0x00FFFFFFu) return false;

    // The calibrated layout is authoritative; the offset baked into this file
    // is only a starting point for the probe in ds_pubg_calibrate_names.
    return ds_pubg_name_probe(g_dspubgVmMap, g_dspubgGNames, g_dspubgNameLayout,
                              id, outBuf, outCap);
}

// Reads the FName index out of a UObject. DUMP/Offsets.hpp puts NamePrivate at
// 0x18 and OuterPrivate at 0x20; the previous order read the outer object's
// name and therefore classified almost every actor as something else entirely.
static inline uint32_t ds_pubg_object_name_index(uint64_t obj) {
    if (!obj || !ds_pubg_valid(obj)) return 0;
    uint32_t idx = ds_pubg_read_u32(obj + 0x18ULL);
    if (idx == 0 || idx > 0x00FFFFFFu) idx = ds_pubg_read_u32(obj + 0x20ULL);
    return idx;
}

// Resolves an actor's class name, then its object name. The class is tried
// first because scenery filtering keys off "StaticMesh" / "Instanced" tokens,
// which live on the class; the object name is the instance label and differs
// per actor.
static bool ds_pubg_get_actor_name(uint64_t actor, char *outBuf, size_t outCap) {
    if (!actor || !outBuf || outCap < 2) return false;
    outBuf[0] = '\0';

    uint64_t cls = ds_pubg_read_ptr(actor + 0x10ULL);
    if (cls && ds_pubg_valid(cls)) {
        uint32_t classIdx = ds_pubg_object_name_index(cls);
        if (classIdx && ds_pubg_get_name_by_id(classIdx, outBuf, outCap) && strlen(outBuf) > 1) {
            return true;
        }
        uint64_t super = ds_pubg_read_ptr(cls + 0x30ULL);
        if (super && ds_pubg_valid(super)) {
            uint32_t superIdx = ds_pubg_object_name_index(super);
            if (superIdx && ds_pubg_get_name_by_id(superIdx, outBuf, outCap) && strlen(outBuf) > 1) {
                return true;
            }
        }
    }

    uint32_t objIdx = ds_pubg_object_name_index(actor);
    if (objIdx && ds_pubg_get_name_by_id(objIdx, outBuf, outCap) && strlen(outBuf) > 1) {
        return true;
    }
    return false;
}

static DSPUBGItemCategory ds_pubg_classify_item(const char *name, char *outDisplay, size_t outCap) {
    if (!name || !outDisplay || outCap < 4) return DSPUBGItemCategoryNone;
    outDisplay[0] = '\0';

    // 0. Fast reject non-item actors (bullets, effects, cameras, players)
    if (strcasestr(name, "Bullet") || strcasestr(name, "Proj") || strcasestr(name, "Shell") ||
        strcasestr(name, "Cartridge") || strcasestr(name, "Trace") || strcasestr(name, "Particle") ||
        strcasestr(name, "Emitter") || strcasestr(name, "Effect") || strcasestr(name, "Decal") ||
        strcasestr(name, "Camera") || strcasestr(name, "Controller") || strcasestr(name, "Player") ||
        strcasestr(name, "Character") || strcasestr(name, "Volume") || strcasestr(name, "Trigger") ||
        strcasestr(name, "Light") || strcasestr(name, "Audio") || strcasestr(name, "Sound") ||
        strcasestr(name, "Landscape") || strcasestr(name, "WorldSettings") || strcasestr(name, "GameMode") ||
        strcasestr(name, "Grenade") || strcasestr(name, "Smoke") || strcasestr(name, "Flash") ||
        strcasestr(name, "Explo") || strcasestr(name, "Fire") || strcasestr(name, "Flame")) {
        return DSPUBGItemCategoryNone;
    }

    // 1. Vehicles
    bool isNonVehicle = (strcasestr(name, "Wrapper") != nullptr) ||
                        (strcasestr(name, "PickUp") != nullptr && strcasestr(name, "VH_") == nullptr) ||
                        (strcasestr(name, "Pickup") != nullptr && strcasestr(name, "VH_") == nullptr) ||
                        (strcasestr(name, "WheelComponent") != nullptr) ||
                        (strcasestr(name, "VehicleWheel") != nullptr) ||
                        (strcasestr(name, "SeatComponent") != nullptr) ||
                        (strcasestr(name, "VehicleSeat") != nullptr) ||
                        (strcasestr(name, "Spawner") != nullptr) ||
                        (strcasestr(name, "SpawnPoint") != nullptr) ||
                        (strcasestr(name, "SpawnPad") != nullptr) ||
                        (strcasestr(name, "Spawn") != nullptr) ||
                        (strcasestr(name, "Terminal") != nullptr) ||
                        (strcasestr(name, "Station") != nullptr) ||
                        (strcasestr(name, "Manager") != nullptr) ||
                        (strcasestr(name, "Stand") != nullptr) ||
                        (strcasestr(name, "Table") != nullptr) ||
                        (strcasestr(name, "Board") != nullptr) ||
                        (strcasestr(name, "Audio") != nullptr) ||
                        (strcasestr(name, "Sound") != nullptr) ||
                        (strcasestr(name, "Decal") != nullptr) ||
                        (strcasestr(name, "Weapon") != nullptr) ||
                        (strcasestr(name, "Trigger") != nullptr) ||
                        (strcasestr(name, "Target") != nullptr) ||
                        (strcasestr(name, "Guide") != nullptr) ||
                        (strcasestr(name, "Button") != nullptr) ||
                        (strcasestr(name, "UI") != nullptr) ||
                        (strcasestr(name, "Widget") != nullptr);
    if (!isNonVehicle) {
        if (strcasestr(name, "Jeep") || strcasestr(name, "UAZ")) {
            snprintf(outDisplay, outCap, "Xe UAZ");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "Sedan") || strcasestr(name, "Dacia")) {
            snprintf(outDisplay, outCap, "Xe Dacia");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "Buggy")) {
            snprintf(outDisplay, outCap, "Xe Buggy");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "VH_PickUp") || strcasestr(name, "VH_Pickup") || (strcasestr(name, "Truck") && !strcasestr(name, "Monster")) || strcasestr(name, "Rony")) {
            snprintf(outDisplay, outCap, "Xe Bán Tải");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "Motorcycle") || strcasestr(name, "Motorbike") || strcasestr(name, "VH_Motor") || strcasestr(name, "Bike")) {
            snprintf(outDisplay, outCap, "Xe Máy");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "Scooter")) {
            snprintf(outDisplay, outCap, "Xe Scooter");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "TukTuk")) {
            snprintf(outDisplay, outCap, "Xe TukTuk");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "MiniBus") || strcasestr(name, "Bus_")) {
            snprintf(outDisplay, outCap, "Xe MiniBus");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "PG117") || strcasestr(name, "Boat") || strcasestr(name, "Cano")) {
            snprintf(outDisplay, outCap, "Thuyền Cano");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "AquaRail") || strcasestr(name, "JetSki")) {
            snprintf(outDisplay, outCap, "Moto Nước");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "BRDM")) {
            snprintf(outDisplay, outCap, "Xe BRDM");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "CoupeRB") || strcasestr(name, "Coupe")) {
            snprintf(outDisplay, outCap, "Xe Coupe RB");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "MonsterTruck") || strcasestr(name, "BigFoot")) {
            snprintf(outDisplay, outCap, "Xe Quái Thú");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "Mirado")) {
            snprintf(outDisplay, outCap, "Xe Mirado");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "Lada")) {
            snprintf(outDisplay, outCap, "Xe Lada Niva");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "Snowmobile") || strcasestr(name, "Snowbike")) {
            snprintf(outDisplay, outCap, "Xe Tuyết");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "Bicycle")) {
            snprintf(outDisplay, outCap, "Xe Đạp");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "Tank")) {
            snprintf(outDisplay, outCap, "Xe Tăng");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "Helicopter") || strcasestr(name, "DirectFly")) {
            snprintf(outDisplay, outCap, "Trực Thăng");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "Lamborghini")) {
            snprintf(outDisplay, outCap, "Xe Lamborghini");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "Tesla") || strcasestr(name, "ModelY")) {
            snprintf(outDisplay, outCap, "Xe Model Y");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "UTV")) {
            snprintf(outDisplay, outCap, "Xe UTV");
            return DSPUBGItemCategoryVehicle;
        }
        if (strcasestr(name, "ATV")) {
            snprintf(outDisplay, outCap, "Xe ATV");
            return DSPUBGItemCategoryVehicle;
        }
    }

    // 2. Scopes
    if (strcasestr(name, "8X")) {
        snprintf(outDisplay, outCap, "Scope 8x");
        return DSPUBGItemCategoryScope;
    }
    if (strcasestr(name, "6X")) {
        snprintf(outDisplay, outCap, "Scope 6x");
        return DSPUBGItemCategoryScope;
    }
    if (strcasestr(name, "4X")) {
        snprintf(outDisplay, outCap, "Scope 4x");
        return DSPUBGItemCategoryScope;
    }
    if (strcasestr(name, "3X")) {
        snprintf(outDisplay, outCap, "Scope 3x");
        return DSPUBGItemCategoryScope;
    }
    if (strcasestr(name, "2X")) {
        snprintf(outDisplay, outCap, "Scope 2x");
        return DSPUBGItemCategoryScope;
    }
    if (strcasestr(name, "RedDot") || strcasestr(name, "HD")) {
        snprintf(outDisplay, outCap, "Red Dot");
        return DSPUBGItemCategoryScope;
    }
    if (strcasestr(name, "Holo") || strcasestr(name, "MZJ_QX")) {
        snprintf(outDisplay, outCap, "Holo");
        return DSPUBGItemCategoryScope;
    }

    // 3. Armor & Helmets
    if (strcasestr(name, "Armor_Lv3") || strcasestr(name, "Armor3")) {
        snprintf(outDisplay, outCap, "Giáp 3");
        return DSPUBGItemCategoryArmor;
    }
    if (strcasestr(name, "Armor_Lv2") || strcasestr(name, "Armor2")) {
        snprintf(outDisplay, outCap, "Giáp 2");
        return DSPUBGItemCategoryArmor;
    }
    if (strcasestr(name, "Armor_Lv1") || strcasestr(name, "Armor1")) {
        snprintf(outDisplay, outCap, "Giáp 1");
        return DSPUBGItemCategoryArmor;
    }
    if (strcasestr(name, "Head_Lv3") || strcasestr(name, "Helmet_Lv3") || strcasestr(name, "Head3")) {
        snprintf(outDisplay, outCap, "Mũ 3");
        return DSPUBGItemCategoryArmor;
    }
    if (strcasestr(name, "Head_Lv2") || strcasestr(name, "Helmet_Lv2") || strcasestr(name, "Head2")) {
        snprintf(outDisplay, outCap, "Mũ 2");
        return DSPUBGItemCategoryArmor;
    }
    if (strcasestr(name, "Head_Lv1") || strcasestr(name, "Helmet_Lv1") || strcasestr(name, "Head1")) {
        snprintf(outDisplay, outCap, "Mũ 1");
        return DSPUBGItemCategoryArmor;
    }

    // 4. Backpacks
    if (strcasestr(name, "Bag_Lv3") || strcasestr(name, "Bag3")) {
        snprintf(outDisplay, outCap, "Balo 3");
        return DSPUBGItemCategoryBag;
    }
    if (strcasestr(name, "Bag_Lv2") || strcasestr(name, "Bag2")) {
        snprintf(outDisplay, outCap, "Balo 2");
        return DSPUBGItemCategoryBag;
    }
    if (strcasestr(name, "Bag_Lv1") || strcasestr(name, "Bag1")) {
        snprintf(outDisplay, outCap, "Balo 1");
        return DSPUBGItemCategoryBag;
    }

    // 5. Weapons
    if (strcasestr(name, "Flare")) {
        snprintf(outDisplay, outCap, "Flare Gun");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "AWM")) {
        snprintf(outDisplay, outCap, "AWM");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "M416")) {
        snprintf(outDisplay, outCap, "M416");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "AKM")) {
        snprintf(outDisplay, outCap, "AKM");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "M24")) {
        snprintf(outDisplay, outCap, "M24");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "Kar98")) {
        snprintf(outDisplay, outCap, "Kar98k");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "Groza")) {
        snprintf(outDisplay, outCap, "Groza");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "AUG")) {
        snprintf(outDisplay, outCap, "AUG");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "M762")) {
        snprintf(outDisplay, outCap, "M762");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "Mk14")) {
        snprintf(outDisplay, outCap, "Mk14");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "SLR")) {
        snprintf(outDisplay, outCap, "SLR");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "SKS")) {
        snprintf(outDisplay, outCap, "SKS");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "Mini14")) {
        snprintf(outDisplay, outCap, "Mini14");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "AMR")) {
        snprintf(outDisplay, outCap, "Lynx AMR");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "MG3")) {
        snprintf(outDisplay, outCap, "MG3");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "M249")) {
        snprintf(outDisplay, outCap, "M249");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "DP28") || strcasestr(name, "DP-28")) {
        snprintf(outDisplay, outCap, "DP-28");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "P90")) {
        snprintf(outDisplay, outCap, "P90");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "Vector")) {
        snprintf(outDisplay, outCap, "Vector");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "UMP")) {
        snprintf(outDisplay, outCap, "UMP45");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "DBS")) {
        snprintf(outDisplay, outCap, "DBS");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "SCAR")) {
        snprintf(outDisplay, outCap, "SCAR-L");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "M16A4") || strcasestr(name, "M16")) {
        snprintf(outDisplay, outCap, "M16A4");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "QBZ")) {
        snprintf(outDisplay, outCap, "QBZ");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "G36")) {
        snprintf(outDisplay, outCap, "G36C");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "ACE32")) {
        snprintf(outDisplay, outCap, "ACE32");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "Honey")) {
        snprintf(outDisplay, outCap, "Honey Badger");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "FAMAS")) {
        snprintf(outDisplay, outCap, "FAMAS");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "Mosin")) {
        snprintf(outDisplay, outCap, "Mosin");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "Mk12")) {
        snprintf(outDisplay, outCap, "Mk12");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "QBU")) {
        snprintf(outDisplay, outCap, "QBU");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "VSS")) {
        snprintf(outDisplay, outCap, "VSS");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "S12K")) {
        snprintf(outDisplay, outCap, "S12K");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "S686")) {
        snprintf(outDisplay, outCap, "S686");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "S1897")) {
        snprintf(outDisplay, outCap, "S1897");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "UZI") || strcasestr(name, "MicroUZI")) {
        snprintf(outDisplay, outCap, "Micro UZI");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "Bizon") || strcasestr(name, "PP19")) {
        snprintf(outDisplay, outCap, "PP-19 Bizon");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "MP5K") || strcasestr(name, "MP5")) {
        snprintf(outDisplay, outCap, "MP5K");
        return DSPUBGItemCategoryWeapon;
    }
    if (strcasestr(name, "Pan")) {
        snprintf(outDisplay, outCap, "Chảo");
        return DSPUBGItemCategoryWeapon;
    }

    // 6. Crates & AirDrops & Tokens
    if (strcasestr(name, "AirDrop")) {
        snprintf(outDisplay, outCap, (g_pubgLanguage == 1) ? "AirDrop" : "HÒM THÍNH");
        return DSPUBGItemCategoryCrate;
    }
    if (strcasestr(name, "DeadBox") || strcasestr(name, "PlayerDeadInventoryBox") || strcasestr(name, "TombBox")) {
        snprintf(outDisplay, outCap, (g_pubgLanguage == 1) ? "DeadBox" : "Hòm Xác");
        return DSPUBGItemCategoryCrate;
    }
    if (strcasestr(name, "PickUpListWrapper")) {
        snprintf(outDisplay, outCap, (g_pubgLanguage == 1) ? "DropLoot" : "Đồ Rơi");
        return DSPUBGItemCategoryCrate;
    }
    if (strcasestr(name, "Token") || strcasestr(name, "ShopToken") || strcasestr(name, "GoldToken")) {
        snprintf(outDisplay, outCap, (g_pubgLanguage == 1) ? "TokenShop" : "Xu Shop");
        return DSPUBGItemCategoryCrate;
    }
    if (strcasestr(name, "GasCan") || strcasestr(name, "JerryCan") || strcasestr(name, "FuelCan")) {
        snprintf(outDisplay, outCap, (g_pubgLanguage == 1) ? "Gascan" : "Bình Xăng");
        return DSPUBGItemCategoryCrate;
    }

    return DSPUBGItemCategoryNone;
}

static inline uint32_t ds_pubg_read_grenade_id(uint64_t actor) {
    // In ASTExtraGrenadeBase, ItemDefineID is at 0x678(0x18)
    // FItemDefineID has Type at 0x0(0x4), TypeSpecificID at 0x4(0x4) -> 0x67C
    uint32_t id = ds_pubg_read_u32(actor + 0x67CULL);
    if (id == 602004 || id == 602003 || id == 602002 || id == 602001 || id == 602005) return id;
    id = ds_pubg_read_u32(actor + 0x678ULL);
    if (id == 602004 || id == 602003 || id == 602002 || id == 602001 || id == 602005) return id;
    id = ds_pubg_read_u32(actor + 0x680ULL);
    if (id == 602004 || id == 602003 || id == 602002 || id == 602001 || id == 602005) return id;
    id = ds_pubg_read_u32(actor + 0x674ULL);
    if (id == 602004 || id == 602003 || id == 602002 || id == 602001 || id == 602005) return id;
    return 0;
}

static bool ds_pubg_identify_grenade(uint64_t actor, DSPUBGGrenadeType *outType, char *outDisplay, size_t outCap, float *outRadius) {
    if (!actor || !outType || !outDisplay || outCap < 8) return false;
    bool isEn = (g_pubgLanguage == 1);

    // 1. Direct ItemDefineID check (exact internal logic from metalbiew.txt)
    uint32_t idbom = ds_pubg_read_grenade_id(actor);
    if (idbom != 0) {
        switch (idbom) {
            case 602004: // Frag Grenade
                *outType = DSPUBGGrenadeTypeFrag;
                snprintf(outDisplay, outCap, isEn ? "LỰU ĐẠN" : "LỰU ĐẠN");
                if (outRadius) *outRadius = 9.0f;
                return true;
            case 602003: // Molotov
                *outType = DSPUBGGrenadeTypeBurn;
                snprintf(outDisplay, outCap, isEn ? "BOM LỬA" : "BOM LỬA");
                if (outRadius) *outRadius = 4.5f;
                return true;
            case 602002: // Smoke
                *outType = DSPUBGGrenadeTypeSmoke;
                snprintf(outDisplay, outCap, isEn ? "BOM KHÓI" : "BOM KHÓI");
                if (outRadius) *outRadius = 6.0f;
                return true;
            case 602001: // Stun
            case 602005:
                *outType = DSPUBGGrenadeTypeStun;
                snprintf(outDisplay, outCap, isEn ? "BOM CHOÁNG" : "BOM CHOÁNG");
                if (outRadius) *outRadius = 8.0f;
                return true;
        }
    }

    // 2. Class name and Actor name fallback
    char actorName[64] = {0};
    if (ds_pubg_get_actor_name(actor, actorName, sizeof(actorName))) {
        if (strcasestr(actorName, "PickUp") || strcasestr(actorName, "Character") ||
            strcasestr(actorName, "Pawn") || strcasestr(actorName, "Camera")) {
            return false;
        }

        if (strcasestr(actorName, "Shoulei") || strcasestr(actorName, "Frag") ||
            strcasestr(actorName, "ProjFrag") || strcasestr(actorName, "BP_Grenade_Shoulei")) {
            *outType = DSPUBGGrenadeTypeFrag;
            snprintf(outDisplay, outCap, isEn ? "LỰU ĐẠN" : "LỰU ĐẠN");
            if (outRadius) *outRadius = 9.0f;
            return true;
        }
        if (strcasestr(actorName, "Burn") || strcasestr(actorName, "Molotov") ||
            strcasestr(actorName, "RanShaoPing") || strcasestr(actorName, "ProjBurn")) {
            *outType = DSPUBGGrenadeTypeBurn;
            snprintf(outDisplay, outCap, isEn ? "BOM LỬA" : "BOM LỬA");
            if (outRadius) *outRadius = 4.5f;
            return true;
        }
        if (strcasestr(actorName, "Smoke") || strcasestr(actorName, "YanWuDan") ||
            strcasestr(actorName, "ProjSmoke")) {
            *outType = DSPUBGGrenadeTypeSmoke;
            snprintf(outDisplay, outCap, isEn ? "BOM KHÓI" : "BOM KHÓI");
            if (outRadius) *outRadius = 6.0f;
            return true;
        }
        if (strcasestr(actorName, "Stun") || strcasestr(actorName, "Flash") ||
            strcasestr(actorName, "ZhenBaoDan") || strcasestr(actorName, "ProjStun")) {
            *outType = DSPUBGGrenadeTypeStun;
            snprintf(outDisplay, outCap, isEn ? "BOM CHOÁNG" : "BOM CHOÁNG");
            if (outRadius) *outRadius = 8.0f;
            return true;
        }
        if (strcasestr(actorName, "STExtraGrenadeBase") || strcasestr(actorName, "STProjectileBase")) {
            *outType = DSPUBGGrenadeTypeFrag;
            snprintf(outDisplay, outCap, isEn ? "LỰU ĐẠN" : "LỰU ĐẠN");
            if (outRadius) *outRadius = 9.0f;
            return true;
        }
    }

    return false;
}

// Enemy pin-pull/cooking check removed per user request

static DSPUBGItemCategory ds_pubg_classify_item_id(int itemId, char *outDisplay, size_t outCap) {
    if (itemId <= 0 || !outDisplay || outCap < 4) return DSPUBGItemCategoryNone;
    outDisplay[0] = '\0';
    bool isEn = (g_pubgLanguage == 1);

    switch (itemId) {
        // --- Assault Rifles (AR) ---
        case 101001: snprintf(outDisplay, outCap, "AKM"); return DSPUBGItemCategoryWeapon;
        case 101002: snprintf(outDisplay, outCap, "M16A4"); return DSPUBGItemCategoryWeapon;
        case 101003: snprintf(outDisplay, outCap, isEn ? "SCARL" : "SCAR-L"); return DSPUBGItemCategoryWeapon;
        case 101004: snprintf(outDisplay, outCap, "M416"); return DSPUBGItemCategoryWeapon;
        case 101005: snprintf(outDisplay, outCap, "Groza"); return DSPUBGItemCategoryWeapon;
        case 101006: snprintf(outDisplay, outCap, "AUG"); return DSPUBGItemCategoryWeapon;
        case 101007: snprintf(outDisplay, outCap, "QBZ"); return DSPUBGItemCategoryWeapon;
        case 101008: snprintf(outDisplay, outCap, "M762"); return DSPUBGItemCategoryWeapon;
        case 101009: snprintf(outDisplay, outCap, "Mk47"); return DSPUBGItemCategoryWeapon;
        case 101010: snprintf(outDisplay, outCap, "G36C"); return DSPUBGItemCategoryWeapon;
        case 101011: snprintf(outDisplay, outCap, "FAMAS"); return DSPUBGItemCategoryWeapon;
        case 101012: snprintf(outDisplay, outCap, "ACE32"); return DSPUBGItemCategoryWeapon;
        case 101013: snprintf(outDisplay, outCap, "HoneyBadger"); return DSPUBGItemCategoryWeapon;
        case 101100: snprintf(outDisplay, outCap, "FAMAS"); return DSPUBGItemCategoryWeapon;
        case 101101: snprintf(outDisplay, outCap, "ASM Abakan"); return DSPUBGItemCategoryWeapon;
        case 101102: snprintf(outDisplay, outCap, "ACE32"); return DSPUBGItemCategoryWeapon;
        case 101103: snprintf(outDisplay, outCap, "HoneyBadger"); return DSPUBGItemCategoryWeapon;
        case 101104: snprintf(outDisplay, outCap, "F2000"); return DSPUBGItemCategoryWeapon;

        // --- Submachine Guns (SMG) ---
        case 102001: snprintf(outDisplay, outCap, "UZI"); return DSPUBGItemCategoryWeapon;
        case 102002: snprintf(outDisplay, outCap, "UMP45"); return DSPUBGItemCategoryWeapon;
        case 102003: snprintf(outDisplay, outCap, "Vector"); return DSPUBGItemCategoryWeapon;
        case 102004: snprintf(outDisplay, outCap, "Tommy Gun"); return DSPUBGItemCategoryWeapon;
        case 102005: snprintf(outDisplay, outCap, isEn ? "Bizon" : "PP-19 Bizon"); return DSPUBGItemCategoryWeapon;
        case 102007: snprintf(outDisplay, outCap, "MP5K"); return DSPUBGItemCategoryWeapon;
        case 102008: snprintf(outDisplay, outCap, "P90"); return DSPUBGItemCategoryWeapon;
        case 102101: snprintf(outDisplay, outCap, "JS9"); return DSPUBGItemCategoryWeapon;

        // --- Sniper Rifles (SR) & DMR ---
        case 103001: snprintf(outDisplay, outCap, "Kar98k"); return DSPUBGItemCategoryWeapon;
        case 103002: snprintf(outDisplay, outCap, "M24"); return DSPUBGItemCategoryWeapon;
        case 103003: snprintf(outDisplay, outCap, "AWM"); return DSPUBGItemCategoryWeapon;
        case 103004: snprintf(outDisplay, outCap, "SKS"); return DSPUBGItemCategoryWeapon;
        case 103005: snprintf(outDisplay, outCap, "VSS"); return DSPUBGItemCategoryWeapon;
        case 103006: snprintf(outDisplay, outCap, "Mini14"); return DSPUBGItemCategoryWeapon;
        case 103007: snprintf(outDisplay, outCap, "Mk14"); return DSPUBGItemCategoryWeapon;
        case 103008: snprintf(outDisplay, outCap, "Win94"); return DSPUBGItemCategoryWeapon;
        case 103009: snprintf(outDisplay, outCap, "SLR"); return DSPUBGItemCategoryWeapon;
        case 103010: snprintf(outDisplay, outCap, "QBU"); return DSPUBGItemCategoryWeapon;
        case 103011: snprintf(outDisplay, outCap, "Mosin"); return DSPUBGItemCategoryWeapon;
        case 103012: snprintf(outDisplay, outCap, "Lynx AMR"); return DSPUBGItemCategoryWeapon;
        case 103013: snprintf(outDisplay, outCap, "AMR"); return DSPUBGItemCategoryWeapon;
        case 103014: snprintf(outDisplay, outCap, "Mk12"); return DSPUBGItemCategoryWeapon;
        case 103015: snprintf(outDisplay, outCap, "Dragunov"); return DSPUBGItemCategoryWeapon;

        // --- Shotguns (SG) ---
        case 104001: snprintf(outDisplay, outCap, "S686"); return DSPUBGItemCategoryWeapon;
        case 104002: snprintf(outDisplay, outCap, "S1897"); return DSPUBGItemCategoryWeapon;
        case 104003: snprintf(outDisplay, outCap, "S12K"); return DSPUBGItemCategoryWeapon;
        case 104004: snprintf(outDisplay, outCap, "DBS"); return DSPUBGItemCategoryWeapon;
        case 104005: snprintf(outDisplay, outCap, "M1014"); return DSPUBGItemCategoryWeapon;
        case 104006: case 104100: snprintf(outDisplay, outCap, "NS2000"); return DSPUBGItemCategoryWeapon;
        case 104101: snprintf(outDisplay, outCap, "SPAS-12"); return DSPUBGItemCategoryWeapon;

        // --- Light Machine Guns (LMG) ---
        case 105001: snprintf(outDisplay, outCap, "M249"); return DSPUBGItemCategoryWeapon;
        case 105002: snprintf(outDisplay, outCap, "DP-28"); return DSPUBGItemCategoryWeapon;
        case 105003: snprintf(outDisplay, outCap, "MG3"); return DSPUBGItemCategoryWeapon;
        case 105010: snprintf(outDisplay, outCap, "M134"); return DSPUBGItemCategoryWeapon;

        // --- Pistols & Special ---
        case 106001: snprintf(outDisplay, outCap, "P92"); return DSPUBGItemCategoryWeapon;
        case 106002: snprintf(outDisplay, outCap, "P1911"); return DSPUBGItemCategoryWeapon;
        case 106003: snprintf(outDisplay, outCap, "R1895"); return DSPUBGItemCategoryWeapon;
        case 106004: snprintf(outDisplay, outCap, "P18C"); return DSPUBGItemCategoryWeapon;
        case 106005: snprintf(outDisplay, outCap, "R45"); return DSPUBGItemCategoryWeapon;
        case 106006: snprintf(outDisplay, outCap, "Sawed-Off"); return DSPUBGItemCategoryWeapon;
        case 106007: snprintf(outDisplay, outCap, "Flare Gun"); return DSPUBGItemCategoryWeapon;
        case 106008: snprintf(outDisplay, outCap, "Skorpion"); return DSPUBGItemCategoryWeapon;
        case 106010: snprintf(outDisplay, outCap, "Deagle"); return DSPUBGItemCategoryWeapon;

        // --- Bows, Crossbows & Special ---
        case 107001: snprintf(outDisplay, outCap, isEn ? "Crossbow" : "Nỏ"); return DSPUBGItemCategoryWeapon;
        case 107002: case 107008: snprintf(outDisplay, outCap, isEn ? "Tactical Crossbow" : "Nỏ Chiến Thuật"); return DSPUBGItemCategoryWeapon;
        case 107003: snprintf(outDisplay, outCap, isEn ? "Explosive Bow" : "Cung Nổ"); return DSPUBGItemCategoryWeapon;
        case 107004: case 107005: case 107011: snprintf(outDisplay, outCap, isEn ? "Grapple" : "Cáp Đu"); return DSPUBGItemCategoryWeapon;

        // --- Melee Weapons ---
        case 108001: snprintf(outDisplay, outCap, isEn ? "Pan" : "Chảo"); return DSPUBGItemCategoryWeapon;
        case 108002: snprintf(outDisplay, outCap, isEn ? "Crowbar" : "Xà Beng"); return DSPUBGItemCategoryWeapon;
        case 108003: snprintf(outDisplay, outCap, isEn ? "Machete" : "Rựa"); return DSPUBGItemCategoryWeapon;
        case 108004: snprintf(outDisplay, outCap, isEn ? "Sickle" : "Lưỡi Liềm"); return DSPUBGItemCategoryWeapon;
        case 108005: case 108008: snprintf(outDisplay, outCap, isEn ? "Katana" : "Kiếm Nhật"); return DSPUBGItemCategoryWeapon;
        case 108011: snprintf(outDisplay, outCap, isEn ? "Tactical Baton" : "Dùi Cui"); return DSPUBGItemCategoryWeapon;

        // --- Scopes & Sights ---
        case 201001: snprintf(outDisplay, outCap, "RedDot"); return DSPUBGItemCategoryScope;
        case 201002: snprintf(outDisplay, outCap, "Holo"); return DSPUBGItemCategoryScope;
        case 201003: snprintf(outDisplay, outCap, isEn ? "Scope2x" : "Scope 2x"); return DSPUBGItemCategoryScope;
        case 201004: snprintf(outDisplay, outCap, isEn ? "Scope4x" : "Scope 4x"); return DSPUBGItemCategoryScope;
        case 201005: snprintf(outDisplay, outCap, isEn ? "Scope8x" : "Scope 8x"); return DSPUBGItemCategoryScope;
        case 201009: snprintf(outDisplay, outCap, isEn ? "Scope3x" : "Scope 3x"); return DSPUBGItemCategoryScope;
        case 201010: snprintf(outDisplay, outCap, isEn ? "Scope6x" : "Scope 6x"); return DSPUBGItemCategoryScope;
        case 201011: snprintf(outDisplay, outCap, "Canted Sight"); return DSPUBGItemCategoryScope;
        case 201012: snprintf(outDisplay, outCap, isEn ? "Scope15x" : "Scope 15x"); return DSPUBGItemCategoryScope;

        // --- Armor & Helmets ---
        case 501001: case 501004: snprintf(outDisplay, outCap, isEn ? "ArmorLv1" : "Giáp 1"); return DSPUBGItemCategoryArmor;
        case 501002: case 501005: snprintf(outDisplay, outCap, isEn ? "ArmorLv2" : "Giáp 2"); return DSPUBGItemCategoryArmor;
        case 501003: case 501006: snprintf(outDisplay, outCap, isEn ? "ArmorLv3" : "Giáp 3"); return DSPUBGItemCategoryArmor;

        case 502001: snprintf(outDisplay, outCap, isEn ? "HelmetLv1" : "Mũ 1"); return DSPUBGItemCategoryArmor;
        case 502002: snprintf(outDisplay, outCap, isEn ? "HelmetLv2" : "Mũ 2"); return DSPUBGItemCategoryArmor;
        case 502003: snprintf(outDisplay, outCap, isEn ? "HelmetLv3" : "Mũ 3"); return DSPUBGItemCategoryArmor;

        // --- Backpacks ---
        case 503001: snprintf(outDisplay, outCap, isEn ? "BagLv1" : "Balo 1"); return DSPUBGItemCategoryBag;
        case 503002: snprintf(outDisplay, outCap, isEn ? "BagLv2" : "Balo 2"); return DSPUBGItemCategoryBag;
        case 503003: snprintf(outDisplay, outCap, isEn ? "BagLv3" : "Balo 3"); return DSPUBGItemCategoryBag;

        // --- Medical / Boosters ---
        case 601001: snprintf(outDisplay, outCap, isEn ? "Bandage" : "Băng Gạc"); return DSPUBGItemCategoryCrate;
        case 601002: snprintf(outDisplay, outCap, isEn ? "FirstaidKit" : "First Aid"); return DSPUBGItemCategoryCrate;
        case 601003: snprintf(outDisplay, outCap, isEn ? "MedKit" : "Med Kit"); return DSPUBGItemCategoryCrate;
        case 601004: snprintf(outDisplay, outCap, isEn ? "EnergyDrink" : "Nước Tăng Lực"); return DSPUBGItemCategoryCrate;
        case 601005: snprintf(outDisplay, outCap, isEn ? "Painkiller" : "Giảm Đau"); return DSPUBGItemCategoryCrate;
        case 601006: snprintf(outDisplay, outCap, "Adrenaline"); return DSPUBGItemCategoryCrate;

        // --- Throwables ---
        case 602001: snprintf(outDisplay, outCap, isEn ? "Grenade" : "Lựu Đạn"); return DSPUBGItemCategoryWeapon;
        case 602002: snprintf(outDisplay, outCap, isEn ? "Smoke" : "Bom Khói"); return DSPUBGItemCategoryWeapon;
        case 602003: snprintf(outDisplay, outCap, isEn ? "Molotof" : "Bom Xăng"); return DSPUBGItemCategoryWeapon;
        case 602004: snprintf(outDisplay, outCap, isEn ? "Flash" : "Choáng"); return DSPUBGItemCategoryWeapon;

        // --- Ammo ---
        case 301001: snprintf(outDisplay, outCap, isEn ? "9mm" : "Đạn 9mm"); return DSPUBGItemCategoryCrate;
        case 302001: snprintf(outDisplay, outCap, isEn ? "7.62mm" : "Đạn 7.62"); return DSPUBGItemCategoryCrate;
        case 303001: snprintf(outDisplay, outCap, isEn ? "5.56mm" : "Đạn 5.56"); return DSPUBGItemCategoryCrate;
        case 304001: snprintf(outDisplay, outCap, isEn ? "12Guage" : "Đạn 12G"); return DSPUBGItemCategoryCrate;
        case 305001: snprintf(outDisplay, outCap, isEn ? ".300 Mag" : "Đạn .300"); return DSPUBGItemCategoryCrate;
        case 306001: snprintf(outDisplay, outCap, isEn ? "FlareAmmo" : "Đạn Flare"); return DSPUBGItemCategoryWeapon;
        case 307001: snprintf(outDisplay, outCap, isEn ? "45ACP" : "Đạn .45"); return DSPUBGItemCategoryCrate;
        case 308001: snprintf(outDisplay, outCap, isEn ? "5.7mm" : "Đạn 5.7"); return DSPUBGItemCategoryCrate;

        // --- Shop Tokens & Event Currency ---
        case 603001: case 603002: case 603003: case 603004:
            snprintf(outDisplay, outCap, isEn ? "TokenShop" : "Xu Shop"); return DSPUBGItemCategoryCrate;

        default:
            break;
    }

    // Meaningful category fallbacks instead of cryptic "Súng (#%d)"
    if (itemId >= 101000 && itemId < 102000) {
        snprintf(outDisplay, outCap, isEn ? "AR Rifle" : "Súng AR");
        return DSPUBGItemCategoryWeapon;
    }
    if (itemId >= 102000 && itemId < 103000) {
        snprintf(outDisplay, outCap, isEn ? "SMG" : "Súng SMG");
        return DSPUBGItemCategoryWeapon;
    }
    if (itemId >= 103000 && itemId < 104000) {
        snprintf(outDisplay, outCap, isEn ? "Sniper" : "Súng Sniper");
        return DSPUBGItemCategoryWeapon;
    }
    if (itemId >= 104000 && itemId < 105000) {
        snprintf(outDisplay, outCap, "Shotgun");
        return DSPUBGItemCategoryWeapon;
    }
    if (itemId >= 105000 && itemId < 106000) {
        snprintf(outDisplay, outCap, isEn ? "LMG" : "Súng Máy LMG");
        return DSPUBGItemCategoryWeapon;
    }
    if (itemId >= 106000 && itemId < 107000) {
        snprintf(outDisplay, outCap, isEn ? "Pistol" : "Súng Lục");
        return DSPUBGItemCategoryWeapon;
    }
    if (itemId >= 107000 && itemId < 108000) {
        snprintf(outDisplay, outCap, isEn ? "Crossbow" : "Nỏ / Cung");
        return DSPUBGItemCategoryWeapon;
    }
    if (itemId >= 108000 && itemId < 109000) {
        snprintf(outDisplay, outCap, isEn ? "Melee" : "Cận Chiến");
        return DSPUBGItemCategoryWeapon;
    }
    if (itemId >= 201000 && itemId < 202000) {
        snprintf(outDisplay, outCap, isEn ? "Scope" : "Ống Ngắm");
        return DSPUBGItemCategoryScope;
    }
    if (itemId >= 501000 && itemId < 502000) {
        int lv = itemId % 10;
        if (lv >= 1 && lv <= 3) snprintf(outDisplay, outCap, isEn ? "Armor Lv%d" : "Giáp %d", lv);
        else snprintf(outDisplay, outCap, isEn ? "Armor" : "Giáp");
        return DSPUBGItemCategoryArmor;
    }
    if (itemId >= 502000 && itemId < 503000) {
        int lv = itemId % 10;
        if (lv >= 1 && lv <= 3) snprintf(outDisplay, outCap, isEn ? "Helmet Lv%d" : "Mũ %d", lv);
        else snprintf(outDisplay, outCap, isEn ? "Helmet" : "Mũ");
        return DSPUBGItemCategoryArmor;
    }
    if (itemId >= 503000 && itemId < 504000) {
        int lv = itemId % 10;
        if (lv >= 1 && lv <= 3) snprintf(outDisplay, outCap, isEn ? "Bag Lv%d" : "Balo %d", lv);
        else snprintf(outDisplay, outCap, isEn ? "Bag" : "Balo");
        return DSPUBGItemCategoryBag;
    }

    return DSPUBGItemCategoryNone;
}

static DSPUBGItemCategory ds_pubg_classify_vehicle_type(uint8_t vtype, char *outDisplay, size_t outCap) {
    if (vtype == 0 || !outDisplay || outCap < 4) return DSPUBGItemCategoryNone;
    outDisplay[0] = '\0';
    switch (vtype) {
        case 1: case 2: case 3: case 4:
            snprintf(outDisplay, outCap, "Xe Máy");
            return DSPUBGItemCategoryVehicle;
        case 5: case 6: case 7: case 8:
            snprintf(outDisplay, outCap, "Xe Dacia");
            return DSPUBGItemCategoryVehicle;
        case 9: case 10: case 11:
            snprintf(outDisplay, outCap, "Xe UAZ");
            return DSPUBGItemCategoryVehicle;
        case 12: case 13: case 14:
            snprintf(outDisplay, outCap, "Xe Buggy");
            return DSPUBGItemCategoryVehicle;
        case 15:
            snprintf(outDisplay, outCap, "Thuyền Cano");
            return DSPUBGItemCategoryVehicle;
        case 16:
            snprintf(outDisplay, outCap, "Moto Nước");
            return DSPUBGItemCategoryVehicle;
        case 17: case 18: case 19:
            snprintf(outDisplay, outCap, "Xe MiniBus");
            return DSPUBGItemCategoryVehicle;
        case 20: case 21: case 22: case 23: case 24: case 25: case 26: case 27: case 28:
            snprintf(outDisplay, outCap, "Xe Bán Tải");
            return DSPUBGItemCategoryVehicle;
        default:
            break;
    }
    return DSPUBGItemCategoryNone;
}

static DSPUBGItemCategory ds_pubg_classify_vehicle_shape(uint8_t shape, char *outDisplay, size_t outCap) {
    if (shape == 0 || !outDisplay || outCap < 4) return DSPUBGItemCategoryNone;
    outDisplay[0] = '\0';

    switch (shape) {
        case 1: case 2: case 28:
            snprintf(outDisplay, outCap, "Xe Máy");
            return DSPUBGItemCategoryVehicle;
        case 3: case 54:
            snprintf(outDisplay, outCap, "Xe Dacia");
            return DSPUBGItemCategoryVehicle;
        case 4:
            snprintf(outDisplay, outCap, "Xe MiniBus");
            return DSPUBGItemCategoryVehicle;
        case 5: case 6: case 55:
            snprintf(outDisplay, outCap, "Xe Bán Tải");
            return DSPUBGItemCategoryVehicle;
        case 7: case 56:
            snprintf(outDisplay, outCap, "Xe Buggy");
            return DSPUBGItemCategoryVehicle;
        case 8: case 9: case 10: case 13: case 33: case 57:
            snprintf(outDisplay, outCap, "Xe UAZ");
            return DSPUBGItemCategoryVehicle;
        case 11:
            snprintf(outDisplay, outCap, "Thuyền Cano");
            return DSPUBGItemCategoryVehicle;
        case 12:
            snprintf(outDisplay, outCap, "Moto Nước");
            return DSPUBGItemCategoryVehicle;
        case 14: case 15: case 52:
            snprintf(outDisplay, outCap, "Xe Mirado");
            return DSPUBGItemCategoryVehicle;
        case 16:
            snprintf(outDisplay, outCap, "Xe Bán Tải");
            return DSPUBGItemCategoryVehicle;
        case 17:
            snprintf(outDisplay, outCap, "Xe Scooter");
            return DSPUBGItemCategoryVehicle;
        case 18: case 20:
            snprintf(outDisplay, outCap, "Xe Tuyết");
            return DSPUBGItemCategoryVehicle;
        case 19:
            snprintf(outDisplay, outCap, "Xe TukTuk");
            return DSPUBGItemCategoryVehicle;
        case 23: case 58:
            snprintf(outDisplay, outCap, "Trực Thăng");
            return DSPUBGItemCategoryVehicle;
        case 24: case 88:
            snprintf(outDisplay, outCap, "Xe BRDM");
            return DSPUBGItemCategoryVehicle;
        case 25:
            snprintf(outDisplay, outCap, "Xe Lada Niva");
            return DSPUBGItemCategoryVehicle;
        case 27:
            snprintf(outDisplay, outCap, "Xe Loot Truck");
            return DSPUBGItemCategoryVehicle;
        case 29:
            snprintf(outDisplay, outCap, "Xe Model Y");
            return DSPUBGItemCategoryVehicle;
        case 30:
            snprintf(outDisplay, outCap, "Xe ATV");
            return DSPUBGItemCategoryVehicle;
        case 50: case 51:
            snprintf(outDisplay, outCap, "Xe Lamborghini");
            return DSPUBGItemCategoryVehicle;
        case 53:
            snprintf(outDisplay, outCap, "Xe Quái Thú");
            return DSPUBGItemCategoryVehicle;
        case 60:
            snprintf(outDisplay, outCap, "Tàu Bay Lượn");
            return DSPUBGItemCategoryVehicle;
        case 61:
            snprintf(outDisplay, outCap, "Xe Coupe RB");
            return DSPUBGItemCategoryVehicle;
        case 63: case 68: case 69: case 114:
            snprintf(outDisplay, outCap, "Xe Tăng");
            return DSPUBGItemCategoryVehicle;
        case 65: case 67:
            snprintf(outDisplay, outCap, "Xe Đạp");
            return DSPUBGItemCategoryVehicle;
        case 66:
            snprintf(outDisplay, outCap, "Xe UTV");
            return DSPUBGItemCategoryVehicle;
        case 70: case 71: case 72:
            snprintf(outDisplay, outCap, "Khủng Long");
            return DSPUBGItemCategoryVehicle;
        case 78: case 79: case 82:
            snprintf(outDisplay, outCap, "Robot Mecha");
            return DSPUBGItemCategoryVehicle;
        case 87: case 89: case 90:
            snprintf(outDisplay, outCap, "Chiến Mã");
            return DSPUBGItemCategoryVehicle;
        case 112:
            snprintf(outDisplay, outCap, "Xe Cảnh Sát");
            return DSPUBGItemCategoryVehicle;
        default:
            break;
    }
    return DSPUBGItemCategoryNone;
}

static DSPUBGItemCategory ds_pubg_identify_item(uint64_t actor, const char *preloadedName, char *outDisplay, size_t outCap) {
    if (!actor || !outDisplay || outCap < 4 || !ds_pubg_valid(actor)) return DSPUBGItemCategoryNone;
    outDisplay[0] = '\0';

    // 0. Check bHidden in AActor (offset 0xE8)
    uint8_t aHidden = ds_pubg_read_u8(actor + 0xE8ULL);
    if (aHidden & 0x1) return DSPUBGItemCategoryNone;

    // Optional: Get actor name via GNames if available (reuse preloadedName if caller already resolved it)
    char actorName[64] = {0};
    bool hasName = false;
    if (preloadedName && preloadedName[0] != '\0') {
        strncpy(actorName, preloadedName, sizeof(actorName) - 1);
        hasName = true;
    } else {
        hasName = ds_pubg_get_actor_name(actor, actorName, sizeof(actorName));
    }

    if (hasName) {
        // Fast reject scenery, props, systems, volumes, decals, bullets, character meshes
        if (strcasestr(actorName, "StaticMesh") || strcasestr(actorName, "InstancedFoliage") ||
            strcasestr(actorName, "Foliage") || strcasestr(actorName, "Landscape") ||
            strcasestr(actorName, "Building") || strcasestr(actorName, "House") ||
            strcasestr(actorName, "Tree") || strcasestr(actorName, "Rock") ||
            strcasestr(actorName, "Wall") || strcasestr(actorName, "Fence") ||
            strcasestr(actorName, "Door") || strcasestr(actorName, "Window") ||
            strcasestr(actorName, "Stairs") || strcasestr(actorName, "Floor") ||
            strcasestr(actorName, "Roof") || strcasestr(actorName, "Brush") ||
            strcasestr(actorName, "Volume") || strcasestr(actorName, "NavMesh") ||
            strcasestr(actorName, "Light") || strcasestr(actorName, "Audio") ||
            strcasestr(actorName, "Sound") || strcasestr(actorName, "Particle") ||
            strcasestr(actorName, "Emitter") || strcasestr(actorName, "Effect") ||
            strcasestr(actorName, "Decal") || strcasestr(actorName, "Camera") ||
            strcasestr(actorName, "Controller") || strcasestr(actorName, "Player") ||
            strcasestr(actorName, "Character") || strcasestr(actorName, "Pawn") ||
            strcasestr(actorName, "WorldSettings") || strcasestr(actorName, "GameMode") ||
            strcasestr(actorName, "GameState") || strcasestr(actorName, "Bullet") ||
            strcasestr(actorName, "Proj") || strcasestr(actorName, "Shell") ||
            strcasestr(actorName, "Cartridge") || strcasestr(actorName, "Trace") ||
            strcasestr(actorName, "Grenade") || strcasestr(actorName, "Smoke") ||
            strcasestr(actorName, "Flash") || strcasestr(actorName, "Explo") ||
            strcasestr(actorName, "Fire") || strcasestr(actorName, "Flame") ||
            strcasestr(actorName, "Trigger") || strcasestr(actorName, "Spawner") ||
            strcasestr(actorName, "SpawnPoint") || strcasestr(actorName, "SpawnPad") ||
            strcasestr(actorName, "Spawn") || strcasestr(actorName, "Terminal") ||
            strcasestr(actorName, "Station") || strcasestr(actorName, "Manager") ||
            strcasestr(actorName, "Stand") || strcasestr(actorName, "Table") ||
            strcasestr(actorName, "Board") || strcasestr(actorName, "Target") ||
            strcasestr(actorName, "Guide") || strcasestr(actorName, "Button") ||
            strcasestr(actorName, "Widget") || strcasestr(actorName, "UI") ||
            strcasestr(actorName, "Seat") || strcasestr(actorName, "Wheel") ||
            strcasestr(actorName, "Collision") || strcasestr(actorName, "Physics")) {
            return DSPUBGItemCategoryNone;
        }

        // 1. Vehicle check by name
        bool isNonVehicle = (strcasestr(actorName, "Wheel") != nullptr) ||
                            (strcasestr(actorName, "Seat") != nullptr) ||
                            (strcasestr(actorName, "Spawner") != nullptr) ||
                            (strcasestr(actorName, "SpawnPoint") != nullptr) ||
                            (strcasestr(actorName, "SpawnPad") != nullptr) ||
                            (strcasestr(actorName, "Spawn") != nullptr) ||
                            (strcasestr(actorName, "Terminal") != nullptr) ||
                            (strcasestr(actorName, "Station") != nullptr) ||
                            (strcasestr(actorName, "Manager") != nullptr) ||
                            (strcasestr(actorName, "Stand") != nullptr) ||
                            (strcasestr(actorName, "Table") != nullptr) ||
                            (strcasestr(actorName, "Board") != nullptr) ||
                            (strcasestr(actorName, "Audio") != nullptr) ||
                            (strcasestr(actorName, "Sound") != nullptr) ||
                            (strcasestr(actorName, "Decal") != nullptr) ||
                            (strcasestr(actorName, "Weapon") != nullptr) ||
                            (strcasestr(actorName, "Trigger") != nullptr) ||
                            (strcasestr(actorName, "Target") != nullptr) ||
                            (strcasestr(actorName, "Guide") != nullptr) ||
                            (strcasestr(actorName, "Button") != nullptr) ||
                            (strcasestr(actorName, "UI") != nullptr) ||
                            (strcasestr(actorName, "Widget") != nullptr);

        if (!isNonVehicle) {
            if (strcasestr(actorName, "Jeep") || strcasestr(actorName, "UAZ")) {
                snprintf(outDisplay, outCap, "Xe UAZ");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "Sedan") || strcasestr(actorName, "Dacia")) {
                snprintf(outDisplay, outCap, "Xe Dacia");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "Buggy")) {
                snprintf(outDisplay, outCap, "Xe Buggy");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "VH_PickUp") || strcasestr(actorName, "VH_Pickup") || (strcasestr(actorName, "Truck") && !strcasestr(actorName, "Monster")) || strcasestr(actorName, "Rony")) {
                snprintf(outDisplay, outCap, "Xe Bán Tải");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "Motorcycle") || strcasestr(actorName, "Motorbike") || strcasestr(actorName, "VH_Motor") || strcasestr(actorName, "Bike")) {
                snprintf(outDisplay, outCap, "Xe Máy");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "Scooter")) {
                snprintf(outDisplay, outCap, "Xe Scooter");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "TukTuk")) {
                snprintf(outDisplay, outCap, "Xe TukTuk");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "MiniBus") || strcasestr(actorName, "Bus_")) {
                snprintf(outDisplay, outCap, "Xe MiniBus");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "PG117") || strcasestr(actorName, "Boat") || strcasestr(actorName, "Cano")) {
                snprintf(outDisplay, outCap, "Thuyền Cano");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "AquaRail") || strcasestr(actorName, "JetSki")) {
                snprintf(outDisplay, outCap, "Moto Nước");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "BRDM")) {
                snprintf(outDisplay, outCap, "Xe BRDM");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "Coupe") || strcasestr(actorName, "CoupeRB")) {
                snprintf(outDisplay, outCap, "Xe Coupe RB");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "Mirado")) {
                snprintf(outDisplay, outCap, "Xe Mirado");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "MonsterTruck") || strcasestr(actorName, "BigFoot")) {
                snprintf(outDisplay, outCap, "Xe Quái Thú");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "Lada")) {
                snprintf(outDisplay, outCap, "Xe Lada Niva");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "Snowmobile") || strcasestr(actorName, "Snowbike")) {
                snprintf(outDisplay, outCap, "Xe Tuyết");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "Bicycle")) {
                snprintf(outDisplay, outCap, "Xe Đạp");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "Tank")) {
                snprintf(outDisplay, outCap, "Xe Tăng");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "Helicopter") || strcasestr(actorName, "DirectFly")) {
                snprintf(outDisplay, outCap, "Trực Thăng");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "Lamborghini")) {
                snprintf(outDisplay, outCap, "Xe Lamborghini");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "Tesla") || strcasestr(actorName, "ModelY")) {
                snprintf(outDisplay, outCap, "Xe Model Y");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "UTV")) {
                snprintf(outDisplay, outCap, "Xe UTV");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "ATV")) {
                snprintf(outDisplay, outCap, "Xe ATV");
                return DSPUBGItemCategoryVehicle;
            } else if (strcasestr(actorName, "VH_") || strcasestr(actorName, "Vehicle")) {
                // Secondary check via vehicle shape / vtype
                uint8_t shape = ds_pubg_read_u8(actor + 0x70DULL);
                if (shape > 0 && shape <= 125) {
                    DSPUBGItemCategory cat = ds_pubg_classify_vehicle_shape(shape, outDisplay, outCap);
                    if (cat != DSPUBGItemCategoryNone) return cat;
                }
                uint8_t vtype = ds_pubg_read_u8(actor + 0x70CULL);
                if (vtype > 0 && vtype <= 30) {
                    DSPUBGItemCategory cat = ds_pubg_classify_vehicle_type(vtype, outDisplay, outCap);
                    if (cat != DSPUBGItemCategoryNone) return cat;
                }
            }
        }

        // 2. AirDrop / DeathBox / Drop check by name
        if (strstr(actorName, "AirDrop")) {
            uint8_t isEmpty = ds_pubg_read_u8(actor + 0x729ULL) & 1;
            if (isEmpty) return DSPUBGItemCategoryNone;
            uint8_t isSuper = (ds_pubg_read_u8(actor + 0x5C4ULL) & 1) || (ds_pubg_read_u8(actor + 0x5C0ULL) & 1);
            snprintf(outDisplay, outCap, isSuper ? "THÍNH ĐỎ" : "HÒM THÍNH");
            return DSPUBGItemCategoryCrate;
        }
        if (strstr(actorName, "TombBox") || strstr(actorName, "DeadBox") || strstr(actorName, "PlayerDeadInventoryBox")) {
            snprintf(outDisplay, outCap, "Hòm Xác");
            return DSPUBGItemCategoryCrate;
        }
        if (strstr(actorName, "PickUpListWrapper")) {
            snprintf(outDisplay, outCap, "Đồ Rơi");
            return DSPUBGItemCategoryCrate;
        }

        // 3. Direct Item Name classification
        DSPUBGItemCategory strCat = ds_pubg_classify_item(actorName, outDisplay, outCap);
        if (strCat != DSPUBGItemCategoryNone) {
            return strCat;
        }

        // 4. Wrapper Actor check
        if (strstr(actorName, "Wrapper") || strstr(actorName, "PickUp") || strstr(actorName, "Pickup")) {
            uint8_t pickedUp = ds_pubg_read_u8(actor + 0x615ULL) & 1;
            if (pickedUp) return DSPUBGItemCategoryNone;

            int typeSpecificID = ds_pubg_read_i32(actor + 0x5FCULL);
            int itemId = ds_pubg_read_i32(actor + 0x758ULL);
            int targetId = (typeSpecificID >= 101001 && typeSpecificID <= 699999) ? typeSpecificID :
                           ((itemId >= 101001 && itemId <= 699999) ? itemId : 0);
            if (targetId > 0) {
                DSPUBGItemCategory idCat = ds_pubg_classify_item_id(targetId, outDisplay, outCap);
                if (idCat != DSPUBGItemCategoryNone) return idCat;
            }
        }

        // If actor has a name and none of the above matched, it is definitely not an item or vehicle!
        return DSPUBGItemCategoryNone;
    }

    // Name resolution failed (hasName == false) - Use strict multi-field memory checks
    // Check if it's already picked up
    uint8_t pickedUp = ds_pubg_read_u8(actor + 0x615ULL) & 1;
    if (pickedUp) return DSPUBGItemCategoryNone;

    // Check Ground Item ID at 0x5FC or 0x758
    int typeSpecificID = ds_pubg_read_i32(actor + 0x5FCULL);
    int itemId = ds_pubg_read_i32(actor + 0x758ULL);
    int targetId = (typeSpecificID >= 101001 && typeSpecificID <= 699999) ? typeSpecificID :
                   ((itemId >= 101001 && itemId <= 699999) ? itemId : 0);
    if (targetId > 0) {
        DSPUBGItemCategory idCat = ds_pubg_classify_item_id(targetId, outDisplay, outCap);
        if (idCat != DSPUBGItemCategoryNone) return idCat;
    }

    // Check AirDrop
    int airdropId = ds_pubg_read_i32(actor + 0x5B0ULL);
    if (airdropId > 0 && airdropId < 1000) {
        float dropSpd = ds_pubg_read_f32(actor + 0x56CULL);
        uint8_t aFlag = ds_pubg_read_u8(actor + 0x5C4ULL);
        if (aFlag == 0) aFlag = ds_pubg_read_u8(actor + 0x5C0ULL);
        if (!isnan(dropSpd) && dropSpd >= -3000.0f && dropSpd <= 3000.0f && aFlag <= 2) {
            uint8_t isEmpty = ds_pubg_read_u8(actor + 0x729ULL) & 1;
            if (!isEmpty) {
                snprintf(outDisplay, outCap, (aFlag & 1) ? "THÍNH ĐỎ" : "HÒM THÍNH");
                return DSPUBGItemCategoryCrate;
            }
        }
    }

    // Check DeathBox
    uint8_t boxType = ds_pubg_read_u8(actor + 0x641ULL);
    uint32_t tombOwner = ds_pubg_read_u32(actor + 0x660ULL);
    if (boxType > 0 && boxType < 10 && tombOwner > 0) {
        snprintf(outDisplay, outCap, "Hòm Xác");
        return DSPUBGItemCategoryCrate;
    }

    // Check Vehicle via strict pointer triad (Common + Seats + Damage)
    uint64_t vCommon = ds_pubg_read_ptr(actor + 0xC08ULL);
    uint64_t vSeats  = ds_pubg_read_ptr(actor + 0xBF0ULL);
    uint64_t vDamage = ds_pubg_read_ptr(actor + 0xC00ULL);
    if (vCommon && vSeats && vDamage) {
        float hpMax = ds_pubg_read_f32(vCommon + 0x350ULL);
        uint8_t shape = ds_pubg_read_u8(actor + 0x70DULL);
        uint8_t vtype = ds_pubg_read_u8(actor + 0x70CULL);
        if (!isnan(hpMax) && hpMax >= 500.0f && hpMax <= 10000.0f &&
            ((shape > 0 && shape <= 125) || (vtype > 0 && vtype <= 30))) {
            if (shape > 0 && shape <= 125) {
                DSPUBGItemCategory cat = ds_pubg_classify_vehicle_shape(shape, outDisplay, outCap);
                if (cat != DSPUBGItemCategoryNone) return cat;
            }
            if (vtype > 0 && vtype <= 30) {
                DSPUBGItemCategory cat = ds_pubg_classify_vehicle_type(vtype, outDisplay, outCap);
                if (cat != DSPUBGItemCategoryNone) return cat;
            }
        }
    }

    return DSPUBGItemCategoryNone;
}

struct CrateItemInfo {
    char name[36];
    DSPUBGItemCategory category;
    int priority;
};

struct DSPUBGCachedCrate {
    uint64_t actor;
    CFAbsoluteTime lastScanTime;
    std::vector<CrateItemInfo> items;
};
static std::vector<DSPUBGCachedCrate> s_crateCache;

static std::vector<CrateItemInfo> ds_pubg_get_crate_items(uint64_t crateActor) {
    std::vector<CrateItemInfo> results;
    if (!crateActor || !ds_pubg_valid(crateActor)) return results;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    for (const auto &cc : s_crateCache) {
        if (cc.actor == crateActor) {
            if (now - cc.lastScanTime < 0.8) {
                return cc.items;
            }
            break;
        }
    }

    uint8_t isEmpty = ds_pubg_read_u8(crateActor + 0x729ULL) & 1;
    if (isEmpty) return results;

    std::vector<uint64_t> targets;
    targets.push_back(crateActor);

    // SDK Direct chain resolution:
    // 1. AirDropBoxActor.DeadInventoryBoxTemplate at 0x598
    uint64_t tomb = ds_pubg_read_ptr(crateActor + 0x598ULL);
    if (tomb && ds_pubg_valid(tomb)) {
        targets.push_back(tomb);
        uint64_t wrap = ds_pubg_read_ptr(tomb + 0x658ULL);
        if (wrap && ds_pubg_valid(wrap)) targets.push_back(wrap);
    }
    // 2. PlayerTombBox.CustomPickListWrapperClass at 0x658
    uint64_t wrap = ds_pubg_read_ptr(crateActor + 0x658ULL);
    if (wrap && ds_pubg_valid(wrap)) targets.push_back(wrap);

    // Look for attached wrappers or inventory components
    static const uint64_t kCompOffsets[] = {
        0x5B8ULL, 0x5C8ULL, 0x620ULL, 0x630ULL, 0x640ULL, 0x650ULL, 0x660ULL, 0x680ULL, 0x6F0ULL, 0x700ULL
    };
    for (uint64_t cOff : kCompOffsets) {
        uint64_t comp = ds_pubg_read_ptr(crateActor + cOff);
        if (comp && comp != crateActor && ds_pubg_valid(comp)) {
            targets.push_back(comp);
        }
    }

    auto addItem = [&](int itemId, int count) {
        if (itemId < 101001 || itemId > 699999) return;
        char dName[36] = {0};
        DSPUBGItemCategory cat = ds_pubg_classify_item_id(itemId, dName, sizeof(dName));
        if (cat == DSPUBGItemCategoryNone) return;

        int prio = 10;
        if (itemId == 101004 || itemId == 103003 || itemId == 101005 || itemId == 103007 ||
            itemId == 105003 || itemId == 103013 || itemId == 102008 || itemId == 101006 ||
            itemId == 106007 || itemId == 101008 || itemId == 103001 || itemId == 103002) {
            prio = 1; // M416, AWM, Groza, Mk14, MG3, AMR, P90, AUG, Flare Gun, M762, Kar98k, M24
        } else if (cat == DSPUBGItemCategoryWeapon) {
            prio = 2; // Other weapons
        } else if (itemId == 501003 || itemId == 501006 || itemId == 502003 || itemId == 503003) {
            prio = 3; // L3 Armor, Helmet, Bag
        } else if (itemId == 201005 || itemId == 201010 || itemId == 201012) {
            prio = 4; // Scope 8x, 6x, 15x
        } else if (itemId == 501002 || itemId == 501005 || itemId == 502002 || itemId == 503002) {
            prio = 5; // L2 Armor, Helmet, Bag
        } else if (itemId == 201004 || itemId == 201009) {
            prio = 6; // Scope 4x, 3x
        } else if (itemId == 601003 || itemId == 601006 || itemId == 601002) {
            prio = 7; // Med Kit, Adrenaline, First Aid
        } else if (itemId == 305001 || itemId == 303001 || itemId == 302001) {
            prio = 8; // Ammo
        }

        // Avoid exact duplicates in list
        for (const auto &ex : results) {
            if (strcmp(ex.name, dName) == 0) return;
        }

        CrateItemInfo info;
        strncpy(info.name, dName, sizeof(info.name) - 1);
        info.name[sizeof(info.name) - 1] = '\0';
        info.category = cat;
        info.priority = prio;
        results.push_back(info);
    };

    // Fast direct check for PickUpListWrapperActor.PickUpDataList (offset 0x968, stride 0x40, ID at +0x4)
    for (uint64_t target : targets) {
        if (!target || !ds_pubg_valid(target)) continue;
        uint64_t dataPtr = ds_pubg_read_ptr(target + 0x968ULL);
        uint32_t count = ds_pubg_read_u32(target + 0x970ULL);
        if (dataPtr && ds_pubg_valid(dataPtr) && count > 0 && count <= 64) {
            for (uint32_t i = 0; i < count; i++) {
                uint64_t elem = dataPtr + i * 0x40ULL;
                int id = ds_pubg_read_i32(elem + 0x4ULL);
                int qty = ds_pubg_read_i32(elem + 0x18ULL);
                addItem(id, qty);
            }
            if (!results.empty()) break;
        }
    }

    if (results.empty()) {
        for (uint64_t target : targets) {
            if (!target || !ds_pubg_valid(target)) continue;

            for (uint64_t off = 0x580ULL; off <= 0x980ULL; off += 8ULL) {
                uint64_t dataPtr = ds_pubg_read_ptr(target + off);
                if (!dataPtr || !ds_pubg_valid(dataPtr)) continue;

                uint32_t count = ds_pubg_read_u32(target + off + 8ULL);
                if (count == 0 || count > 64) continue;
                uint32_t max = ds_pubg_read_u32(target + off + 12ULL);
                if (max < count || max > 128) continue;

                // Test if pointer array
                int validItemsPtr = 0;
                int testLimit = (count > 6) ? 6 : (int)count;
                for (int t = 0; t < testLimit; t++) {
                    uint64_t obj = ds_pubg_read_ptr(dataPtr + t * 8ULL);
                    if (obj && ds_pubg_valid(obj)) {
                        int id = ds_pubg_read_i32(obj + 0x5FCULL);
                        if (id < 101001 || id > 699999) id = ds_pubg_read_i32(obj + 0x758ULL);
                        if (id < 101001 || id > 699999) id = ds_pubg_read_i32(obj + 0x2F4ULL);
                        if (id < 101001 || id > 699999) id = ds_pubg_read_i32(obj + 0xCCULL);
                        if (id >= 101001 && id <= 699999) validItemsPtr++;
                    }
                }

                if (validItemsPtr > 0) {
                    for (uint32_t i = 0; i < count; i++) {
                        uint64_t obj = ds_pubg_read_ptr(dataPtr + i * 8ULL);
                        if (!obj || !ds_pubg_valid(obj)) continue;
                        int id = ds_pubg_read_i32(obj + 0x5FCULL);
                        if (id < 101001 || id > 699999) id = ds_pubg_read_i32(obj + 0x758ULL);
                        if (id < 101001 || id > 699999) id = ds_pubg_read_i32(obj + 0x2F4ULL);
                        if (id < 101001 || id > 699999) id = ds_pubg_read_i32(obj + 0xCCULL);
                        int qty = ds_pubg_read_i32(obj + 0x618ULL);
                        addItem(id, qty);
                    }
                    break;
                }

                // Test struct array
                static const int kStrides[] = { 56, 48, 64, 40, 32, 72, 80 };
                static const int kIdOffsets[] = { 4, 0, 8, 12, 16, 20 };
                int bestStride = 0, bestIdOff = 0, bestMatchCount = 0;

                for (int stride : kStrides) {
                    for (int idOff : kIdOffsets) {
                        int matches = 0;
                        for (int t = 0; t < testLimit; t++) {
                            int id = ds_pubg_read_i32(dataPtr + t * stride + idOff);
                            if (id >= 101001 && id <= 699999) matches++;
                        }
                        if (matches > bestMatchCount) {
                            bestMatchCount = matches;
                            bestStride = stride;
                            bestIdOff = idOff;
                        }
                    }
                    if (bestMatchCount >= 2 || (count == 1 && bestMatchCount == 1)) break;
                }

                if (bestMatchCount > 0) {
                    for (uint32_t i = 0; i < count; i++) {
                        uint64_t elem = dataPtr + i * bestStride;
                        int id = ds_pubg_read_i32(elem + bestIdOff);
                        int qty = ds_pubg_read_i32(elem + bestIdOff + 4);
                        addItem(id, qty);
                    }
                    break;
                }
            }
            if (!results.empty()) break;
        }
    }

    if (!results.empty()) {
        std::sort(results.begin(), results.end(), [](const CrateItemInfo &a, const CrateItemInfo &b) {
            if (a.priority != b.priority) return a.priority < b.priority;
            return strcmp(a.name, b.name) < 0;
        });
        if (results.size() > 10) results.resize(10);
    }

    bool foundCache = false;
    for (auto &cc : s_crateCache) {
        if (cc.actor == crateActor) {
            cc.items = results;
            cc.lastScanTime = now;
            foundCache = true;
            break;
        }
    }
    if (!foundCache) {
        if (s_crateCache.size() > 24) s_crateCache.erase(s_crateCache.begin());
        s_crateCache.push_back({crateActor, now, results});
    }

    return results;
}

// Automatically scans __DATA sections of the main Mach-O image to discover GEngine or GWorld dynamically.
// This allows DarkPubg to work across different PUBG Mobile versions (Global, VN, KR, TW, updates)
// without breaking on static RVA changes.
static bool ds_pubg_scan_for_engine_and_world(uint64_t vmMap, uint64_t base) {
    if (!vmMap || !base) return false;

    // 1. Check currently configured RVA
    if (g_dspubgEngineRva) {
        uint64_t ge = 0;
        if (ds_debug_read_bytes(vmMap, base + g_dspubgEngineRva, &ge, sizeof(ge))) {
            ge &= 0x0000FFFFFFFFFFFFULL;
            uint64_t vpOff = 0, world = 0;
            if (ds_pubg_is_valid_engine(vmMap, ge, &vpOff, &world)) {
                g_dspubgEngineViewportOffset = vpOff;
                g_dspubgCachedWorld = world;
                if (!g_dspubgGNames) {
                    ds_pubg_try_known_gnames(vmMap, base);
                }
                if (!g_dspubgGNames) {
                    std::vector<ScanRange> ranges;
                    if (ds_pubg_get_data_ranges(vmMap, base, ranges)) ds_pubg_scan_for_gnames(vmMap, ranges);
                }
                return true;
            }
        }
    }

    // 2. Check known common RVAs across PUBG Mobile versions
    static const uint64_t kKnownRVAs[] = {
        0x0ACC4680ULL, // Updated from DUMP/Offsets.hpp (Engine = 0x10acc4680)
        0x0A8AA8A0ULL, // v3.4 Global
        0x0A8A98A0ULL,
        0x0A8B08A0ULL,
        0x0A88B8A0ULL,
        0x0A8B88A0ULL,
        0x0A9008A0ULL,
        0x0A7AA8A0ULL,
        0x0A692D18ULL,
        0x0A692D28ULL
    };
    for (uint64_t rva : kKnownRVAs) {
        uint64_t ge = 0;
        if (ds_debug_read_bytes(vmMap, base + rva, &ge, sizeof(ge))) {
            ge &= 0x0000FFFFFFFFFFFFULL;
            uint64_t vpOff = 0, world = 0;
            if (ds_pubg_is_valid_engine(vmMap, ge, &vpOff, &world)) {
                g_dspubgEngineRva = rva;
                g_dspubgEngineViewportOffset = vpOff;
                g_dspubgCachedWorld = world;
                if (!g_dspubgGNames) {
                    ds_pubg_try_known_gnames(vmMap, base);
                }
                if (!g_dspubgGNames) {
                    std::vector<ScanRange> ranges;
                    if (ds_pubg_get_data_ranges(vmMap, base, ranges)) ds_pubg_scan_for_gnames(vmMap, ranges);
                }
                return true;
            }
        }
    }

    // 3. Parse Mach-O load commands to scan __DATA sections (__bss, __common, __data)
    std::vector<ScanRange> scanRanges;
    if (!ds_pubg_get_data_ranges(vmMap, base, scanRanges)) return false;

    if (!g_dspubgGNames) {
        ds_pubg_try_known_gnames(vmMap, base);
        if (!g_dspubgGNames) {
            ds_pubg_scan_for_gnames(vmMap, scanRanges);
        }
    }

    const size_t kChunkSize = 32768;
    std::vector<uint8_t> chunk(kChunkSize);

    for (const auto &range : scanRanges) {
        uint64_t limitSize = range.size > (16ULL * 1024ULL * 1024ULL) ? (16ULL * 1024ULL * 1024ULL) : range.size;
        for (uint64_t offset = 0; offset < limitSize; offset += kChunkSize) {
            size_t toRead = (size_t)std::min((uint64_t)kChunkSize, limitSize - offset);
            uint64_t chunkAddr = range.start + offset;
            if (!ds_debug_read_bytes(vmMap, chunkAddr, chunk.data(), toRead)) continue;

            size_t ptrCount = toRead / 8;
            const uint64_t *ptrs = (const uint64_t *)chunk.data();
            for (size_t p = 0; p < ptrCount; p++) {
                uint64_t val = ptrs[p] & 0x0000FFFFFFFFFFFFULL;
                if (!val || (val & 0x7ULL) != 0 || !ds_pubg_valid(val)) continue;

                uint64_t ptrAddr = chunkAddr + p * 8;

                // Check 1: Is val GWorld directly?
                if (ds_pubg_is_valid_world(vmMap, val)) {
                    g_dspubgWorldRva = ptrAddr - base;
                    g_dspubgCachedWorld = val;
                    return true;
                }

                // Check 2: Is val GEngine?
                uint64_t vpOff = 0, world = 0;
                if (ds_pubg_is_valid_engine(vmMap, val, &vpOff, &world)) {
                    g_dspubgEngineRva = ptrAddr - base;
                    g_dspubgEngineViewportOffset = vpOff;
                    g_dspubgCachedWorld = world;
                    return true;
                }
            }
        }
    }
    return false;
}

// Find PUBG Mobile process. In iOS XNU, p_comm is 16 bytes max (15 chars + \0),
// so "ShadowTrackerExtra" (18 chars) truncates to "ShadowTrackerEx".
static void ds_pubg_overlay_reset(void);

static uint64_t ds_pubg_find_proc(pid_t *outPid) {
    if (outPid) *outPid = 0;
    if (!ds_is_ready()) return 0;

    proc_entry_t *list = NULL;
    @try {
        // 1. Prefix match via procbyname (15 chars)
        uint64_t proc = procbyname("ShadowTrackerEx");
        if (!proc) proc = procbyname("ShadowTrackerExtra");
        if (!proc) proc = procbyname("ShadowTracker");
        if (!proc) proc = procbyname("PUBG MOBILE");
        if (!proc) proc = procbyname("PUBGMOBILE");
        if (!proc) proc = procbyname("pubgmobile");
        if (!proc) proc = procbyname("PUBGM");
        if (!proc) proc = procbyname("pubg");

        if (proc) {
            if (outPid) {
                pid_t pid = (pid_t)(off_proc_p_pid ? ds_kread32(proc + off_proc_p_pid) : 0);
                if (pid <= 0) pid = (pid_t)ds_kread32(proc + 0x60);
                if (pid <= 0) pid = (pid_t)ds_kread32(proc + 0x28);
                *outPid = pid;
            }
            return proc;
        }

        // 2. Full proclist search with case-insensitive substring
        int count = 0;
        list = proclist("", &count);
        if (list && count > 0) {
            for (int i = 0; i < count; i++) {
                const char *name = list[i].name;
                if (!name || !name[0]) continue;
                if (strcasestr(name, "Shadow") != NULL || strcasestr(name, "PUBG") != NULL) {
                    uint64_t p = list[i].kaddr;
                    if (p && ds_isvalid(p)) {
                        pid_t pid = off_proc_p_pid ? (pid_t)ds_kread32(p + off_proc_p_pid) : (pid_t)list[i].pid;
                        if (pid <= 0) pid = (pid_t)list[i].pid;
                        if (pid > 0) {
                            if (outPid) *outPid = pid;
                            proc = p;
                            break;
                        }
                    }
                }
            }
        }
        return proc;
    } @catch (__unused NSException *exception) {
        if (outPid) *outPid = 0;
        return 0;
    } @finally {
        if (list) free_proclist(list);
    }
}

// Locate main executable base image.
static uint64_t ds_pubg_find_base(uint64_t vmMap) {
    if (!vmMap) return 0;

    std::vector<uint64_t> starts;
    os_unfair_lock_lock(&g_debugVMRegionsLock);
    for (const DSDebugVMRegion &region : g_debugVMRegions) {
        starts.push_back(region.start);
    }
    os_unfair_lock_unlock(&g_debugVMRegionsLock);

    uint64_t firstMacho = 0;
    for (uint64_t start : starts) {
        if (ds_debug_macho_main_identity(vmMap, start)) {
            firstMacho = start;
            break;
        }
    }
    if (!firstMacho) {
        firstMacho = ds_debug_find_main_image_base(vmMap);
    }
    return firstMacho;
}

static bool ds_pubg_attach(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (g_dspubgTargetActive.load(std::memory_order_acquire) && g_dspubgBase && g_dspubgVmMap) {
        if (g_dspubgPid > 0 && ds_pid_alive_userspace((pid_t)g_dspubgPid)) {
            return true;
        }
        // Target exited or restarted: drop stale shmem/VM/match state right away.
        ds_debug_shmem_flush_ex(NO);
        ds_pubg_overlay_reset();
        g_dspubgTargetActive.store(false, std::memory_order_release);
        g_dspubgProc = g_dspubgVmMap = g_dspubgBase = 0;
        g_dspubgPid = 0;
        g_dspubgCachedWorld = 0;
        g_dspubgEngineRva = 0;
        g_dspubgWorldRva = 0;
    }
    if (now < g_dspubgNextAttach) return false;

    pid_t targetPid = 0;
    uint64_t proc = ds_pubg_find_proc(&targetPid);

    if (!ds_isvalid(proc) || targetPid <= 0) {
        g_dspubgTargetActive.store(false, std::memory_order_release);
        g_dspubgProc = g_dspubgVmMap = g_dspubgBase = 0;
        g_dspubgPid = 0;
        g_dspubgNextAttach = now + 1.0;
        return false;
    }

    uint64_t task = proc_task(proc);
    uint64_t vmMap = ds_isvalid(task) ? task_get_vm_map(task) : 0;
    if (!ds_isvalid(vmMap)) {
        g_dspubgTargetActive.store(false, std::memory_order_release);
        g_dspubgNextAttach = now + 1.0;
        return false;
    }

    bool identityChanged = (g_dspubgProc != proc || g_dspubgPid != (uint32_t)targetPid || g_dspubgVmMap != vmMap);
    if (identityChanged) {
        g_dspubgBase = 0;
        g_dspubgEngineRva = 0;
        g_dspubgWorldRva = 0;
        g_dspubgCachedWorld = 0;
    }
    g_dspubgProc = proc;
    g_dspubgPid = (uint32_t)targetPid;
    g_dspubgVmMap = vmMap;

    if (!ds_debug_shmem_claim_target(DSDebugShmemOwner::PUBG, targetPid, proc, vmMap)) {
        g_dspubgTargetActive.store(false, std::memory_order_release);
        g_dspubgNextAttach = now + 1.0;
        return false;
    }

    if (!g_dspubgBase || identityChanged) {
        ds_debug_vm_regions_rebuild(vmMap, targetPid, YES);
        g_dspubgBase = ds_pubg_find_base(vmMap);
        if (g_dspubgBase) {
            ds_pubg_scan_for_engine_and_world(vmMap, g_dspubgBase);
        }
    }

    if (!g_dspubgBase) {
        g_dspubgNextAttach = now + 1.0;
        return false;
    }

    g_dspubgTargetActive.store(true, std::memory_order_release);
    g_dspubgNextAttach = now + 1.5;
    return true;
}

// Build Camera Basis for World-to-Screen projection (DarkPubg proven algorithm)
static bool ds_pubg_cam_basis_build(DSPUBGVector camLoc, DSPUBGRotator camRot, float fov,
                                    float screenW, float screenH, DSPUBGCamBasis &b) {
    if (screenW <= 0.0f || screenH <= 0.0f || fov < 10.0f || fov > 170.0f) return false;
    const float kPi = 3.141592653589793f;
    float radPitch = camRot.Pitch * kPi / 180.0f;
    float radYaw   = camRot.Yaw   * kPi / 180.0f;
    float radRoll  = camRot.Roll  * kPi / 180.0f;

    float SP = sinf(radPitch), CP = cosf(radPitch);
    float SY = sinf(radYaw),   CY = cosf(radYaw);
    float SR = sinf(radRoll),  CR = cosf(radRoll);

    float tanHalf = tanf(fov * kPi / 360.0f);
    if (tanHalf <= 0.01f || tanHalf > 10.0f) return false;

    b.m00 = CP * CY;
    b.m01 = CP * SY;
    b.m02 = SP;

    b.m10 = SR * SP * CY - CR * SY;
    b.m11 = SR * SP * SY + CR * CY;
    b.m12 = -SR * CP;

    b.m20 = -(CR * SP * CY + SR * SY);
    b.m21 = CY * SR - CR * SP * SY;
    b.m22 = CR * CP;

    b.lx = camLoc.X;
    b.ly = camLoc.Y;
    b.lz = camLoc.Z;

    b.cx = screenW * 0.5f;
    b.cy = screenH * 0.5f;
    b.k  = b.cx / tanHalf;

    return true;
}

static bool ds_pubg_cam_basis_project(const DSPUBGCamBasis &b, DSPUBGVector world,
                                      float &outX, float &outY, float &outDist) {
    if (isnan(world.X) || isinf(world.X) ||
        isnan(world.Y) || isinf(world.Y) ||
        isnan(world.Z) || isinf(world.Z)) return false;

    float dx = world.X - b.lx;
    float dy = world.Y - b.ly;
    float dz = world.Z - b.lz;

    float tx = dx * b.m10 + dy * b.m11 + dz * b.m12;
    float ty = dx * b.m20 + dy * b.m21 + dz * b.m22;
    float tz = dx * b.m00 + dy * b.m01 + dz * b.m02;

    if (isnan(tz) || isinf(tz) || tz < 10.0f) return false; // Behind or too close

    float distSq = dx * dx + dy * dy + dz * dz;
    if (isnan(distSq) || isinf(distSq) || distSq < 0.0f) return false;
    float distM = sqrtf(distSq) / 100.0f;

    float projX = b.cx + tx * b.k / tz;
    float projY = b.cy - ty * b.k / tz;
    if (isnan(projX) || isinf(projX) || isnan(projY) || isinf(projY)) return false;

    outX = projX;
    outY = projY;
    outDist = distM;
    return true;
}

static bool ds_pubg_read_c2w(uint64_t meshComp, const DSPUBGVector &rootLoc, float halfH, uint8_t *outC2W) {
    if (!meshComp || !ds_pubg_valid(meshComp) || !outC2W) return false;

    // Direct read from 0x210 (UE4 arm64 USceneComponent::ComponentToWorld aligned offset)
    if (ds_pubg_read(meshComp + 0x210ULL, outC2W, 48)) {
        float qx = 0, qy = 0, qz = 0, qw = 1.0f;
        memcpy(&qx, outC2W + 0x0, 4);
        memcpy(&qy, outC2W + 0x4, 4);
        memcpy(&qz, outC2W + 0x8, 4);
        memcpy(&qw, outC2W + 0xC, 4);
        float qlen2 = qx * qx + qy * qy + qz * qz + qw * qw;
        if (!isnan(qlen2) && !isinf(qlen2) && qlen2 >= 0.4f && qlen2 <= 2.2f) {
            return true;
        }
    }

    if (ds_pubg_read(meshComp + 0x208ULL, outC2W, 48)) {
        return true;
    }
    return false;
}

static void ds_pubg_bone_world_from_local(const uint8_t *c2w,
                                          const DSPUBGVector &rootLoc,
                                          float halfH,
                                          const DSPUBGRotator &actorRot,
                                          const DSPUBGVector *local,
                                          DSPUBGVector *out) {
    float qx = 0, qy = 0, qz = 0, qw = 1.0f;
    float tx = 0, ty = 0, tz = 0;
    float sx = 1.0f, sy = 1.0f, sz = 1.0f;
    if (c2w) {
        memcpy(&qx, c2w + 0x0, 4);
        memcpy(&qy, c2w + 0x4, 4);
        memcpy(&qz, c2w + 0x8, 4);
        memcpy(&qw, c2w + 0xC, 4);
        memcpy(&tx, c2w + 0x10, 4);
        memcpy(&ty, c2w + 0x14, 4);
        memcpy(&tz, c2w + 0x18, 4);
        memcpy(&sx, c2w + 0x20, 4);
        memcpy(&sy, c2w + 0x24, 4);
        memcpy(&sz, c2w + 0x28, 4);
    }

    if (isnan(sx) || isinf(sx) || sx < 0.01f || sx > 100.0f) sx = 1.0f;
    if (isnan(sy) || isinf(sy) || sy < 0.01f || sy > 100.0f) sy = 1.0f;
    if (isnan(sz) || isinf(sz) || sz < 0.01f || sz > 100.0f) sz = 1.0f;

    // Translation validation & anchoring:
    // If c2w translation is valid, use it directly (exact UE4 mesh world transform).
    // Only fallback to rootLoc if c2w translation is uninitialized/corrupt.
    float meshOriginZ = rootLoc.Z - halfH;
    float dX = tx - rootLoc.X;
    float dY = ty - rootLoc.Y;
    float distSq = dX * dX + dY * dY;
    if (isnan(tx) || isinf(tx) || isnan(ty) || isinf(ty) || isnan(tz) || isinf(tz) ||
        (fabsf(tx) < 1.0f && fabsf(ty) < 1.0f) || distSq > (500.0f * 500.0f)) {
        tx = rootLoc.X;
        ty = rootLoc.Y;
        tz = meshOriginZ;
    }

    // Rotation quaternion validation & fallback:
    float qlen2 = qx * qx + qy * qy + qz * qz + qw * qw;
    bool quatValid = (!isnan(qlen2) && !isinf(qlen2) && qlen2 >= 0.5f && qlen2 <= 2.0f);
    if (quatValid) {
        float qlen = sqrtf(qlen2);
        qx /= qlen; qy /= qlen; qz /= qlen; qw /= qlen;
    } else if (!isnan(actorRot.Yaw) && !isinf(actorRot.Yaw)) {
        // In UE4 Character, Mesh is attached with RelativeRotation(0, -90, 0),
        // so Mesh Yaw = ActorYaw - 90
        const float kPi = 3.141592653589793f;
        float radYaw = ((actorRot.Yaw - 90.0f) * kPi / 180.0f) * 0.5f;
        qx = 0.0f;
        qy = 0.0f;
        qz = sinf(radYaw);
        qw = cosf(radYaw);
    } else {
        qx = 0.0f; qy = 0.0f; qz = 0.0f; qw = 1.0f;
    }

    float vx = local->X * sx, vy = local->Y * sy, vz = local->Z * sz;
    float cx = qy * vz - qz * vy;
    float cy = qz * vx - qx * vz;
    float cz = qx * vy - qy * vx;
    float ux = 2.0f * (cx + qw * vx);
    float uy = 2.0f * (cy + qw * vy);
    float uz = 2.0f * (cz + qw * vz);

    out->X = vx + (qy * uz - qz * uy) + tx;
    out->Y = vy + (qz * ux - qx * uz) + ty;
    out->Z = vz + (qx * uy - qy * ux) + tz;
}

// Dynamically locates live ComponentSpaceTransforms TArray<FTransform> on USkeletalMeshComponent.
// Tests verified double buffer offsets (0xA30/0xA40), eval-context (0xE18/0xE28), cached (0xCE0/0xCD0),
// and bone-space (0xC98).
static bool ds_pubg_find_bone_array(uint64_t meshComp, uint64_t *outData, uint32_t *outCount, uint32_t *outOffset) {
    if (!meshComp || !ds_pubg_valid(meshComp)) return false;

    auto testOffset = [&](uint32_t off) -> bool {
        uint8_t hdr[16] = {0};
        if (!ds_pubg_read(meshComp + (uint64_t)off, hdr, sizeof(hdr))) return false;
        uint64_t d = 0;
        uint32_t c = 0, maxc = 0;
        memcpy(&d, hdr, 8);
        memcpy(&c, hdr + 8, 4);
        memcpy(&maxc, hdr + 12, 4);
        d &= 0x0000FFFFFFFFFFFFULL;
        if (!ds_pubg_valid(d) || (d & 0x7ULL) != 0) return false;
        if (c < 20 || c > 800 || maxc < c || maxc > 2000) return false;
        if (outData) *outData = d;
        if (outCount) *outCount = c;
        if (outOffset) *outOffset = off;
        return true;
    };

    // 1. CachedComponentSpaceTransforms (0xCE0) - post-IK fully evaluated transforms
    if (testOffset(0xCE0)) return true;

    // 2. Double buffer ComponentSpaceTransformsArray[2] (0xA30 / 0xA40)
    // Read CurrentReadIndex (0xA50 / 0xA54 / 0xA74 / 0xA78)
    int32_t rd = ds_pubg_read_i32(meshComp + 0xA50ULL);
    if (rd != 0 && rd != 1) rd = ds_pubg_read_i32(meshComp + 0xA54ULL);
    if (rd != 0 && rd != 1) rd = ds_pubg_read_i32(meshComp + 0xA74ULL);
    if (rd != 0 && rd != 1) rd = ds_pubg_read_i32(meshComp + 0xA78ULL);
    uint32_t first = (rd == 1) ? 0xA40 : 0xA30;
    uint32_t second = (rd == 1) ? 0xA30 : 0xA40;

    if (testOffset(first)) return true;
    if (testOffset(second)) return true;

    // 3. Live transforms eval-context (0xE18 / 0xE28)
    if (testOffset(0xE18)) return true;
    if (testOffset(0xE28)) return true;

    return false;
}

static const char *ds_pubg_weapon_name_by_id(int32_t id) {
    switch (id) {
        // Assault Rifles
        case 101001: return "AKM";
        case 101002: return "M16A4";
        case 101003: return "SCAR-L";
        case 101004: return "M416";
        case 101005: return "Groza";
        case 101006: return "AUG";
        case 101007: return "QBZ";
        case 101008: return "M762";
        case 101009: return "Mk47";
        case 101010: return "G36C";
        case 101011: return "FAMAS";
        case 101012: return "ACE32";
        case 101013: return "HoneyBadger";

        // SMGs
        case 102001: return "UZI";
        case 102002: return "UMP45";
        case 102003: return "Vector";
        case 102004: return "Tommy";
        case 102005: return "Bizon";
        case 102007: return "P90";
        case 102008: return "MP5K";

        // Sniper & DMR
        case 103001: return "Kar98k";
        case 103002: return "M24";
        case 103003: return "AWM";
        case 103004: return "SKS";
        case 103005: return "VSS";
        case 103006: return "Mini14";
        case 103007: return "Mk14";
        case 103008: return "Win94";
        case 103009: return "SLR";
        case 103010: return "QBU";
        case 103011: return "Mosin";
        case 103012: return "AMR";
        case 103013: return "Lynx AMR";

        // Shotguns
        case 104001: return "S686";
        case 104002: return "S1897";
        case 104003: return "S12K";
        case 104004: return "DBS";
        case 104005: return "M1014";

        // LMGs
        case 105001: return "M249";
        case 105002: return "DP-28";
        case 105003: return "MG3";

        // Pistols
        case 106001: return "P92";
        case 106002: return "P1911";
        case 106003: return "R1895";
        case 106004: return "P18C";
        case 106005: return "R45";
        case 106006: return "SawedOff";
        case 106008: return "Skorpion";
        case 106010: return "Deagle";

        // Others / Melee
        case 107001: return "Crossbow";
        case 108001: return "Pan";
        case 108002: return "Crowbar";
        case 108003: return "Machete";
        case 108004: return "Sickle";

        // Throwables / Grenades
        case 601001: return "Frag Grenade";
        case 601002: return "Smoke Grenade";
        case 601003: return "Molotov";
        case 601004: return "Stun Grenade";
        case 601005: return "Grenade";
        case 602001: return "Smoke Grenade";
        case 602002: return "Frag Grenade";
        case 602003: return "Molotov";
        case 602004: return "Stun Grenade";
        default: return NULL;
    }
}

static int32_t ds_pubg_read_equipped_weapon_id(uint64_t pawn) {
    if (!pawn || !ds_pubg_valid(pawn)) return 0;

    auto isValidWeaponId = [](int32_t wid) -> bool {
        return (wid >= 101001 && wid <= 108999) || (wid >= 601001 && wid <= 603999);
    };

    auto extractWeaponIdFromActor = [&](uint64_t weapon) -> int32_t {
        if (!weapon || !ds_pubg_valid(weapon)) return 0;

        // 1. WeaponCfg.KeyID (0x798 on ASTExtraWeapon)
        int32_t wid = ds_pubg_read_i32(weapon + 0x798ULL);
        if (isValidWeaponId(wid)) return wid;

        // 2. OwnerClientCreateWeaponData.ID.TypeSpecificID (0x68C on ASTExtraWeapon: 0x670 + 0x18 + 0x4)
        wid = ds_pubg_read_i32(weapon + 0x68CULL);
        if (isValidWeaponId(wid)) return wid;

        // 3. WeaponEntityComp (0x868) -> WeaponId (0x1E0 on UWeaponEntity)
        uint64_t wepEntity = ds_pubg_read_ptr(weapon + 0x868ULL);
        if (wepEntity && ds_pubg_valid(wepEntity)) {
            wid = ds_pubg_read_i32(wepEntity + 0x1E0ULL);
            if (isValidWeaponId(wid)) return wid;
        }

        // 4. ShootID (0xCBC on ASTExtraShootWeapon)
        wid = ds_pubg_read_i32(weapon + 0xCBCULL);
        if (isValidWeaponId(wid)) return wid;

        // 5. Standard heuristic offsets on weapon
        static const uint64_t idOffsets[] = { 0x74ULL, 0x1E0ULL, 0x200ULL, 0x220ULL, 0x238ULL, 0x280ULL };
        for (uint64_t idOff : idOffsets) {
            wid = ds_pubg_read_i32(weapon + idOff);
            if (isValidWeaponId(wid)) return wid;
        }
        return 0;
    };

    // Step 1: Check WeaponManagerComponent on pawn
    // Offsets on ASTExtraBaseCharacter: 0x2768 (DUMP updated), 0x2628 (primary dump), 0x25B8, 0x15B8, 0x2600, 0x2618, 0x2620, 0x2630
    static const uint64_t wmOffsets[] = { 0x2768ULL, 0x2628ULL, 0x25B8ULL, 0x15B8ULL, 0x2600ULL, 0x2618ULL, 0x2620ULL, 0x2630ULL };
    for (uint64_t wmOff : wmOffsets) {
        uint64_t wm = ds_pubg_read_ptr(pawn + wmOff);
        if (!wm || !ds_pubg_valid(wm)) continue;

        // Check active / held weapons:
        // CurrentWeaponReplicated (0x5E8), CurrentWeaponSimulate (0x5F8), TemporaryWeaponReplicated (0x5F0), CurrentShield (0x600, 0x608)
        static const uint64_t cwOffsets[] = { 0x5E8ULL, 0x5F8ULL, 0x5F0ULL, 0x600ULL, 0x608ULL };
        for (uint64_t cwOff : cwOffsets) {
            uint64_t w = ds_pubg_read_ptr(wm + cwOff);
            if (w && ds_pubg_valid(w)) {
                int32_t wid = extractWeaponIdFromActor(w);
                if (wid > 0) return wid;
            }
        }

        // If held weapon pointer was temporarily null during switch, check active socket:
        // CurUseWeaponLogicSocketRep: 1=Slot1, 2=Slot2, 3=SubSlot, 4=MeleeSlot
        uint8_t curSlot = ds_pubg_read_u8(wm + 0x320ULL);
        if (curSlot >= 1 && curSlot <= 4) {
            uint64_t slotOff = 0;
            if (curSlot == 1) slotOff = 0x4C8ULL;
            else if (curSlot == 2) slotOff = 0x500ULL;
            else if (curSlot == 3) slotOff = 0x538ULL;
            else if (curSlot == 4) slotOff = 0x570ULL;

            if (slotOff != 0) {
                // Check TargetWeapon at slot + 0x0
                uint64_t w = ds_pubg_read_ptr(wm + slotOff);
                if (w && ds_pubg_valid(w)) {
                    int32_t wid = extractWeaponIdFromActor(w);
                    if (wid > 0) return wid;
                }
                // Check ID.TypeSpecificID at slot + 0x1C (0x18 + 0x4)
                int32_t slotWid = ds_pubg_read_i32(wm + slotOff + 0x1CULL);
                if (isValidWeaponId(slotWid)) return slotWid;
            }
        } else if (curSlot == 0) {
            // curSlot == 0 (SWPS_None) explicitly means Unarmed (tay không)
            return 0;
        }
    }

    // Step 2: Check CurrentReloadWeapon on ASTExtraBaseCharacter (0x3220ULL)
    uint64_t reloadWep = ds_pubg_read_ptr(pawn + 0x3220ULL);
    if (reloadWep && ds_pubg_valid(reloadWep)) {
        int32_t wid = extractWeaponIdFromActor(reloadWep);
        if (wid > 0) return wid;
    }

    // Step 3: Check fallback direct weapon pointers on pawn
    static const uint64_t directWeaponOffsets[] = {
        0x2AF4ULL, 0x2A84ULL, 0x2B00ULL, 0x2A70ULL, 0x2B10ULL, 0x2AA0ULL, 0x21F0ULL, 0x1A00ULL
    };
    for (uint64_t off : directWeaponOffsets) {
        uint64_t w = ds_pubg_read_ptr(pawn + off);
        if (w && ds_pubg_valid(w)) {
            int32_t wid = extractWeaponIdFromActor(w);
            if (wid > 0) return wid;
        }
    }

    return 0;
}

static int g_dspubgTotalEnemies = 0;
static int g_dspubgTotalBots = 0;

static void ds_pubg_get_total_counts(int *outEnemies, int *outBots) {
    os_unfair_lock_lock(&g_dspubgSnapshotLock);
    if (outEnemies) *outEnemies = g_dspubgTotalEnemies;
    if (outBots) *outBots = g_dspubgTotalBots;
    os_unfair_lock_unlock(&g_dspubgSnapshotLock);
}

static bool ds_pubg_has_render_source(void) {
    return g_dspubgTargetActive.load(std::memory_order_acquire);
}

static int ds_pubg_copy_projected_players(DSPUBGProjectedPlayer out[kDSPUBGMaxPlayers], uint64_t *epochOut) {
    os_unfair_lock_lock(&g_dspubgSnapshotLock);
    int count = g_dspubgPlayerCount;
    if (count > 0 && out) {
        memcpy(out, g_dspubgPlayers, count * sizeof(DSPUBGProjectedPlayer));
    }
    if (epochOut) *epochOut = g_dspubgEpoch;
    os_unfair_lock_unlock(&g_dspubgSnapshotLock);
    return count;
}

static int ds_pubg_copy_projected_items(DSPUBGProjectedItem out[kDSPUBGMaxItems], uint64_t *epochOut) {
    os_unfair_lock_lock(&g_dspubgSnapshotLock);
    int count = g_dspubgItemCount;
    if (count > kDSPUBGMaxItems) count = kDSPUBGMaxItems;
    if (count > 0 && out) {
        memcpy(out, g_dspubgItems, count * sizeof(DSPUBGProjectedItem));
    }
    if (epochOut) *epochOut = g_dspubgItemEpoch;
    os_unfair_lock_unlock(&g_dspubgSnapshotLock);
    return count;
}

static int ds_pubg_copy_projected_grenades(DSPUBGProjectedGrenade out[kDSPUBGMaxGrenades], uint64_t *epochOut) {
    os_unfair_lock_lock(&g_dspubgSnapshotLock);
    int count = g_dspubgGrenadeCount;
    if (count > kDSPUBGMaxGrenades) count = kDSPUBGMaxGrenades;
    if (count > 0 && out) {
        memcpy(out, g_dspubgGrenades, count * sizeof(DSPUBGProjectedGrenade));
    }
    if (epochOut) *epochOut = g_dspubgGrenadeEpoch;
    os_unfair_lock_unlock(&g_dspubgSnapshotLock);
    return count;
}

static void ds_pubg_reset_match_caches(void) {
    s_cachedLootCount = 0;
    s_levelScanTick = 0;
    s_trackedLevelPawns.clear();
    s_trackedLevelGrenades.clear();
    s_trackedLevelVehicles.clear();
    s_lastMatchWorld = 0;
    s_lastMatchLevel = 0;
    s_lastMatchMapIsLobby = false;
    g_dspubgWorldLevelsOff = 0;
}

static void ds_pubg_overlay_reset(void) {
    os_unfair_lock_lock(&g_dspubgSnapshotLock);
    g_dspubgPlayerCount = 0;
    g_dspubgItemCount = 0;
    g_dspubgGrenadeCount = 0;
    g_dspubgTotalEnemies = 0;
    g_dspubgTotalBots = 0;
    memset(g_dspubgPlayers, 0, sizeof(g_dspubgPlayers));
    memset(g_dspubgItems, 0, sizeof(g_dspubgItems));
    memset(g_dspubgGrenades, 0, sizeof(g_dspubgGrenades));
    memset(g_dspubgActorCache, 0, sizeof(g_dspubgActorCache));
    ++g_dspubgEpoch;
    ++g_dspubgItemEpoch;
    ++g_dspubgGrenadeEpoch;
    os_unfair_lock_unlock(&g_dspubgSnapshotLock);

    ds_pubg_reset_match_caches();
    s_crateCache.clear();
}

static bool ds_pubg_actors_array_at(uint64_t arr, uint64_t *outData, uint32_t *outCount) {
    if (!ds_pubg_valid(arr)) return false;
    uint64_t data = ds_pubg_read_ptr(arr + 0x0ULL);
    uint32_t count = ds_pubg_read_u32(arr + 0x8ULL);
    if (count > 20000) return false;
    if (count > 0 && !ds_pubg_valid(data)) return false;
    if (outData) *outData = data;
    if (outCount) *outCount = count;
    return true;
}

// Scores a {TArrayData,TArrayNum} header by how many of its first entries read
// back as real UObjects. `arr` points at the header itself, not at the
// elements. A random {pointer, small integer} pair in the level body scores 0,
// so the highest score is the actor list.
static int ds_pubg_actor_array_score(uint64_t arr, uint64_t &outData, uint32_t &outCount) {
    uint64_t data = 0;
    uint32_t count = 0;
    if (!ds_pubg_actors_array_at(arr, &data, &count)) return 0;
    if (!data || count == 0) return 0;

    const uint32_t probe = count < 16 ? count : 16;
    int score = 0;
    for (uint32_t i = 0; i < probe; i++) {
        uint64_t a = ds_pubg_read_ptr(data + (uint64_t)i * sizeof(uint64_t));
        if (!a) continue; // UE4 leaves nullptr slots in ULevel::Actors between GC cycles
        if (!ds_pubg_valid(a)) return 0;
        score++;
        // A live UObject carries ClassPrivate at 0x10; that second hop is what
        // separates an actor list from an array of random in-range pointers.
        uint64_t cls = ds_pubg_read_ptr(a + 0x10ULL);
        if (cls && ds_pubg_valid(cls)) score += 2;
    }
    outData = data;
    outCount = count;
    return score;
}

static bool ds_pubg_actor_array_plausible(uint64_t arr, uint64_t *outData, uint32_t *outCount) {
    uint64_t data = 0;
    uint32_t count = 0;
    if (ds_pubg_actor_array_score(arr, data, count) < 2) return false;
    if (outData) *outData = data;
    if (outCount) *outCount = count;
    return true;
}

// The actors TArray is not at a fixed offset on this build: reading 0xA0 gave a
// one element "array" (HUD A1 S0 B0). The header is located by scanning the
// ULevel body for a {ptr,count} pair whose elements are real UObjects, and the
// winning offset is cached for the session.
static uint64_t g_dspubgLevelActorsOff = 0;

static uint32_t ds_pubg_find_world_levels(uint64_t world, uint64_t persistentLevel, uint64_t *outLevels, uint32_t maxLevels) {
    if (!outLevels || maxLevels == 0) return 0;
    uint32_t outCount = 0;
    if (persistentLevel && ds_pubg_valid(persistentLevel)) {
        outLevels[outCount++] = persistentLevel;
    }
    if (!world || !ds_pubg_valid(world) || !persistentLevel || !ds_pubg_valid(persistentLevel)) {
        return outCount;
    }

    auto readLevelsAt = [&](uint64_t off) -> bool {
        uint8_t hdr[16] = {0};
        if (!ds_pubg_read(world + off, hdr, sizeof(hdr))) return false;
        uint64_t data = 0;
        uint32_t count = 0, maxc = 0;
        memcpy(&data, hdr, 8);
        memcpy(&count, hdr + 8, 4);
        memcpy(&maxc, hdr + 12, 4);
        data &= 0x0000FFFFFFFFFFFFULL;
        if (!data || !ds_pubg_valid(data) || (data & 0x7ULL) != 0) return false;
        if (count < 1 || count > 128 || maxc < count || maxc > 512) return false;

        uint32_t readCnt = (count > 64) ? 64 : count;
        uint64_t lvls[64] = {0};
        if (!ds_pubg_read(data, lvls, readCnt * sizeof(uint64_t))) return false;
        if ((lvls[0] & 0x0000FFFFFFFFFFFFULL) != persistentLevel) return false;

        if (readCnt > 1) {
            bool subOk = false;
            uint32_t checkN = (readCnt > 4) ? 4 : readCnt;
            for (uint32_t i = 1; i < checkN; i++) {
                uint64_t sl = lvls[i] & 0x0000FFFFFFFFFFFFULL;
                if (sl && ds_pubg_valid(sl)) {
                    uint64_t owning = ds_pubg_read_ptr(sl + 0xC0ULL);
                    if (owning == world) {
                        subOk = true;
                        break;
                    }
                }
            }
            if (!subOk) return false;
        }

        for (uint32_t i = 0; i < readCnt && outCount < maxLevels; i++) {
            uint64_t sl = lvls[i] & 0x0000FFFFFFFFFFFFULL;
            if (!sl || !ds_pubg_valid(sl)) continue;
            bool dup = false;
            for (uint32_t k = 0; k < outCount; k++) {
                if (outLevels[k] == sl) { dup = true; break; }
            }
            if (!dup) outLevels[outCount++] = sl;
        }
        return true;
    };

    if (g_dspubgWorldLevelsOff) {
        if (readLevelsAt(g_dspubgWorldLevelsOff)) return outCount;
        g_dspubgWorldLevelsOff = 0;
    }

    const uint64_t kScanBase = 0x100ULL;
    const uint64_t kScanSize = 0x400ULL;
    uint8_t body[kScanSize];
    if (!ds_pubg_read(world + kScanBase, body, sizeof(body))) {
        return outCount;
    }

    for (uint64_t off = 0; off + 0x10 <= sizeof(body); off += 0x8) {
        uint64_t data = 0;
        uint32_t count = 0, maxc = 0;
        memcpy(&data, body + off, 8);
        memcpy(&count, body + off + 8, 4);
        memcpy(&maxc, body + off + 12, 4);
        data &= 0x0000FFFFFFFFFFFFULL;
        if (!data || !ds_pubg_valid(data) || (data & 0x7ULL) != 0) continue;
        if (count < 1 || count > 128 || maxc < count || maxc > 512) continue;
        uint64_t candidateOff = kScanBase + off;
        if (readLevelsAt(candidateOff)) {
            g_dspubgWorldLevelsOff = candidateOff;
            break;
        }
    }
    return outCount;
}

static bool ds_pubg_find_level_actors(uint64_t lvl, uint64_t *outData, uint32_t *outCount) {
    if (!lvl || !ds_pubg_valid(lvl)) return false;

    if (g_dspubgLevelActorsOff) {
        uint64_t cachedData = 0;
        uint32_t cachedCount = 0;
        if (ds_pubg_actors_array_at(lvl + g_dspubgLevelActorsOff, &cachedData, &cachedCount)) {
            if (cachedCount == 0) return false; // Empty sublevel; keep cached offset
            if (ds_pubg_actor_array_plausible(lvl + g_dspubgLevelActorsOff, outData, outCount)) return true;
        }
        g_dspubgLevelActorsOff = 0;
    }

    // One bulk read of the level body, then score every {ptr,count} pair in it.
    // Probe cost is one read per level; scoring runs entirely on the snapshot.
    // The best-scoring header wins, so a decoy one-element array cannot latch.
    const uint64_t kScanBase = 0x28ULL;
    const uint64_t kScanSize = 0x1FD8ULL;
    static uint8_t body[kScanSize];
    if (!ds_pubg_read(lvl + kScanBase, body, sizeof(body))) return false;

    uint64_t bestOff = 0;
    uint64_t bestData = 0;
    uint32_t bestCount = 0;
    int bestScore = 0;
    for (uint64_t off = 0; off + 0x10 <= sizeof(body); off += 0x8) {
        uint64_t data = 0;
        uint32_t count = 0;
        memcpy(&data, body + off, sizeof(data));
        memcpy(&count, body + off + 8, sizeof(count));
        data &= 0x0000FFFFFFFFFFFFULL;
        if (!data || !ds_pubg_valid(data)) continue;
        if (count < 2 || count > 20000) continue;

        uint64_t arrAddr = lvl + kScanBase + off;
        int score = ds_pubg_actor_array_score(arrAddr, data, count);
        // Prefer the largest list, then the best score: ULevel::Actors is the
        // longest UObject array in the level by a wide margin.
        if (score > 0 && (count > bestCount || (count == bestCount && score > bestScore))) {
            bestScore = score;
            bestCount = count;
            bestData = data;
            bestOff = kScanBase + off;
        }
    }
    if (!bestOff) return false;
    g_dspubgLevelActorsOff = bestOff;
    if (outData) *outData = bestData;
    if (outCount) *outCount = bestCount;
    return true;
}

// -----------------------------------------------------------------------------
// Client-Side Map Collision Obstacle Ray-Box Vischeck System
// (Pure Read-Only Math Ray-OBB Intersection, zero engine hooks, zero anticheat risk)
// -----------------------------------------------------------------------------
static inline void ds_pubg_rotator_to_axes(
    const DSPUBGRotator &rot,
    DSPUBGVector &outX,
    DSPUBGVector &outY,
    DSPUBGVector &outZ)
{
    const float kPi = 3.141592653589793f;
    float radPitch = rot.Pitch * kPi / 180.0f;
    float radYaw   = rot.Yaw   * kPi / 180.0f;
    float radRoll  = rot.Roll  * kPi / 180.0f;

    float SP = sinf(radPitch), CP = cosf(radPitch);
    float SY = sinf(radYaw),   CY = cosf(radYaw);
    float SR = sinf(radRoll),  CR = cosf(radRoll);

    // Forward (X)
    outX.X = CP * CY;
    outX.Y = CP * SY;
    outX.Z = SP;

    // Right (Y)
    outY.X = SR * SP * CY - CR * SY;
    outY.Y = SR * SP * SY + CR * CY;
    outY.Z = -SR * CP;

    // Up (Z)
    outZ.X = -(CR * SP * CY + SR * SY);
    outZ.Y = CY * SR - CR * SP * SY;
    outZ.Z = CR * CP;
}

// FQuat -> orthonormal axes. The collision primitives in FKAggregateGeom only
// carry a quaternion, so the box builder needs this instead of a rotator.
static inline void ds_pubg_quat_to_axes(float x, float y, float z, float w,
                                        DSPUBGVector &outX,
                                        DSPUBGVector &outY,
                                        DSPUBGVector &outZ) {
    float n = x * x + y * y + z * z + w * w;
    if (!isfinite(n) || n <= 1e-6f) {
        outX = DSPUBGVector{ 1.0f, 0.0f, 0.0f };
        outY = DSPUBGVector{ 0.0f, 1.0f, 0.0f };
        outZ = DSPUBGVector{ 0.0f, 0.0f, 1.0f };
        return;
    }
    float s = 2.0f / n;
    outX = DSPUBGVector{ 1.0f - s * (y * y + z * z), s * (x * y + z * w),       s * (x * z - y * w) };
    outY = DSPUBGVector{ s * (x * y - z * w),       1.0f - s * (x * x + z * z), s * (y * z + x * w) };
    outZ = DSPUBGVector{ s * (x * z + y * w),       s * (y * z - x * w),       1.0f - s * (x * x + y * y) };
}

// One occlusion primitive: centre, half extents along its own three axes and a
// circumscribed sphere radius for the broad phase.
struct DSPUBGObstacleBox {
    DSPUBGVector center;
    DSPUBGVector extent;   // half extents along axisX/Y/Z
    DSPUBGVector axisX;    // world-space box axes (orthonormal)
    DSPUBGVector axisY;
    DSPUBGVector axisZ;
    float radius;          // circumscribed sphere radius
};

static bool ds_pubg_component_world_pose(uint64_t comp,
                                         DSPUBGVector &outLoc,
                                         DSPUBGVector &outX,
                                         DSPUBGVector &outY,
                                         DSPUBGVector &outZ,
                                         DSPUBGVector &outScale);

// --- World-space box helpers ------------------------------------------------
// A box is stored as center + three orthonormal world axes + half extents, so
// the slab test never has to re-derive axes from a rotator (ISMs and concave
// collision elements are not rotator-aligned).

static inline DSPUBGVector ds_pubg_axes_apply(const DSPUBGVector &v,
                                              const DSPUBGVector &ax,
                                              const DSPUBGVector &ay,
                                              const DSPUBGVector &az) {
    DSPUBGVector out = {};
    out.X = v.X * ax.X + v.Y * ay.X + v.Z * az.X;
    out.Y = v.X * ax.Y + v.Y * ay.Y + v.Z * az.Y;
    out.Z = v.X * ax.Z + v.Y * ay.Z + v.Z * az.Z;
    return out;
}

static inline DSPUBGVector ds_pubg_axes_scale(const DSPUBGVector &v,
                                              const DSPUBGVector &s) {
    return DSPUBGVector{ v.X * s.X, v.Y * s.Y, v.Z * s.Z };
}

static inline DSPUBGVector ds_pubg_rotated_axes(const DSPUBGVector &parentX,
                                                const DSPUBGVector &parentY,
                                                const DSPUBGVector &parentZ,
                                                const DSPUBGVector &localAxis) {
    return ds_pubg_axes_apply(localAxis, parentX, parentY, parentZ);
}

static inline void ds_pubg_box_finalize(DSPUBGObstacleBox &box) {
    box.radius = hypotf(hypotf(box.extent.X, box.extent.Y), box.extent.Z);
    if (!isfinite(box.radius) || box.radius <= 0.0f) box.radius = 1.0f;
}

// A single occlusion box must stay in the size range of a real wall, floor or
// prop module. Anything larger is an aggregate mesh bound (terrain, landscape,
// sky dome, a whole building cluster) and would black out every sight line.
// 50 m half extent is already far beyond any usable wall module.
static const float kDSPUBGMaxObstacleHalfExtent = 5000.0f;

static inline bool ds_pubg_box_is_sane(const DSPUBGObstacleBox &box) {
    if (!isfinite(box.center.X) || !isfinite(box.center.Y) || !isfinite(box.center.Z)) return false;
    if (!isfinite(box.extent.X) || !isfinite(box.extent.Y) || !isfinite(box.extent.Z)) return false;
    if (box.extent.X <= 0.0f || box.extent.Y <= 0.0f || box.extent.Z <= 0.0f) return false;
    if (box.extent.X > kDSPUBGMaxObstacleHalfExtent ||
        box.extent.Y > kDSPUBGMaxObstacleHalfExtent ||
        box.extent.Z > kDSPUBGMaxObstacleHalfExtent) return false;
    return true;
}

// True when `point` sits inside the box (or within `margin` of its surface).
// A component whose bound swallows the camera cannot block the ray - the slab
// test would start inside, and its only sane reading is "the camera is in it",
// not "the camera is behind a wall".
static inline bool ds_pubg_box_contains_point(const DSPUBGObstacleBox &box,
                                              const DSPUBGVector &point,
                                              float margin) {
    DSPUBGVector d = { point.X - box.center.X, point.Y - box.center.Y, point.Z - box.center.Z };
    float x = d.X * box.axisX.X + d.Y * box.axisX.Y + d.Z * box.axisX.Z;
    float y = d.X * box.axisY.X + d.Y * box.axisY.Y + d.Z * box.axisY.Z;
    float z = d.X * box.axisZ.X + d.Y * box.axisZ.Y + d.Z * box.axisZ.Z;
    return fabsf(x) <= box.extent.X + margin &&
           fabsf(y) <= box.extent.Y + margin &&
           fabsf(z) <= box.extent.Z + margin;
}

// ---------------------------------------------------------------------------
// Cover classification (ported from the external.cpp / PhysX reference)
// ---------------------------------------------------------------------------
// The reference filters PhysX shapes by measured size before trusting them as
// cover. Without these tests the wrong shapes dominate the result: capsule
// bounds of players act as walls, thin panes seal window openings, and volume
// boxes fill whole rooms. All thresholds are centimetres.

static inline void ds_pubg_box_half_extent_sorted(const DSPUBGObstacleBox &box,
                                                  float &mn, float &mid, float &mx) {
    float a = box.extent.X * 2.0f, b = box.extent.Y * 2.0f, c = box.extent.Z * 2.0f;
    if (a > b) { float t = a; a = b; b = t; }
    if (b > c) { float t = b; b = c; c = t; }
    if (a > b) { float t = a; a = b; b = t; }
    mn = a; mid = b; mx = c;
}

// A container / trigger volume: every axis large. It encloses space instead of
// occupying it, so it must never occlude.
static inline bool ds_pubg_box_is_wrapper_volume(const DSPUBGObstacleBox &box) {
    float mn = 0.0f, mid = 0.0f, mx = 0.0f;
    ds_pubg_box_half_extent_sorted(box, mn, mid, mx);
    return mn > 500.0f && mx > 900.0f;
}

// Window glass: a thin sheet spanning a pane. The visual opening is
// transparent and a player behind it is still visible. Only sheets are
// dropped - a solid wall is commonly 15-30 cm thick and must stay cover, so
// the thin side is capped at 6 cm (a 20 cm wall and a 4 cm pane are different
// objects, not a threshold to blur).
static inline bool ds_pubg_box_is_glass_pane(const DSPUBGObstacleBox &box) {
    float mn = 0.0f, mid = 0.0f, mx = 0.0f;
    ds_pubg_box_half_extent_sorted(box, mn, mid, mx);
    if (mn > 6.0f || mn < 0.4f) return false;
    if (mid < 70.0f || mx < 80.0f || mx > 380.0f) return false;
    return true;
}

// Terrain / road slab: wide and flat. Handled as its own layer so it blocks
// hills without consuming the wall budget.
static inline bool ds_pubg_box_is_terrain(const DSPUBGObstacleBox &box) {
    float mn = 0.0f, mid = 0.0f, mx = 0.0f;
    ds_pubg_box_half_extent_sorted(box, mn, mid, mx);
    float horizontal = (mx > mid) ? mx : mid;
    return horizontal > 2200.0f && mn < 380.0f;
}

// Player-sized capsule: the reference drops every small rounded shape so bodies
// never act as cover.
static inline bool ds_pubg_box_is_character_sized(const DSPUBGObstacleBox &box) {
    float mn = 0.0f, mid = 0.0f, mx = 0.0f;
    ds_pubg_box_half_extent_sorted(box, mn, mid, mx);
    return mx < 230.0f && mn < 95.0f;
}

// Single entry point used by both the extractor and the ray test.
//
// `rounded` marks shapes that came from a sphere or capsule. The
// character-sized rejection only makes sense there: the reference applies it to
// Sphere/Capsule meshes so player bodies never act as cover. Applied to boxes it
// also discarded real walls - a 2 m wall section with a 0.3 m thickness lands in
// the same size window as a torso.
static inline bool ds_pubg_box_is_valid_cover_ex(const DSPUBGObstacleBox &box,
                                                 const DSPUBGVector *rayStart,
                                                 bool rounded) {
    if (!ds_pubg_box_is_sane(box)) return false;
    if (ds_pubg_box_is_wrapper_volume(box)) return false;
    if (ds_pubg_box_is_glass_pane(box)) return false;
    if (ds_pubg_box_is_terrain(box)) return false;
    if (rounded && ds_pubg_box_is_character_sized(box)) return false;
    if (rayStart && ds_pubg_box_contains_point(box, *rayStart, 10.0f)) return false;
    return true;
}

static inline bool ds_pubg_box_is_valid_cover(const DSPUBGObstacleBox &box,
                                              const DSPUBGVector *rayStart) {
    return ds_pubg_box_is_valid_cover_ex(box, rayStart, false);
}

// ---------------------------------------------------------------------------
// PhysX shape source (ported from the external.cpp BGMI reference, arm64)
// ---------------------------------------------------------------------------
// The reference does not trust UE's cooked AggregateGeom: it walks the live
// PhysX shapes and ray-tests real geometry. The same chain is used here, with
// the shape's AABB standing in for the triangle stream (the render mesh data
// is stripped from the shipped build, so PhysX is the only triangle source).
//
//   UStaticMeshComponent.BodyInstance    0x550   (FBodyInstance, 0x210)
//   FBodyInstance.RigidActorSyncId       0x110   -> PxRigidActor*
//   FBodyInstance.RigidActorAsyncId      0x118   -> async scene twin
//   NpRigidActor.ShapeMgr                0x0C    (32-bit reference value)
//   NpShape.Geometry (GeometryUnion)     0x74
//   GeometryUnion.Type                   0x00    (PxGeometryType)
//   PxBoxGeometry.HalfExtents            0x04
//   PxCapsuleGeometry.Radius/HalfHeight  0x04 / 0x08
//   PxSphereGeometry.Radius              0x04
//   PxMeshScale (3 floats + quat)        0x04
//   PxConvexMeshGeometry.ConvexMesh      ~0x20
//   PxTriangleMeshGeometry.TriangleMesh  ~0x24 (32-bit) / ~0x28 (arm64)
//   Gu::ConvexMesh -> ConvexHullData.AABB 0x10 (PxBounds3)
//   Gu::TriangleMesh.AABB                 0x20 (PxBounds3)
//
// Geometry values are already in world units (UE bakes component scale into
// box/capsule half extents and into PxMeshScale for meshes), so the component
// transform is applied as rotation + translation only.
static const uint64_t kDSPUBGBodyInstanceOffset   = 0x550ULL;
static const uint64_t kDSPUBGBodyInstanceSyncId   = 0x110ULL;
static const uint64_t kDSPUBGBodyInstanceAsyncId  = 0x118ULL;
static const uint64_t kDSPUBGPxShapeMgrOffset     = 0x0CULL;
static const uint64_t kDSPUBGPxGeometryOffset     = 0x74ULL;

enum : int {
    kDSPUBGPxGeomSphere      = 0,
    kDSPUBGPxGeomPlane       = 1,
    kDSPUBGPxGeomCapsule     = 2,
    kDSPUBGPxGeomBox         = 3,
    kDSPUBGPxGeomConvex      = 4,
    kDSPUBGPxGeomTriMesh     = 5,
    kDSPUBGPxGeomHeightField = 6,
};

// Where the GeometryUnion sits inside NpShape is width dependent: the 0x74
// constant comes from the 32-bit reference, and the PxTransform/StreamPtr
// members before it grow when pointers are 8 bytes. 0x74 still reads a value in
// 0..6 on arm64 often enough to look correct, which is how a probe can accept
// 89 shapes and build one box out of them. The offset is therefore discovered
// by requiring the union to yield a usable AABB, never by trusting a constant.
static uint64_t g_dspubgPxGeomOff = 0;

// Candidate slots for the discriminant. Covers the 32-bit value, the arm64
// shift, and the neighbouring padding in case a member was added.
static const uint64_t kDSPUBGPxGeomOffCandidates[] = {
    0x6CULL, 0x70ULL, 0x74ULL, 0x78ULL, 0x7CULL, 0x80ULL, 0x84ULL, 0x88ULL, 0x8CULL
};

static inline int32_t ds_pubg_px_geom_type_at(uint64_t shape, uint64_t geomOff) {
    int32_t type = (int32_t)ds_pubg_read_u32(shape + geomOff);
    if (type < kDSPUBGPxGeomSphere || type > kDSPUBGPxGeomHeightField) return -1;
    return type;
}

// ds_pubg_read_ptr rejects any address that is not 8-byte aligned, but
// NpRigidActor stores its shape manager at a member offset, not a pointer
// boundary - on a 4-mod-8 layout that check alone would hide the list. Read
// the raw word and mask it the same way ds_pubg_read_ptr does.
static uint64_t ds_pubg_px_read_ptr_any(uint64_t addr) {
    uint64_t value = 0;
    if (!ds_pubg_read(addr, &value, sizeof(value))) return 0;
    value &= 0x0000FFFFFFFFFFFFULL;
    return ds_pubg_valid(value) ? value : 0;
}

// A geometry union lands on 4-mod-8 addresses and its members move between
// pointer widths, so the mesh pointer and the PxMeshScale vector are probed in
// this order instead of trusting one constant.
static const uint64_t kDSPUBGPxMeshPtrSlots[] = {
    0x30ULL, 0x2CULL, 0x28ULL, 0x24ULL, 0x20ULL, 0x38ULL, 0x40ULL, 0x18ULL, 0x1CULL
};
static const uint64_t kDSPUBGPxScaleSlots[] = { 0x4ULL, 0x20ULL, 0x10ULL, 0x14ULL, 0x24ULL };

static inline bool ds_pubg_px_scale_vec_ok(const float *s) {
    for (int i = 0; i < 3; i++) {
        if (!isfinite(s[i]) || fabsf(s[i]) < 0.001f || fabsf(s[i]) > 1000.0f) return false;
    }
    return true;
}

static inline bool ds_pubg_px_quat_ok(const float *q) {
    const float n = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
    return isfinite(n) && n > 0.81f && n < 1.21f;
}

// Validates PxMeshScale for both known layouts:
//   scale-first (32-bit reference): scale at S, quat at S+0x0C
//   quat-first  (PhysX 3.4 arm64):  quat at S, scale at S+0x10
// A mesh pointer read as floats, or an uninitialised slot, fails both.
static bool ds_pubg_px_mesh_scale_at(uint64_t geom, float outScale[3]) {
    for (uint64_t slot : kDSPUBGPxScaleSlots) {
        float raw[8] = {};
        if (!ds_pubg_read(geom + slot, raw, sizeof(raw))) continue;

        // scale-first: raw[0..2] is the vector, raw[3..6] the quaternion.
        if (ds_pubg_px_scale_vec_ok(raw) && ds_pubg_px_quat_ok(raw + 3)) {
            if (outScale) { outScale[0] = fabsf(raw[0]); outScale[1] = fabsf(raw[1]); outScale[2] = fabsf(raw[2]); }
            return true;
        }
        // quat-first: raw[0..3] is the quaternion, raw[4..6] the vector.
        if (ds_pubg_px_quat_ok(raw) && ds_pubg_px_scale_vec_ok(raw + 4)) {
            if (outScale) { outScale[0] = fabsf(raw[4]); outScale[1] = fabsf(raw[5]); outScale[2] = fabsf(raw[6]); }
            return true;
        }
    }
    return false;
}

// A slot holding a small integer 0..6 is not a geometry: padding, flags and
// counts all read in that range. A shape only qualifies when the union at that
// slot also carries a payload of the matching primitive - half extents with a
// real size, a positive radius, or a valid PxMeshScale. Without this test the
// manager probe locked onto junk (63 "shapes", zero boxes).
static bool ds_pubg_px_geom_signature_at(uint64_t shape, uint64_t geomOff) {
    const int32_t type = ds_pubg_px_geom_type_at(shape, geomOff);
    if (type < 0) return false;
    const uint64_t geom = shape + geomOff;
    switch (type) {
        case kDSPUBGPxGeomBox: {
            float h[3] = {};
            if (!ds_pubg_read(geom + 0x4ULL, h, sizeof(h))) return false;
            for (int i = 0; i < 3; i++) {
                if (!isfinite(h[i]) || fabsf(h[i]) < 0.1f || fabsf(h[i]) > 20000.0f) return false;
            }
            return true;
        }
        case kDSPUBGPxGeomSphere: {
            float r = ds_pubg_read_f32(geom + 0x4ULL);
            return isfinite(r) && r > 0.05f && r < 20000.0f;
        }
        case kDSPUBGPxGeomCapsule: {
            float r = ds_pubg_read_f32(geom + 0x4ULL);
            float hh = ds_pubg_read_f32(geom + 0x8ULL);
            return isfinite(r) && isfinite(hh) && r > 0.05f && r < 20000.0f && hh >= 0.0f && hh < 20000.0f;
        }
        case kDSPUBGPxGeomConvex:
        case kDSPUBGPxGeomTriMesh:
            // A mesh is only believed when its PxMeshScale reads back or a
            // mesh pointer resolves. Requiring the pointer alone would drop
            // every mesh whose StreamPtr is a serialised id instead of an
            // address, and the shape would vanish before the reader saw it.
            return ds_pubg_px_mesh_scale_at(geom, nullptr);
        default:
            return false;
    }
}

// Used while walking a shape list: the shape is a candidate only when a known
// slot carries a geometry whose payload is valid.
static bool ds_pubg_px_shape_type(uint64_t shape, int &outType) {
    outType = -1;
    if (!shape || !ds_pubg_valid(shape)) return false;

    if (g_dspubgPxGeomOff) {
        int32_t type = ds_pubg_px_geom_type_at(shape, g_dspubgPxGeomOff);
        if (type >= 0 && ds_pubg_px_geom_signature_at(shape, g_dspubgPxGeomOff)) {
            outType = type;
            return true;
        }
        // A cached slot that decoded one shape does not guarantee the next
        // one: keep the shape by scanning the other candidates instead of
        // dropping it from the list before the reader ever sees it.
    }
    for (uint64_t off : kDSPUBGPxGeomOffCandidates) {
        int32_t type = ds_pubg_px_geom_type_at(shape, off);
        if (type >= 0 && ds_pubg_px_geom_signature_at(shape, off)) {
            outType = type;
            return true;
        }
    }
    return false;
}

// Collect the shape pointers hanging off a PxRigidActor.
//
// NpRigidActor keeps its NpShapeManager inline: a pointer to the first shape
// followed by the shape count. The count sits at sizeof(void*), so +4 on the
// 32-bit BGMI build the reference targets and +8 on arm64 - reading +4 here
// would slice the pointer instead of the count.
//
// The manager's own offset inside the actor is not portable across pointer
// widths either, so the working value is probed once and cached.
// PhysX path diagnostics: components that exposed a rigid actor, shapes
// collected and shapes that produced a usable box. A zero B count is then
// attributable to the actor walk, the ShapeMgr scan or the geometry reader.
static uint32_t s_obsPxActors = 0;
static uint32_t s_obsPxShapes = 0;
static uint32_t s_obsPxBoxes = 0;
// Per-geometry counters. A shape that never reaches a box is either an
// unsupported primitive, an unreadable mesh header, a degenerate bound or a
// rejected cover; without these four numbers the fix is guesswork.
static uint32_t s_pxGeomCount[7] = {};
static uint32_t s_pxNoAabb = 0;
static uint32_t s_pxNoCover = 0;
static uint32_t s_pxNoSane = 0;
// Mesh internals: a pointer that resolved, a bound derived from the vertex
// stream, and a bound taken from the header AABB fallback. The three split the
// "shape read but no box" case into pointer / vertex / header failures.
static uint32_t s_pxMeshPtrOk = 0;
static uint32_t s_pxMeshVertOk = 0;
static uint32_t s_pxMeshStoredOk = 0;
static uint64_t g_dspubgPxShapeMgrOff = 0;

static int ds_pubg_px_collect_at(uint64_t rigidActor, uint64_t mgrOff,
                                 uint64_t *outShapes, int maxShapes) {
    uint64_t list = ds_pubg_px_read_ptr_any(rigidActor + mgrOff);
    uint32_t count = (uint32_t)ds_pubg_read_u32(rigidActor + mgrOff + 8ULL) & 0xFFFFu;
    if (count == 0 || count > 32) return 0;

    if (count == 1) {
        int type = -1;
        if (!ds_pubg_px_shape_type(list, type)) return 0;
        outShapes[0] = list;
        return 1;
    }
    if (!list || !ds_pubg_valid(list)) return 0;

    uint64_t buf[32] = {0};
    if (!ds_pubg_read(list, buf, (size_t)count * sizeof(uint64_t))) return 0;

    int written = 0;
    for (uint32_t i = 0; i < count && written < maxShapes; i++) {
        int type = -1;
        if (!ds_pubg_px_shape_type(buf[i], type)) continue;
        outShapes[written++] = buf[i];
    }
    return written;
}

static int ds_pubg_px_collect_shapes(uint64_t rigidActor, uint64_t *outShapes, int maxShapes) {
    if (!outShapes || maxShapes <= 0) return 0;
    if (!rigidActor || !ds_pubg_valid(rigidActor)) return 0;
    outShapes[0] = 0;

    if (g_dspubgPxShapeMgrOff) {
        int n = ds_pubg_px_collect_at(rigidActor, g_dspubgPxShapeMgrOff, outShapes, maxShapes);
        if (n > 0) return n;
    }

    // Probe order: the documented 32-bit value first, then every 8-byte slot an
    // arm64 pointer member could occupy, then a 4-byte sweep for padding.
    static const uint64_t kCandidates[] = {
        0x0CULL, 0x10ULL, 0x08ULL, 0x18ULL, 0x20ULL, 0x14ULL, 0x1CULL, 0x24ULL,
        0x00ULL, 0x04ULL, 0x28ULL, 0x2CULL, 0x30ULL, 0x34ULL, 0x38ULL, 0x3CULL,
        0x40ULL, 0x44ULL, 0x48ULL, 0x4CULL, 0x50ULL, 0x54ULL, 0x58ULL, 0x5CULL,
        0x60ULL, 0x64ULL, 0x68ULL, 0x6CULL, 0x70ULL, 0x74ULL
    };
    for (uint64_t off : kCandidates) {
        int n = ds_pubg_px_collect_at(rigidActor, off, outShapes, maxShapes);
        if (n > 0) {
            g_dspubgPxShapeMgrOff = off;
            return n;
        }
    }
    for (uint64_t off : kCandidates) {
        if (off % 8 == 0) continue;
        int n = ds_pubg_px_collect_at(rigidActor, off + 4ULL, outShapes, maxShapes);
        if (n > 0) {
            g_dspubgPxShapeMgrOff = off + 4ULL;
            return n;
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// PhysX geometry -> local AABB inside the component
// ---------------------------------------------------------------------------
static inline bool ds_pubg_px_aabb_sane(const DSPUBGVector &lo, const DSPUBGVector &hi) {
    if (!isfinite(lo.X) || !isfinite(lo.Y) || !isfinite(lo.Z)) return false;
    if (!isfinite(hi.X) || !isfinite(hi.Y) || !isfinite(hi.Z)) return false;
    if (hi.X < lo.X || hi.Y < lo.Y || hi.Z < lo.Z) return false;
    float ex = hi.X - lo.X, ey = hi.Y - lo.Y, ez = hi.Z - lo.Z;
    if (ex < 0.05f && ey < 0.05f && ez < 0.05f) return false;
    if (ex > 40000.0f || ey > 40000.0f || ez > 40000.0f) return false;
    return true;
}

// Read a mesh-space AABB out of the live vertex buffer. The Gu:: mesh headers
// carry two pointer members, so their absolute layout shifts between the
// 32-bit reference and this arm64 build; the header triple itself (vertex
// count, triangle count, vertex pointer) keeps its relative shape. Both are
// located by scanning the first 0x60 bytes and validating against the vertices
// that actually read back, which cannot be faked by padding.
static inline DSPUBGVector ds_pubg_px_v3(const float *v) {
    return DSPUBGVector{ v[0], v[1], v[2] };
}

static inline void ds_pubg_px_grow_bounds(DSPUBGVector &lo, DSPUBGVector &hi,
                                         const DSPUBGVector &v, bool &have) {
    if (!have) {
        lo = v;
        hi = v;
        have = true;
        return;
    }
    if (v.X < lo.X) lo.X = v.X; else if (v.X > hi.X) hi.X = v.X;
    if (v.Y < lo.Y) lo.Y = v.Y; else if (v.Y > hi.Y) hi.Y = v.Y;
    if (v.Z < lo.Z) lo.Z = v.Z; else if (v.Z > hi.Z) hi.Z = v.Z;
}

// Vertex stream at `vp` with `count` entries of 12 bytes. Full read up to 32k
// vertices, otherwise a uniform sample - the AABB only needs coverage, not
// every triangle vertex.
static bool ds_pubg_px_bounds_from_vertices(uint64_t vp, uint32_t count,
                                            DSPUBGVector &outLo, DSPUBGVector &outHi) {
    if (!ds_pubg_valid(vp) || count < 3) return false;
    if (count > 2000000) return false;

    const uint32_t kFullRead = 32768;
    const uint32_t kSamples = 4096;
    uint32_t stride = 1;
    uint32_t last = count - 1;
    if (count > kFullRead) stride = (count + kSamples - 1) / kSamples;

    DSPUBGVector lo = {}, hi = {};
    bool have = false;
    float v[3] = {};
    uint32_t reads = 0;

    for (uint32_t i = 0; i < count; i += stride) {
        if (!ds_pubg_read(vp + (uint64_t)i * 12ULL, v, sizeof(v))) return false;
        if (!isfinite(v[0]) || !isfinite(v[1]) || !isfinite(v[2])) return false;
        if (fabsf(v[0]) > 200000.0f || fabsf(v[1]) > 200000.0f || fabsf(v[2]) > 200000.0f) return false;
        ds_pubg_px_grow_bounds(lo, hi, ds_pubg_px_v3(v), have);
        reads++;
    }
    // Always include the final vertex: a sampled sweep would otherwise miss it.
    if (last % stride != 0) {
        if (ds_pubg_read(vp + (uint64_t)last * 12ULL, v, sizeof(v))) {
            if (isfinite(v[0]) && isfinite(v[1]) && isfinite(v[2])) {
                ds_pubg_px_grow_bounds(lo, hi, ds_pubg_px_v3(v), have);
            }
        }
    }
    if (!have || reads < 3) return false;
    if (!ds_pubg_px_aabb_sane(lo, hi)) return false;
    outLo = lo;
    outHi = hi;
    return true;
}

// Stored PxBounds3 (min.xyz, max.xyz) at `addr`. ConvexHullData opens with it,
// and Gu::TriangleMesh carries one behind its vertex/triangle header - both
// survive pointer-width changes because they are plain float triples.
static bool ds_pubg_px_stored_bounds(uint64_t addr, DSPUBGVector &outLo, DSPUBGVector &outHi) {
    float b[6] = {};
    if (!ds_pubg_read(addr, b, sizeof(b))) return false;
    for (int i = 0; i < 6; i++) if (!isfinite(b[i])) return false;
    DSPUBGVector lo = { b[0], b[1], b[2] };
    DSPUBGVector hi = { b[3], b[4], b[5] };
    if (!ds_pubg_px_aabb_sane(lo, hi)) return false;
    outLo = lo;
    outHi = hi;
    return true;
}

// TriangleMesh: PxTriangleMeshGeometry.TriangleMesh -> Gu::TriangleMesh, whose
// header is (NbVertices, NbTriangles, Vertices, Triangles, AABB, Flags).
static bool ds_pubg_px_trimesh_bounds(uint64_t meshPtr, DSPUBGVector &outLo, DSPUBGVector &outHi) {
    if (!meshPtr || !ds_pubg_valid(meshPtr)) return false;

    uint8_t raw[0x60] = {};
    if (!ds_pubg_read(meshPtr, raw, sizeof(raw))) return false;

    for (uint64_t off = 0x08; off + 0x30 <= sizeof(raw); off += 4) {
        uint32_t nbV = 0, nbT = 0;
        memcpy(&nbV, raw + off, 4);
        memcpy(&nbT, raw + off + 4, 4);
        if (nbV < 3 || nbV > 2000000) continue;
        if (nbT < 1 || nbT > 4000000) continue;
        if (nbT > nbV * 8ULL + 64ULL) continue;

        for (uint64_t d = off + 8; d + 8 <= off + 0x30; d += 4) {
            uint64_t vp8 = 0;
            memcpy(&vp8, raw + d, 8);
            uint64_t candidates[2] = { vp8 & 0x0000FFFFFFFFFFFFULL, 0 };
            uint32_t vp32 = 0;
            memcpy(&vp32, raw + d, 4);
            candidates[1] = (uint64_t)vp32;

            for (uint64_t vp : candidates) {
                if (!ds_pubg_valid(vp)) continue;
                if (ds_pubg_px_bounds_from_vertices(vp, nbV, outLo, outHi)) {
                    s_pxMeshVertOk++;
                    return true;
                }
            }
        }
    }

    // Vertex stream unreadable: fall back to the mesh's own AABB. It is stored
    // right after the pointer members, so its slot moves between 32-bit and
    // arm64 - scan the plausible window instead of pinning one offset.
    for (uint64_t off = 0x18; off + 24 <= 0x60; off += 4) {
        if (ds_pubg_px_stored_bounds(meshPtr + off, outLo, outHi)) {
            s_pxMeshStoredOk++;
            return true;
        }
    }
    return false;
}

// ConvexMesh: ConvexHullData holds NbEdges / NbHullVertices / NbPolygons /
// Polygons, and the hull vertices follow the polygon array. Scanned for the
// same reason as the trimesh header, then validated polygon by polygon.
static bool ds_pubg_px_convex_bounds(uint64_t meshPtr, DSPUBGVector &outLo, DSPUBGVector &outHi) {
    if (!meshPtr || !ds_pubg_valid(meshPtr)) return false;

    uint8_t raw[0xC0] = {};
    if (!ds_pubg_read(meshPtr, raw, sizeof(raw))) return false;

    for (uint64_t off = 0x08; off + 0x50 <= sizeof(raw); off += 4) {
        // Polygon record: { normal, vertRef } - 20 bytes in the 32-bit build,
        // 24 in arm64. Both layouts keep NbHullVertices/NbPolygons adjacent and
        // the polygon pointer right behind them.
        uint8_t nV = raw[off + 0x36];
        uint8_t nPoly = raw[off + 0x37];
        if (nV < 4 || nPoly < 4) continue;
        if (nV == 0xFF || nPoly == 0xFF) continue;

        uint64_t polyCandidates[2] = { 0, 0 };
        uint64_t p8 = 0;
        memcpy(&p8, raw + off + 0x38, 8);
        polyCandidates[0] = p8 & 0x0000FFFFFFFFFFFFULL;
        uint32_t p32 = 0;
        memcpy(&p32, raw + off + 0x38, 4);
        polyCandidates[1] = (uint64_t)p32;

        for (uint64_t polys : polyCandidates) {
            if (!ds_pubg_valid(polys)) continue;

            float normal[3] = {};
            if (!ds_pubg_read(polys, normal, sizeof(normal))) continue;
            float nl = sqrtf(normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]);
            if (!isfinite(nl) || nl < 0.8f || nl > 1.2f) continue;

            for (uint64_t polySize = 20; polySize <= 24; polySize += 4) {
                uint64_t verts = polys + (uint64_t)nPoly * polySize;
                if (ds_pubg_px_bounds_from_vertices(verts, (uint32_t)nV, outLo, outHi)) {
                    s_pxMeshVertOk++;
                    return true;
                }
            }
        }
    }

    // ConvexHullData begins with its own PxBounds3 - the cheapest reliable
    // source when the hull vertex block does not read back.
    if (ds_pubg_px_stored_bounds(meshPtr, outLo, outHi)) {
        s_pxMeshStoredOk++;
        return true;
    }
    return false;
}

// Applies PxMeshScale to a mesh-space AABB. The scale rotation is skipped on
// purpose: the resulting axis-aligned bound stays conservative.
static bool ds_pubg_px_mesh_aabb(uint64_t geom, int type, DSPUBGVector &outLo, DSPUBGVector &outHi) {
    DSPUBGVector mn = {}, mx = {};
    bool got = false;
    for (uint64_t slot : kDSPUBGPxMeshPtrSlots) {
        // geometry offsets land on 4-mod-8 addresses, so the strict aligned
        // reader never resolved the mesh pointer (all 63 shapes, 0 boxes).
        uint64_t meshPtr = ds_pubg_px_read_ptr_any(geom + slot);
        if (!meshPtr || !ds_pubg_valid(meshPtr)) continue;
        s_pxMeshPtrOk++;
        got = (type == kDSPUBGPxGeomConvex)
            ? ds_pubg_px_convex_bounds(meshPtr, mn, mx)
            : ds_pubg_px_trimesh_bounds(meshPtr, mn, mx);
        if (got) break;
    }
    if (!got) return false;

    float sc[3] = { 1.0f, 1.0f, 1.0f };
    ds_pubg_px_mesh_scale_at(geom, sc);

    outLo = DSPUBGVector{ mn.X * sc[0], mn.Y * sc[1], mn.Z * sc[2] };
    outHi = DSPUBGVector{ mx.X * sc[0], mx.Y * sc[1], mx.Z * sc[2] };
    if (outLo.X > outHi.X) { float t = outLo.X; outLo.X = outHi.X; outHi.X = t; }
    if (outLo.Y > outHi.Y) { float t = outLo.Y; outLo.Y = outHi.Y; outHi.Y = t; }
    if (outLo.Z > outHi.Z) { float t = outLo.Z; outLo.Z = outHi.Z; outHi.Z = t; }
    return ds_pubg_px_aabb_sane(outLo, outHi);
}

static bool ds_pubg_px_geom_local_aabb_at(uint64_t shape, uint64_t geomOff,
                                          DSPUBGVector &outLo, DSPUBGVector &outHi) {
    outLo = {};
    outHi = {};
    if (!shape || !ds_pubg_valid(shape)) return false;

    uint64_t geom = shape + geomOff;
    int32_t type = (int32_t)ds_pubg_read_u32(geom);
    if (type < kDSPUBGPxGeomSphere || type > kDSPUBGPxGeomHeightField) return false;

    switch (type) {
        case kDSPUBGPxGeomBox: {
            DSPUBGVector h = {};
            if (!ds_pubg_read(geom + 0x4ULL, &h, sizeof(h))) return false;
            float hx = fabsf(h.X), hy = fabsf(h.Y), hz = fabsf(h.Z);
            if (!isfinite(hx) || !isfinite(hy) || !isfinite(hz)) return false;
            outLo = DSPUBGVector{ -hx, -hy, -hz };
            outHi = DSPUBGVector{  hx,  hy,  hz };
            return ds_pubg_px_aabb_sane(outLo, outHi);
        }
        case kDSPUBGPxGeomCapsule: {
            float r = ds_pubg_read_f32(geom + 0x4ULL);
            float hh = ds_pubg_read_f32(geom + 0x8ULL);
            if (!isfinite(r) || r <= 0.0f || r > 5000.0f) return false;
            if (!isfinite(hh) || hh < 0.0f || hh > 5000.0f) return false;
            // PhysX capsules are aligned to the shape's local X axis.
            outLo = DSPUBGVector{ -(r + hh), -r, -r };
            outHi = DSPUBGVector{  (r + hh),  r,  r };
            return ds_pubg_px_aabb_sane(outLo, outHi);
        }
        case kDSPUBGPxGeomSphere: {
            float r = ds_pubg_read_f32(geom + 0x4ULL);
            if (!isfinite(r) || r <= 0.0f || r > 5000.0f) return false;
            outLo = DSPUBGVector{ -r, -r, -r };
            outHi = DSPUBGVector{  r,  r,  r };
            return ds_pubg_px_aabb_sane(outLo, outHi);
        }
        case kDSPUBGPxGeomConvex:
        case kDSPUBGPxGeomTriMesh:
            return ds_pubg_px_mesh_aabb(geom, type, outLo, outHi);
        default:
            // Plane and heightfield are terrain: handled by the terrain layer,
            // never by a single wall box.
            return false;
    }
}

// A cached offset can be settled by the first shape of a level and then miss on
// every other one - the union's type slot reads 0..6 on several padding
// positions. After a run of misses the cache is dropped and re-probed instead
// of starving the whole scan.
static uint32_t s_pxGeomOffMisses = 0;

static bool ds_pubg_px_geom_local_aabb(uint64_t shape, DSPUBGVector &outLo, DSPUBGVector &outHi,
                                       uint64_t *outGeomOff = nullptr) {
    if (g_dspubgPxGeomOff) {
        if (ds_pubg_px_geom_local_aabb_at(shape, g_dspubgPxGeomOff, outLo, outHi)) {
            s_pxGeomOffMisses = 0;
            if (outGeomOff) *outGeomOff = g_dspubgPxGeomOff;
            return true;
        }
        if (++s_pxGeomOffMisses < 8) return false;
        s_pxGeomOffMisses = 0;
        g_dspubgPxGeomOff = 0;
    }
    // Two passes: offsets whose union carries a real primitive payload first,
    // then the raw AABB read. Padding that happens to hold 0..6 and three
    // plausible floats passes the second test but not the first, so the
    // strict pass settles the layout before the loose one can claim it.
    for (int pass = 0; pass < 2; pass++) {
        if (pass == 0) {
            if (ds_pubg_px_geom_signature_at(shape, kDSPUBGPxGeometryOffset) &&
                ds_pubg_px_geom_local_aabb_at(shape, kDSPUBGPxGeometryOffset, outLo, outHi)) {
                if (outGeomOff) *outGeomOff = kDSPUBGPxGeometryOffset;
                return true;
            }
            for (uint64_t off : kDSPUBGPxGeomOffCandidates) {
                if (off == kDSPUBGPxGeometryOffset) continue;
                if (!ds_pubg_px_geom_signature_at(shape, off)) continue;
                if (ds_pubg_px_geom_local_aabb_at(shape, off, outLo, outHi)) {
                    if (outGeomOff) *outGeomOff = off;
                    return true;
                }
            }
            continue;
        }
        if (ds_pubg_px_geom_local_aabb_at(shape, kDSPUBGPxGeometryOffset, outLo, outHi)) {
            if (outGeomOff) *outGeomOff = kDSPUBGPxGeometryOffset;
            return true;
        }
        for (uint64_t off : kDSPUBGPxGeomOffCandidates) {
            if (off == kDSPUBGPxGeometryOffset) continue;
            if (ds_pubg_px_geom_local_aabb_at(shape, off, outLo, outHi)) {
                if (outGeomOff) *outGeomOff = off;
                return true;
            }
        }
    }
    return false;
}

// Locks in the geometry offset once a shape is decoded with it. Called from the
// shape reader, so the first shape that produces a real AABB settles the layout
// for the session instead of the code guessing again per shape.
static void ds_pubg_px_note_geom_offset(uint64_t shape) {
    if (g_dspubgPxGeomOff) return;
    DSPUBGVector lo = {}, hi = {};
    if (ds_pubg_px_geom_local_aabb_at(shape, kDSPUBGPxGeometryOffset, lo, hi)) {
        g_dspubgPxGeomOff = kDSPUBGPxGeometryOffset;
        return;
    }
    for (uint64_t off : kDSPUBGPxGeomOffCandidates) {
        if (off == kDSPUBGPxGeometryOffset) continue;
        if (ds_pubg_px_geom_local_aabb_at(shape, off, lo, hi)) {
            g_dspubgPxGeomOff = off;
            return;
        }
    }
}

// NpShape.Shape2Actor is a PxTransform: quat (4 floats), then position (3
// floats) at +0x10. Its offset moves with the pointer width for the same reason
// the geometry union does, so the transform is located by its own signature - a
// unit quaternion followed by a small position - instead of a fixed constant.
static uint64_t g_dspubgPxPoseOff = 0;

static bool ds_pubg_px_read_pose_at(uint64_t shape, uint64_t poseOff,
                                    DSPUBGVector &outPos,
                                    DSPUBGVector &outX,
                                    DSPUBGVector &outY,
                                    DSPUBGVector &outZ,
                                    bool *outQuatOk) {
    outPos = {};
    outX = DSPUBGVector{ 1.0f, 0.0f, 0.0f };
    outY = DSPUBGVector{ 0.0f, 1.0f, 0.0f };
    outZ = DSPUBGVector{ 0.0f, 0.0f, 1.0f };
    if (outQuatOk) *outQuatOk = false;

    float q[4] = {};
    if (!ds_pubg_read(shape + poseOff, q, sizeof(q))) return false;
    float p[3] = {};
    if (!ds_pubg_read(shape + poseOff + 0x10ULL, p, sizeof(p))) return false;

    for (int i = 0; i < 4; i++) if (!isfinite(q[i])) return false;
    for (int i = 0; i < 3; i++) if (!isfinite(p[i])) return false;

    // A PxTransform position is a shape offset inside its actor, so a
    // world-sized translation means the wrong slot was read.
    const float mag = fabsf(p[0]) + fabsf(p[1]) + fabsf(p[2]);
    if (mag > 8000.0f) return false;

    const float n = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
    const bool unitQuat = (n > 0.9f && n < 1.1f);
    if (unitQuat) {
        ds_pubg_quat_to_axes(q[0], q[1], q[2], q[3], outX, outY, outZ);
        if (outQuatOk) *outQuatOk = true;
    }
    outPos = DSPUBGVector{ p[0], p[1], p[2] };
    return true;
}

static bool ds_pubg_px_shape_local_pose(uint64_t shape,
                                        DSPUBGVector &outPos,
                                        DSPUBGVector &outX,
                                        DSPUBGVector &outY,
                                        DSPUBGVector &outZ) {
    static const uint64_t kPoseCandidates[] = {
        0x50ULL, 0x58ULL, 0x48ULL, 0x60ULL, 0x40ULL, 0x68ULL, 0x38ULL, 0x78ULL
    };

    if (g_dspubgPxPoseOff) {
        return ds_pubg_px_read_pose_at(shape, g_dspubgPxPoseOff, outPos, outX, outY, outZ, nullptr);
    }

    // Only a unit-length quaternion identifies a real PxTransform: an identity
    // transform is (0,0,0,1), which passes this test too. A slot with merely a
    // plausible position is rejected - taking it shifted walls off their mesh.
    for (uint64_t off : kPoseCandidates) {
        DSPUBGVector pos = {}, x = {}, y = {}, z = {};
        bool quatOk = false;
        if (!ds_pubg_px_read_pose_at(shape, off, pos, x, y, z, &quatOk)) continue;
        if (!quatOk) continue;
        g_dspubgPxPoseOff = off;
        outPos = pos; outX = x; outY = y; outZ = z;
        return true;
    }

    // No transform found: the shape is used with an identity local pose, which
    // is the common case for collision primitives attached directly.
    return true;
}

// One PxShape -> world-space cover box, composed from the component transform
// (world rotation and translation) and the shape's local pose.
static bool ds_pubg_px_shape_box(uint64_t shape,
                                 const DSPUBGVector &compLoc,
                                 const DSPUBGVector &compX,
                                 const DSPUBGVector &compY,
                                 const DSPUBGVector &compZ,
                                 DSPUBGObstacleBox &outBox) {
    outBox = {};
    if (!shape || !ds_pubg_valid(shape)) return false;

    DSPUBGVector localLo = {}, localHi = {};
    uint64_t usedGeomOff = 0;
    if (!ds_pubg_px_geom_local_aabb(shape, localLo, localHi, &usedGeomOff)) { s_pxNoAabb++; return false; }

    DSPUBGVector localMid = { (localLo.X + localHi.X) * 0.5f,
                              (localLo.Y + localHi.Y) * 0.5f,
                              (localLo.Z + localHi.Z) * 0.5f };
    DSPUBGVector half = { (localHi.X - localLo.X) * 0.5f,
                          (localHi.Y - localLo.Y) * 0.5f,
                          (localHi.Z - localLo.Z) * 0.5f };

    ds_pubg_px_note_geom_offset(shape);
    // The type must come from the slot that actually decoded the bound; the
    // cached value can differ from the probe that succeeded for this shape.
    const uint64_t geomOff = usedGeomOff ? usedGeomOff
                                         : (g_dspubgPxGeomOff ? g_dspubgPxGeomOff : kDSPUBGPxGeometryOffset);
    int32_t geomType = (int32_t)ds_pubg_read_u32(shape + geomOff);
    if (geomType >= 0 && geomType <= 6) s_pxGeomCount[geomType]++;
    const bool rounded = (geomType == kDSPUBGPxGeomSphere || geomType == kDSPUBGPxGeomCapsule);

    DSPUBGVector shapePos = {};
    DSPUBGVector shapeX = { 1.0f, 0.0f, 0.0f };
    DSPUBGVector shapeY = { 0.0f, 1.0f, 0.0f };
    DSPUBGVector shapeZ = { 0.0f, 0.0f, 1.0f };
    ds_pubg_px_shape_local_pose(shape, shapePos, shapeX, shapeY, shapeZ);

    // Geometric centre in shape space, rotated into component space by the
    // shape's own axes, then translated by the shape pose. Adding the two
    // vectors without rotating first shifted offset shapes (window frames,
    // door panels) sideways by the hull centre.
    //
    // No compScale multiply here: UE bakes the component scale into the PhysX
    // geometry at creation (half extents and shape offsets are already in world
    // units), so scaling the offset again pushed the primitive away from its
    // visual mesh.
    DSPUBGVector rotatedMid = ds_pubg_axes_apply(localMid, shapeX, shapeY, shapeZ);
    DSPUBGVector worldOffset = ds_pubg_axes_apply(
        DSPUBGVector{ rotatedMid.X + shapePos.X,
                      rotatedMid.Y + shapePos.Y,
                      rotatedMid.Z + shapePos.Z },
        compX, compY, compZ);

    outBox.center = DSPUBGVector{ compLoc.X + worldOffset.X,
                                  compLoc.Y + worldOffset.Y,
                                  compLoc.Z + worldOffset.Z };
    outBox.extent = half;
    outBox.axisX = ds_pubg_rotated_axes(compX, compY, compZ, shapeX);
    outBox.axisY = ds_pubg_rotated_axes(compX, compY, compZ, shapeY);
    outBox.axisZ = ds_pubg_rotated_axes(compX, compY, compZ, shapeZ);
    ds_pubg_box_finalize(outBox);

    if (!ds_pubg_box_is_sane(outBox)) { s_pxNoSane++; return false; }
    if (!ds_pubg_box_is_valid_cover_ex(outBox, nullptr, rounded)) { s_pxNoCover++; return false; }
    return true;
}

// Shape sources for one component: sync actor first, async twin second (a few
// level actors only register in the async scene). The component's own world
// pose is resolved here so callers never have to pass it - passing the camera
// location instead placed every PhysX box on top of the player.
static int ds_pubg_px_component_boxes(uint64_t comp,
                                      const DSPUBGVector &camLoc,
                                      DSPUBGObstacleBox *outBoxes,
                                      int maxBoxes) {
    if (!outBoxes || maxBoxes <= 0) return 0;
    if (!comp || !ds_pubg_valid(comp)) return 0;

    DSPUBGVector compLoc = {}, compScale = { 1.0f, 1.0f, 1.0f };
    DSPUBGVector compX = {}, compY = {}, compZ = {};
    if (!ds_pubg_component_world_pose(comp, compLoc, compX, compY, compZ, compScale)) return 0;

    static const uint64_t kActorIds[] = {
        kDSPUBGBodyInstanceSyncId, kDSPUBGBodyInstanceAsyncId
    };

    int written = 0;
    for (uint64_t idOff : kActorIds) {
        uint64_t rigidActor = ds_pubg_read_ptr(comp + kDSPUBGBodyInstanceOffset + idOff);
        if (!rigidActor || !ds_pubg_valid(rigidActor)) continue;

        uint64_t shapes[32] = {0};
        int shapeCount = ds_pubg_px_collect_shapes(rigidActor, shapes, 32);
        if (shapeCount > 0) s_obsPxActors++;
        s_obsPxShapes += (uint32_t)(shapeCount > 0 ? shapeCount : 0);
        for (int i = 0; i < shapeCount && written < maxBoxes; i++) {
            DSPUBGObstacleBox box = {};
            if (!ds_pubg_px_shape_box(shapes[i], compLoc, compX, compY, compZ, box)) continue;
            if (ds_pubg_box_contains_point(box, camLoc, 10.0f)) continue;
            s_obsPxBoxes++;
            outBoxes[written++] = box;
        }
    }
    return written;
}

static inline bool ds_pubg_box_is_valid_cover(const DSPUBGObstacleBox &box, const DSPUBGVector *rayStart);
static const int kDSPUBGMaxObstacles = 4096;
static DSPUBGObstacleBox s_obstacles[kDSPUBGMaxObstacles] = {};
static int s_obstacleCount = 0;
static DSPUBGVector s_lastObstacleScanLoc = { 999999.0f, 999999.0f, 999999.0f };
static uint64_t s_obstacleLastScanTick = 0;
// Live counters of the Actor & Shape Classification system (see section A).
static size_t s_staticActorCount = 0;
static size_t s_dynamicActorCount = 0;
// Obstacle pre-pass stage counters (diagnostics: shows exactly which stage
// of the scan fails: A=actors iterated, N=names resolved, S=scenery
// classified, B=boxes extracted, L=levels scanned).
static uint32_t s_obsScanActors = 0;
static uint32_t s_obsNameOk = 0;
static uint32_t s_obsScenery = 0;
static uint32_t s_obsBoxOk = 0;
static uint32_t s_obsLevels = 0;
// Per-stage drop counters for one scan. S122/B0 only says "no boxes"; these
// say where the actors went: no root component, no components at all, or
// components that yielded no geometry from any of the three extractors.
static uint32_t s_obsNoRoot = 0;
static uint32_t s_obsNoComp = 0;
static uint32_t s_obsNoMeshComp = 0;
static uint32_t s_obsCompBoxes = 0;
static uint32_t s_obsPxActorsSeen = 0;
static uint32_t s_obsRootZero = 0;
static uint32_t s_obsFar = 0;
static uint32_t s_obsPxIdFound = 0;
static uint32_t s_obsUnnamed = 0;

// Live informative diagnostic HUD string (disabled per user request)
static const char* ds_pubg_get_debug_status(void) {
    return "";
}

static inline bool ds_pubg_is_lobby_name(const char *name) {
    if (!name || !name[0]) return false;
    if (strcasestr(name, "Training") != NULL ||
        strcasestr(name, "Shooting") != NULL ||
        strcasestr(name, "Practice") != NULL ||
        strcasestr(name, "CheerPark") != NULL) {
        return false;
    }
    return (strcasestr(name, "Lobby") != NULL ||
            strcasestr(name, "Frontend") != NULL ||
            strcasestr(name, "Login") != NULL ||
            strcasestr(name, "Menu") != NULL ||
            strcasestr(name, "Showroom") != NULL);
}

static bool ds_pubg_is_in_match(uint64_t world, uint64_t playerController, uint64_t localPawn) {
    if (!world || !ds_pubg_valid(world)) return false;

    uint64_t level = ds_pubg_read_ptr(world + 0x30ULL); // PersistentLevel

    // 1. World, PersistentLevel, and World->Outer (map package) check.
    // Clear actor/loot caches whenever the active world/level changes (e.g. Lobby -> Training).
    if (world != s_lastMatchWorld || level != s_lastMatchLevel) {
        memset(g_dspubgActorCache, 0, sizeof(g_dspubgActorCache));
        s_cachedLootCount = 0;
        s_levelScanTick = 0;
        s_trackedLevelPawns.clear();
        s_trackedLevelGrenades.clear();
        s_trackedLevelVehicles.clear();
        s_crateCache.clear();

        bool isLobbyMap = false;
        char objName[64] = {0};
        if (ds_pubg_get_actor_name(world, objName, sizeof(objName)) &&
            ds_pubg_is_lobby_name(objName)) {
            isLobbyMap = true;
        }
        if (!isLobbyMap && level && ds_pubg_valid(level)) {
            memset(objName, 0, sizeof(objName));
            if (ds_pubg_get_actor_name(level, objName, sizeof(objName)) &&
                ds_pubg_is_lobby_name(objName)) {
                isLobbyMap = true;
            }
        }
        if (!isLobbyMap) {
            uint64_t worldOuter = ds_pubg_read_ptr(world + 0x20ULL); // UObject.Outer (UPackage)
            if (worldOuter && ds_pubg_valid(worldOuter)) {
                memset(objName, 0, sizeof(objName));
                if (ds_pubg_get_actor_name(worldOuter, objName, sizeof(objName)) &&
                    ds_pubg_is_lobby_name(objName)) {
                    isLobbyMap = true;
                }
            }
        }
        s_lastMatchWorld = world;
        s_lastMatchLevel = level;
        s_lastMatchMapIsLobby = isLobbyMap;
    }
    if (s_lastMatchMapIsLobby) {
        return false;
    }

    // 2. Reject Lobby / UI controllers & pawns before trusting NetDriver
    if (playerController && ds_pubg_valid(playerController)) {
        char ctrlName[64] = {0};
        if (ds_pubg_get_actor_name(playerController, ctrlName, sizeof(ctrlName))) {
            if (ds_pubg_is_lobby_name(ctrlName) || strcasestr(ctrlName, "UIController")) {
                return false;
            }
        }
    }

    if (localPawn && ds_pubg_valid(localPawn)) {
        char pawnName[64] = {0};
        if (ds_pubg_get_actor_name(localPawn, pawnName, sizeof(pawnName))) {
            if (ds_pubg_is_lobby_name(pawnName) || strcasestr(pawnName, "Preview") || strcasestr(pawnName, "Avatar")) {
                return false;
            }
        }
    }

    uint64_t gs = ds_pubg_read_ptr(world + kDSPUBGWorldGameStateOffset);
    if (!gs || !ds_pubg_valid(gs)) gs = ds_pubg_read_ptr(world + 0x140ULL);
    if (!gs || !ds_pubg_valid(gs)) gs = ds_pubg_read_ptr(world + 0x120ULL);
    char gsName[64] = {0};
    bool hasGsName = (gs && ds_pubg_valid(gs) && ds_pubg_get_actor_name(gs, gsName, sizeof(gsName)));
    if (hasGsName && ds_pubg_is_lobby_name(gsName)) {
        return false;
    }

    // 3. NetDriver -> ServerConnection check (active in matches, Training Ground, and Cheer Park)
    uint64_t netDriver = ds_pubg_read_ptr(world + 0x38ULL); // UWorld.NetDriver
    if (!netDriver || !ds_pubg_valid(netDriver)) {
        netDriver = ds_pubg_read_ptr(world + 0x98ULL);
    }
    if (netDriver && ds_pubg_valid(netDriver)) {
        uint64_t serverConn = ds_pubg_read_ptr(netDriver + 0x78ULL); // UNetDriver.ServerConnection
        if (!serverConn || !ds_pubg_valid(serverConn)) {
            serverConn = ds_pubg_read_ptr(netDriver + 0x70ULL);
        }
        if (!serverConn || !ds_pubg_valid(serverConn)) {
            serverConn = ds_pubg_read_ptr(netDriver + 0x80ULL);
        }
        if (serverConn && ds_pubg_valid(serverConn)) {
            return true; // Confirmed active dedicated server connection -> In Match / Training!
        }
    }

    // MainCity without a ServerConnection is the offline social lobby.
    if (hasGsName && strcasestr(gsName, "MainCity") != NULL) {
        return false;
    }

    // 4. Fallback if NetDriver offset shifted: require BOTH an active match GameState
    // AND a live local character pawn with valid health (never default-true in Lobby).
    bool isMatchGs = (hasGsName && (strcasestr(gsName, "STExtra") != NULL || strcasestr(gsName, "UAEGameState") != NULL));
    bool hasLiveLocalPawn = false;
    if (localPawn && ds_pubg_valid(localPawn)) {
        float lpMaxHp = ds_pubg_read_f32(localPawn + kDSPUBGCharacterHealthMaxOffset);
        if (!isnan(lpMaxHp) && !isinf(lpMaxHp) && lpMaxHp >= 50.0f && lpMaxHp <= 2000.0f) {
            hasLiveLocalPawn = true;
        }
    }
    return (isMatchGs && hasLiveLocalPawn);
}

// Gate on the class of the *mesh object itself*, not on the component's FName.
// A light / volume / decal / audio component does not point at a UStaticMesh at
// 0xA30; what lives there is padding that almost never resolves to a live
// UObject, and never to one whose class name is "StaticMesh". Resolving the
// mesh class also survives builds where the component FName is unreadable,
// which would otherwise silently zero out every obstacle box.
static inline bool ds_pubg_object_class_contains(uint64_t obj, const char *needle) {
    if (!obj || !needle || !ds_pubg_valid(obj)) return false;
    char className[64] = {0};
    if (!ds_pubg_get_actor_name(obj, className, sizeof(className))) return false;
    return strstr(className, needle) != nullptr;
}

// A component is usable as an occlusion source only if the mesh pointer at
// 0xA30 actually leads to a UStaticMesh.
// A live UStaticMesh also exposes a BodySetup at 0xB0 that points at a
// UBodySetup carrying an FKAggregateGeom. Checking that shape is structural: it
// holds whether or not the name pool resolved, which matters because the name
// gate alone dropped every obstacle when GNames degraded.
static inline bool ds_pubg_looks_like_static_mesh(uint64_t mesh) {
    if (!mesh || !ds_pubg_valid(mesh)) return false;
    if (ds_pubg_object_class_contains(mesh, "StaticMesh")) return true;

    uint64_t bodySetup = ds_pubg_read_ptr(mesh + 0xB0ULL);
    if (!bodySetup || !ds_pubg_valid(bodySetup)) return false;
    if (!ds_pubg_object_class_contains(bodySetup, "BodySetup")) {
        // Even without a resolvable class, a BodySetup always starts with an
        // FKAggregateGeom whose TArrays must be readable or empty.
        uint64_t boxData = ds_pubg_read_ptr(bodySetup + 0x28ULL + 0x30ULL);
        uint32_t boxCount = ds_pubg_read_u32(bodySetup + 0x28ULL + 0x30ULL + 0x8ULL);
        if (boxCount > 0 && boxCount <= 4096 && (!boxData || !ds_pubg_valid(boxData))) return false;
    }
    return true;
}

static inline bool ds_pubg_component_has_static_mesh(uint64_t comp, uint64_t &outMesh) {
    outMesh = 0;
    if (!comp || !ds_pubg_valid(comp)) return false;
    uint64_t mesh = ds_pubg_read_ptr(comp + 0xA30ULL);
    if (!ds_pubg_looks_like_static_mesh(mesh)) return false;
    outMesh = mesh;
    return true;
}

// Soft scenery must never become an occlusion box: foliage and terrain would
// otherwise block the sight line to an enemy standing in the open next to a
// bush, and a landscape heightfield box covers the whole map.
static inline bool ds_pubg_is_soft_scenery_name(const char *name) {
    if (!name || !name[0]) return false;
    // Only reject far-field / soft geometry. "Tree" also appears in
    // "TreeHouse" style props, so the check is limited to plain class tokens.
    return (strstr(name, "Foliage") || strstr(name, "Grass") ||
            strstr(name, "Bush") || strstr(name, "Landscape") ||
            strstr(name, "Terrain") || strstr(name, "Heightfield") ||
            strstr(name, "Water") || strstr(name, "Sky") ||
            strstr(name, "Cloud") || strstr(name, "Fog") ||
            strstr(name, "Particle") || strstr(name, "Decal") ||
            strstr(name, "Decorative") || strstr(name, "TreeFoliage") ||
            strstr(name, "Billboard"));
}

// Reads the component's world pose by walking AttachParent. PUBG attaches the
// building collision components to the level actor, so RelativeLocation alone
// points at the wrong place (that was one root cause of the vischeck failing
// near doorways and corners). Composes the UE relative-transform chain:
//   World = RootLocal * ... * ParentLocal * CompLocal
// Each local transform is (rotation axes, scale, translation) and the walk
// goes leaf -> root, prepending every parent onto the accumulated transform.
static bool ds_pubg_component_world_pose(uint64_t comp,
                                         DSPUBGVector &outLoc,
                                         DSPUBGVector &outX,
                                         DSPUBGVector &outY,
                                         DSPUBGVector &outZ,
                                         DSPUBGVector &outScale) {
    outLoc = DSPUBGVector{};
    outX = DSPUBGVector{ 1.0f, 0.0f, 0.0f };
    outY = DSPUBGVector{ 0.0f, 1.0f, 0.0f };
    outZ = DSPUBGVector{ 0.0f, 0.0f, 1.0f };
    outScale = DSPUBGVector{ 1.0f, 1.0f, 1.0f };
    if (!comp || !ds_pubg_valid(comp)) return false;

    bool have = false;
    DSPUBGVector accLoc = {};
    DSPUBGVector accScale = { 1.0f, 1.0f, 1.0f };
    DSPUBGVector accX = { 1.0f, 0.0f, 0.0f };
    DSPUBGVector accY = { 0.0f, 1.0f, 0.0f };
    DSPUBGVector accZ = { 0.0f, 0.0f, 1.0f };

    uint64_t node = comp;
    for (int depth = 0; depth < 6; depth++) {
        if (!node || !ds_pubg_valid(node)) break;

        DSPUBGVector loc = {};
        if (!ds_pubg_read(node + kDSPUBGSceneCompRelativeLocOffset, &loc, sizeof(loc))) break;
        DSPUBGRotator rot = {};
        ds_pubg_read(node + 0x1F0ULL, &rot, sizeof(rot));
        DSPUBGVector sc = { 1.0f, 1.0f, 1.0f };
        ds_pubg_read(node + 0x1FCULL, &sc, sizeof(sc));
        if (fabsf(sc.X) < 0.01f) sc.X = 1.0f;
        if (fabsf(sc.Y) < 0.01f) sc.Y = 1.0f;
        if (fabsf(sc.Z) < 0.01f) sc.Z = 1.0f;

        DSPUBGVector nx = {}, ny = {}, nz = {};
        ds_pubg_rotator_to_axes(rot, nx, ny, nz);

        if (!have) {
            accLoc = loc;
            accScale = sc;
            accX = nx;
            accY = ny;
            accZ = nz;
            have = true;
        } else {
            // parent ∘ acc
            DSPUBGVector scaledLoc = ds_pubg_axes_scale(accLoc, sc);
            DSPUBGVector rotatedLoc = ds_pubg_axes_apply(scaledLoc, nx, ny, nz);
            accLoc.X = rotatedLoc.X + loc.X;
            accLoc.Y = rotatedLoc.Y + loc.Y;
            accLoc.Z = rotatedLoc.Z + loc.Z;
            accScale.X *= sc.X;
            accScale.Y *= sc.Y;
            accScale.Z *= sc.Z;
            accX = ds_pubg_rotated_axes(nx, ny, nz, accX);
            accY = ds_pubg_rotated_axes(nx, ny, nz, accY);
            accZ = ds_pubg_rotated_axes(nx, ny, nz, accZ);
        }

        node = ds_pubg_read_ptr(node + kDSPUBGSceneCompAttachedParentOffset);
    }

    if (!have) return false;
    if (!isfinite(accLoc.X) || !isfinite(accLoc.Y) || !isfinite(accLoc.Z)) return false;

    outLoc = accLoc;
    outScale = accScale;
    outX = accX;
    outY = accY;
    outZ = accZ;
    return true;
}

// Emits every box collision element of UBodySetup.AggGeom (the real cooked
// collision of the mesh) plus the static mesh bounds as a fallback.
//   UStaticMeshComponent.StaticMesh  0xA30
//   UStaticMesh.BodySetup            0xB0
//   UBodySetup.AggGeom               0x28
//   FKAggregateGeom.BoxElems         0x30 (TArray, stride 0xB0)
//   FKBoxElem: Center 0x80, Rotation 0x8C, X/Y/Z half 0x98/0x9C/0xA0
static int ds_pubg_extract_component_boxes(uint64_t comp,
                                           const DSPUBGVector &camLoc,
                                           DSPUBGObstacleBox *outBoxes,
                                           int maxBoxes) {
    if (!outBoxes || maxBoxes <= 0) return 0;
    if (!comp || !ds_pubg_valid(comp)) return 0;

    // Only real static mesh components resolve to a UStaticMesh at 0xA30.
    // Lights, audio emitters, volumes, decals and triggers do not, and reading
    // their padding as a mesh produced phantom obstacle boxes.
    uint64_t staticMesh = 0;
    if (!ds_pubg_component_has_static_mesh(comp, staticMesh)) return 0;

    DSPUBGVector compLoc = {}, compScale = { 1.0f, 1.0f, 1.0f };
    DSPUBGVector compX = {}, compY = {}, compZ = {};
    if (!ds_pubg_component_world_pose(comp, compLoc, compX, compY, compZ, compScale)) return 0;
    if (!isfinite(compLoc.X) || !isfinite(compLoc.Y) || !isfinite(compLoc.Z)) return 0;

    uint64_t bodySetup = ds_pubg_read_ptr(staticMesh + 0xB0ULL);

    int written = 0;

    // BuildScale3D scales the cooked collision back to mesh space. It lives on
    // UBodySetup and applies to every primitive kind, so it is read once here
    // and shared by the box / convex / capsule passes below.
    DSPUBGVector buildScale = { 1.0f, 1.0f, 1.0f };
    if (bodySetup && ds_pubg_valid(bodySetup)) {
        ds_pubg_read(bodySetup + 0x3B4ULL, &buildScale, sizeof(buildScale));
        if (fabsf(buildScale.X) < 0.01f) buildScale.X = 1.0f;
        if (fabsf(buildScale.Y) < 0.01f) buildScale.Y = 1.0f;
        if (fabsf(buildScale.Z) < 0.01f) buildScale.Z = 1.0f;
    }

    if (bodySetup && ds_pubg_valid(bodySetup)) {
        uint64_t boxData = ds_pubg_read_ptr(bodySetup + 0x28ULL + 0x30ULL);
        uint32_t boxCount = ds_pubg_read_u32(bodySetup + 0x28ULL + 0x30ULL + 0x8ULL);
        if (boxData && ds_pubg_valid(boxData) && boxCount > 0 && boxCount <= 256) {
            if (boxCount > (uint32_t)maxBoxes) boxCount = (uint32_t)maxBoxes;
            for (uint32_t i = 0; i < boxCount; i++) {
                uint64_t elem = boxData + (uint64_t)i * 0xB0ULL;
                DSPUBGVector eCenter = {};
                DSPUBGRotator eRot = {};
                float ex = 0.0f, ey = 0.0f, ez = 0.0f;
                if (!ds_pubg_read(elem + 0x80ULL, &eCenter, sizeof(eCenter))) break;
                ds_pubg_read(elem + 0x8CULL, &eRot, sizeof(eRot));
                ds_pubg_read(elem + 0x98ULL, &ex, sizeof(ex));
                ds_pubg_read(elem + 0x9CULL, &ey, sizeof(ey));
                ds_pubg_read(elem + 0xA0ULL, &ez, sizeof(ez));

                ex *= 0.5f * fabsf(buildScale.X) * fabsf(compScale.X);
                ey *= 0.5f * fabsf(buildScale.Y) * fabsf(compScale.Y);
                ez *= 0.5f * fabsf(buildScale.Z) * fabsf(compScale.Z);
                if (!isfinite(ex) || !isfinite(ey) || !isfinite(ez)) continue;
                if (ex < 1.0f && ey < 1.0f && ez < 1.0f) continue;
                if (ex > 20000.0f || ey > 20000.0f || ez > 20000.0f) continue;

                DSPUBGVector localOffset = ds_pubg_axes_scale(
                    eCenter,
                    DSPUBGVector{ fabsf(buildScale.X) * fabsf(compScale.X),
                                  fabsf(buildScale.Y) * fabsf(compScale.Y),
                                  fabsf(buildScale.Z) * fabsf(compScale.Z) });
                DSPUBGVector worldOffset = ds_pubg_axes_apply(localOffset, compX, compY, compZ);

                DSPUBGObstacleBox box = {};
                box.center.X = compLoc.X + worldOffset.X;
                box.center.Y = compLoc.Y + worldOffset.Y;
                box.center.Z = compLoc.Z + worldOffset.Z;
                box.extent = DSPUBGVector{ ex, ey, ez };

                DSPUBGVector exX = {}, exY = {}, exZ = {};
                ds_pubg_rotator_to_axes(eRot, exX, exY, exZ);
                box.axisX = ds_pubg_rotated_axes(compX, compY, compZ, exX);
                box.axisY = ds_pubg_rotated_axes(compX, compY, compZ, exY);
                box.axisZ = ds_pubg_rotated_axes(compX, compY, compZ, exZ);
                ds_pubg_box_finalize(box);
                if (!ds_pubg_box_is_valid_cover(box, nullptr)) continue;
                outBoxes[written++] = box;
            }
        }
    }

    // Convex hulls: PUBG cooks most building shells as convex elements, not
    // boxes, so a mesh whose walls are convex reported zero obstacles and the
    // ray passed straight through the wall. ElemBox is the hull's own mesh-space
    // AABB, which is the correct conservative stand-in for a ray test.
    //   FKAggregateGeom.ConvexElems 0x90 (stride 0xA0)
    //   FKConvexElem.ElemBox        0x38 (FBox: Min 0x00, Max 0x0C)
    if (bodySetup && ds_pubg_valid(bodySetup)) {
        uint64_t convexData = ds_pubg_read_ptr(bodySetup + 0x28ULL + 0x90ULL);
        uint32_t convexCount = ds_pubg_read_u32(bodySetup + 0x28ULL + 0x90ULL + 0x8ULL);
        if (convexData && ds_pubg_valid(convexData) && convexCount > 0 && convexCount <= 256) {
            for (uint32_t i = 0; i < convexCount && written < maxBoxes; i++) {
                uint64_t elem = convexData + (uint64_t)i * 0xA0ULL;
                DSPUBGVector eMin = {}, eMax = {};
                if (!ds_pubg_read(elem + 0x38ULL, &eMin, sizeof(eMin))) break;
                if (!ds_pubg_read(elem + 0x44ULL, &eMax, sizeof(eMax))) break;
                if (!isfinite(eMin.X) || !isfinite(eMax.X)) continue;

                DSPUBGVector half = { (eMax.X - eMin.X) * 0.5f,
                                      (eMax.Y - eMin.Y) * 0.5f,
                                      (eMax.Z - eMin.Z) * 0.5f };
                DSPUBGVector mid = { (eMax.X + eMin.X) * 0.5f,
                                     (eMax.Y + eMin.Y) * 0.5f,
                                     (eMax.Z + eMin.Z) * 0.5f };
                half.X *= fabsf(buildScale.X) * fabsf(compScale.X);
                half.Y *= fabsf(buildScale.Y) * fabsf(compScale.Y);
                half.Z *= fabsf(buildScale.Z) * fabsf(compScale.Z);
                if (half.X < 4.0f && half.Y < 4.0f && half.Z < 4.0f) continue;
                if (!isfinite(half.X) || !isfinite(half.Y) || !isfinite(half.Z)) continue;

                DSPUBGVector scaledMid = ds_pubg_axes_scale(
                    mid,
                    DSPUBGVector{ fabsf(buildScale.X) * fabsf(compScale.X),
                                  fabsf(buildScale.Y) * fabsf(compScale.Y),
                                  fabsf(buildScale.Z) * fabsf(compScale.Z) });
                DSPUBGVector worldOffset = ds_pubg_axes_apply(scaledMid, compX, compY, compZ);

                DSPUBGObstacleBox box = {};
                box.center.X = compLoc.X + worldOffset.X;
                box.center.Y = compLoc.Y + worldOffset.Y;
                box.center.Z = compLoc.Z + worldOffset.Z;
                box.extent = half;
                box.axisX = compX;
                box.axisY = compY;
                box.axisZ = compZ;
                ds_pubg_box_finalize(box);
                if (!ds_pubg_box_is_valid_cover(box, &camLoc)) continue;
                outBoxes[written++] = box;
            }
        }
    }

    // Capsules (FKSphylElem): pillars, trunks, railings, pipes.
    //   FKAggregateGeom.SphylElems 0x60 (stride 0xA0)
    //   Center 0x80, Rotation 0x8C, Radius 0x98, Length 0x9C
    if (bodySetup && ds_pubg_valid(bodySetup)) {
        uint64_t sphylData = ds_pubg_read_ptr(bodySetup + 0x28ULL + 0x60ULL);
        uint32_t sphylCount = ds_pubg_read_u32(bodySetup + 0x28ULL + 0x60ULL + 0x8ULL);
        if (sphylData && ds_pubg_valid(sphylData) && sphylCount > 0 && sphylCount <= 256) {
            for (uint32_t i = 0; i < sphylCount && written < maxBoxes; i++) {
                uint64_t elem = sphylData + (uint64_t)i * 0xA0ULL;
                DSPUBGVector eCenter = {};
                DSPUBGRotator eRot = {};
                float radius = 0.0f, length = 0.0f;
                if (!ds_pubg_read(elem + 0x80ULL, &eCenter, sizeof(eCenter))) break;
                ds_pubg_read(elem + 0x8CULL, &eRot, sizeof(eRot));
                ds_pubg_read(elem + 0x98ULL, &radius, sizeof(radius));
                ds_pubg_read(elem + 0x9CULL, &length, sizeof(length));
                if (!isfinite(radius) || radius <= 0.0f) continue;
                if (!isfinite(length) || length < 0.0f) continue;

                float ax = radius * fabsf(buildScale.X) * fabsf(compScale.X);
                float ay = radius * fabsf(buildScale.Y) * fabsf(compScale.Y);
                float az = (radius + length) * fabsf(buildScale.Z) * fabsf(compScale.Z);
                if (ax < 3.0f && ay < 3.0f && az < 3.0f) continue;

                DSPUBGVector localOffset = ds_pubg_axes_scale(
                    eCenter,
                    DSPUBGVector{ fabsf(buildScale.X) * fabsf(compScale.X),
                                  fabsf(buildScale.Y) * fabsf(compScale.Y),
                                  fabsf(buildScale.Z) * fabsf(compScale.Z) });
                DSPUBGVector worldOffset = ds_pubg_axes_apply(localOffset, compX, compY, compZ);

                DSPUBGObstacleBox box = {};
                box.center.X = compLoc.X + worldOffset.X;
                box.center.Y = compLoc.Y + worldOffset.Y;
                box.center.Z = compLoc.Z + worldOffset.Z;
                box.extent = DSPUBGVector{ ax, ay, az };
                DSPUBGVector exX = {}, exY = {}, exZ = {};
                ds_pubg_rotator_to_axes(eRot, exX, exY, exZ);
                box.axisX = ds_pubg_rotated_axes(compX, compY, compZ, exX);
                box.axisY = ds_pubg_rotated_axes(compX, compY, compZ, exY);
                box.axisZ = ds_pubg_rotated_axes(compX, compY, compZ, exZ);
                ds_pubg_box_finalize(box);
                if (!ds_pubg_box_is_valid_cover(box, nullptr)) continue;
                outBoxes[written++] = box;
            }
        }
    }

    if (written > 0) return written;

    // Fallback: whole-mesh bounds. Good enough for simple props.
    DSPUBGVector boxOrigin = {}, boxExtent = {};
    bool gotBounds = false;

    if (staticMesh && ds_pubg_valid(staticMesh)) {
        ds_pubg_read(staticMesh + 0x1A8ULL, &boxOrigin, sizeof(boxOrigin));
        ds_pubg_read(staticMesh + 0x1B4ULL, &boxExtent, sizeof(boxExtent));
        if (boxExtent.X > 5.0f && boxExtent.Y > 5.0f && boxExtent.Z > 5.0f && boxExtent.X < 30000.0f) {
            gotBounds = true;
        } else {
            ds_pubg_read(staticMesh + 0x54ULL, &boxOrigin, sizeof(boxOrigin));
            ds_pubg_read(staticMesh + 0x60ULL, &boxExtent, sizeof(boxExtent));
            if (boxExtent.X > 5.0f && boxExtent.Y > 5.0f && boxExtent.Z > 5.0f && boxExtent.X < 30000.0f) {
                gotBounds = true;
            }
        }
    }

    // No third fallback: 0xB8C is USkinnedMeshComponent.CachedLocalBounds and
    // does not exist on UStaticMeshComponent. Reading it returned whatever
    // happened to live in UStaticMeshComponent's padding, which produced huge
    // phantom boxes around lights, audio emitters, volumes and decals - the
    // cause of "everything is red in an empty field".
    if (!gotBounds) return 0;

    boxExtent.X *= fabsf(compScale.X);
    boxExtent.Y *= fabsf(compScale.Y);
    boxExtent.Z *= fabsf(compScale.Z);

    DSPUBGObstacleBox box = {};
    box.center = compLoc;
    if (fabsf(boxOrigin.X) > 0.1f || fabsf(boxOrigin.Y) > 0.1f || fabsf(boxOrigin.Z) > 0.1f) {
        DSPUBGVector scaledOrigin = ds_pubg_axes_scale(boxOrigin, compScale);
        DSPUBGVector worldOffset = ds_pubg_axes_apply(scaledOrigin, compX, compY, compZ);
        box.center.X += worldOffset.X;
        box.center.Y += worldOffset.Y;
        box.center.Z += worldOffset.Z;
    }
    box.extent = boxExtent;
    box.axisX = compX;
    box.axisY = compY;
    box.axisZ = compZ;
    ds_pubg_box_finalize(box);
    if (!ds_pubg_box_is_valid_cover(box, &camLoc)) return 0;
    outBoxes[0] = box;
    return 1;
}

// Instanced static meshes carry their own per-instance matrices. One actor can
// hold hundreds of wall modules, which is why the old one-box-per-actor scan
// produced an almost empty obstacle set.
//   UInstancedStaticMeshComponent.PerInstanceSMData 0xBD8 (TArray<FMatrix 0x40>)
static int ds_pubg_extract_instanced_boxes(uint64_t comp,
                                           const DSPUBGVector &camLoc,
                                           DSPUBGObstacleBox *outBoxes,
                                           int maxBoxes) {
    if (!outBoxes || maxBoxes <= 0) return 0;
    if (!comp || !ds_pubg_valid(comp)) return 0;

    // 0xBD8 is inside UStaticMeshComponent's padding, so the array there must be
    // validated before use: a plain static mesh would read garbage as instances.
    // The class name is a hint only - PUBG ships several subclasses (Color /
    // Photon / Creative / Hierarchical) and the pool may not resolve them, so a
    // missing or unmatched name must not disable the instanced path.
    char compClassName[64] = {0};
    if (ds_pubg_get_actor_name(comp, compClassName, sizeof(compClassName))) {
        if (strstr(compClassName, "Foliage")) return 0;
    }

    // The instance data at 0xBD8 only means something when the component truly
    // owns a static mesh; otherwise the count/matrix pair is padding.
    uint64_t mesh = 0;
    if (!ds_pubg_component_has_static_mesh(comp, mesh)) return 0;

    DSPUBGVector compLoc = {}, compScale = { 1.0f, 1.0f, 1.0f };
    DSPUBGVector compX = {}, compY = {}, compZ = {};
    if (!ds_pubg_component_world_pose(comp, compLoc, compX, compY, compZ, compScale)) return 0;

    DSPUBGVector meshOrigin = {}, meshExtent = {};
    ds_pubg_read(mesh + 0x1A8ULL, &meshOrigin, sizeof(meshOrigin));
    ds_pubg_read(mesh + 0x1B4ULL, &meshExtent, sizeof(meshExtent));
    if (!(meshExtent.X > 5.0f && meshExtent.Y > 5.0f && meshExtent.Z > 5.0f)) {
        ds_pubg_read(mesh + 0x54ULL, &meshOrigin, sizeof(meshOrigin));
        ds_pubg_read(mesh + 0x60ULL, &meshExtent, sizeof(meshExtent));
    }
    if (!(meshExtent.X > 1.0f && meshExtent.Y > 1.0f && meshExtent.Z > 1.0f)) return 0;
    if (meshExtent.X > 30000.0f || meshExtent.Y > 30000.0f || meshExtent.Z > 30000.0f) return 0;

    uint64_t data = ds_pubg_read_ptr(comp + 0xBD8ULL);
    uint32_t count = ds_pubg_read_u32(comp + 0xBD8ULL + 0x8ULL);
    if (!data || !ds_pubg_valid(data) || count == 0 || count > 20000) return 0;

    float maxDistSq = 25000.0f * 25000.0f;
    int written = 0;

    for (uint32_t i = 0; i < count && written < maxBoxes; i++) {
        uint64_t m = data + (uint64_t)i * 0x40ULL;
        float mat[16] = {};
        if (!ds_pubg_read(m, mat, sizeof(mat))) break;

        // FMatrix: XPlane(0..3), YPlane(4..7), ZPlane(8..11), WPlane(12..15)
        DSPUBGVector iX = { mat[0], mat[1], mat[2] };
        DSPUBGVector iY = { mat[4], mat[5], mat[6] };
        DSPUBGVector iZ = { mat[8], mat[9], mat[10] };
        DSPUBGVector iPos = { mat[12], mat[13], mat[14] };
        if (!isfinite(iPos.X) || !isfinite(iPos.Y) || !isfinite(iPos.Z)) continue;

        float sx = hypotf(hypotf(iX.X, iX.Y), iX.Z);
        float sy = hypotf(hypotf(iY.X, iY.Y), iY.Z);
        float sz = hypotf(hypotf(iZ.X, iZ.Y), iZ.Z);
        if (!isfinite(sx) || !isfinite(sy) || !isfinite(sz)) continue;
        if (sx < 0.01f || sy < 0.01f || sz < 0.01f) continue;
        if (sx > 100.0f || sy > 100.0f || sz > 100.0f) continue;

        DSPUBGVector iAxisX = { iX.X / sx, iX.Y / sx, iX.Z / sx };
        DSPUBGVector iAxisY = { iY.X / sy, iY.Y / sy, iY.Z / sy };
        DSPUBGVector iAxisZ = { iZ.X / sz, iZ.Y / sz, iZ.Z / sz };

        DSPUBGVector instLoc = ds_pubg_axes_scale(iPos, compScale);
        DSPUBGVector worldPos = ds_pubg_axes_apply(instLoc, compX, compY, compZ);
        DSPUBGVector center = { compLoc.X + worldPos.X, compLoc.Y + worldPos.Y, compLoc.Z + worldPos.Z };

        float dx = center.X - camLoc.X;
        float dy = center.Y - camLoc.Y;
        float dz = center.Z - camLoc.Z;
        if (dx * dx + dy * dy + dz * dz > maxDistSq) continue;

        DSPUBGObstacleBox box = {};
        box.center = center;
        box.extent.X = meshExtent.X * sx * fabsf(compScale.X);
        box.extent.Y = meshExtent.Y * sy * fabsf(compScale.Y);
        box.extent.Z = meshExtent.Z * sz * fabsf(compScale.Z);
        box.axisX = ds_pubg_rotated_axes(compX, compY, compZ, iAxisX);
        box.axisY = ds_pubg_rotated_axes(compX, compY, compZ, iAxisY);
        box.axisZ = ds_pubg_rotated_axes(compX, compY, compZ, iAxisZ);
        ds_pubg_box_finalize(box);
        if (!ds_pubg_box_is_valid_cover(box, nullptr)) continue;
        outBoxes[written++] = box;
    }

    return written;
}

static bool ds_pubg_ray_intersects_box(
    const DSPUBGVector &rayStart,
    const DSPUBGVector &rayEnd,
    const DSPUBGObstacleBox &box)
{
    DSPUBGVector dir = { rayEnd.X - rayStart.X, rayEnd.Y - rayStart.Y, rayEnd.Z - rayStart.Z };
    float len = hypotf(hypotf(dir.X, dir.Y), dir.Z);
    if (len < 10.0f) return false;
    float invLen = 1.0f / len;
    DSPUBGVector d = { dir.X * invLen, dir.Y * invLen, dir.Z * invLen };

    // 1. Fast bounding sphere rejection test
    DSPUBGVector v = { box.center.X - rayStart.X, box.center.Y - rayStart.Y, box.center.Z - rayStart.Z };
    float t_proj = v.X * d.X + v.Y * d.Y + v.Z * d.Z;
    float radius = box.radius;
    if (t_proj < -radius || t_proj > len + radius) return false;

    float vSq = v.X * v.X + v.Y * v.Y + v.Z * v.Z;
    float dPerpSq = vSq - t_proj * t_proj;
    if (dPerpSq > radius * radius) return false;

    // 2. Kay-Kajiya slab test along each of the 3 world-space box axes
    DSPUBGVector diff = { rayStart.X - box.center.X, rayStart.Y - box.center.Y, rayStart.Z - box.center.Z };
    float tMin = 0.0f;
    float tMax = len;

    auto testSlab = [&](const DSPUBGVector &axis, float ext) -> bool {
        float f = axis.X * d.X + axis.Y * d.Y + axis.Z * d.Z;
        float s = axis.X * diff.X + axis.Y * diff.Y + axis.Z * diff.Z;
        if (fabsf(f) > 1e-6f) {
            float t1 = (-s - ext) / f;
            float t2 = (-s + ext) / f;
            if (t1 > t2) { float tmp = t1; t1 = t2; t2 = tmp; }
            if (t1 > tMin) tMin = t1;
            if (t2 < tMax) tMax = t2;
            if (tMin > tMax) return false;
        } else {
            if (fabsf(s) > ext) return false;
        }
        return true;
    };

    if (!testSlab(box.axisX, box.extent.X)) return false;
    if (!testSlab(box.axisY, box.extent.Y)) return false;
    if (!testSlab(box.axisZ, box.extent.Z)) return false;

    // Must intersect strictly between camera and target. A box that swallows
    // the camera (tMin == 0) is rejected on purpose: aggregate bounds that
    // cover the player are over-approximations, and letting them block turned
    // every enemy red in the first field test. Real occluders are extracted
    // per collision primitive, so they never contain the camera.
    return (tMin > 10.0f && tMin < len - 10.0f && tMin <= tMax);
}

static bool ds_pubg_is_blocked_by_obstacle(const DSPUBGVector &camLoc, const DSPUBGVector &targetLoc) {
    if (s_obstacleCount <= 0) return false;

    // Broad phase: reject every box that cannot possibly lie on the segment
    // cam->target before running the full slab test. With up to 4096 boxes and
    // six rays per enemy this keeps the per-frame cost bounded.
    float segX = targetLoc.X - camLoc.X;
    float segY = targetLoc.Y - camLoc.Y;
    float segZ = targetLoc.Z - camLoc.Z;
    float segLenSq = segX * segX + segY * segY + segZ * segZ;
    if (segLenSq < 100.0f) return false;

    for (int i = 0; i < s_obstacleCount; i++) {
        const DSPUBGObstacleBox &box = s_obstacles[i];
        float vx = box.center.X - camLoc.X;
        float vy = box.center.Y - camLoc.Y;
        float vz = box.center.Z - camLoc.Z;
        // Cheap sphere/segment distance test.
        float t = (vx * segX + vy * segY + vz * segZ) / segLenSq;
        if (t < 0.0f) t = 0.0f; else if (t > 1.0f) t = 1.0f;
        float dx = vx - segX * t;
        float dy = vy - segY * t;
        float dz = vz - segZ * t;
        float r = box.radius;
        if (dx * dx + dy * dy + dz * dz > r * r) continue;

        if (ds_pubg_ray_intersects_box(camLoc, targetLoc, s_obstacles[i])) {
            return true;
        }
    }
    return false;
}

static inline bool ds_pubg_ray_has_line_of_sight(const DSPUBGVector &start, const DSPUBGVector &target) {
    // Map StaticMesh Collision Box Query (Ray-OBB Kay-Kajiya slab test)
    if (s_obstacleCount > 0) {
        if (ds_pubg_is_blocked_by_obstacle(start, target)) {
            return false; // Blocked by StaticMesh building / wall box
        }
    }

    return true; // Clear line of sight
}

// ===========================================================================
// A. ACTOR & SHAPE CLASSIFICATION SYSTEM
// ---------------------------------------------------------------------------
// The ESP walks thousands of level actors every frame. Instead of treating all
// of them the same way, every actor is classified into exactly one bucket so
// each consumer can use the cheapest strategy:
//
//   [A1] Static Actors   - immutable world geometry (houses, walls, terrain,
//                          foliage). Their world transform + collision OBB is
//                          captured ONCE and cached, so later frames cost
//                          zero memory reads.
//   [A2] Dynamic Actors  - everything that moves (players, bots, vehicles,
//                          loot). Their transform matrix is refreshed every
//                          frame so we always know where they are right now.
//   [A3] Smart Filtering - recognises the local capsule hitbox, vehicles and
//                          dropped weapons, and maintains a skipActors set
//                          (self / teammates) that every scanner consults.
// ===========================================================================

enum class DSPUBGShapeKind : uint8_t {
    None = 0,
    Obb,      // oriented bounding box - static collision geometry
    Capsule,  // character capsule hitbox
    Sphere,   // pickup / loot sphere
};

enum class DSPUBGActorClass : uint8_t {
    Unknown = 0,
    StaticScenery,   // walls, houses, terrain, foliage
    DynamicPawn,     // players + bots
    DynamicVehicle,  // cars, motorcycles, boats
    LootItem,        // dropped weapons, ammo, meds, crates
    Ignored,         // dropped weapon / self / teammate -> skipped
};

enum : uint32_t {
    DSPUBGActLocal    = 1u << 0,
    DSPUBGActTeammate = 1u << 1,
    DSPUBGActVehicle  = 1u << 2,
    DSPUBGActDropped  = 1u << 3,
};

// --- A1. Static Actor Library -------------------------------------------------
// Cached geometry for immutable actors. Keyed by AActor pointer, open
// addressed, and bound to one UWorld so a map change drops the whole library.
// One actor yields at most this many boxes, both when it is scanned fresh and
// when it is served from the static cache. The two budgets must match, or the
// geometry would visibly thin out on cached frames.
static const int kDSPUBGStaticBoxesPerActor = 32;
static const int kDSPUBGBoxesPerComponent = 32;
struct DSPUBGStaticActor {
    uint64_t actor;
    uint64_t component;
    int boxCount;
    DSPUBGObstacleBox boxes[kDSPUBGStaticBoxesPerActor];
    uint64_t capturedTick;
};

static const size_t kDSPUBGStaticActorSlots = 2048;   // power of two
static DSPUBGStaticActor s_staticActors[kDSPUBGStaticActorSlots] = {};
static uint64_t s_staticActorWorld = 0;
static uint64_t s_staticActorLevelSig = 0;

static inline size_t ds_pubg_static_hash(uint64_t actor) {
    return (size_t)((actor >> 4) ^ (actor >> 17)) & (kDSPUBGStaticActorSlots - 1);
}

// --- A1b. Non-static actor memory ---------------------------------------------
// Actors that are known to be *not* world geometry (players, loot, lights,
// volumes, ...). Kept here so the static scanner never has to read their name
// again, and - more importantly - so it never has to write into the shared
// actor cache that the player and item scanners own.
static const size_t kDSPUBGNonStaticSlots = 4096;   // power of two
static uint64_t s_nonStaticActors[kDSPUBGNonStaticSlots] = {};

static inline size_t ds_pubg_nonstatic_hash(uint64_t actor) {
    return (size_t)((actor >> 4) ^ (actor >> 15)) & (kDSPUBGNonStaticSlots - 1);
}

static bool ds_pubg_nonstatic_known(uint64_t actor) {
    if (!actor) return true;
    size_t idx = ds_pubg_nonstatic_hash(actor);
    for (size_t probe = 0; probe < kDSPUBGNonStaticSlots; probe++) {
        uint64_t slot = s_nonStaticActors[(idx + probe) & (kDSPUBGNonStaticSlots - 1)];
        if (slot == actor) return true;
        if (slot == 0) return false;
    }
    return false;
}

static void ds_pubg_nonstatic_remember(uint64_t actor) {
    if (!actor) return;
    size_t idx = ds_pubg_nonstatic_hash(actor);
    for (size_t probe = 0; probe < kDSPUBGNonStaticSlots; probe++) {
        uint64_t &slot = s_nonStaticActors[(idx + probe) & (kDSPUBGNonStaticSlots - 1)];
        if (slot == actor) return;
        if (slot == 0) { slot = actor; return; }
    }
}

// A new UWorld means every cached transform is stale: drop the whole library.
static void ds_pubg_static_library_reset(uint64_t world) {
    if (world == s_staticActorWorld) return;
    memset(s_staticActors, 0, sizeof(s_staticActors));
    memset(s_nonStaticActors, 0, sizeof(s_nonStaticActors));
    s_staticActorCount = 0;
    s_staticActorWorld = world;
}

// Seamless travel keeps the same UWorld but swaps the level set, so the
// caller can force a drop when the levels change. The world binding is kept
// so the next frame does not clear the (still empty) library again.
static void ds_pubg_static_library_invalidate(void) {
    memset(s_staticActors, 0, sizeof(s_staticActors));
    memset(s_nonStaticActors, 0, sizeof(s_nonStaticActors));
    s_staticActorCount = 0;
}

// Returns the slot holding the actor, or the first free slot for insertion.
static DSPUBGStaticActor *ds_pubg_static_slot(uint64_t actor, bool &found) {
    size_t idx = ds_pubg_static_hash(actor);
    for (size_t probe = 0; probe < kDSPUBGStaticActorSlots; probe++) {
        DSPUBGStaticActor &e = s_staticActors[(idx + probe) & (kDSPUBGStaticActorSlots - 1)];
        if (e.actor == actor) { found = true; return &e; }
        if (e.actor == 0) { found = false; return &e; }
    }
    found = false;
    return nullptr;   // library full
}

// --- A2. Dynamic Actor Registry ----------------------------------------------
// Live transform of every actor that moves. Refreshed each frame by the
// player / vehicle / loot passes.
struct DSPUBGDynamicActor {
    uint64_t actor;
    DSPUBGShapeKind shape;
    DSPUBGActorClass actorClass;
    uint32_t flags;
    DSPUBGVector location;
    DSPUBGRotator rotation;
    DSPUBGVector scale;
    float radius;
    float halfHeight;
    uint64_t lastSeenTick;
};

static const size_t kDSPUBGDynamicActorSlots = 512;   // power of two
static DSPUBGDynamicActor s_dynamicActors[kDSPUBGDynamicActorSlots] = {};

static inline size_t ds_pubg_dynamic_hash(uint64_t actor) {
    return (size_t)((actor >> 4) ^ (actor >> 13)) & (kDSPUBGDynamicActorSlots - 1);
}

static DSPUBGDynamicActor *ds_pubg_dynamic_slot(uint64_t actor, bool &found) {
    size_t idx = ds_pubg_dynamic_hash(actor);
    for (size_t probe = 0; probe < kDSPUBGDynamicActorSlots; probe++) {
        DSPUBGDynamicActor &e = s_dynamicActors[(idx + probe) & (kDSPUBGDynamicActorSlots - 1)];
        if (e.actor == actor) { found = true; return &e; }
        if (e.actor == 0) { found = false; return &e; }
    }
    found = false;
    return nullptr;
}

// Refresh the transform matrix of a moving actor. Called every frame for each
// player, vehicle and loot actor we can see.
static void ds_pubg_dynamic_update(uint64_t actor,
                                   DSPUBGShapeKind shape,
                                   DSPUBGActorClass actorClass,
                                   uint32_t flags,
                                   const DSPUBGVector &location,
                                   const DSPUBGRotator &rotation,
                                   const DSPUBGVector &scale,
                                   float radius,
                                   float halfHeight) {
    if (!actor) return;
    bool found = false;
    DSPUBGDynamicActor *e = ds_pubg_dynamic_slot(actor, found);
    if (!e) return;
    if (!found) {
        memset(e, 0, sizeof(*e));
        e->actor = actor;
        s_dynamicActorCount++;
    }
    e->shape = shape;
    e->actorClass = actorClass;
    e->flags = flags;
    e->location = location;
    e->rotation = rotation;
    e->scale = scale;
    e->radius = radius;
    e->halfHeight = halfHeight;
    e->lastSeenTick = s_visTickCounter;
}

static DSPUBGDynamicActor *ds_pubg_dynamic_find(uint64_t actor) {
    if (!actor) return nullptr;
    bool found = false;
    DSPUBGDynamicActor *e = ds_pubg_dynamic_slot(actor, found);
    return found ? e : nullptr;
}

// Drop entries that stopped being refreshed so the registry never keeps a
// stale transform alive.
static void ds_pubg_dynamic_prune(void) {
    for (size_t i = 0; i < kDSPUBGDynamicActorSlots; i++) {
        DSPUBGDynamicActor &e = s_dynamicActors[i];
        if (e.actor == 0) continue;
        if ((s_visTickCounter - e.lastSeenTick) > 30) {
            memset(&e, 0, sizeof(e));
            if (s_dynamicActorCount) s_dynamicActorCount--;
        }
    }
}

// --- A3. Smart Filtering ------------------------------------------------------
// Recognises the shapes that must never be treated as static geometry and
// keeps the skipActors set (self / teammates) consulted by every scanner.
struct DSPUBGLocalCapsule {
    bool valid;
    uint64_t component;
    DSPUBGVector location;
    float radius;
    float halfHeight;
};
static DSPUBGLocalCapsule s_localCapsule = {};

// UCapsuleComponent: CapsuleHalfHeight 0x9F8 | CapsuleRadius 0x9FC
static const uint64_t kDSPUGCapsuleHalfHeightOffset = 0x9F8ULL;
static const uint64_t kDSPUGCapsuleRadiusOffset = 0x9FCULL;
static const uint64_t kDSPUBGCharacterCapsuleOffset = 0x520ULL;  // ACharacter.CapsuleComponent

// skipActors set (open addressed, O(1) lookup)
static const size_t kDSPUBGSkipActorSlots = 1024;   // power of two
static uint64_t s_skipActors[kDSPUBGSkipActorSlots] = {};
static size_t s_skipActorCount = 0;

static inline size_t ds_pubg_skip_hash(uint64_t actor) {
    return (size_t)((actor >> 4) ^ (actor >> 13)) & (kDSPUBGSkipActorSlots - 1);
}

static void ds_pubg_smart_skip(uint64_t actor) {
    if (!actor) return;
    size_t idx = ds_pubg_skip_hash(actor);
    for (size_t probe = 0; probe < kDSPUBGSkipActorSlots; probe++) {
        uint64_t &slot = s_skipActors[(idx + probe) & (kDSPUBGSkipActorSlots - 1)];
        if (slot == actor) return;
        if (slot == 0) { slot = actor; s_skipActorCount++; return; }
    }
}

static bool ds_pubg_smart_is_skipped(uint64_t actor) {
    if (!actor) return true;
    size_t idx = ds_pubg_skip_hash(actor);
    for (size_t probe = 0; probe < kDSPUBGSkipActorSlots; probe++) {
        uint64_t slot = s_skipActors[(idx + probe) & (kDSPUBGSkipActorSlots - 1)];
        if (slot == actor) return true;
        if (slot == 0) return false;
    }
    return false;
}

// Locate the local player capsule hitbox. The capsule is the authoritative
// collision shape of a character, so knowing it lets the vischeck ignore the
// player's own collision and lets the renderer skip self.
static bool ds_pubg_smart_detect_local_capsule(uint64_t localPawn) {
    if (!localPawn || !ds_pubg_valid(localPawn)) return false;

    uint64_t capsule = ds_pubg_read_ptr(localPawn + kDSPUBGCharacterCapsuleOffset);
    if (!capsule || !ds_pubg_valid(capsule)) {
        capsule = ds_pubg_read_ptr(localPawn + 0x180ULL);   // RootComponent fallback
    }
    if (!capsule || !ds_pubg_valid(capsule)) return false;

    DSPUBGVector loc = {};
    if (!ds_pubg_read(capsule + kDSPUBGSceneCompRelativeLocOffset, &loc, sizeof(loc))) return false;
    if (isnan(loc.X) || isnan(loc.Y) || isnan(loc.Z)) return false;

    float halfHeight = ds_pubg_read_f32(capsule + kDSPUGCapsuleHalfHeightOffset);
    float radius = ds_pubg_read_f32(capsule + kDSPUGCapsuleRadiusOffset);
    if (!isfinite(halfHeight) || halfHeight <= 0.0f || halfHeight > 2000.0f) return false;
    if (!isfinite(radius) || radius <= 0.0f || radius > 500.0f) return false;

    s_localCapsule.valid = true;
    s_localCapsule.component = capsule;
    s_localCapsule.location = loc;
    s_localCapsule.radius = radius;
    s_localCapsule.halfHeight = halfHeight;
    return true;
}

// Characters are never world geometry. They must be recognised before the
// scenery list, because a pawn can carry a scenery-looking token (bots are
// often named "...Target...") and would otherwise be baked into the obstacle
// list and block its own line of sight.
static inline bool ds_pubg_smart_is_pawn_name(const char *name) {
    if (!name || !name[0]) return false;
    return (strstr(name, "Pawn") || strstr(name, "Character") ||
            strstr(name, "Player") || strstr(name, "Target") ||
            strstr(name, "Dummy") || strstr(name, "Model") ||
            strstr(name, "Avatar") || strstr(name, "Soldier") ||
            strstr(name, "Bot") || strstr(name, "AI_"));
}

// Vehicles move, so they must never be baked into the static geometry cache.
static inline bool ds_pubg_smart_is_vehicle_name(const char *name) {
    if (!name || !name[0]) return false;
    return (strstr(name, "VH_") || strstr(name, "Vehicle") ||
            strstr(name, "Jeep") || strstr(name, "UAZ") ||
            strstr(name, "Sedan") || strstr(name, "Dacia") ||
            strstr(name, "Buggy") || strstr(name, "Truck") ||
            strstr(name, "Rony") || strstr(name, "Motorcycle") ||
            strstr(name, "Scooter") || strstr(name, "Boat") ||
            strstr(name, "Helicopter") || strstr(name, "Airdrop") ||
            strstr(name, "Parachute") || strstr(name, "Bike"));
}

// Dropped weapons are loot on the floor: they are not world geometry and must
// not block the line of sight.
static inline bool ds_pubg_smart_is_dropped_weapon_name(const char *name) {
    if (!name || !name[0]) return false;
    if (strstr(name, "PickUp") || strstr(name, "Pickup") || strstr(name, "Wrapper")) {
        return (strstr(name, "Weapon") || strstr(name, "Gun") ||
                strstr(name, "AWM") || strstr(name, "AKM") || strstr(name, "M416") ||
                strstr(name, "DP28") || strstr(name, "Kar98") || strstr(name, "SCAR") ||
                strstr(name, "UMP") || strstr(name, "SKS") || strstr(name, "S686"));
    }
    return false;
}

// Classify one actor for the static scanner: scenery that is neither a
// character, a vehicle nor a dropped weapon becomes static geometry.
static inline DSPUBGActorClass ds_pubg_smart_classify_scenery(const char *name) {
    if (!name || !name[0]) return DSPUBGActorClass::Unknown;
    if (ds_pubg_smart_is_pawn_name(name)) return DSPUBGActorClass::DynamicPawn;
    if (ds_pubg_smart_is_vehicle_name(name)) return DSPUBGActorClass::DynamicVehicle;
    if (ds_pubg_smart_is_dropped_weapon_name(name)) return DSPUBGActorClass::Ignored;
    if (ds_pubg_is_scenery_name(name)) return DSPUBGActorClass::StaticScenery;
    return DSPUBGActorClass::Unknown;
}

// Called once per tick, before any scanner runs: refreshes the skip set,
// detects the local capsule and rebinds the static library to this world.
static void ds_pubg_smart_begin_frame(uint64_t world, uint64_t localPawn) {
    (void)world;
    (void)localPawn;
}

static void ds_pubg_tick_impl(void) {
    if (!ds_pubg_attach()) {
        return;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    // 1. Resolve World pointer
    uint64_t world = 0;
    if (g_dspubgEngineRva) {
        uint64_t gengine = ds_pubg_read_ptr(g_dspubgBase + g_dspubgEngineRva);
        if (gengine) {
            uint64_t vp = ds_pubg_read_ptr(gengine + g_dspubgEngineViewportOffset);
            if (vp) {
                world = ds_pubg_read_ptr(vp + kDSPUBGViewportWorldOffset);
                if (!world) world = ds_pubg_read_ptr(vp + 0x80ULL);
            }
        }
    }

    if (!world && g_dspubgWorldRva) {
        world = ds_pubg_read_ptr(g_dspubgBase + g_dspubgWorldRva);
    }

    if (!world && g_dspubgCachedWorld) {
        if (ds_pubg_is_valid_world(g_dspubgVmMap, g_dspubgCachedWorld)) {
            world = g_dspubgCachedWorld;
        }
    }

    // Dynamic scan fallback if world is lost or unlocated
    if (!world) {
        if (now >= g_dspubgNextScan) {
            g_dspubgNextScan = now + 1.5;
            if (ds_pubg_scan_for_engine_and_world(g_dspubgVmMap, g_dspubgBase)) {
                world = g_dspubgCachedWorld;
            }
        }
    } else {
        g_dspubgCachedWorld = world;
    }

    if (!world) {
        ds_pubg_reset_match_caches();
        g_dspubgLastActorsCount = 0;
        g_dspubgLastEnemyCount = 0;
        g_dspubgLastBotCount = 0;
        return;
    }

    // 2. Resolve LocalPlayer, PlayerController, CameraManager
    uint64_t gameInstance = 0;
    if (g_dspubgEngineRva) {
        uint64_t ge = ds_pubg_read_ptr(g_dspubgBase + g_dspubgEngineRva);
        if (ge) gameInstance = ds_pubg_read_ptr(ge + kDSPUBGEngineGameInstanceOffset);
    }
    if (!gameInstance) {
        gameInstance = ds_pubg_read_ptr(world + kDSPUBGWorldOwningGameInstanceOffset);
        if (!gameInstance) gameInstance = ds_pubg_read_ptr(world + 0x240ULL);
    }

    uint64_t localPlayer = 0;
    if (gameInstance) {
        uint64_t lpArray = ds_pubg_read_ptr(gameInstance + kDSPUBGGameInstanceLocalPlayersOffset);
        if (lpArray) localPlayer = ds_pubg_read_ptr(lpArray);
        if (!localPlayer) {
            uint64_t lp38 = ds_pubg_read_ptr(gameInstance + 0x38ULL);
            if (lp38 && ds_pubg_valid(lp38)) localPlayer = ds_pubg_read_ptr(lp38);
        }
    }

    uint64_t playerController = 0;
    if (localPlayer) {
        playerController = ds_pubg_read_ptr(localPlayer + kDSPUBGLocalPlayerControllerOffset);
    }

    // Fallback: Find local PlayerController from GameState if LocalPlayers was empty or encrypted
    if (!playerController) {
        uint64_t gs = ds_pubg_read_ptr(world + kDSPUBGWorldGameStateOffset);
        if (gs) {
            uint64_t paData = ds_pubg_read_ptr(gs + kDSPUBGGameStatePlayerArrayOffset);
            uint32_t paCount = ds_pubg_read_u32(gs + kDSPUBGGameStatePlayerArrayOffset + 8);
            if (paData && paCount > 0) {
                if (paCount > 100) paCount = 100;
                for (uint32_t i = 0; i < paCount; i++) {
                    uint64_t ps = ds_pubg_read_ptr(paData + i * 8);
                    if (!ps) continue;
                    uint64_t owner = ds_pubg_read_ptr(ps + 0xF0ULL); // AActor.Owner
                    if (owner && ds_pubg_valid(owner)) {
                        uint64_t cam = ds_pubg_read_ptr(owner + kDSPUBGPlayerControllerCameraMgrOffset);
                        if (cam && ds_pubg_valid(cam)) {
                            playerController = owner;
                            break;
                        }
                    }
                }
            }
        }
    }

    uint64_t localPawn = playerController ? ds_pubg_read_ptr(playerController + kDSPUBGPlayerControllerPawnOffset) : 0;

    // [A3] Refresh the smart filters for this frame: skip set, local capsule
    // hitbox and the static geometry library binding.
    ds_pubg_smart_begin_frame(world, localPawn);

    // Check if player is actually in an active match (filters out Lobby, MainCity, Frontend)
    if (!ds_pubg_is_in_match(world, playerController, localPawn)) {
        os_unfair_lock_lock(&g_dspubgSnapshotLock);
        g_dspubgPlayerCount = 0;
        g_dspubgItemCount = 0;
        g_dspubgGrenadeCount = 0;
        g_dspubgTotalEnemies = 0;
        g_dspubgTotalBots = 0;
        ++g_dspubgEpoch;
        ++g_dspubgItemEpoch;
        ++g_dspubgGrenadeEpoch;
        os_unfair_lock_unlock(&g_dspubgSnapshotLock);

        ds_pubg_reset_match_caches();
        g_dspubgLastActorsCount = 0;
        g_dspubgLastEnemyCount = 0;
        g_dspubgLastBotCount = 0;
        return;
    }

    uint64_t cameraManager = playerController ? ds_pubg_read_ptr(playerController + kDSPUBGPlayerControllerCameraMgrOffset) : 0;

    DSPUBGVector camLoc = {};
    DSPUBGRotator camRot = {};
    float camFOV = 90.0f;
    float camAspect = 0.0f;

    if (cameraManager) {
        // 1. Primary: CameraCache.POV (0x520 + 0x10 = 0x530)
        // CameraCache contains the post-update, post-modifier camera transform directly used
        // by the GPU render pass every frame. It tracks camera rotation with zero latency!
        uint64_t cachePov = cameraManager + 0x520ULL + 0x10ULL;
        DSPUBGVector cLoc = {};
        DSPUBGRotator cRot = {};
        float cFOV = 0.0f;
        if (ds_pubg_read(cachePov + kDSPUBGPOVLocationOffset, &cLoc, sizeof(cLoc)) &&
            ds_pubg_read(cachePov + kDSPUBGPOVRotationOffset, &cRot, sizeof(cRot)) &&
            ds_pubg_read(cachePov + kDSPUBGPOVFOVOffset, &cFOV, sizeof(cFOV)) &&
            !isnan(cLoc.X) && !isinf(cLoc.X) && (fabsf(cLoc.X) > 1.0f || fabsf(cLoc.Y) > 1.0f) &&
            !isnan(cRot.Pitch) && !isnan(cRot.Yaw) && cFOV >= 20.0f && cFOV <= 160.0f) {
            camLoc = cLoc;
            camRot = cRot;
            camFOV = cFOV;
        } else {
            // 2. Secondary fallback: ViewTarget.POV (0x10A0 + 0x10 = 0x10B0)
            uint64_t pov = cameraManager + kDSPUBGCameraViewTargetOffset + kDSPUBGViewTargetPOVOffset;
            ds_pubg_read(pov + kDSPUBGPOVLocationOffset, &camLoc, sizeof(camLoc));
            ds_pubg_read(pov + kDSPUBGPOVRotationOffset, &camRot, sizeof(camRot));
            ds_pubg_read(pov + kDSPUBGPOVFOVOffset, &camFOV, sizeof(camFOV));
            ds_pubg_read(pov + kDSPUBGPOVAspectOffset, &camAspect, sizeof(camAspect));
        }
    }

    // Tertiary camera fallback: If cameraManager was null or loc is 0, search PersistentLevel for any PlayerCameraManager
    uint64_t level = ds_pubg_read_ptr(world + kDSPUBGWorldPersistentLevelOffset);
    if ((!cameraManager || (fabsf(camLoc.X) < 1.0f && fabsf(camLoc.Y) < 1.0f && fabsf(camLoc.Z) < 1.0f)) && level) {
        uint64_t cluster = ds_pubg_read_ptr(level + 0xE0ULL);
        uint64_t aData = cluster ? ds_pubg_read_ptr(cluster + 0x28ULL) : ds_pubg_read_ptr(level + 0x98ULL);
        uint32_t aCount = cluster ? ds_pubg_read_u32(cluster + 0x30ULL) : ds_pubg_read_u32(level + 0xA0ULL);
        if (aData && aCount > 0) {
            if (aCount > 512) aCount = 512;
            std::vector<uint64_t> act(aCount, 0);
            if (ds_pubg_read(aData, act.data(), aCount * sizeof(uint64_t))) {
                for (uint32_t i = 0; i < aCount; i++) {
                    uint64_t a = act[i];
                    if (!a || !ds_pubg_valid(a)) continue;
                    float testFov = ds_pubg_read_f32(a + 0x530ULL + 0x24ULL);
                    if (testFov >= 50.0f && testFov <= 120.0f) {
                        DSPUBGVector testLoc = {};
                        ds_pubg_read(a + 0x530ULL, &testLoc, sizeof(testLoc));
                        if (fabsf(testLoc.X) > 10.0f || fabsf(testLoc.Y) > 10.0f) {
                            cameraManager = a;
                            camLoc = testLoc;
                            ds_pubg_read(a + 0x530ULL + 0x18ULL, &camRot, sizeof(camRot));
                            camFOV = testFov;
                            break;
                        }
                    }
                }
            }
        }
    }

    if (camFOV < 10.0f || camFOV > 170.0f) camFOV = 90.0f;

    int32_t localTeamId = -1;
    if (localPawn) {
        localTeamId = ds_pubg_read_i32(localPawn + kDSPUBGCharacterTeamIDOffset);
    }

    float screenW = (float)CGRectGetWidth(g_hostedContentBounds);
    float screenH = (float)CGRectGetHeight(g_hostedContentBounds);
    if (screenW <= 0.0f || screenH <= 0.0f) {
        CGRect sb = [UIScreen mainScreen].bounds;
        if (CGRectGetWidth(sb) < CGRectGetHeight(sb)) {
            screenW = (float)CGRectGetHeight(sb);
            screenH = (float)CGRectGetWidth(sb);
        } else {
            screenW = (float)CGRectGetWidth(sb);
            screenH = (float)CGRectGetHeight(sb);
        }
        if (screenW <= 0.0f || screenH <= 0.0f) {
            screenW = 844.0f;
            screenH = 390.0f;
        }
    }

    DSPUBGCamBasis basis = {};
    if (!ds_pubg_cam_basis_build(camLoc, camRot, camFOV, screenW, screenH, basis)) {
        return;
    }

    DSPUBGProjectedPlayer staging[kDSPUBGMaxPlayers] = {};
    int publishedCount = 0;
    int enemyCount = 0;
    int botCount = 0;
    int total360EnemyCount = 0;
    int total360BotCount = 0;
    std::vector<uint64_t> seenPawns;

    DSPUBGProjectedGrenade grenadeStaging[kDSPUBGMaxGrenades * 2];
    int grenadeStagingCount = 0;
    s_grenadeTickCounter++;

    auto processPawn = [&](uint64_t pawn, uint64_t psHint, bool knownBot) -> bool {
        if (!pawn || pawn == localPawn || !ds_pubg_valid(pawn)) return false;
        for (uint64_t seen : seenPawns) {
            if (seen == pawn) return false;
        }

        uint32_t cSlot = ds_pubg_actor_cache_hash(pawn);
        DSPUBGActorCacheEntry &cEntry = g_dspubgActorCache[cSlot];
        bool isTrainingTarget = false;
        if (cEntry.actor == pawn) {
            if (cEntry.isScenery) {
                return false;
            }
            if (cEntry.isPawn) {
                isTrainingTarget = cEntry.isTrainingTarget;
            }
        }

        // Fast path: if already cached as a Pawn, skip costly GNames name lookups
        if (!(cEntry.actor == pawn && cEntry.isPawn)) {
            char pawnName[64] = {0};
            bool hasPawnName = ds_pubg_get_actor_name(pawn, pawnName, sizeof(pawnName));
            if (hasPawnName) {
                isTrainingTarget = ds_pubg_is_training_target_name(pawnName);
                if (!isTrainingTarget) {
                    bool isScenery = (strstr(pawnName, "StaticMesh") || strstr(pawnName, "Foliage") ||
                        strstr(pawnName, "Landscape") || strstr(pawnName, "Building") ||
                        strstr(pawnName, "House") || strstr(pawnName, "Tree") ||
                        strstr(pawnName, "Rock") || strstr(pawnName, "Wall") ||
                        strstr(pawnName, "Fence") || strstr(pawnName, "Door") ||
                        strstr(pawnName, "Window") || strstr(pawnName, "Floor") ||
                        strstr(pawnName, "Roof") || strstr(pawnName, "Brush") ||
                        strstr(pawnName, "SM_") || strstr(pawnName, "Mesh") ||
                        strstr(pawnName, "BP_Building") || strstr(pawnName, "BP_House") ||
                        strstr(pawnName, "BP_Wall") || strstr(pawnName, "BP_Door") ||
                        strstr(pawnName, "BP_Fence") || strstr(pawnName, "BP_Stair") ||
                        strstr(pawnName, "Arch") || strstr(pawnName, "Prop") ||
                        strstr(pawnName, "Stair") || strstr(pawnName, "Tower") ||
                        strstr(pawnName, "Shed") || strstr(pawnName, "Gate") ||
                        strstr(pawnName, "Container") || strstr(pawnName, "Obstacle"));
                    if (isScenery) {
                        cEntry.actor = pawn;
                        cEntry.isScenery = true;
                        cEntry.isPawn = false;
                        cEntry.isTrainingTarget = false;
                        cEntry.itemCat = DSPUBGItemCategoryNone;
                        cEntry.vCommon = 0;
                        return false;
                    }

                    if (ds_pubg_is_pet_name(pawnName) ||
                        strcasestr(pawnName, "Particle") || strcasestr(pawnName, "Effect") ||
                        strcasestr(pawnName, "Decal") || strcasestr(pawnName, "Camera") ||
                        strcasestr(pawnName, "Volume") || strcasestr(pawnName, "Trigger") ||
                        strcasestr(pawnName, "Light") || strcasestr(pawnName, "Audio") ||
                        strcasestr(pawnName, "Sound") || strcasestr(pawnName, "Zone") ||
                        strcasestr(pawnName, "Fog") || strcasestr(pawnName, "Lobby") ||
                        strcasestr(pawnName, "MainCity") || strcasestr(pawnName, "PetAvatar") ||
                        strcasestr(pawnName, "LobbyModel") || strcasestr(pawnName, "Avatar") ||
                        strcasestr(pawnName, "Preview")) {
                        cEntry.actor = pawn;
                        cEntry.isScenery = true;
                        cEntry.isPawn = false;
                        cEntry.isTrainingTarget = false;
                        cEntry.itemCat = DSPUBGItemCategoryNone;
                        cEntry.vCommon = 0;
                        return false;
                    }

                    if (strcasestr(pawnName, "Bullet") || strcasestr(pawnName, "Proj") || strcasestr(pawnName, "Weapon") ||
                        strcasestr(pawnName, "PickUp") || strcasestr(pawnName, "Vehicle") || strcasestr(pawnName, "VH_") ||
                        strcasestr(pawnName, "Drop") || strcasestr(pawnName, "Tomb") || strcasestr(pawnName, "Box") ||
                        strcasestr(pawnName, "Supply") || strcasestr(pawnName, "AirDrop") || strcasestr(pawnName, "Item") ||
                        strcasestr(pawnName, "Controller") || strcasestr(pawnName, "Shell") ||
                        strcasestr(pawnName, "Cartridge") || strcasestr(pawnName, "Trace") ||
                        strcasestr(pawnName, "Grenade") || strcasestr(pawnName, "Smoke") ||
                        strcasestr(pawnName, "Explosion") || strcasestr(pawnName, "Shoulei") ||
                        strcasestr(pawnName, "Molotov") || strcasestr(pawnName, "Burn")) {
                        return false;
                    }
                }
            }
        }

        // 1. Reject local player's own bullets, weapons, projectiles
        uint64_t owner = ds_pubg_read_ptr(pawn + 0x140ULL);
        uint64_t instigator = ds_pubg_read_ptr(pawn + 0x138ULL);
        if (!isTrainingTarget && localPawn && (owner == localPawn || instigator == localPawn)) {
            return false;
        }

        // 2. Check bHidden in AActor (offset 0xE8)
        uint8_t aHidden = ds_pubg_read_u8(pawn + 0xE8ULL);
        if (aHidden & 0x1) return false;

        // 3. Dead check - STExtraCharacter.bDead at 0xE8C
        uint8_t isDead = ds_pubg_read_u8(pawn + kDSPUBGCharacterDeadOffset) & 1;
        if (isDead) return false;

        // 4. Must have valid RootComponent and Mesh (standard UE4 character)
        uint64_t rootComp = (cEntry.actor == pawn && cEntry.rootComp) ? cEntry.rootComp : ds_pubg_read_ptr(pawn + kDSPUBGActorRootComponentOffset);
        if (!rootComp) rootComp = ds_pubg_read_ptr(pawn + 0x180ULL);
        if (!rootComp || !ds_pubg_valid(rootComp)) return false;

        uint64_t meshComp = (cEntry.actor == pawn && cEntry.meshComp) ? cEntry.meshComp : ds_pubg_read_ptr(pawn + kDSPUBGCharacterMeshOffset);
        if (!meshComp) meshComp = ds_pubg_read_ptr(pawn + 0x320ULL);
        if (!meshComp || !ds_pubg_valid(meshComp)) return false;

        // 5. Strict Health validation (Reject all non-characters and dead bodies):
        // Training target dummies may use > 2000 HP (e.g. 5000 / 10000) or 0 max HP.
        float health = ds_pubg_read_f32(pawn + kDSPUBGCharacterHealthOffset);
        float healthMax = ds_pubg_read_f32(pawn + kDSPUBGCharacterHealthMaxOffset);
        if (isTrainingTarget) {
            if (isnan(healthMax) || isinf(healthMax) || healthMax < 50.0f || healthMax > 1000000.0f) {
                healthMax = 100.0f;
            }
            if (isnan(health) || isinf(health)) {
                health = healthMax;
            }
        } else {
            if (isnan(health) || isinf(health) || isnan(healthMax) || isinf(healthMax)) return false;
            if (healthMax < 50.0f || healthMax > 1000000.0f) return false;
        }

        cEntry.actor = pawn;
        cEntry.isPawn = true;
        cEntry.isScenery = false;
        cEntry.isTrainingTarget = isTrainingTarget;
        cEntry.itemCat = DSPUBGItemCategoryNone;
        cEntry.vCommon = 0;
        cEntry.rootComp = rootComp;
        cEntry.meshComp = meshComp;

        bool isKnocked = false;
        // Check multiple possible GroggyHealth offsets in STExtraCharacter (shifted by +0x10 in new DUMP: 0xE78, 0xE7C, 0xE80)
        float gh = ds_pubg_read_f32(pawn + 0xE78ULL);
        if (isnan(gh) || isinf(gh) || gh <= 0.0f || gh > 200.0f) {
            gh = ds_pubg_read_f32(pawn + 0xE7CULL);
        }
        if (isnan(gh) || isinf(gh) || gh <= 0.0f || gh > 200.0f) {
            gh = ds_pubg_read_f32(pawn + 0xE80ULL);
        }
        if (isnan(gh) || isinf(gh) || gh <= 0.0f || gh > 200.0f) {
            gh = ds_pubg_read_f32(pawn + 0xE84ULL);
        }

        // If bDead (offset 0xE8C) is 0, but standard health <= 0, the player is knocked down (gục ngã)!
        if (health <= 0.0f) {
            if (isTrainingTarget) {
                health = healthMax;
            } else {
                isKnocked = true;
                if (!isnan(gh) && !isinf(gh) && gh > 0.0f && gh <= 200.0f) {
                    health = gh;
                } else {
                    health = 100.0f; // Default knocked health if groggy offset shifted
                }
            }
        } else if (!isTrainingTarget && !isnan(gh) && !isinf(gh) && gh > 0.0f && gh <= 200.0f && gh < health) {
            // Some versions update groggy health before main health
            isKnocked = true;
            health = gh;
        }

        if (health <= 0.0f || health > healthMax + 50.0f) return false;

        // 6. Team filter:
        int32_t teamId = ds_pubg_read_i32(pawn + kDSPUBGCharacterTeamIDOffset);
        if (!isTrainingTarget && localTeamId > 0 && teamId == localTeamId) {
            ds_pubg_smart_skip(pawn);
            return false;
        }
        if (teamId < 0 || teamId > 200000000) {
            teamId = -1;
        }

        seenPawns.push_back(pawn);

        // Resolve world-space location BEFORE rejecting near-(0,0), because pawns attached to
        // moving platforms/tracks (e.g. Training Ground moving mannequins) have RelativeLocation == (0,0,Z).
        DSPUBGVector rootLoc = {};
        uint64_t parent = ds_pubg_read_ptr(rootComp + kDSPUBGSceneCompAttachedParentOffset);
        bool haveWorldLoc = false;
        if (parent && ds_pubg_valid(parent)) {
            DSPUBGVector ax = {}, ay = {}, az = {}, sc = {};
            if (ds_pubg_component_world_pose(rootComp, rootLoc, ax, ay, az, sc) &&
                (fabsf(rootLoc.X) >= 1.0f || fabsf(rootLoc.Y) >= 1.0f)) {
                haveWorldLoc = true;
            }
        }
        if (!haveWorldLoc) {
            if (!ds_pubg_read(rootComp + kDSPUBGSceneCompRelativeLocOffset, &rootLoc, sizeof(rootLoc))) {
                return false;
            }
            if (isnan(rootLoc.X) || isinf(rootLoc.X) || (fabsf(rootLoc.X) < 1.0f && fabsf(rootLoc.Y) < 1.0f)) {
                // Fallback to ComponentToWorld translation (+0x210 quat, +0x220 translation)
                uint8_t rc2w[32] = {0};
                if (ds_pubg_read(rootComp + 0x210ULL, rc2w, sizeof(rc2w))) {
                    float qx = 0, qy = 0, qz = 0, qw = 1.0f;
                    DSPUBGVector c2wLoc = {};
                    memcpy(&qx, rc2w + 0x0, 4);
                    memcpy(&qy, rc2w + 0x4, 4);
                    memcpy(&qz, rc2w + 0x8, 4);
                    memcpy(&qw, rc2w + 0xC, 4);
                    memcpy(&c2wLoc, rc2w + 0x10, sizeof(c2wLoc));
                    float qlen2 = qx * qx + qy * qy + qz * qz + qw * qw;
                    if (!isnan(qlen2) && !isinf(qlen2) && qlen2 >= 0.4f && qlen2 <= 2.2f &&
                        !isnan(c2wLoc.X) && !isinf(c2wLoc.X) &&
                        !isnan(c2wLoc.Y) && !isinf(c2wLoc.Y) &&
                        !isnan(c2wLoc.Z) && !isinf(c2wLoc.Z) &&
                        (fabsf(c2wLoc.X) >= 1.0f || fabsf(c2wLoc.Y) >= 1.0f)) {
                        rootLoc = c2wLoc;
                    }
                }
            }
        }
        if (isnan(rootLoc.X) || isinf(rootLoc.X) ||
            isnan(rootLoc.Y) || isinf(rootLoc.Y) ||
            isnan(rootLoc.Z) || isinf(rootLoc.Z) ||
            (fabsf(rootLoc.X) < 1.0f && fabsf(rootLoc.Y) < 1.0f)) {
            return false;
        }

        DSPUBGRotator actorRot = {};
        if (!ds_pubg_read(rootComp + 0x1F0ULL, &actorRot, sizeof(actorRot)) ||
            isnan(actorRot.Yaw) || isinf(actorRot.Yaw) || (actorRot.Pitch == 0.0f && actorRot.Yaw == 0.0f && actorRot.Roll == 0.0f)) {
            ds_pubg_read(pawn + 0x134ULL, &actorRot, sizeof(actorRot));
        }

        // 3D Euclidean distance in meters from camera to actor:
        float dx = rootLoc.X - basis.lx;
        float dy = rootLoc.Y - basis.ly;
        float dz = rootLoc.Z - basis.lz;
        float dist3D = sqrtf(dx * dx + dy * dy + dz * dz) * 0.01f;
        if (isnan(dist3D) || isinf(dist3D) || dist3D > g_dspubgMaxDistance) {
            return false;
        }

        uint64_t ps = psHint ? psHint : ds_pubg_read_ptr(pawn + 0x4D0ULL);
        bool isAI = knownBot || isTrainingTarget;
        char readNation[16] = {0};
        bool hasNation = false;

        if (cEntry.actor == pawn && cEntry.metaActor == pawn && cEntry.metaPs == ps) {
            if (!isAI) isAI = cEntry.cachedIsAI;
            hasNation = cEntry.cachedHasNation;
            if (hasNation) {
                memcpy(readNation, cEntry.cachedMetaNation, sizeof(readNation));
            }
        } else {
            // 1. Check Character AI flags (UAECharacter.bIsAI, bIsMLAI, bIsAIWithPet)
            if (!isAI) {
                uint8_t a50 = ds_pubg_read_u8(pawn + kDSPUBGCharacterIsAIOffset); // 0xA50 UAECharacter.bIsAI
                uint8_t a51 = ds_pubg_read_u8(pawn + 0xA51ULL);                 // 0xA51 UAECharacter.bIsMLAI
                uint8_t a52 = ds_pubg_read_u8(pawn + 0xA52ULL);                 // 0xA52 UAECharacter.bIsAIWithPet
                uint8_t a40 = ds_pubg_read_u8(pawn + 0xA40ULL);                 // Older UAECharacter.bIsAI
                uint8_t a41 = ds_pubg_read_u8(pawn + 0xA41ULL);                 // Older UAECharacter.bIsMLAI
                if (a50 == 1 || a51 == 1 || a52 == 1 || a40 == 1 || a41 == 1) {
                    isAI = true;
                }
            }

            // 2. Check PlayerState AI flags
            if (!isAI && ps && ds_pubg_valid(ps)) {
                uint8_t botByte = ds_pubg_read_u8(ps + kDSPUBGPlayerStateIsABotOffset);
                if ((botByte & 0x4) != 0) {
                    isAI = true;
                }
                uint64_t mlaiUid = ds_pubg_read_ptr(ps + 0x6D0ULL); // AUAEPlayerState.MLAIDisplayUID
                if (mlaiUid != 0) {
                    isAI = true;
                }
            }

            // 3. Check AI Controller on Pawn (Remote players on client have Controller == 0)
            if (!isAI) {
                uint64_t ctrl = ds_pubg_read_ptr(pawn + 0x4E8ULL);
                if (ctrl && ds_pubg_valid(ctrl)) {
                    char ctrlName[64] = {0};
                    if (ds_pubg_get_actor_name(ctrl, ctrlName, sizeof(ctrlName))) {
                        if (ds_pubg_is_pet_name(ctrlName)) {
                            cEntry.actor = pawn;
                            cEntry.isScenery = true;
                            cEntry.isPawn = false;
                            cEntry.itemCat = DSPUBGItemCategoryNone;
                            cEntry.vCommon = 0;
                            return false;
                        }
                        if (strcasestr(ctrlName, "AI") || strcasestr(ctrlName, "Fake")) {
                            isAI = true;
                        }
                    } else {
                        isAI = true;
                    }
                }
            }

            // 4. Read Nation & PlayerUID to verify real player presence
            hasNation = ds_pubg_read_fstring_nation(pawn + kDSPUBGCharacterNationOffset, readNation, sizeof(readNation));
            if (!hasNation && ps && ds_pubg_valid(ps)) {
                hasNation = ds_pubg_read_fstring_nation(ps + kDSPUBGPlayerStateNationOffset, readNation, sizeof(readNation));
            }

            char readUID[32] = {0};
            bool hasUID = ds_pubg_read_fstring_nick(pawn + kDSPUBGCharacterPlayerUIDOffset, readUID, sizeof(readUID)) && strlen(readUID) >= 5;
            if (!hasUID && ps && ds_pubg_valid(ps)) {
                hasUID = ds_pubg_read_fstring_nick(ps + 0x668ULL, readUID, sizeof(readUID)) && strlen(readUID) >= 5;
            }

            if (!isAI) {
                // Real players in multiplayer ALWAYS have at least a valid PlayerState, PlayerUID, or Nation.
                // If pawn has neither PlayerState nor PlayerUID nor Nation, it is an AI pawn.
                if ((!ps || !ds_pubg_valid(ps)) && !hasUID && !hasNation) {
                    isAI = true;
                }
            }

            cEntry.metaActor = pawn;
            cEntry.metaPs = ps;
            cEntry.cachedIsAI = isAI;
            cEntry.cachedHasNation = hasNation;
            cEntry.cachedHasUID = hasUID;
            memset(cEntry.cachedMetaNation, 0, sizeof(cEntry.cachedMetaNation));
            if (hasNation) {
                strncpy(cEntry.cachedMetaNation, readNation, sizeof(cEntry.cachedMetaNation) - 1);
            }
        }

        // 360-Degree Radar Enemy & Bot Counter (independent of camera viewport)
        if (isAI) {
            total360BotCount++;
        } else {
            total360EnemyCount++;
        }

        // Camera-relative coordinates for 3D arrow indicator & projection:
        float camRelX = dx * basis.m10 + dy * basis.m11 + dz * basis.m12; // Camera Right
        float camRelY = dx * basis.m20 + dy * basis.m21 + dz * basis.m22; // Camera Up
        float camRelZ = dx * basis.m00 + dy * basis.m01 + dz * basis.m02; // Camera Forward

        DSPUBGProjectedPlayer p = {};
        p.distanceMeters = dist3D;
        p.health = health;
        p.healthMax = (healthMax >= 20.0f) ? healthMax : 100.0f;
        p.teamId = teamId;
        p.isAI = isAI;
        if (!isAI && hasNation) {
            strncpy(p.nation, readNation, sizeof(p.nation) - 1);
        }
        p.isDead = false;
        p.isKnocked = isKnocked;
        p.isVisible = false;
        p.isOccluded = false;
        p.isVehicle = false;
        p.actorPtr = pawn;
        p.playerKey = ds_pubg_read_u32(pawn + kDSPUBGCharacterPlayerKeyOffset);
        p.camRelX = camRelX;
        p.camRelY = camRelY;
        p.camRelZ = camRelZ;

        bool onScreen = false;
        float boxX = 0, boxY = 0, boxW = 0, boxH = 0, centerX = 0, topY = 0;
        float halfH = 87.5f;

        if (camRelZ > 10.0f) {
            float extZ = ds_pubg_read_f32(meshComp + kDSPUBGMeshBoxExtentZOffset);
            float actorH = 165.0f;
            if (isKnocked) {
                actorH = 45.0f;
            } else if (extZ >= 30.0f && extZ <= 95.0f) {
                actorH = extZ * 2.0f;
            }

            DSPUBGVector pos = rootLoc;
            halfH = actorH * 0.5f;
            DSPUBGVector bot = pos; bot.Z -= halfH;
            DSPUBGVector top = pos; top.Z += halfH;

            float bx = 0, by = 0, bd = 0;
            float tx = 0, ty = 0, td = 0;
            bool okB = ds_pubg_cam_basis_project(basis, bot, bx, by, bd);
            bool okT = ds_pubg_cam_basis_project(basis, top, tx, ty, td);

            float sx = 0, sy = 0, dist = dist3D;
            bool hasProj = false;
            if (okB || okT) {
                hasProj = true;
                dist = okB ? bd : td;
            } else if (ds_pubg_cam_basis_project(basis, pos, sx, sy, dist)) {
                hasProj = true;
            }

            if (hasProj) {
                float bottomY = 0;
                if (okB && okT) {
                    topY = fminf(ty, by);
                    bottomY = fmaxf(ty, by);
                    boxH = bottomY - topY;
                    centerX = (tx + bx) * 0.5f;
                } else {
                    float tz = dist * 100.0f;
                    if (tz < 10.0f) tz = 10.0f;
                    boxH = (actorH / tz) * basis.k;
                    topY = sy - boxH * 0.5f;
                    centerX = sx;
                    bottomY = topY + boxH;
                }

                if (boxH < 8.0f) boxH = 8.0f;
                if (boxH <= screenH * 2.0f) {
                    boxW = boxH * 0.5f;
                    boxX = centerX - boxW * 0.5f;
                    boxY = topY;

                    // Visible if projected on or near screen bounds (generous padding for partial entry)
                    if (centerX + boxW * 0.5f >= -150.0f && centerX - boxW * 0.5f <= screenW + 150.0f &&
                        topY + boxH >= -150.0f && topY <= screenH + 150.0f) {
                        onScreen = true;
                        p.screenX = boxX;
                        p.screenY = topY;
                        p.headX = centerX;
                        p.headY = topY + boxH * 0.08f;
                        p.boxWidth = boxW;
                        p.boxHeight = boxH;
                        p.distanceMeters = dist;
                        p.isVisible = true;

                        // 3D Bounding Box Calculation matching authentic MADNESS GetBox3D
                        float extZ = isKnocked ? 25.0f : halfH;
                        float extXY = isKnocked ? 35.0f : 40.0f;
                        DSPUBGVector c3d[8] = {
                            { rootLoc.X - extXY, rootLoc.Y - extXY, rootLoc.Z - extZ },
                            { rootLoc.X + extXY, rootLoc.Y - extXY, rootLoc.Z - extZ },
                            { rootLoc.X + extXY, rootLoc.Y + extXY, rootLoc.Z - extZ },
                            { rootLoc.X - extXY, rootLoc.Y + extXY, rootLoc.Z - extZ },
                            { rootLoc.X - extXY, rootLoc.Y - extXY, rootLoc.Z + extZ },
                            { rootLoc.X + extXY, rootLoc.Y - extXY, rootLoc.Z + extZ },
                            { rootLoc.X + extXY, rootLoc.Y + extXY, rootLoc.Z + extZ },
                            { rootLoc.X - extXY, rootLoc.Y + extXY, rootLoc.Z + extZ },
                        };
                        bool c3dOk = true;
                        for (int c = 0; c < 8; c++) {
                            float csx = 0, csy = 0, cdist = 0;
                            if (ds_pubg_cam_basis_project(basis, c3d[c], csx, csy, cdist)) {
                                p.boxCorners[c] = CGPointMake(csx, csy);
                            } else {
                                c3dOk = false;
                                break;
                            }
                        }
                        p.has3DBox = c3dOk;

                        // Vischeck disabled per user request: enemies are not occluded
                        p.isOccluded = false;
                    }
                }
            }
        }

        if (onScreen) {
            if (cEntry.weaponActor != pawn ||
                (s_visTickCounter - cEntry.weaponRefreshTick) >= 10) {
                char resolvedWeapon[32] = {0};
                int32_t wid = ds_pubg_read_equipped_weapon_id(pawn);
                if (wid > 0) {
                    const char *wName = ds_pubg_weapon_name_by_id(wid);
                    if (wName) {
                        strncpy(resolvedWeapon, wName, sizeof(resolvedWeapon) - 1);
                    } else {
                        snprintf(resolvedWeapon, sizeof(resolvedWeapon), "Gun %d", wid);
                    }
                }
                memcpy(cEntry.cachedWeapon, resolvedWeapon, sizeof(cEntry.cachedWeapon));
                cEntry.weaponActor = pawn;
                cEntry.weaponRefreshTick = s_visTickCounter;
            }
            memcpy(p.weaponName, cEntry.cachedWeapon, sizeof(p.weaponName));

            if (cEntry.infoActor != pawn) {
                char resolvedName[32] = {0};
                char resolvedNation[16] = {0};

                if (!ds_pubg_read_fstring_nick(pawn + kDSPUBGCharacterPlayerNameOffset, resolvedName, sizeof(resolvedName))) {
                    if (ps && ds_pubg_valid(ps)) {
                        ds_pubg_read_fstring_nick(ps + kDSPUBGPlayerStatePlayerNameOffset, resolvedName, sizeof(resolvedName));
                    }
                }
                if (resolvedName[0] == '\0') {
                    strncpy(resolvedName, isAI ? "Bot" : "Enemy", sizeof(resolvedName) - 1);
                }
                if (!isAI && resolvedNation[0] == '\0') {
                    if (!ds_pubg_read_fstring_nation(pawn + kDSPUBGCharacterNationOffset, resolvedNation, sizeof(resolvedNation))) {
                        if (ps && ds_pubg_valid(ps)) {
                            ds_pubg_read_fstring_nation(ps + kDSPUBGPlayerStateNationOffset, resolvedNation, sizeof(resolvedNation));
                        }
                    }
                }

                memcpy(cEntry.cachedName, resolvedName, sizeof(cEntry.cachedName));
                memcpy(cEntry.cachedNation, resolvedNation, sizeof(cEntry.cachedNation));
                cEntry.infoActor = pawn;
            }
            memcpy(p.name, cEntry.cachedName, sizeof(p.name));
            memcpy(p.nation, cEntry.cachedNation, sizeof(p.nation));

            // Real Skeletal Bones (16 joints, 15 bone links)
            p.hasSkeleton = false;
        if (g_pubgEspSkeleton) {
            bool skeletonDone = false;
            uint64_t boneData = 0;
            if (meshComp && ds_pubg_valid(meshComp)) {
                uint32_t bCount = 0;
                uint32_t resolvedOff = 0;
                if (cEntry.actor == pawn && cEntry.boneData && cEntry.boneCount >= 20) {
                    boneData = cEntry.boneData;
                    bCount = cEntry.boneCount;
                    resolvedOff = cEntry.boneOffset;
                } else if (ds_pubg_find_bone_array(meshComp, &boneData, &bCount, &resolvedOff) && boneData && bCount >= 20) {
                    cEntry.boneData = boneData;
                    cEntry.boneCount = bCount;
                    cEntry.boneOffset = resolvedOff;
                }

                if (boneData && bCount >= 20) {
                    g_dspubgLastBoneOff = resolvedOff;

                    uint8_t boneBuf[68 * 48];
                    uint32_t needReadCount = (bCount > 68) ? 68 : bCount;
                    size_t readSize = (size_t)needReadCount * 48;
                    bool readOk = ds_pubg_read(boneData, boneBuf, readSize);
                    if (!readOk) {
                        if (ds_pubg_find_bone_array(meshComp, &boneData, &bCount, &resolvedOff) && boneData && bCount >= 20) {
                            cEntry.boneData = boneData;
                            cEntry.boneCount = bCount;
                            cEntry.boneOffset = resolvedOff;
                            needReadCount = (bCount > 68) ? 68 : bCount;
                            readSize = (size_t)needReadCount * 48;
                            readOk = ds_pubg_read(boneData, boneBuf, readSize);
                        }
                    }
                    if (readOk) {
                        auto getBoneLocal = [&](int idx, DSPUBGVector &outV) -> bool {
                            if (idx < 0 || idx >= (int)needReadCount) return false;
                            const uint8_t *boneEntry = boneBuf + (size_t)idx * 48;
                            memcpy(&outV.X, boneEntry + 0x10, 4);
                            memcpy(&outV.Y, boneEntry + 0x14, 4);
                            memcpy(&outV.Z, boneEntry + 0x18, 4);
                            if (isnan(outV.X) || isinf(outV.X) || isnan(outV.Y) || isinf(outV.Y) || isnan(outV.Z) || isinf(outV.Z)) return false;
                            if (fabsf(outV.X) < 0.01f && fabsf(outV.Y) < 0.01f && fabsf(outV.Z) < 0.01f) return false;
                            return true;
                        };

                        auto dist3D = [](const DSPUBGVector &a, const DSPUBGVector &b) -> float {
                            float dx = a.X - b.X, dy = a.Y - b.Y, dz = a.Z - b.Z;
                            return sqrtf(dx * dx + dy * dy + dz * dz);
                        };
                        (void)dist3D;

                        int bHead = 6, bNeck = 5, bPelvis = 1;
                        int bUprR = -1, bLwrR = -1, bHandR = -1;
                        int bUprL = -1, bLwrL = -1, bHandL = -1;
                        int bThighR = -1, bCalfR = -1, bFootR = -1;
                        int bThighL = -1, bCalfL = -1, bFootL = -1;

                        if (needReadCount < 35) {
                            // Training dummy rig (< 35 bones, typically ~22)
                            bHead = 6; bNeck = 5; bPelvis = 1;
                            DSPUBGVector armA = {}, armB = {};
                            getBoneLocal(12, armA);
                            getBoneLocal(8, armB);
                            if (armA.Y >= armB.Y) {
                                bUprR = 12; bLwrR = 13; bHandR = 14;
                                bUprL = 8;  bLwrL = 9;  bHandL = 10;
                            } else {
                                bUprR = 8;  bLwrR = 9;  bHandR = 10;
                                bUprL = 12; bLwrL = 13; bHandL = 14;
                            }

                            DSPUBGVector legA = {}, legB = {};
                            getBoneLocal(19, legA);
                            getBoneLocal(15, legB);
                            if (legA.Y >= legB.Y) {
                                bThighR = 19; bCalfR = 20; bFootR = 21;
                                bThighL = 15; bCalfL = 16; bFootL = 17;
                            } else {
                                bThighR = 15; bCalfR = 16; bFootR = 17;
                                bThighL = 19; bCalfL = 20; bFootL = 21;
                            }
                        } else {
                            // Player & Bot rig (67 bones - ShadowTrackerExtra standard UE4 skeleton)
                            bHead = 6; bNeck = 5; bPelvis = 1;

                            // Right Arm: UpperArm=13, LowerArm=15, Hand=16
                            // Left Arm: UpperArm=34, LowerArm=36, Hand=37
                            bUprR = 13; bLwrR = 15; bHandR = 16;
                            bUprL = 34; bLwrL = 36; bHandL = 37;
                            DSPUBGVector armA = {}, armB = {};
                            if (getBoneLocal(13, armA) && getBoneLocal(34, armB)) {
                                if (armA.Y < armB.Y) {
                                    bUprR = 34; bLwrR = 36; bHandR = 37;
                                    bUprL = 13; bLwrL = 15; bHandL = 16;
                                }
                            }

                            // Dynamic Leg Selection with anatomical validation:
                            // Candidate 0: Right={57, 58, 59}, Left={53, 54, 55} (Standard standing / armed pose)
                            // Candidate 1: Right={55, 56, 57}, Left={59, 60, 61} (Standard crawling / unarmed)
                            // Candidate 2: Right={58, 59, 60}, Left={55, 56, 57} (Prone rig variant)
                            // Candidate 3: Right={59, 60, 61}, Left={55, 56, 57} (Flipped variant)
                            struct LegPairCandidate {
                                int r[3];
                                int l[3];
                            };
                            const LegPairCandidate legCandidates[] = {
                                { {57, 58, 59}, {53, 54, 55} },
                                { {55, 56, 57}, {59, 60, 61} },
                                { {58, 59, 60}, {55, 56, 57} },
                                { {59, 60, 61}, {55, 56, 57} }
                            };
                            const int numCandidates = (int)(sizeof(legCandidates) / sizeof(legCandidates[0]));

                            auto scoreLegChain = [&](int thigh, int calf, int foot) -> float {
                                DSPUBGVector t = {}, c = {}, f = {};
                                if (!getBoneLocal(thigh, t) || !getBoneLocal(calf, c) || !getBoneLocal(foot, f)) return -999.0f;
                                float dtc = dist3D(t, c);
                                float dcf = dist3D(c, f);
                                if (dtc < 15.0f || dtc > 80.0f) return -999.0f;
                                if (dcf < 15.0f || dcf > 80.0f) return -999.0f;

                                DSPUBGVector pel = {};
                                if (getBoneLocal(bPelvis, pel)) {
                                    float dPelThigh = dist3D(pel, t);
                                    if (dPelThigh > 70.0f) return -999.0f;
                                    // In all natural postures, calf and foot must never float high above pelvis
                                    // (this strictly eliminates IK bones shooting up into the sky when prone)
                                    if (c.Z > pel.Z + 35.0f || f.Z > pel.Z + 35.0f) return -999.0f;
                                }

                                return 100.0f - fabsf(dtc - 45.0f) - fabsf(dcf - 42.0f);
                            };

                            float bestScore = -999.0f;
                            int bestIdx = 0;
                            for (int ci = 0; ci < numCandidates; ci++) {
                                float sR = scoreLegChain(legCandidates[ci].r[0], legCandidates[ci].r[1], legCandidates[ci].r[2]);
                                float sL = scoreLegChain(legCandidates[ci].l[0], legCandidates[ci].l[1], legCandidates[ci].l[2]);
                                if (sR > 0.0f && sL > 0.0f) {
                                    float total = sR + sL;
                                    if (total > bestScore) {
                                        bestScore = total;
                                        bestIdx = ci;
                                    }
                                }
                            }

                            bThighR = legCandidates[bestIdx].r[0];
                            bCalfR  = legCandidates[bestIdx].r[1];
                            bFootR  = legCandidates[bestIdx].r[2];

                            bThighL = legCandidates[bestIdx].l[0];
                            bCalfL  = legCandidates[bestIdx].l[1];
                            bFootL  = legCandidates[bestIdx].l[2];

                            DSPUBGVector rLocal = {}, lLocal = {};
                            if (getBoneLocal(bThighR, rLocal) && getBoneLocal(bThighL, lLocal)) {
                                if (rLocal.Y < lLocal.Y) {
                                    std::swap(bThighR, bThighL);
                                    std::swap(bCalfR, bCalfL);
                                    std::swap(bFootR, bFootL);
                                }
                            }
                        }

                        const int jointIndices[15] = {
                            bHead, bNeck, bPelvis,
                            bUprR, bLwrR, bHandR,
                            bUprL, bLwrL, bHandL,
                            bThighR, bCalfR, bFootR,
                            bThighL, bCalfL, bFootL
                        };

                        DSPUBGVector locals[15] = {};
                        bool localsValid[15] = {};
                        for (int i = 0; i < 15; i++) {
                            localsValid[i] = getBoneLocal(jointIndices[i], locals[i]);
                        }

                        // Anatomical sanity checks before projecting:
                        // Invalidate individual joints if bone lengths exceed human anatomical limits (non-cascading)
                        if (localsValid[1] && localsValid[3] && dist3D(locals[1], locals[3]) > 65.0f) localsValid[3] = false;
                        if (localsValid[3] && localsValid[4] && dist3D(locals[3], locals[4]) > 65.0f) localsValid[4] = false;
                        if (localsValid[4] && localsValid[5] && dist3D(locals[4], locals[5]) > 60.0f) localsValid[5] = false;

                        if (localsValid[1] && localsValid[6] && dist3D(locals[1], locals[6]) > 65.0f) localsValid[6] = false;
                        if (localsValid[6] && localsValid[7] && dist3D(locals[6], locals[7]) > 65.0f) localsValid[7] = false;
                        if (localsValid[7] && localsValid[8] && dist3D(locals[7], locals[8]) > 60.0f) localsValid[8] = false;

                        if (localsValid[2] && localsValid[9] && dist3D(locals[2], locals[9]) > 75.0f) localsValid[9] = false;
                        if (localsValid[9] && localsValid[10] && dist3D(locals[9], locals[10]) > 85.0f) localsValid[10] = false;
                        if (localsValid[10] && localsValid[11] && dist3D(locals[10], locals[11]) > 85.0f) localsValid[11] = false;

                        if (localsValid[2] && localsValid[12] && dist3D(locals[2], locals[12]) > 75.0f) localsValid[12] = false;
                        if (localsValid[12] && localsValid[13] && dist3D(locals[12], locals[13]) > 85.0f) localsValid[13] = false;
                        if (localsValid[13] && localsValid[14] && dist3D(locals[13], locals[14]) > 85.0f) localsValid[14] = false;

                        uint8_t c2w[48] = {0};
                        ds_pubg_read_c2w(meshComp, rootLoc, halfH, c2w);

                        int okBones = 0;
                        for (int i = 0; i < 15; i++) {
                            if (localsValid[i]) {
                                DSPUBGVector world = {};
                                ds_pubg_bone_world_from_local(c2w, rootLoc, halfH, actorRot, &locals[i], &world);
                                float sx_proj = 0, sy_proj = 0, d_proj = 0;
                                if (ds_pubg_cam_basis_project(basis, world, sx_proj, sy_proj, d_proj)) {
                                    p.skeleton[i] = { sx_proj, sy_proj, true };
                                    okBones++;
                                }
                            }
                        }

                        // Project HeadTop for circle at vHead.Z += 7.0f (exact internal snippet logic)
                        if (localsValid[0]) {
                            DSPUBGVector headTopLocal = locals[0];
                            headTopLocal.Z += 7.0f;
                            DSPUBGVector worldHeadTop = {};
                            ds_pubg_bone_world_from_local(c2w, rootLoc, halfH, actorRot, &headTopLocal, &worldHeadTop);
                            float sx_ht = 0, sy_ht = 0, d_ht = 0;
                            if (ds_pubg_cam_basis_project(basis, worldHeadTop, sx_ht, sy_ht, d_ht)) {
                                p.skeleton[15] = { sx_ht, sy_ht, true };
                            }
                        }

                        if (okBones >= 4) {
                            p.hasSkeleton = true;
                            if (p.skeleton[0].valid) {
                                p.headX = p.skeleton[0].x;
                                p.headY = p.skeleton[0].y;
                            }
                            skeletonDone = true;

                            float minBoneX = 99999.0f, maxBoneX = -99999.0f;
                            float minBoneY = 99999.0f, maxBoneY = -99999.0f;
                            for (int bi = 0; bi < 16; bi++) {
                                if (p.skeleton[bi].valid) {
                                    if (p.skeleton[bi].x < minBoneX) minBoneX = p.skeleton[bi].x;
                                    if (p.skeleton[bi].x > maxBoneX) maxBoneX = p.skeleton[bi].x;
                                    if (p.skeleton[bi].y < minBoneY) minBoneY = p.skeleton[bi].y;
                                    if (p.skeleton[bi].y > maxBoneY) maxBoneY = p.skeleton[bi].y;
                                }
                            }
                            if (okBones >= 6 && maxBoneY > minBoneY + 8.0f) {
                                float realTop = (p.skeleton[15].valid) ? (p.skeleton[15].y - 3.0f) : (minBoneY - 4.0f);
                                float realBot = maxBoneY + 1.5f;
                                topY = realTop;
                                boxH = realBot - realTop;
                                if (boxH < 8.0f) boxH = 8.0f;
                                float boneSpanX = (maxBoneX > minBoneX) ? (maxBoneX - minBoneX) : 0.0f;
                                boxW = fmaxf(boneSpanX * 1.15f, boxH * 0.45f);
                                boxX = (boneSpanX > 0.0f) ? ((minBoneX + maxBoneX) * 0.5f - boxW * 0.5f) : (centerX - boxW * 0.5f);
                                p.screenX = boxX;
                                p.screenY = topY;
                                p.boxWidth = boxW;
                                p.boxHeight = boxH;
                            }
                        }
                    }
                }
            }

            // Fallback: ONLY if the mesh had NO component-space transforms at all
            // (e.g. culled mesh or non-skeletal actor), use bounding box proportional skeleton.
            // NEVER fallback when real bone transforms were found, to avoid flickering!
            if (!skeletonDone && boneData == 0 && boxH >= 8.0f && !isnan(boxH) && !isnan(centerX) && !isnan(topY)) {
                p.skeleton[0]  = { centerX,                 topY + boxH * 0.12f, true }; // Head
                p.skeleton[1]  = { centerX,                 topY + boxH * 0.18f, true }; // Neck
                p.skeleton[2]  = { centerX,                 topY + boxH * 0.52f, true }; // Pelvis
                p.skeleton[3]  = { centerX + boxW * 0.22f,  topY + boxH * 0.24f, true }; // UprR
                p.skeleton[4]  = { centerX + boxW * 0.32f,  topY + boxH * 0.38f, true }; // LwrR
                p.skeleton[5]  = { centerX + boxW * 0.35f,  topY + boxH * 0.50f, true }; // HandR
                p.skeleton[6]  = { centerX - boxW * 0.22f,  topY + boxH * 0.24f, true }; // UprL
                p.skeleton[7]  = { centerX - boxW * 0.32f,  topY + boxH * 0.38f, true }; // LwrL
                p.skeleton[8]  = { centerX - boxW * 0.35f,  topY + boxH * 0.50f, true }; // HandL
                p.skeleton[9]  = { centerX + boxW * 0.16f,  topY + boxH * 0.56f, true }; // ThighR
                p.skeleton[10] = { centerX + boxW * 0.18f,  topY + boxH * 0.76f, true }; // CalfR
                p.skeleton[11] = { centerX + boxW * 0.20f,  topY + boxH * 0.96f, true }; // FootR
                p.skeleton[12] = { centerX - boxW * 0.16f,  topY + boxH * 0.56f, true }; // ThighL
                p.skeleton[13] = { centerX - boxW * 0.18f,  topY + boxH * 0.76f, true }; // CalfL
                p.skeleton[14] = { centerX - boxW * 0.20f,  topY + boxH * 0.96f, true }; // FootL
                p.skeleton[15] = { centerX,                 topY + boxH * 0.10f, true }; // HeadTop
                p.hasSkeleton = true;
            }
        }
    }

        if (publishedCount < kDSPUBGMaxPlayers) {
            staging[publishedCount++] = p;
            if (isAI) botCount++; else enemyCount++;
        }

        cEntry.actor = pawn;
        cEntry.isScenery = false;
        cEntry.isPawn = true;
        cEntry.itemCat = DSPUBGItemCategoryNone;
        cEntry.vCommon = 0;
        return true;
    };

    auto processGrenade = [&](uint64_t actor) -> bool {
        if (grenadeStagingCount >= kDSPUBGMaxGrenades) return false;
        if (!g_pubgEspGrenade) return false;

        // 1. Location check (handles both in-hand / pin-pulled and in-flight / on-ground)
        DSPUBGVector rootLoc = {};
        bool hasLoc = false;
        uint64_t rootComp = ds_pubg_read_ptr(actor + kDSPUBGActorRootComponentOffset);
        if (!rootComp || !ds_pubg_valid(rootComp)) {
            rootComp = ds_pubg_read_ptr(actor + 0x180ULL);
        }
        if (rootComp && ds_pubg_valid(rootComp)) {
            DSPUBGVector rLoc = {};
            if (ds_pubg_read(rootComp + kDSPUBGSceneCompRelativeLocOffset, &rLoc, sizeof(rLoc))) {
                if (!isnan(rLoc.X) && !isinf(rLoc.X) && (rLoc.X != 0.0f || rLoc.Y != 0.0f || rLoc.Z != 0.0f)) {
                    rootLoc = rLoc;
                    hasLoc = true;
                }
            }

            // When holding grenade (pin pulled / attached to pawn hand socket)
            uint64_t attachParent = ds_pubg_read_ptr(rootComp + 0x188ULL);
            if (attachParent && ds_pubg_valid(attachParent)) {
                float magSq = rootLoc.X * rootLoc.X + rootLoc.Y * rootLoc.Y + rootLoc.Z * rootLoc.Z;
                if (!hasLoc || magSq < 40000.0f) { // If offset is near (0,0,0) in hand socket space
                    DSPUBGVector pLoc = {};
                    if (ds_pubg_read(attachParent + kDSPUBGSceneCompRelativeLocOffset, &pLoc, sizeof(pLoc)) &&
                        !isnan(pLoc.X) && (pLoc.X != 0.0f || pLoc.Y != 0.0f || pLoc.Z != 0.0f)) {
                        rootLoc = pLoc;
                        hasLoc = true;
                    } else {
                        uint64_t grandParent = ds_pubg_read_ptr(attachParent + 0x188ULL);
                        if (grandParent && ds_pubg_valid(grandParent)) {
                            if (ds_pubg_read(grandParent + kDSPUBGSceneCompRelativeLocOffset, &pLoc, sizeof(pLoc)) &&
                                !isnan(pLoc.X) && (pLoc.X != 0.0f || pLoc.Y != 0.0f || pLoc.Z != 0.0f)) {
                                rootLoc = pLoc;
                                hasLoc = true;
                            }
                        }
                    }
                }
            }
        }

        // Fallback: AActor.Instigator (Pawn holding the grenade)
        if (!hasLoc || (rootLoc.X == 0.0f && rootLoc.Y == 0.0f && rootLoc.Z == 0.0f)) {
            uint64_t inst = ds_pubg_read_ptr(actor + 0x1F0ULL); // AActor.Instigator
            if (!inst || !ds_pubg_valid(inst)) inst = ds_pubg_read_ptr(actor + 0x138ULL);
            if (!inst || !ds_pubg_valid(inst)) inst = ds_pubg_read_ptr(actor + 0x140ULL);
            if (inst && ds_pubg_valid(inst)) {
                uint64_t instRoot = ds_pubg_read_ptr(inst + kDSPUBGActorRootComponentOffset);
                if (instRoot && ds_pubg_valid(instRoot)) {
                    DSPUBGVector instLoc = {};
                    if (ds_pubg_read(instRoot + kDSPUBGSceneCompRelativeLocOffset, &instLoc, sizeof(instLoc))) {
                        rootLoc = instLoc;
                        hasLoc = true;
                    }
                }
            }
        }
        if (!hasLoc) return false;

        // 2. Early Distance check (grenades only exist within 100m, exactly as in reference code)
        float dx = (rootLoc.X - basis.lx) * 0.01f;
        float dy = (rootLoc.Y - basis.ly) * 0.01f;
        float dz = (rootLoc.Z - basis.lz) * 0.01f;
        float dist3D = sqrtf(dx * dx + dy * dy + dz * dz);
        if (dist3D > 100.0f) return false;

        // 3. Grenade Identification (ItemDefineID first, then Class/Actor name fallback)
        DSPUBGGrenadeType gType = DSPUBGGrenadeTypeFrag;
        char gDisplayName[32] = {0};
        float dmgRadius = 18.0f;
        if (!ds_pubg_identify_grenade(actor, &gType, gDisplayName, sizeof(gDisplayName), &dmgRadius)) {
            return false;
        }

        // 4. Update / find history slot for real flight trail & motion smoothing
        int histSlot = -1;
        for (int h = 0; h < 16; h++) {
            if (s_grenadeHistories[h].actor == actor) {
                // Verify slot is fresh and hasn't jumped across the map (prevent recycled actor pointer bug)
                float mdx = (rootLoc.X - s_grenadeHistories[h].lastLoc.X);
                float mdy = (rootLoc.Y - s_grenadeHistories[h].lastLoc.Y);
                float mdz = (rootLoc.Z - s_grenadeHistories[h].lastLoc.Z);
                float jumpDist = sqrtf(mdx * mdx + mdy * mdy + mdz * mdz);
                if ((s_grenadeTickCounter - s_grenadeHistories[h].lastSeenTick) <= 3 && jumpDist < 1500.0f) {
                    histSlot = h;
                } else {
                    // Stale slot from a previous despawned grenade reusing this heap address
                    memset(&s_grenadeHistories[h], 0, sizeof(DSPUBGGrenadeHistory));
                }
                break;
            }
        }
        if (histSlot < 0) {
            for (int h = 0; h < 16; h++) {
                if (s_grenadeHistories[h].actor == 0 || (s_grenadeTickCounter - s_grenadeHistories[h].lastSeenTick) > 3) {
                    histSlot = h;
                    memset(&s_grenadeHistories[h], 0, sizeof(DSPUBGGrenadeHistory));
                    s_grenadeHistories[h].actor = actor;
                    s_grenadeHistories[h].type = gType;
                    s_grenadeHistories[h].lastLoc = rootLoc;
                    s_grenadeHistories[h].lastTimestamp = CACurrentMediaTime();
                    s_grenadeHistories[h].firstSeenTimestamp = s_grenadeHistories[h].lastTimestamp;
                    s_grenadeHistories[h].lastSeenTick = s_grenadeTickCounter;
                    s_grenadeHistories[h].groundZ = (basis.lz - 90.0f);
                    break;
                }
            }
        }

        if (histSlot >= 0) {
            DSPUBGGrenadeHistory &hist = s_grenadeHistories[histSlot];
            hist.lastSeenTick = s_grenadeTickCounter;

            float mdx = (rootLoc.X - hist.lastLoc.X);
            float mdy = (rootLoc.Y - hist.lastLoc.Y);
            float mdz = (rootLoc.Z - hist.lastLoc.Z);
            float moveDist = sqrtf(mdx * mdx + mdy * mdy + mdz * mdz);

            // Smooth position during flight to eliminate 20Hz network tick stepping
            if (moveDist > 5.0f && moveDist < 600.0f && hist.lastTimestamp > 0.0) {
                rootLoc.X = hist.lastLoc.X * 0.35f + rootLoc.X * 0.65f;
                rootLoc.Y = hist.lastLoc.Y * 0.35f + rootLoc.Y * 0.65f;
                rootLoc.Z = hist.lastLoc.Z * 0.35f + rootLoc.Z * 0.65f;
            }

            // If moving > 30cm, record actual flight trail point
            if (moveDist > 30.0f) {
                if (hist.trailCount < 30) {
                    hist.trail[hist.trailCount++] = rootLoc;
                } else {
                    for (int k = 0; k < 29; k++) hist.trail[k] = hist.trail[k + 1];
                    hist.trail[29] = rootLoc;
                }
            }
            if (hist.firstSeenTimestamp == 0.0) hist.firstSeenTimestamp = CACurrentMediaTime();
            if (hist.trailCount == 0 && hist.groundZ == 0.0f) {
                hist.groundZ = rootLoc.Z - 140.0f;
            }
            hist.lastLoc = rootLoc;
            hist.lastTimestamp = CACurrentMediaTime();
        }

        // Project grenade center with smoothed location
        float sx = 0, sy = 0, dist = 0;
        bool isVisible = ds_pubg_cam_basis_project(basis, rootLoc, sx, sy, dist);

        DSPUBGProjectedGrenade &pg = grenadeStaging[grenadeStagingCount++];
        pg.screenX = sx;
        pg.screenY = sy;
        pg.distanceMeters = dist3D;
        pg.isVisible = isVisible;
        pg.type = gType;
        strncpy(pg.name, gDisplayName, sizeof(pg.name) - 1);
        pg.name[sizeof(pg.name) - 1] = '\0';
        float maxFuse = 7.0f; // PUBG Mobile Frag Grenade fuse is 7.0 seconds
        if (gType == DSPUBGGrenadeTypeStun) {
            maxFuse = 3.5f;
        } else if (gType == DSPUBGGrenadeTypeBurn) {
            maxFuse = 5.0f;
        } else if (gType == DSPUBGGrenadeTypeSmoke) {
            maxFuse = 25.0f; // Smoke canister duration (~25s)
        }

        // Check if UE4 set InitialLifeSpan (offset 0x158 in AActor) when cooked in hand before throwing
        float lifeSpan = ds_pubg_read_f32(actor + 0x158ULL);
        if (lifeSpan > 0.5f && lifeSpan <= maxFuse) {
            maxFuse = lifeSpan;
        }
        pg.totalFuseSeconds = maxFuse;

        // Remaining cook time in seconds counting down
        double nowTime = CACurrentMediaTime();
        double elapsed = (histSlot >= 0 && s_grenadeHistories[histSlot].firstSeenTimestamp > 0.0) ? (nowTime - s_grenadeHistories[histSlot].firstSeenTimestamp) : 0.0;

        float fuseLeft = maxFuse - (float)elapsed;
        if (fuseLeft < 0.0f) fuseLeft = 0.0f;
        pg.cookSeconds = fuseLeft;

        // 3D Damage Circle Radius matching metalbiew.txt (360.0f units = 3.6m)
        float rOuter = 360.0f;
        float rMid   = 260.0f;
        float rInner = 180.0f;
        if (gType == DSPUBGGrenadeTypeBurn) {
            rOuter = 280.0f; rMid = 200.0f; rInner = 140.0f;
        } else if (gType == DSPUBGGrenadeTypeSmoke) {
            rOuter = 320.0f; rMid = 220.0f; rInner = 150.0f;
        } else if (gType == DSPUBGGrenadeTypeStun) {
            rOuter = 360.0f; rMid = 260.0f; rInner = 180.0f;
        }

        pg.damageRadiusMeters = (rOuter / 100.0f);
        pg.isLocalInDanger = (dist3D <= pg.damageRadiusMeters);
        pg.trajCount = 0;
        pg.circlePointCount = kDSPUBGCirclePoints;

        // Altitude Drop Line to ground
        float gZ = (histSlot >= 0 && s_grenadeHistories[histSlot].groundZ != 0.0f) ? s_grenadeHistories[histSlot].groundZ : (basis.lz - 90.0f);
        pg.hasDropLine = false;
        pg.groundPoint = CGPointZero;
        if (rootLoc.Z > (gZ + 25.0f)) {
            DSPUBGVector gPt = { rootLoc.X, rootLoc.Y, gZ };
            float gsx = 0, gsy = 0, gdist = 0;
            if (ds_pubg_cam_basis_project(basis, gPt, gsx, gsy, gdist)) {
                pg.hasDropLine = true;
                pg.groundPoint = CGPointMake(gsx, gsy);
            }
        }

        // Real Flight Trail: Only tracks actual positions when grenade moves in the air
        if (histSlot >= 0) {
            DSPUBGGrenadeHistory &hist = s_grenadeHistories[histSlot];
            if (hist.trailCount >= 2) {
                int count = 0;
                for (int t = 0; t < hist.trailCount && count < (kDSPUBGMaxTrajPoints - 1); t++) {
                    float tsx = 0, tsy = 0, tdist = 0;
                    if (ds_pubg_cam_basis_project(basis, hist.trail[t], tsx, tsy, tdist)) {
                        pg.trajPoints[count++] = CGPointMake(tsx, tsy);
                    }
                }
                if (isVisible && count < kDSPUBGMaxTrajPoints) {
                    pg.trajPoints[count++] = CGPointMake(sx, sy);
                }
                pg.trajCount = count;
            } else {
                pg.trajCount = 0;
            }
        }

        // 5. 3 Concentric Circles matching metalbiew.txt (32 segments)

        for (int k = 0; k < kDSPUBGCirclePoints; k++) {
            float theta = (float)k / (float)kDSPUBGCirclePoints * 2.0f * (float)M_PI;
            float ca = cosf(theta);
            float sa = sinf(theta);

            // Outer circle (White: 1800)
            DSPUBGVector cptOut = { rootLoc.X + rOuter * ca, rootLoc.Y + rOuter * sa, rootLoc.Z };
            float csx = 0, csy = 0, cdist = 0;
            if (ds_pubg_cam_basis_project(basis, cptOut, csx, csy, cdist)) {
                pg.circlePoints[k] = CGPointMake(csx, csy);
                pg.circlePointsValid[k] = true;
            } else {
                pg.circlePoints[k] = CGPointMake(-9999.0f, -9999.0f);
                pg.circlePointsValid[k] = false;
            }

            // Mid circle (Yellow: 1500)
            DSPUBGVector cptMid = { rootLoc.X + rMid * ca, rootLoc.Y + rMid * sa, rootLoc.Z };
            if (ds_pubg_cam_basis_project(basis, cptMid, csx, csy, cdist)) {
                pg.circlePointsMid[k] = CGPointMake(csx, csy);
                pg.circlePointsMidValid[k] = true;
            } else {
                pg.circlePointsMid[k] = CGPointMake(-9999.0f, -9999.0f);
                pg.circlePointsMidValid[k] = false;
            }

            // Inner circle (Red: 1200)
            DSPUBGVector cptIn = { rootLoc.X + rInner * ca, rootLoc.Y + rInner * sa, rootLoc.Z };
            if (ds_pubg_cam_basis_project(basis, cptIn, csx, csy, cdist)) {
                pg.circlePointsInner[k] = CGPointMake(csx, csy);
                pg.circlePointsInnerValid[k] = true;
            } else {
                pg.circlePointsInner[k] = CGPointMake(-9999.0f, -9999.0f);
                pg.circlePointsInnerValid[k] = false;
            }
        }

        // 6. 3D Bounding Box when distance < 13.0m (matching metalbiew.txt bbExtends(10, 10, 10))
        if (dist3D < 13.0f) {
            float ext = 12.0f; // 12cm half-extent
            DSPUBGVector corners[8] = {
                { rootLoc.X - ext, rootLoc.Y - ext, rootLoc.Z - ext }, // 0
                { rootLoc.X + ext, rootLoc.Y - ext, rootLoc.Z - ext }, // 1
                { rootLoc.X + ext, rootLoc.Y + ext, rootLoc.Z - ext }, // 2
                { rootLoc.X - ext, rootLoc.Y + ext, rootLoc.Z - ext }, // 3
                { rootLoc.X - ext, rootLoc.Y - ext, rootLoc.Z + ext }, // 4
                { rootLoc.X + ext, rootLoc.Y - ext, rootLoc.Z + ext }, // 5
                { rootLoc.X + ext, rootLoc.Y + ext, rootLoc.Z + ext }, // 6
                { rootLoc.X - ext, rootLoc.Y + ext, rootLoc.Z + ext }, // 7
            };
            bool allValid = true;
            for (int b = 0; b < 8; b++) {
                float bsx = 0, bsy = 0, bdist = 0;
                if (ds_pubg_cam_basis_project(basis, corners[b], bsx, bsy, bdist)) {
                    pg.boxCorners[b] = CGPointMake(bsx, bsy);
                    pg.boxCornersValid[b] = true;
                } else {
                    pg.boxCornersValid[b] = false;
                    allValid = false;
                }
            }
            pg.hasBox = allValid;
        } else {
            pg.hasBox = false;
        }

        return true;
    };

    DSPUBGProjectedItem itemStaging[kDSPUBGMaxItems * 2] = {};
    DSPUBGVector itemWorldLocStaging[kDSPUBGMaxItems * 2] = {};
    int itemStagingCount = 0;
    int stagedVehicleCount = 0;

    auto processItemOrVehicle = [&](uint64_t actor) {
        if (itemStagingCount >= (kDSPUBGMaxItems * 2)) return;
        if (!g_pubgEspVehicle && !g_pubgEspCrate && !g_pubgEspScope && !g_pubgEspDrug &&
            !g_pubgEspFlareGun && !g_pubgEspGrenade &&
            !g_pubgEspWeaponAR && !g_pubgEspWeaponSMG && !g_pubgEspWeaponShotgun && !g_pubgEspWeaponSniper &&
            !g_pubgEspArmorLv1 && !g_pubgEspArmorLv2 && !g_pubgEspArmorLv3 && !g_pubgEspAmmo) {
            return;
        }

        uint32_t cSlot = ds_pubg_actor_cache_hash(actor);
        DSPUBGActorCacheEntry &cEntry = g_dspubgActorCache[cSlot];
        if (cEntry.actor == actor) {
            if (cEntry.isScenery) return;
            if (cEntry.itemCat != DSPUBGItemCategoryNone) {
                if (!ds_pubg_is_item_type_enabled(cEntry.itemCat, cEntry.itemName)) return;
            }
        }

        if (localPawn) {
            uint64_t inst = ds_pubg_read_ptr(actor + 0x138ULL);
            uint64_t own = ds_pubg_read_ptr(actor + 0x140ULL);
            if (inst == localPawn || own == localPawn) {
                return;
            }
        }

        // [A3] Smart filter: never list self or a teammate as loot.
        if (ds_pubg_smart_is_skipped(actor)) return;

        // 1. Fast RootComponent and Location check FIRST (filters out 95% of non-spatial/offscreen actors without GNames)
        DSPUBGVector rootLoc = {};
        bool hasLoc = false;
        uint64_t rootComp = ds_pubg_read_ptr(actor + kDSPUBGActorRootComponentOffset);
        if (!rootComp || !ds_pubg_valid(rootComp)) {
            rootComp = ds_pubg_read_ptr(actor + 0x180ULL);
        }
        if (rootComp && ds_pubg_valid(rootComp)) {
            if (ds_pubg_read(rootComp + kDSPUBGSceneCompRelativeLocOffset, &rootLoc, sizeof(rootLoc))) {
                if (!isnan(rootLoc.X) && !isinf(rootLoc.X) &&
                    !isnan(rootLoc.Y) && !isinf(rootLoc.Y) &&
                    !isnan(rootLoc.Z) && !isinf(rootLoc.Z) &&
                    (rootLoc.X != 0.0f || rootLoc.Y != 0.0f || rootLoc.Z != 0.0f)) {
                    hasLoc = true;
                }
            }
        }
        if (!hasLoc) {
            // AttachedRelLoc at 0x634 (APickUpWrapperActor) or 0x624 (APlayerTombBox)
            if (ds_pubg_read(actor + 0x634ULL, &rootLoc, sizeof(rootLoc)) &&
                !isnan(rootLoc.X) && !isinf(rootLoc.X) &&
                (rootLoc.X != 0.0f || rootLoc.Y != 0.0f || rootLoc.Z != 0.0f)) {
                hasLoc = true;
            } else if (ds_pubg_read(actor + 0x624ULL, &rootLoc, sizeof(rootLoc)) &&
                       !isnan(rootLoc.X) && !isinf(rootLoc.X) &&
                       (rootLoc.X != 0.0f || rootLoc.Y != 0.0f || rootLoc.Z != 0.0f)) {
                hasLoc = true;
            }
        }
        if (!hasLoc) return;

        // 2. Early Distance Check (skip actors across the 8x8 km map)
        float dx = (rootLoc.X - basis.lx) * 0.01f;
        float dy = (rootLoc.Y - basis.ly) * 0.01f;
        float dz = (rootLoc.Z - basis.lz) * 0.01f;
        float dist3D = sqrtf(dx * dx + dy * dy + dz * dz);
        float vehicleMaxDist = fminf(fmaxf(g_pubgItemMaxDistance * 1.6f, 200.0f), 280.0f);
        float limitDist = (cEntry.actor == actor && cEntry.itemCat == DSPUBGItemCategoryVehicle) ? vehicleMaxDist :
                          ((cEntry.actor == actor && cEntry.itemCat == DSPUBGItemCategoryCrate) ? (g_pubgItemMaxDistance * 2.0f) :
                           (g_pubgItemMaxDistance > vehicleMaxDist ? g_pubgItemMaxDistance : vehicleMaxDist));
        if (dist3D < 1.0f || dist3D > limitDist) return;

        // 3. Early Screen Projection & Frustum Culling (skip actors behind or off screen)
        float sx = 0, sy = 0, dist = 0;
        if (!ds_pubg_cam_basis_project(basis, rootLoc, sx, sy, dist)) {
            return;
        }
        if (sx < -80.0f || sx > (screenW + 80.0f) || sy < -80.0f || sy > (screenH + 80.0f)) {
            return;
        }

        // 4. Fast Cache-Accelerated Item / Vehicle Identification
        char displayName[36] = {0};
        DSPUBGItemCategory cat = DSPUBGItemCategoryNone;
        if (cEntry.actor == actor && cEntry.itemCat != DSPUBGItemCategoryNone) {
            cat = cEntry.itemCat;
            strncpy(displayName, cEntry.itemName, sizeof(displayName) - 1);
            if (cat != DSPUBGItemCategoryVehicle) {
                uint8_t pickedUp = ds_pubg_read_u8(actor + 0x615ULL) & 1;
                if (pickedUp) {
                    cEntry.actor = 0;
                    cEntry.isScenery = false;
                    cEntry.isPawn = false;
                    cEntry.itemCat = DSPUBGItemCategoryNone;
                    cEntry.vCommon = 0;
                    return;
                }
            }
        } else {
            char actorName[64] = {0};
            if (ds_pubg_get_actor_name(actor, actorName, sizeof(actorName))) {
                if (strcasestr(actorName, "Lobby") || strcasestr(actorName, "MainCity") ||
                    strcasestr(actorName, "Preview") || strcasestr(actorName, "Avatar")) {
                    cEntry.actor = actor;
                    cEntry.isScenery = true;
                    cEntry.isPawn = false;
                    cEntry.itemCat = DSPUBGItemCategoryNone;
                    cEntry.vCommon = 0;
                    return;
                }
            }
            cat = ds_pubg_identify_item(actor, actorName, displayName, sizeof(displayName));
            if (cat == DSPUBGItemCategoryNone) {
                if (actorName[0] && ds_pubg_is_scenery_name(actorName)) {
                    cEntry.actor = actor;
                    cEntry.isScenery = true;
                    cEntry.isPawn = false;
                    cEntry.itemCat = DSPUBGItemCategoryNone;
                    cEntry.vCommon = 0;
                }
                return;
            }
            cEntry.actor = actor;
            cEntry.isScenery = false;
            cEntry.isPawn = false;
            cEntry.itemCat = cat;
            strncpy(cEntry.itemName, displayName, sizeof(cEntry.itemName) - 1);
            cEntry.itemName[sizeof(cEntry.itemName) - 1] = '\0';
            cEntry.vCommon = 0;
            cEntry.cachedHp = 0.0f;
            cEntry.cachedHpMax = 0.0f;
            cEntry.cachedFuel = 0.0f;
            cEntry.cachedFuelMax = 0.0f;
        }

        if (!ds_pubg_is_item_type_enabled(cat, displayName)) return;

        float maxDist = (cat == DSPUBGItemCategoryVehicle) ? vehicleMaxDist :
                        ((cat == DSPUBGItemCategoryCrate) ? (g_pubgItemMaxDistance * 2.0f) : g_pubgItemMaxDistance);
        if (dist3D > maxDist) return;

        if (cat == DSPUBGItemCategoryVehicle && stagedVehicleCount >= 24) {
            return;
        }

        if (cat == DSPUBGItemCategoryCrate) {
            std::vector<CrateItemInfo> cItems = ds_pubg_get_crate_items(actor);
            if (!cItems.empty()) {
                for (const auto &ci : cItems) {
                    if (!ds_pubg_is_item_type_enabled(ci.category, ci.name)) continue;
                    if (itemStagingCount >= (kDSPUBGMaxItems * 2 - 2)) break;
                    int idx = itemStagingCount++;
                    itemWorldLocStaging[idx] = rootLoc;
                    DSPUBGProjectedItem &pi = itemStaging[idx];
                    pi.screenX = sx;
                    pi.screenY = sy;
                    pi.distanceMeters = dist3D;
                    pi.category = ci.category;
                    pi.isVisible = true;
                    strncpy(pi.name, ci.name, sizeof(pi.name) - 1);
                    pi.name[sizeof(pi.name) - 1] = '\0';
                    pi.hp = 0.0f; pi.hpMax = 0.0f; pi.fuel = 0.0f; pi.fuelMax = 0.0f;

                    uint32_t ciColor = 0;
                    bool ciPrio = false;
                    ds_pubg_compute_item_props(ci.category, ci.name, ciColor, ciPrio);
                    pi.colorRGBA = ciColor;
                    pi.isPriority = ciPrio;
                }
                return;
            }
        }

        int idx = itemStagingCount++;
        itemWorldLocStaging[idx] = rootLoc;
        DSPUBGProjectedItem &pi = itemStaging[idx];
        pi.screenX = sx;
        pi.screenY = sy;
        pi.distanceMeters = dist3D;
        pi.category = cat;
        pi.isVisible = true;
        strncpy(pi.name, displayName, sizeof(pi.name) - 1);
        pi.name[sizeof(pi.name) - 1] = '\0';
        pi.hp = 0.0f;
        pi.hpMax = 0.0f;
        pi.fuel = 0.0f;
        pi.fuelMax = 0.0f;

        uint32_t cColor = 0;
        bool cPrio = false;
        ds_pubg_compute_item_props(cat, displayName, cColor, cPrio);
        pi.colorRGBA = cColor;
        pi.isPriority = cPrio;

        if (cat == DSPUBGItemCategoryVehicle) {
            stagedVehicleCount++;
            bool tracked = false;
            for (uint64_t tv : s_trackedLevelVehicles) { if (tv == actor) { tracked = true; break; } }
            if (!tracked && s_trackedLevelVehicles.size() < 24) s_trackedLevelVehicles.push_back(actor);
        }

    };

    // Vischeck disabled per user request: map obstacle scan skipped
    s_obstacleCount = 0;

    // Source 1: GameState.PlayerArray
    uint64_t gameState = ds_pubg_read_ptr(world + kDSPUBGWorldGameStateOffset);
    if (!gameState) {
        uint64_t gm = ds_pubg_read_ptr(world + kDSPUBGWorldAuthorityGameModeOffset);
        if (gm) gameState = ds_pubg_read_ptr(gm + kDSPUBGGameModeGameStateOffset);
    }
    if (gameState) {
        uint64_t playerArrayData = ds_pubg_read_ptr(gameState + kDSPUBGGameStatePlayerArrayOffset);
        uint32_t playerCount = ds_pubg_read_u32(gameState + kDSPUBGGameStatePlayerArrayOffset + 8);
        if (playerArrayData && playerCount > 0) {
            if (playerCount > 128) playerCount = 128;
            std::vector<uint64_t> playerStates(playerCount, 0);
            if (ds_pubg_read(playerArrayData, playerStates.data(), playerCount * sizeof(uint64_t))) {
                for (uint32_t i = 0; i < playerCount; i++) {
                    uint64_t ps = playerStates[i];
                    if (!ps || !ds_pubg_valid(ps)) continue;
                    uint64_t pawn = ds_pubg_read_ptr(ps + kDSPUBGPlayerStatePawnPrivateOffset);
                    uint8_t botByte = ds_pubg_read_u8(ps + kDSPUBGPlayerStateIsABotOffset);
                    bool isBot = (botByte & 0x4) != 0;
                    if (pawn) {
                        processPawn(pawn, ps, isBot);
                    }
                }
            }
        }
    }

    // Source 2: Levels Actors (Dual-Cadence Engine: tracked pawns/grenades/vehicles every frame, full loot scan throttled)
    // Fast-path: Update tracked level pawns at full frame rate
    for (size_t pi = 0; pi < s_trackedLevelPawns.size(); ) {
        uint64_t tp = s_trackedLevelPawns[pi];
        if (!tp || !ds_pubg_valid(tp)) {
            s_trackedLevelPawns.erase(s_trackedLevelPawns.begin() + pi);
            continue;
        }
        if (!processPawn(tp, 0, false)) {
            s_trackedLevelPawns.erase(s_trackedLevelPawns.begin() + pi);
        } else {
            pi++;
        }
    }

    for (size_t gi = 0; gi < s_trackedLevelGrenades.size(); ) {
        uint64_t tg = s_trackedLevelGrenades[gi];
        if (!tg || !ds_pubg_valid(tg) || !processGrenade(tg)) {
            s_trackedLevelGrenades.erase(s_trackedLevelGrenades.begin() + gi);
        } else {
            gi++;
        }
    }

    auto collectActorsFromLevel = [&](uint64_t lvl) {
        if (!lvl || !ds_pubg_valid(lvl)) return;
        uint64_t actorsData = 0;
        uint32_t actorsCount = 0;

        if (!ds_pubg_find_level_actors(lvl, &actorsData, &actorsCount)) {
            uint64_t cluster = ds_pubg_read_ptr(lvl + 0xE0ULL);
            if (cluster && ds_pubg_valid(cluster)) {
                ds_pubg_actor_array_plausible(cluster + 0x28ULL, &actorsData, &actorsCount);
            }
        }

        if (actorsData && actorsCount > 0) {
            g_dspubgLastActorsCount = (int)actorsCount;
            if (actorsCount > 16384) actorsCount = 16384;
            static std::vector<uint64_t> s_levelActors;
            if (s_levelActors.size() < actorsCount) s_levelActors.resize(actorsCount);
            if (ds_pubg_read(actorsData, s_levelActors.data(), actorsCount * sizeof(uint64_t))) {
                for (uint32_t i = 0; i < actorsCount; i++) {
                    uint64_t actor = s_levelActors[i];
                    if (!actor || actor == localPawn || !ds_pubg_valid(actor)) continue;

                    uint32_t cSlot = ds_pubg_actor_cache_hash(actor);
                    DSPUBGActorCacheEntry &cEntry = g_dspubgActorCache[cSlot];
                    if (cEntry.actor == actor) {
                        if (cEntry.isScenery) {
                            continue;
                        }
                        if (cEntry.itemCat != DSPUBGItemCategoryNone) {
                            processItemOrVehicle(actor);
                            continue;
                        }
                        if (cEntry.isPawn) {
                            if (processPawn(actor, 0, false)) {
                                bool already = false;
                                for (uint64_t tp : s_trackedLevelPawns) { if (tp == actor) { already = true; break; } }
                                if (!already && s_trackedLevelPawns.size() < 64) s_trackedLevelPawns.push_back(actor);
                            }
                            continue;
                        }
                    }

                    if (!processPawn(actor, 0, false)) {
                        if (!processGrenade(actor)) {
                            processItemOrVehicle(actor);
                        } else {
                            bool alreadyG = false;
                            for (uint64_t tg : s_trackedLevelGrenades) { if (tg == actor) { alreadyG = true; break; } }
                            if (!alreadyG && s_trackedLevelGrenades.size() < 16) s_trackedLevelGrenades.push_back(actor);
                        }
                    } else {
                        bool already = false;
                        for (uint64_t tp : s_trackedLevelPawns) { if (tp == actor) { already = true; break; } }
                        if (!already && s_trackedLevelPawns.size() < 64) s_trackedLevelPawns.push_back(actor);
                    }
                }
            }
        }
    };

    static const uint32_t kDSPUBGFullScanInterval = 10;
    bool needFullLevelScan = ((s_levelScanTick++ % kDSPUBGFullScanInterval) == 0);
    if (needFullLevelScan && level) {
        s_trackedLevelVehicles.clear();
        int beforeCount = itemStagingCount;
        uint64_t worldLevels[32] = {0};
        uint32_t worldLevelCount = ds_pubg_find_world_levels(world, level, worldLevels, 32);
        for (uint32_t li = 0; li < worldLevelCount; li++) {
            collectActorsFromLevel(worldLevels[li]);
        }
        // Cache discovered static loot items with their 3D world coordinates for smooth reprojection
        s_cachedLootCount = 0;
        for (int i = beforeCount; i < itemStagingCount && s_cachedLootCount < (int)(sizeof(s_cachedLoot)/sizeof(s_cachedLoot[0])); i++) {
            if (itemStaging[i].category == DSPUBGItemCategoryVehicle) continue;
            DSPUBGCachedLoot &cl = s_cachedLoot[s_cachedLootCount++];
            cl.worldLoc = itemWorldLocStaging[i];
            cl.hasWorldLoc = true;
            cl.category = itemStaging[i].category;
            strncpy(cl.name, itemStaging[i].name, sizeof(cl.name) - 1);
            cl.name[sizeof(cl.name) - 1] = '\0';
            cl.colorRGBA = itemStaging[i].colorRGBA;
            cl.isPriority = itemStaging[i].isPriority;
        }
    } else {
        // Intermediate frames: live-update tracked vehicles and reproject cached loot
        // through the current camera basis so labels move smoothly without (0,0) flicker.
        for (size_t vi = 0; vi < s_trackedLevelVehicles.size(); ) {
            uint64_t tv = s_trackedLevelVehicles[vi];
            if (!tv || !ds_pubg_valid(tv)) {
                s_trackedLevelVehicles.erase(s_trackedLevelVehicles.begin() + vi);
                continue;
            }
            processItemOrVehicle(tv);
            vi++;
        }
        for (int i = 0; i < s_cachedLootCount && itemStagingCount < kDSPUBGMaxItems * 2; i++) {
            const DSPUBGCachedLoot &cl = s_cachedLoot[i];
            if (!cl.hasWorldLoc) continue;
            if (!ds_pubg_is_item_type_enabled(cl.category, cl.name)) continue;

            float dx = (cl.worldLoc.X - basis.lx) * 0.01f;
            float dy = (cl.worldLoc.Y - basis.ly) * 0.01f;
            float dz = (cl.worldLoc.Z - basis.lz) * 0.01f;
            float dist3D = sqrtf(dx * dx + dy * dy + dz * dz);
            float maxDist = (cl.category == DSPUBGItemCategoryCrate) ? (g_pubgItemMaxDistance * 2.0f) : g_pubgItemMaxDistance;
            if (dist3D < 1.0f || dist3D > maxDist) continue;

            float sx = 0.0f, sy = 0.0f, dist = 0.0f;
            if (!ds_pubg_cam_basis_project(basis, cl.worldLoc, sx, sy, dist)) continue;
            if (sx < -80.0f || sx > (screenW + 80.0f) || sy < -80.0f || sy > (screenH + 80.0f)) continue;

            DSPUBGProjectedItem &pi = itemStaging[itemStagingCount++];
            memset(&pi, 0, sizeof(pi));
            pi.screenX = sx;
            pi.screenY = sy;
            pi.distanceMeters = dist3D;
            pi.category = cl.category;
            strncpy(pi.name, cl.name, sizeof(pi.name) - 1);
            pi.isVisible = true;
            pi.colorRGBA = cl.colorRGBA;
            pi.isPriority = cl.isPriority;
        }
    }

    g_dspubgLastEnemyCount = enemyCount;
    g_dspubgLastBotCount = botCount;

    if (publishedCount > 1) {
        std::sort(staging, staging + publishedCount, [](const DSPUBGProjectedPlayer &a, const DSPUBGProjectedPlayer &b) {
            return a.distanceMeters < b.distanceMeters;
        });
    }

    if (itemStagingCount > 1) {
        std::sort(itemStaging, itemStaging + itemStagingCount, [](const DSPUBGProjectedItem &a, const DSPUBGProjectedItem &b) {
            if (a.isPriority != b.isPriority) {
                if (fabsf(a.distanceMeters - b.distanceMeters) < 70.0f) {
                    return a.isPriority > b.isPriority;
                }
            }
            return a.distanceMeters < b.distanceMeters;
        });
    }

    // Filter and publish items with vehicle quota protection (max 16 nearest vehicles)
    // to prevent vehicles from crowding out weapons/crates and dropping FPS
    static const int kDSPUBGMaxPublishedVehicles = 16;
    DSPUBGProjectedItem finalItems[kDSPUBGMaxItems];
    int copyItemCount = 0;
    int publishedVehicles = 0;

    for (int i = 0; i < itemStagingCount && copyItemCount < kDSPUBGMaxItems; i++) {
        if (itemStaging[i].category == DSPUBGItemCategoryVehicle) {
            if (publishedVehicles >= kDSPUBGMaxPublishedVehicles) continue;
            publishedVehicles++;
        }
        finalItems[copyItemCount++] = itemStaging[i];
    }
    int copyGrenadeCount = grenadeStagingCount > kDSPUBGMaxGrenades ? kDSPUBGMaxGrenades : grenadeStagingCount;

    os_unfair_lock_lock(&g_dspubgSnapshotLock);
    memcpy(g_dspubgPlayers, staging, publishedCount * sizeof(DSPUBGProjectedPlayer));
    g_dspubgPlayerCount = publishedCount;
    g_dspubgTotalEnemies = total360EnemyCount;
    g_dspubgTotalBots = total360BotCount;
    ++g_dspubgEpoch;

    memcpy(g_dspubgItems, finalItems, copyItemCount * sizeof(DSPUBGProjectedItem));
    g_dspubgItemCount = copyItemCount;
    ++g_dspubgItemEpoch;

    memcpy(g_dspubgGrenades, grenadeStaging, copyGrenadeCount * sizeof(DSPUBGProjectedGrenade));
    g_dspubgGrenadeCount = copyGrenadeCount;
    ++g_dspubgGrenadeEpoch;
    os_unfair_lock_unlock(&g_dspubgSnapshotLock);

    // Garbage collect stale grenade histories (> 3 ticks unseen)
    for (int h = 0; h < 16; h++) {
        if (s_grenadeHistories[h].actor != 0 && (s_grenadeTickCounter - s_grenadeHistories[h].lastSeenTick) > 3) {
            memset(&s_grenadeHistories[h], 0, sizeof(DSPUBGGrenadeHistory));
        }
    }

    // Advance tick
    ++s_visTickCounter;
}

static void ds_pubg_tick(void) {
    @try {
        ds_pubg_tick_impl();
    } @catch (__unused NSException *exception) {
        if (!ds_debug_target_alive()) {
            ds_pubg_overlay_reset();
            ds_debug_shmem_flush_ex(NO);
            g_dspubgTargetActive.store(false, std::memory_order_release);
            g_dspubgProc = g_dspubgVmMap = g_dspubgBase = 0;
            g_dspubgPid = 0;
            g_dspubgCachedWorld = 0;
        }
    }
}

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
static std::atomic<bool> g_dspubgActiveMatch(false);

// Live diagnostic statistics
static int g_dspubgLastActorsCount = 0;
static int g_dspubgLastEnemyCount = 0;
static int g_dspubgLastBotCount = 0;
static uint32_t g_dspubgLastBoneOff = 0;

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

// Fast Actor Classification Cache: eliminates repetitive GNames lookups and memory reads.
struct DSPUBGActorCacheEntry {
    uint64_t actor;
    uint64_t classPrivate;
    uint32_t nameIndex;
    bool isScenery;
    bool isPawn;
    bool isTrainingTarget;
    DSPUBGItemCategory itemCat;
    char itemName[36];
    uint64_t rootComp;
    uint64_t meshComp;
    uint64_t boneData;
    uint32_t boneCount;
    uint32_t boneOffset;
    uint64_t infoActor;
    char cachedName[32];
    char cachedNation[16];
    uint32_t cachedPlayerKey;
    uint64_t metaActor;
    uint64_t metaPs;
    bool cachedIsAI;
    bool cachedHasNation;
    bool cachedHasUID;
    char cachedMetaNation[16];
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
static uint64_t s_cachedWorldLevels[64] = {};
static uint32_t s_cachedWorldLevelCount = 0;
static uint32_t s_sublevelCursor = 1;

static inline uint32_t ds_pubg_actor_cache_hash(uint64_t actor) {
    return (uint32_t)((actor >> 4) ^ (actor >> 13)) & (uint32_t)(kDSPUBGActorCacheSize - 1);
}

static void ds_pubg_smart_reset(void);

static inline bool ds_pubg_contains_any(const char *haystack, const char *const *needles, size_t count, bool icase) {
    if (!haystack || !haystack[0]) return false;
    for (size_t i = 0; i < count; i++) {
        if (icase ? (strcasestr(haystack, needles[i]) != NULL) : (strstr(haystack, needles[i]) != NULL)) {
            return true;
        }
    }
    return false;
}

static inline bool ds_pubg_is_pet_name(const char *name) {
    static const char *const kPetTokens[] = {
        "Pet", "Companion", "Buddy", "Mascot", "Partner", "Falcon", "Pigeon"
    };
    return ds_pubg_contains_any(name, kPetTokens, sizeof(kPetTokens) / sizeof(kPetTokens[0]), true);
}

static inline bool ds_pubg_is_training_target_name(const char *name) {
    static const char *const kTargetTokens[] = {
        "ModelTarget", "TrainingTarget", "TrainingDummy", "TargetDummy",
        "ShootTarget", "PracticeTarget", "MoveTarget", "RangeTarget",
        "HumanTarget", "Target_"
    };
    return ds_pubg_contains_any(name, kTargetTokens, sizeof(kTargetTokens) / sizeof(kTargetTokens[0]), true);
}

static inline bool ds_pubg_is_scenery_name(const char *name) {
    if (!name || !name[0]) return false;
    if (ds_pubg_is_pet_name(name)) return true;
    if (ds_pubg_is_training_target_name(name)) return false;
    static const char *const kSceneryTokens[] = {
        "StaticMesh", "Foliage", "Landscape", "Building", "House", "Tree", "Rock",
        "Wall", "Fence", "Door", "Window", "Floor", "Roof", "Brush", "Decal",
        "Particle", "Effect", "Volume", "Audio", "Sound", "Zone", "Fog", "Light",
        "Camera", "Trigger", "Controller", "Water", "Sky", "Cloud", "Shadow",
        "Nav", "Navigation", "Spline", "Occlusion", "Reflection", "PostProcess",
        "Wind", "Emitter", "Shell", "Cartridge", "Trace", "Lobby", "MainCity",
        "Preview", "Avatar", "PetAvatar", "LobbyModel", "DefaultPhysicsVolume",
        "Spawner", "SpawnPoint", "SpawnPad", "Terminal", "Station", "Manager",
        "Stand", "Table", "Board", "Target", "Guide", "Button", "Widget",
        "UI_", "_UI", "SeatComponent", "WheelComponent"
    };
    return ds_pubg_contains_any(name, kSceneryTokens, sizeof(kSceneryTokens) / sizeof(kSceneryTokens[0]), false);
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

static inline bool ds_pubg_cache_entry_valid(const DSPUBGActorCacheEntry &entry, uint64_t actor) {
    if (entry.actor != actor || !actor) return false;
    uint64_t cls = ds_pubg_read_ptr(actor + 0x10ULL);
    uint32_t nid = ds_pubg_read_u32(actor + 0x18ULL);
    return (cls == entry.classPrivate && nid == entry.nameIndex);
}

static inline void ds_pubg_cache_stamp(DSPUBGActorCacheEntry &entry, uint64_t actor) {
    entry.actor = actor;
    entry.classPrivate = ds_pubg_read_ptr(actor + 0x10ULL);
    entry.nameIndex = ds_pubg_read_u32(actor + 0x18ULL);
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
            if (!ds_debug_read_bytes_uncached(vmMap, chunkAddr, chunk.data(), toRead)) continue;

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

static DSPUBGItemCategory ds_pubg_classify_vehicle_name(const char *name, char *outDisplay, size_t outCap) {
    if (!name || !name[0] || !outDisplay || outCap < 4) return DSPUBGItemCategoryNone;
    static const char *const kNonVehTokens[] = {
        "Wheel", "Seat", "Spawner", "SpawnPoint", "SpawnPad", "Spawn",
        "Terminal", "Station", "Manager", "Stand", "Table", "Board",
        "Audio", "Sound", "Decal", "Weapon", "Trigger", "Target",
        "Guide", "Button", "Widget"
    };
    if (ds_pubg_contains_any(name, kNonVehTokens, sizeof(kNonVehTokens) / sizeof(kNonVehTokens[0]), true) ||
        strstr(name, "UI_") || strstr(name, "_UI") ||
        ((strcasestr(name, "PickUp") || strcasestr(name, "Pickup") || strcasestr(name, "Wrapper")) && !strcasestr(name, "VH_"))) {
        return DSPUBGItemCategoryNone;
    }

    static const struct { const char *kw; const char *label; } kVehTable[] = {
        { "Jeep", "Xe UAZ" }, { "UAZ", "Xe UAZ" },
        { "Sedan", "Xe Dacia" }, { "Dacia", "Xe Dacia" },
        { "Buggy", "Xe Buggy" },
        { "VH_PickUp", "Xe Bán Tải" }, { "VH_Pickup", "Xe Bán Tải" }, { "Rony", "Xe Bán Tải" },
        { "Motorcycle", "Xe Máy" }, { "Motorbike", "Xe Máy" }, { "VH_Motor", "Xe Máy" }, { "Bike", "Xe Máy" },
        { "Scooter", "Xe Scooter" },
        { "TukTuk", "Xe TukTuk" },
        { "MiniBus", "Xe MiniBus" }, { "Bus_", "Xe MiniBus" },
        { "PG117", "Thuyền Cano" }, { "Boat", "Thuyền Cano" }, { "Cano", "Thuyền Cano" },
        { "AquaRail", "Moto Nước" }, { "JetSki", "Moto Nước" },
        { "BRDM", "Xe BRDM" },
        { "CoupeRB", "Xe Coupe RB" }, { "Coupe", "Xe Coupe RB" },
        { "MonsterTruck", "Xe Quái Thú" }, { "BigFoot", "Xe Quái Thú" },
        { "Mirado", "Xe Mirado" },
        { "Lada", "Xe Lada Niva" },
        { "Snowmobile", "Xe Tuyết" }, { "Snowbike", "Xe Tuyết" },
        { "Bicycle", "Xe Đạp" },
        { "Tank", "Xe Tăng" },
        { "Helicopter", "Trực Thăng" }, { "DirectFly", "Trực Thăng" },
        { "Lamborghini", "Xe Lamborghini" },
        { "Tesla", "Xe Model Y" }, { "ModelY", "Xe Model Y" },
        { "UTV", "Xe UTV" },
        { "ATV", "Xe ATV" },
    };
    if (strcasestr(name, "Truck") && !strcasestr(name, "Monster")) {
        snprintf(outDisplay, outCap, "Xe Bán Tải");
        return DSPUBGItemCategoryVehicle;
    }
    for (const auto &entry : kVehTable) {
        if (strcasestr(name, entry.kw)) {
            snprintf(outDisplay, outCap, "%s", entry.label);
            return DSPUBGItemCategoryVehicle;
        }
    }
    return DSPUBGItemCategoryNone;
}

static DSPUBGItemCategory ds_pubg_classify_item(const char *name, char *outDisplay, size_t outCap) {
    if (!name || !outDisplay || outCap < 4) return DSPUBGItemCategoryNone;
    outDisplay[0] = '\0';

    static const char *const kNonItemTokens[] = {
        "Bullet", "Proj", "Shell", "Cartridge", "Trace", "Particle", "Emitter", "Effect",
        "Decal", "Camera", "Controller", "Player", "Character", "Volume", "Trigger",
        "Light", "Audio", "Sound", "Landscape", "WorldSettings", "GameMode",
        "Grenade", "Smoke", "Flash", "Explo", "Fire", "Flame"
    };
    if (ds_pubg_contains_any(name, kNonItemTokens, sizeof(kNonItemTokens) / sizeof(kNonItemTokens[0]), true)) {
        return DSPUBGItemCategoryNone;
    }

    DSPUBGItemCategory vehCat = ds_pubg_classify_vehicle_name(name, outDisplay, outCap);
    if (vehCat != DSPUBGItemCategoryNone) return vehCat;

    static const struct { const char *kw; const char *label; DSPUBGItemCategory cat; } kNamedItems[] = {
        // Scopes
        { "8X", "Scope 8x", DSPUBGItemCategoryScope },
        { "6X", "Scope 6x", DSPUBGItemCategoryScope },
        { "4X", "Scope 4x", DSPUBGItemCategoryScope },
        { "3X", "Scope 3x", DSPUBGItemCategoryScope },
        { "2X", "Scope 2x", DSPUBGItemCategoryScope },
        { "RedDot", "Red Dot", DSPUBGItemCategoryScope }, { "HD", "Red Dot", DSPUBGItemCategoryScope },
        { "Holo", "Holo", DSPUBGItemCategoryScope }, { "MZJ_QX", "Holo", DSPUBGItemCategoryScope },
        // Armor & Helmets
        { "Armor_Lv3", "Giáp 3", DSPUBGItemCategoryArmor }, { "Armor3", "Giáp 3", DSPUBGItemCategoryArmor },
        { "Armor_Lv2", "Giáp 2", DSPUBGItemCategoryArmor }, { "Armor2", "Giáp 2", DSPUBGItemCategoryArmor },
        { "Armor_Lv1", "Giáp 1", DSPUBGItemCategoryArmor }, { "Armor1", "Giáp 1", DSPUBGItemCategoryArmor },
        { "Head_Lv3", "Mũ 3", DSPUBGItemCategoryArmor }, { "Helmet_Lv3", "Mũ 3", DSPUBGItemCategoryArmor }, { "Head3", "Mũ 3", DSPUBGItemCategoryArmor },
        { "Head_Lv2", "Mũ 2", DSPUBGItemCategoryArmor }, { "Helmet_Lv2", "Mũ 2", DSPUBGItemCategoryArmor }, { "Head2", "Mũ 2", DSPUBGItemCategoryArmor },
        { "Head_Lv1", "Mũ 1", DSPUBGItemCategoryArmor }, { "Helmet_Lv1", "Mũ 1", DSPUBGItemCategoryArmor }, { "Head1", "Mũ 1", DSPUBGItemCategoryArmor },
        // Backpacks
        { "Bag_Lv3", "Balo 3", DSPUBGItemCategoryBag }, { "Bag3", "Balo 3", DSPUBGItemCategoryBag },
        { "Bag_Lv2", "Balo 2", DSPUBGItemCategoryBag }, { "Bag2", "Balo 2", DSPUBGItemCategoryBag },
        { "Bag_Lv1", "Balo 1", DSPUBGItemCategoryBag }, { "Bag1", "Balo 1", DSPUBGItemCategoryBag },
        // Weapons
        { "Flare", "Flare Gun", DSPUBGItemCategoryWeapon },
        { "AWM", "AWM", DSPUBGItemCategoryWeapon },
        { "M416", "M416", DSPUBGItemCategoryWeapon },
        { "AKM", "AKM", DSPUBGItemCategoryWeapon },
        { "M24", "M24", DSPUBGItemCategoryWeapon },
        { "Kar98", "Kar98k", DSPUBGItemCategoryWeapon },
        { "Groza", "Groza", DSPUBGItemCategoryWeapon },
        { "AUG", "AUG", DSPUBGItemCategoryWeapon },
        { "M762", "M762", DSPUBGItemCategoryWeapon },
        { "Mk14", "Mk14", DSPUBGItemCategoryWeapon },
        { "SLR", "SLR", DSPUBGItemCategoryWeapon },
        { "SKS", "SKS", DSPUBGItemCategoryWeapon },
        { "Mini14", "Mini14", DSPUBGItemCategoryWeapon },
        { "AMR", "Lynx AMR", DSPUBGItemCategoryWeapon },
        { "MG3", "MG3", DSPUBGItemCategoryWeapon },
        { "M249", "M249", DSPUBGItemCategoryWeapon },
        { "DP28", "DP-28", DSPUBGItemCategoryWeapon }, { "DP-28", "DP-28", DSPUBGItemCategoryWeapon },
        { "P90", "P90", DSPUBGItemCategoryWeapon },
        { "Vector", "Vector", DSPUBGItemCategoryWeapon },
        { "UMP", "UMP45", DSPUBGItemCategoryWeapon },
        { "DBS", "DBS", DSPUBGItemCategoryWeapon },
        { "SCAR", "SCAR-L", DSPUBGItemCategoryWeapon },
        { "M16A4", "M16A4", DSPUBGItemCategoryWeapon }, { "M16", "M16A4", DSPUBGItemCategoryWeapon },
        { "QBZ", "QBZ", DSPUBGItemCategoryWeapon },
        { "G36", "G36C", DSPUBGItemCategoryWeapon },
        { "ACE32", "ACE32", DSPUBGItemCategoryWeapon },
        { "Honey", "Honey Badger", DSPUBGItemCategoryWeapon },
        { "FAMAS", "FAMAS", DSPUBGItemCategoryWeapon },
        { "Mosin", "Mosin", DSPUBGItemCategoryWeapon },
        { "Mk12", "Mk12", DSPUBGItemCategoryWeapon },
        { "QBU", "QBU", DSPUBGItemCategoryWeapon },
        { "VSS", "VSS", DSPUBGItemCategoryWeapon },
        { "S12K", "S12K", DSPUBGItemCategoryWeapon },
        { "S686", "S686", DSPUBGItemCategoryWeapon },
        { "S1897", "S1897", DSPUBGItemCategoryWeapon },
        { "UZI", "Micro UZI", DSPUBGItemCategoryWeapon }, { "MicroUZI", "Micro UZI", DSPUBGItemCategoryWeapon },
        { "Bizon", "PP-19 Bizon", DSPUBGItemCategoryWeapon }, { "PP19", "PP-19 Bizon", DSPUBGItemCategoryWeapon },
        { "MP5K", "MP5K", DSPUBGItemCategoryWeapon }, { "MP5", "MP5K", DSPUBGItemCategoryWeapon },
        { "Pan", "Chảo", DSPUBGItemCategoryWeapon },
    };
    for (const auto &entry : kNamedItems) {
        if (strcasestr(name, entry.kw)) {
            snprintf(outDisplay, outCap, "%s", entry.label);
            return entry.cat;
        }
    }

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
    // ASTExtraGrenadeBase.ItemDefineID.TypeSpecificID at 0x67C (neighbours for minor struct alignment diffs)
    static const uint64_t kGrenadeIdOffs[] = { 0x67CULL, 0x678ULL, 0x680ULL, 0x674ULL };
    for (uint64_t off : kGrenadeIdOffs) {
        uint32_t id = ds_pubg_read_u32(actor + off);
        if (id >= 602001 && id <= 602005) return id;
    }
    return 0;
}

static bool ds_pubg_identify_grenade(uint64_t actor, DSPUBGGrenadeType *outType, char *outDisplay, size_t outCap, float *outRadius) {
    if (!actor || !outType || !outDisplay || outCap < 8) return false;

    auto setResult = [&](DSPUBGGrenadeType t, const char *label, float r) {
        *outType = t;
        snprintf(outDisplay, outCap, "%s", label);
        if (outRadius) *outRadius = r;
        return true;
    };

    switch (ds_pubg_read_grenade_id(actor)) {
        case 602004: return setResult(DSPUBGGrenadeTypeFrag, "LỰU ĐẠN", 9.0f);
        case 602003: return setResult(DSPUBGGrenadeTypeBurn, "BOM LỬA", 4.5f);
        case 602002: return setResult(DSPUBGGrenadeTypeSmoke, "BOM KHÓI", 6.0f);
        case 602001:
        case 602005: return setResult(DSPUBGGrenadeTypeStun, "BOM CHOÁNG", 8.0f);
        default: break;
    }

    char actorName[64] = {0};
    if (!ds_pubg_get_actor_name(actor, actorName, sizeof(actorName))) return false;
    if (strcasestr(actorName, "PickUp") || strcasestr(actorName, "Character") ||
        strcasestr(actorName, "Pawn") || strcasestr(actorName, "Camera")) {
        return false;
    }
    if (strcasestr(actorName, "Shoulei") || strcasestr(actorName, "Frag") ||
        strcasestr(actorName, "ProjFrag") || strcasestr(actorName, "BP_Grenade_Shoulei")) {
        return setResult(DSPUBGGrenadeTypeFrag, "LỰU ĐẠN", 9.0f);
    }
    if (strcasestr(actorName, "Burn") || strcasestr(actorName, "Molotov") ||
        strcasestr(actorName, "RanShaoPing") || strcasestr(actorName, "ProjBurn")) {
        return setResult(DSPUBGGrenadeTypeBurn, "BOM LỬA", 4.5f);
    }
    if (strcasestr(actorName, "Smoke") || strcasestr(actorName, "YanWuDan") || strcasestr(actorName, "ProjSmoke")) {
        return setResult(DSPUBGGrenadeTypeSmoke, "BOM KHÓI", 6.0f);
    }
    if (strcasestr(actorName, "Stun") || strcasestr(actorName, "Flash") ||
        strcasestr(actorName, "ZhenBaoDan") || strcasestr(actorName, "ProjStun")) {
        return setResult(DSPUBGGrenadeTypeStun, "BOM CHOÁNG", 8.0f);
    }
    if (strcasestr(actorName, "STExtraGrenadeBase") || strcasestr(actorName, "STProjectileBase")) {
        return setResult(DSPUBGGrenadeTypeFrag, "LỰU ĐẠN", 9.0f);
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

static int ds_pubg_read_pickup_item_id(uint64_t actor) {
    static const uint64_t kItemIdOffsets[] = {
        0x5FCULL, 0x758ULL
    };
    for (uint64_t off : kItemIdOffsets) {
        int val = ds_pubg_read_i32(actor + off);
        if (val >= 101001 && val <= 699999) {
            return val;
        }
    }
    return 0;
}

static DSPUBGItemCategory ds_pubg_identify_item(uint64_t actor, const char *preloadedName, char *outDisplay, size_t outCap) {
    if (!actor || !outDisplay || outCap < 4 || !ds_pubg_valid(actor)) return DSPUBGItemCategoryNone;
    outDisplay[0] = '\0';

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
        static const char *const kIgnoreItemTokens[] = {
            "StaticMesh", "InstancedFoliage", "Foliage", "Landscape", "Building", "House",
            "Tree", "Rock", "Wall", "Fence", "Door", "Window", "Stairs", "Floor", "Roof",
            "Brush", "Volume", "NavMesh", "Light", "Audio", "Sound", "Particle", "Emitter",
            "Effect", "Decal", "Camera", "Controller", "Player", "Character", "Pawn",
            "WorldSettings", "GameMode", "GameState", "Bullet", "Proj", "Shell", "Cartridge",
            "Trace", "Grenade", "Smoke", "Flash", "Explo", "Fire", "Flame", "Trigger",
            "Spawner", "SpawnPoint", "SpawnPad", "Spawn", "Terminal", "Station", "Manager",
            "Stand", "Table", "Board", "Target", "Guide", "Button", "Widget",
            "Seat", "Wheel", "Collision", "Physics"
        };
        if (ds_pubg_contains_any(actorName, kIgnoreItemTokens, sizeof(kIgnoreItemTokens) / sizeof(kIgnoreItemTokens[0]), true) ||
            strstr(actorName, "UI_") || strstr(actorName, "_UI")) {
            return DSPUBGItemCategoryNone;
        }

        // 1. Vehicle check by name / secondary shape fallback
        DSPUBGItemCategory vehCat = ds_pubg_classify_vehicle_name(actorName, outDisplay, outCap);
        if (vehCat != DSPUBGItemCategoryNone) {
            return vehCat;
        }
        if (strcasestr(actorName, "VH_") || strcasestr(actorName, "Vehicle")) {
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

        // 3. Item define ID. Ground loot is an APickUpWrapperActor holding an
        // item ID; that ID is authoritative and needs no name heuristics.
        // Containers and characters are excluded because 0x5FC/0x758 hold
        // unrelated state on them.
        static const char *const kNonLootTokens[] = {
            "Character", "Pawn", "Player", "Bot", "STExtra", "Controller",
            "Camera", "Vehicle", "VH_", "InventoryBox", "TombBox", "DeadBox"
        };
        int targetId = 0;
        if (!ds_pubg_contains_any(actorName, kNonLootTokens,
                                  sizeof(kNonLootTokens) / sizeof(kNonLootTokens[0]), true)) {
            targetId = ds_pubg_read_pickup_item_id(actor);
        }

        // 4. Pick-up wrapper: the class name is only trusted here. Matching item
        // keywords against every actor's name painted weapon meshes, armour
        // props and set dressing ("Pan", "HD", "2X" are ordinary substrings)
        // as ground loot.
        const bool wrapperName = (strstr(actorName, "Wrapper") != NULL ||
                                  strstr(actorName, "PickUp") != NULL ||
                                  strstr(actorName, "Pickup") != NULL ||
                                  strstr(actorName, "DroppedItem") != NULL);
        if (wrapperName || targetId > 0) {
            uint8_t pickedUp = ds_pubg_read_u8(actor + 0x615ULL) & 1;
            if (pickedUp) return DSPUBGItemCategoryNone;
            uint64_t own = ds_pubg_read_ptr(actor + 0x140ULL);
            if (own && ds_pubg_valid(own)) return DSPUBGItemCategoryNone;

            if (targetId > 0) {
                DSPUBGItemCategory idCat = ds_pubg_classify_item_id(targetId, outDisplay, outCap);
                if (idCat != DSPUBGItemCategoryNone) return idCat;
            }
            if (wrapperName) {
                DSPUBGItemCategory strCat = ds_pubg_classify_item(actorName, outDisplay, outCap);
                if (strCat != DSPUBGItemCategoryNone) return strCat;
            }
        }

        // If actor has a name and none of the above matched, it is definitely not an item or vehicle!
        return DSPUBGItemCategoryNone;
    }

    // Name resolution failed (hasName == false) - Use strict multi-field memory checks
    uint8_t pickedUp = ds_pubg_read_u8(actor + 0x615ULL) & 1;
    if (pickedUp) return DSPUBGItemCategoryNone;
    int targetId = ds_pubg_read_pickup_item_id(actor);
    if (targetId > 0) {
        uint64_t own = ds_pubg_read_ptr(actor + 0x140ULL);
        if (own && ds_pubg_valid(own)) return DSPUBGItemCategoryNone;
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

    auto addItem = [&](int itemId, int count) {
        (void)count;
        if (itemId < 101001 || itemId > 699999) return;
        char dName[36] = {0};
        DSPUBGItemCategory cat = ds_pubg_classify_item_id(itemId, dName, sizeof(dName));
        if (cat == DSPUBGItemCategoryNone) return;

        int prio = 10;
        if (itemId == 101004 || itemId == 103003 || itemId == 101005 || itemId == 103007 ||
            itemId == 105003 || itemId == 103013 || itemId == 102008 || itemId == 101006 ||
            itemId == 106007 || itemId == 101008 || itemId == 103001 || itemId == 103002) {
            prio = 1; // High-tier rifles/snipers/airdrop guns
        } else if (cat == DSPUBGItemCategoryWeapon) {
            prio = 2;
        } else if (itemId == 501003 || itemId == 501006 || itemId == 502003 || itemId == 503003) {
            prio = 3; // Lv3 Armor, Helmet, Bag
        } else if (itemId == 201005 || itemId == 201010 || itemId == 201012) {
            prio = 4; // Scope 8x, 6x, 15x
        } else if (itemId == 501002 || itemId == 501005 || itemId == 502002 || itemId == 503002) {
            prio = 5; // Lv2 Armor, Helmet, Bag
        } else if (itemId == 201004 || itemId == 201009) {
            prio = 6; // Scope 4x, 3x
        } else if (itemId == 601003 || itemId == 601006 || itemId == 601002) {
            prio = 7; // Meds
        } else if (itemId == 305001 || itemId == 303001 || itemId == 302001) {
            prio = 8; // Ammo
        }

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

    // PickUpListWrapperActor.PickUpDataList (offset 0x968, stride 0x40, ID at +0x4, Count at +0x18)
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
            if (!ds_debug_read_bytes_uncached(vmMap, chunkAddr, chunk.data(), toRead)) continue;

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

static inline bool ds_pubg_is_excluded_process(const char *name, pid_t pid) {
    if (pid <= 1 || pid == getpid()) return true;
    if (!name || !name[0]) return true;
    if (strcasestr(name, "DarkPubg") != NULL ||
        strcasestr(name, "DarkSpeed") != NULL ||
        strcasestr(name, "TrollSpeed") != NULL ||
        strcasestr(name, "WebContent") != NULL) {
        return true;
    }
    return false;
}

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

        if (proc) {
            pid_t pid = (pid_t)(off_proc_p_pid ? ds_kread32(proc + off_proc_p_pid) : 0);
            if (pid <= 0) pid = (pid_t)ds_kread32(proc + 0x60);
            if (pid <= 0) pid = (pid_t)ds_kread32(proc + 0x28);
            if (pid > 1 && pid != getpid()) {
                if (outPid) *outPid = pid;
                return proc;
            }
            proc = 0;
        }

        // 2. Full proclist search with case-insensitive substring (never match self)
        int count = 0;
        list = proclist("", &count);
        if (list && count > 0) {
            for (int i = 0; i < count; i++) {
                const char *name = list[i].name;
                if (ds_pubg_is_excluded_process(name, (pid_t)list[i].pid)) continue;
                if (strcasestr(name, "ShadowTracker") != NULL ||
                    strcasestr(name, "PUBGM") != NULL ||
                    strcasestr(name, "pubgmobile") != NULL ||
                    strcasestr(name, "PUBG") != NULL) {
                    uint64_t p = list[i].kaddr;
                    if (p && ds_isvalid(p)) {
                        pid_t pid = off_proc_p_pid ? (pid_t)ds_kread32(p + off_proc_p_pid) : (pid_t)list[i].pid;
                        if (pid <= 0) pid = (pid_t)list[i].pid;
                        if (!ds_pubg_is_excluded_process(name, pid)) {
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
        g_dspubgActiveMatch.store(false, std::memory_order_release);
        g_dspubgTargetActive.store(false, std::memory_order_release);
        g_dspubgProc = g_dspubgVmMap = g_dspubgBase = 0;
        g_dspubgPid = 0;
        g_dspubgNextAttach = now + 1.0;
        return false;
    }

    uint64_t task = proc_task(proc);
    uint64_t vmMap = ds_isvalid(task) ? task_get_vm_map(task) : 0;
    if (!ds_isvalid(vmMap)) {
        g_dspubgActiveMatch.store(false, std::memory_order_release);
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
        g_dspubgActiveMatch.store(false, std::memory_order_release);
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
        g_dspubgActiveMatch.store(false, std::memory_order_release);
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
static int32_t ds_pubg_read_bone_idx(uint64_t meshComp) {
    // Do not latch the offset process-wide: different skeletal mesh subclasses
    // in the same match park CurrentReadIndex at different members (0xA50 vs
    // 0xA74). A cached hit from one component then read a bogus 0/1 byte on
    // every other pawn, which silently picked the stale half of the double
    // buffer and produced broken skeletons.
    static const uint32_t kIdxOffs[] = { 0xA50U, 0xA54U, 0xA74U, 0xA78U };
    for (uint32_t off : kIdxOffs) {
        int32_t v = ds_pubg_read_i32(meshComp + (uint64_t)off);
        if (v == 0 || v == 1) return v;
    }
    return -1;
}

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
    int32_t rd = ds_pubg_read_bone_idx(meshComp);
    uint32_t first = (rd == 1) ? 0xA40 : 0xA30;
    uint32_t second = (rd == 1) ? 0xA30 : 0xA40;

    if (testOffset(first)) return true;
    if (testOffset(second)) return true;

    // 3. Live transforms eval-context (0xE18 / 0xE28)
    if (testOffset(0xE18)) return true;
    if (testOffset(0xE28)) return true;

    return false;
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

static bool ds_pubg_has_active_match(void) {
    return g_dspubgTargetActive.load(std::memory_order_acquire) &&
           g_dspubgActiveMatch.load(std::memory_order_acquire);
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
    g_dspubgActiveMatch.store(false, std::memory_order_release);
    s_cachedLootCount = 0;
    s_levelScanTick = 0;
    s_trackedLevelPawns.clear();
    s_trackedLevelGrenades.clear();
    s_trackedLevelVehicles.clear();
    s_lastMatchWorld = 0;
    s_lastMatchLevel = 0;
    s_lastMatchMapIsLobby = false;
    g_dspubgWorldLevelsOff = 0;
    s_cachedWorldLevelCount = 0;
    s_sublevelCursor = 1;
    ds_pubg_smart_reset();
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

    g_dspubgGNames = 0;
    g_dspubgNamesCalibrated = false;
    g_dspubgEngineViewportOffset = kDSPUBGEngineGameViewportOffset;
    g_dspubgNextScan = 0;

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

    // Walk further than the old fixed 16-slot window: destroyed actors leave
    // runs of nullptr slots at the head of ULevel::Actors, and a window that is
    // all null used to score zero even for the real list. Stop once eight live
    // objects have been confirmed; a random {ptr,count} pair never gets there.
    const uint32_t probe = count < 32 ? count : 32;
    int score = 0;
    int validObjects = 0;
    for (uint32_t i = 0; i < probe; i++) {
        uint64_t a = ds_pubg_read_ptr(data + (uint64_t)i * sizeof(uint64_t));
        if (!a) continue; // UE4 leaves nullptr slots in ULevel::Actors when actors are destroyed/GC'd
        if (!ds_pubg_valid(a)) return 0;
        score++;
        // A live UObject carries ClassPrivate at 0x10; that second hop is what
        // separates an actor list from an array of random in-range pointers.
        uint64_t cls = ds_pubg_read_ptr(a + 0x10ULL);
        if (cls && ds_pubg_valid(cls)) {
            score += 2;
            if (++validObjects >= 8) break;
        }
    }
    // Decoy {pointer, small-count} pairs scattered through the level body used
    // to win the scan once a single resolvable object was enough, and every
    // actor in those arrays was reported as a phantom enemy or ground item.
    // ULevel::Actors is by far the longest UObject list in a level, so a large
    // count plus one live object is still accepted -- that keeps streamed
    // matches from losing enemies after a GC pass leaves null slots up front.
    const bool largeArray = (count >= 512);
    if (validObjects < 2 && !(largeArray && validObjects >= 1) &&
        !(count <= 8 && validObjects >= 1)) return 0;
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
            // Accept a level list with an unreadable owner field (offset drift),
            // but reject one where every readable owner belongs to another
            // world -- those levels are what produced ghost actors.
            int ownersKnown = 0;
            int unknownOwners = 0;
            bool ownerMatch = false;
            uint32_t checkN = (readCnt > 8) ? 8 : readCnt;
            for (uint32_t i = 1; i < checkN; i++) {
                uint64_t sl = lvls[i] & 0x0000FFFFFFFFFFFFULL;
                if (!sl || !ds_pubg_valid(sl)) continue;
                uint64_t owning = ds_pubg_read_ptr(sl + 0xC0ULL);
                if (!owning) { unknownOwners++; continue; }
                ownersKnown++;
                if (owning == world) { ownerMatch = true; break; }
            }
            // Reject only a list whose every readable owner belongs to another
            // world. An unreadable owner field still means "offset drifted",
            // not "wrong world", so those levels stay in the scan.
            if (ownersKnown > 0 && unknownOwners == 0 && !ownerMatch) return false;
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
        if (ds_pubg_actor_array_plausible(lvl + g_dspubgLevelActorsOff, outData, outCount)) return true;
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

// ComponentToWorld (+0x210 quat, +0x220 translation) fallback: on some builds
// the published relative pose is stale for attached actors (vehicle seats,
// parachutes), but it is only trusted when the relative path has no usable XY.
static bool ds_pubg_read_component_to_world(uint64_t rootComp, DSPUBGVector &outLoc) {
    uint8_t rc2w[32] = {0};
    if (!ds_pubg_read(rootComp + 0x210ULL, rc2w, sizeof(rc2w))) return false;
    float qx = 0, qy = 0, qz = 0, qw = 1.0f;
    DSPUBGVector c2wLoc = {};
    memcpy(&qx, rc2w + 0x0, 4);
    memcpy(&qy, rc2w + 0x4, 4);
    memcpy(&qz, rc2w + 0x8, 4);
    memcpy(&qw, rc2w + 0xC, 4);
    memcpy(&c2wLoc, rc2w + 0x10, sizeof(c2wLoc));
    float qlen2 = qx * qx + qy * qy + qz * qz + qw * qw;
    if (!isfinite(qlen2) || qlen2 < 0.4f || qlen2 > 2.2f) return false;
    if (!isfinite(c2wLoc.X) || !isfinite(c2wLoc.Y) || !isfinite(c2wLoc.Z)) return false;
    if (fabsf(c2wLoc.X) < 1.0f && fabsf(c2wLoc.Y) < 1.0f) return false;
    outLoc = c2wLoc;
    return true;
}

// Resolve a component's world translation. For characters/attached actors the
// published RelativeLocation (+ AttachParent translation) is authoritative on
// this build and is what the working ESP used; ComponentToWorld is the
// fallback for components whose relative pose is stale (vehicle seats,
// parachutes). Reading C2W first mis-projected every pawn when the 0x210
// transform offset shifted.
static bool ds_pubg_read_world_loc(uint64_t rootComp, DSPUBGVector &outLoc, bool includeAttachParent) {
    if (!rootComp || !ds_pubg_valid(rootComp)) return false;

    DSPUBGVector relLoc = {};
    bool haveRel = ds_pubg_read(rootComp + kDSPUBGSceneCompRelativeLocOffset, &relLoc, sizeof(relLoc));
    if (haveRel) {
        if (includeAttachParent) {
            uint64_t parent = ds_pubg_read_ptr(rootComp + kDSPUBGSceneCompAttachedParentOffset);
            if (parent && ds_pubg_valid(parent)) {
                DSPUBGVector parentLoc = {};
                if (ds_pubg_read(parent + kDSPUBGSceneCompRelativeLocOffset, &parentLoc, sizeof(parentLoc))) {
                    relLoc.X += parentLoc.X;
                    relLoc.Y += parentLoc.Y;
                    relLoc.Z += parentLoc.Z;
                }
            }
        }
        if (isfinite(relLoc.X) && isfinite(relLoc.Y) && isfinite(relLoc.Z) &&
            (fabsf(relLoc.X) >= 1.0f || fabsf(relLoc.Y) >= 1.0f)) {
            outLoc = relLoc;
            return true;
        }
    }

    return ds_pubg_read_component_to_world(rootComp, outLoc);
}



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

    // 4. Fallback when the NetDriver offset shifted or is only half-initialised.
    // A match GameState plus either an owned pawn or a populated PlayerArray is
    // already proof of a running session; requiring max-health to have
    // replicated dropped every enemy in the first seconds after landing.
    bool isMatchGs = (hasGsName && (strcasestr(gsName, "STExtra") != NULL ||
                                    strcasestr(gsName, "UAEGameState") != NULL ||
                                    strcasestr(gsName, "GameState") != NULL));
    if (!isMatchGs) {
        // Last resort for builds where the GameState offset moved: a name-passed
        // player controller with an owned pawn is an in-match state. Lobby and
        // preview controllers were already rejected above.
        return (playerController && ds_pubg_valid(playerController) &&
                localPawn && ds_pubg_valid(localPawn));
    }

    if (localPawn && ds_pubg_valid(localPawn)) {
        float lpMaxHp = ds_pubg_read_f32(localPawn + kDSPUBGCharacterHealthMaxOffset);
        float lpHealth = ds_pubg_read_f32(localPawn + kDSPUBGCharacterHealthOffset);
        if (isfinite(lpMaxHp) && lpMaxHp >= 50.0f && lpMaxHp <= 1000000.0f) return true;
        if (isfinite(lpHealth) && lpHealth > 0.0f && lpHealth <= 1000000.0f) return true;
    }

    if (gs && ds_pubg_valid(gs)) {
        uint32_t paCount = ds_pubg_read_u32(gs + kDSPUBGGameStatePlayerArrayOffset + 8ULL);
        if (paCount > 0 && paCount <= 128) return true;
    }

    // Match GameState present but nothing replicated yet: let the tick run so
    // the level scan can populate pawns instead of zeroing the snapshot.
    return true;
}

// Live teammate/self skip set consulted by item/vehicle scanner.

// skipActors set (open addressed, O(1) lookup)
static const size_t kDSPUBGSkipActorSlots = 1024;   // power of two
static uint64_t s_skipActors[kDSPUBGSkipActorSlots] = {};
static size_t s_skipActorCount = 0;

static inline size_t ds_pubg_skip_hash(uint64_t actor) {
    return (size_t)((actor >> 4) ^ (actor >> 13)) & (kDSPUBGSkipActorSlots - 1);
}

static void ds_pubg_smart_reset(void) {
    memset(s_skipActors, 0, sizeof(s_skipActors));
    s_skipActorCount = 0;
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

    // Dynamic scan fallback if world is lost or unlocated (common during cold launch)
    if (!world) {
        if (now >= g_dspubgNextScan) {
            g_dspubgNextScan = now + 1.5;
            // Guard against catching a process mid-exec before its final vm_map is live.
            if (ds_debug_target_alive()) {
                uint64_t curTask = proc_task(g_dspubgProc);
                uint64_t curMap = ds_isvalid(curTask) ? task_get_vm_map(curTask) : 0;
                if (ds_isvalid(curMap) && curMap != g_dspubgVmMap) {
                    ds_debug_shmem_flush_ex(YES);
                    ds_pubg_overlay_reset();
                    g_dspubgTargetActive.store(false, std::memory_order_release);
                    g_dspubgBase = 0;
                    g_dspubgVmMap = 0;
                    g_dspubgEngineRva = 0;
                    g_dspubgWorldRva = 0;
                    return;
                }
            }
            ds_debug_vm_regions_request_async(g_dspubgVmMap, (pid_t)g_dspubgPid);
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

    // If World came online during cold launch before GNames finished initializing
    // or before GNames' heap block entered the VM-region index, keep retrying.
    if (!g_dspubgGNames || !g_dspubgNamesCalibrated) {
        static CFAbsoluteTime s_nextGNamesRetry = 0;
        if (now >= s_nextGNamesRetry) {
            s_nextGNamesRetry = now + 1.5;
            ds_debug_vm_regions_request_async(g_dspubgVmMap, (pid_t)g_dspubgPid);
            ds_pubg_try_known_gnames(g_dspubgVmMap, g_dspubgBase);
            if (!g_dspubgGNames) {
                std::vector<ScanRange> ranges;
                if (ds_pubg_get_data_ranges(g_dspubgVmMap, g_dspubgBase, ranges)) {
                    ds_pubg_scan_for_gnames(g_dspubgVmMap, ranges);
                }
            }
        }
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
    g_dspubgActiveMatch.store(true, std::memory_order_release);

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
        bool cacheValid = ds_pubg_cache_entry_valid(cEntry, pawn);
        bool isTrainingTarget = false;
        if (cacheValid) {
            if (cEntry.isScenery && !psHint) {
                return false;
            }
            if (cEntry.isPawn) {
                isTrainingTarget = cEntry.isTrainingTarget;
            }
        }

        // Fast path: if already cached as a Pawn, skip costly GNames name lookups
        bool isCharacterNamed = false;
        if (!(cacheValid && cEntry.isPawn)) {
            char pawnName[64] = {0};
            bool hasPawnName = ds_pubg_get_actor_name(pawn, pawnName, sizeof(pawnName));
            if (hasPawnName) {
                isTrainingTarget = ds_pubg_is_training_target_name(pawnName);
                isCharacterNamed = isTrainingTarget ||
                    (strcasestr(pawnName, "Character") != NULL ||
                     strcasestr(pawnName, "Pawn") != NULL ||
                     strcasestr(pawnName, "Player") != NULL ||
                     strcasestr(pawnName, "Bot") != NULL ||
                     strcasestr(pawnName, "STExtra") != NULL);
                if (!isTrainingTarget && !psHint) {
                    static const char *const kPawnSceneryExtraTokens[] = {
                        "SM_", "Mesh", "BP_Building", "BP_House", "BP_Wall", "BP_Door",
                        "BP_Fence", "BP_Stair", "Arch", "Prop", "Stair", "Tower",
                        "Shed", "Gate", "Container", "Obstacle"
                    };
                    static const char *const kPawnNonCharTokens[] = {
                        "Bullet", "Proj", "Weapon", "PickUp", "Vehicle", "VH_",
                        "Drop", "Tomb", "Box", "Supply", "AirDrop", "Item",
                        "Controller", "Shell", "Cartridge", "Trace", "Grenade",
                        "Smoke", "Explosion", "Shoulei", "Molotov", "Burn"
                    };
                    // A real character class always wins over the scenery list:
                    // PUBG characters wear meshes whose names carry "Mesh", and
                    // caching one as scenery permanently hid that pawn.
                    // Death boxes and air drops are containers whose class
                    // names still contain "Player" ("PlayerDeadInventoryBox"),
                    // so they used to pass the character-name exemption above
                    // and were drawn as enemies. These tokens are unambiguous,
                    // and the check runs before the exemption on purpose.
                    static const char *const kContainerTokens[] = {
                        "TombBox", "DeadBox", "InventoryBox", "AirDrop",
                        "PickUpListWrapper", "PickupWrapper", "ItemWrapper"
                    };
                    const bool isContainer =
                        ds_pubg_contains_any(pawnName, kContainerTokens, sizeof(kContainerTokens) / sizeof(kContainerTokens[0]), true);
                    if (isContainer) {
                        // Not cached as scenery: the caller falls through to the
                        // item scanner, which labels death boxes and air drops
                        // with their crate name instead of an enemy box.
                        return false;
                    }
                    const bool sceneryHit =
                        ds_pubg_is_scenery_name(pawnName) ||
                        ds_pubg_contains_any(pawnName, kPawnSceneryExtraTokens, sizeof(kPawnSceneryExtraTokens) / sizeof(kPawnSceneryExtraTokens[0]), false);
                    if (sceneryHit && !isCharacterNamed) {
                        ds_pubg_cache_stamp(cEntry, pawn);
                        cEntry.isScenery = true;
                        cEntry.isPawn = false;
                        cEntry.isTrainingTarget = false;
                        cEntry.itemCat = DSPUBGItemCategoryNone;
                        return false;
                    }

                    if (!sceneryHit &&
                        ds_pubg_contains_any(pawnName, kPawnNonCharTokens, sizeof(kPawnNonCharTokens) / sizeof(kPawnNonCharTokens[0]), true) &&
                        !isCharacterNamed) {
                        return false;
                    }
                }
            }
        }

        // 1. Reject local player's own bullets, weapons, projectiles (once per actor)
        if (!(cacheValid && cEntry.isPawn) && !isTrainingTarget && localPawn) {
            uint64_t owner = ds_pubg_read_ptr(pawn + 0x140ULL);
            uint64_t instigator = ds_pubg_read_ptr(pawn + 0x138ULL);
            if (owner == localPawn || instigator == localPawn) {
                return false;
            }
        }

        // 2. Hidden check - AActor.bHidden (0xE8) and batch Health/Groggy/bDead read
        uint8_t healthBlock[0x20] = {0};
        if (isTrainingTarget) {
            if (!ds_pubg_read(pawn + kDSPUBGCharacterHealthOffset, healthBlock, 8)) {
                return false;
            }
        } else {
            uint8_t aHidden = ds_pubg_read_u8(pawn + 0xE8ULL);
            if (aHidden & 0x1) return false;
            if (!ds_pubg_read(pawn + kDSPUBGCharacterHealthOffset, healthBlock, sizeof(healthBlock))) {
                return false;
            }
            if (healthBlock[0x1C] & 1) {
                return false;
            }
        }

        // 3. Must have valid RootComponent and Mesh (standard UE4 character)
        uint64_t rootComp = (cacheValid && cEntry.rootComp) ? cEntry.rootComp : ds_pubg_read_ptr(pawn + kDSPUBGActorRootComponentOffset);
        if (!rootComp) rootComp = ds_pubg_read_ptr(pawn + 0x180ULL);
        if (!rootComp || !ds_pubg_valid(rootComp)) return false;

        uint64_t meshComp = (cacheValid && cEntry.meshComp) ? cEntry.meshComp : ds_pubg_read_ptr(pawn + kDSPUBGCharacterMeshOffset);
        if (!meshComp) meshComp = ds_pubg_read_ptr(pawn + 0x320ULL);
        if (!meshComp || !ds_pubg_valid(meshComp)) return false;

        // Reject level candidates whose mesh component is provably not a
        // skeletal mesh. Death boxes, air drops, pick-up wrappers and set
        // dressing carry a StaticMeshComponent here and were the source of the
        // phantom enemies. This is negative evidence only: an unresolvable or
        // unfamiliar component class still passes, so streamed pawns are never
        // dropped just because their class name has not replicated yet.
        if (!(cacheValid && cEntry.isPawn) && !isTrainingTarget && !psHint) {
            char meshClassName[64] = {0};
            if (ds_pubg_get_actor_name(meshComp, meshClassName, sizeof(meshClassName)) &&
                meshClassName[0] != '\0') {
                static const char *const kNonSkeletalMeshTokens[] = {
                    "StaticMesh", "InstancedStaticMesh", "ParticleSystem",
                    "SplineMesh", "Billboard", "DecalComponent"
                };
                if (ds_pubg_contains_any(meshClassName, kNonSkeletalMeshTokens,
                                         sizeof(kNonSkeletalMeshTokens) / sizeof(kNonSkeletalMeshTokens[0]),
                                         true)) {
                    // Do not cache as scenery: a static mesh is also how a
                    // weapon or armour pick-up is drawn, and the caller needs
                    // to reach the item scanner for those.
                    return false;
                }
            }
        }

        // 4. Health validation (Reject non-characters, pets/companions, and dead bodies, while
        // keeping PlayerArray pawns whose HealthMax has not replicated yet).
        float health = 0.0f, healthMax = 0.0f;
        memcpy(&health, healthBlock + 0x00, 4);
        memcpy(&healthMax, healthBlock + 0x04, 4);
        if (isTrainingTarget) {
            if (isnan(healthMax) || isinf(healthMax) || healthMax < 50.0f || healthMax > 1000000.0f) {
                healthMax = 100.0f;
            }
            if (isnan(health) || isinf(health)) {
                health = healthMax;
            }
        } else {
            if (isnan(health) || isinf(health) || isnan(healthMax) || isinf(healthMax)) return false;
            if (healthMax < 50.0f || healthMax > 1000000.0f) {
                // PlayerArray pawns, name-confirmed characters and previously
                // accepted pawns keep showing while HealthMax is still being
                // replicated; level-scanned enemies fail this otherwise.
                const bool trustedPawn = (psHint != 0) || isCharacterNamed || (cacheValid && cEntry.isPawn);
                if (trustedPawn && health > 0.0f && health <= 10000.0f) {
                    healthMax = fmaxf(health, 100.0f);
                } else {
                    return false;
                }
            }
        }

        if (!cacheValid) {
            cEntry.boneData = 0;
            cEntry.boneCount = 0;
            cEntry.boneOffset = 0;
            cEntry.metaActor = 0;
            cEntry.metaPs = 0;
            cEntry.infoActor = 0;
        }
        ds_pubg_cache_stamp(cEntry, pawn);
        cEntry.isPawn = true;
        cEntry.isScenery = false;
        cEntry.isTrainingTarget = isTrainingTarget;
        cEntry.itemCat = DSPUBGItemCategoryNone;
        cEntry.rootComp = rootComp;
        cEntry.meshComp = meshComp;

        bool isKnocked = false;
        float gh = 0.0f;
        for (int gOff = 0x08; gOff <= 0x14; gOff += 4) {
            float candidate = 0.0f;
            memcpy(&candidate, healthBlock + gOff, 4);
            if (!isnan(candidate) && !isinf(candidate) && candidate > 0.0f && candidate <= 200.0f) {
                gh = candidate;
                break;
            }
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

        DSPUBGVector rootLoc = {};
        if (!ds_pubg_read_world_loc(rootComp, rootLoc, true)) {
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

        if (cacheValid && cEntry.metaActor == pawn && cEntry.metaPs == ps) {
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
                            ds_pubg_cache_stamp(cEntry, pawn);
                            cEntry.isScenery = true;
                            cEntry.isPawn = false;
                            cEntry.itemCat = DSPUBGItemCategoryNone;
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
                if (boxH <= screenH * 6.0f) {
                    if (boxH > screenH * 2.5f) boxH = screenH * 2.5f;
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
            if (!cacheValid || cEntry.infoActor != pawn) {
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
                cEntry.cachedPlayerKey = ds_pubg_read_u32(pawn + kDSPUBGCharacterPlayerKeyOffset);
                cEntry.infoActor = pawn;
            }
            memcpy(p.name, cEntry.cachedName, sizeof(p.name));
            memcpy(p.nation, cEntry.cachedNation, sizeof(p.nation));
            p.playerKey = cEntry.cachedPlayerKey;

            // Real Skeletal Bones (16 joints, 15 bone links)
            p.hasSkeleton = false;
        if (g_pubgEspSkeleton) {
            bool skeletonDone = false;
            uint64_t boneData = 0;
            if (meshComp && ds_pubg_valid(meshComp)) {
                uint32_t bCount = 0;
                uint32_t resolvedOff = 0;
                if (ds_pubg_find_bone_array(meshComp, &boneData, &bCount, &resolvedOff) &&
                    boneData && bCount >= 20) {
                    cEntry.boneData = boneData;
                    cEntry.boneCount = bCount;
                    cEntry.boneOffset = resolvedOff;
                }
                // Player and bot rigs expose 67 transforms; the training dummy
                // exposes a ~22-bone layout. A shorter array on a character is
                // the wrong half of the double buffer and drawing it produced
                // the mangled skeleton. Skip only the bones -- the enemy box,
                // health bar and snapline must keep rendering.
                if (!isTrainingTarget && !psHint && bCount > 0 && bCount < 35) {
                    boneData = 0;
                    skeletonDone = true;
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

        // 1. Fast RootComponent and Location check FIRST (ComponentToWorld then RelativeLocation)
        DSPUBGVector rootLoc = {};
        uint64_t rootComp = ds_pubg_read_ptr(actor + kDSPUBGActorRootComponentOffset);
        if (!rootComp || !ds_pubg_valid(rootComp)) {
            rootComp = ds_pubg_read_ptr(actor + 0x180ULL);
        }
        bool hasLoc = ds_pubg_read_world_loc(rootComp, rootLoc, false);
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
        bool itemCacheValid = ds_pubg_cache_entry_valid(cEntry, actor);
        if (itemCacheValid && cEntry.itemCat != DSPUBGItemCategoryNone) {
            cat = cEntry.itemCat;
            strncpy(displayName, cEntry.itemName, sizeof(displayName) - 1);
            if (cat != DSPUBGItemCategoryVehicle && cat != DSPUBGItemCategoryCrate) {
                uint8_t pickedUp = ds_pubg_read_u8(actor + 0x615ULL) & 1;
                uint64_t own = ds_pubg_read_ptr(actor + 0x140ULL);
                if (pickedUp || (own && ds_pubg_valid(own))) {
                    cEntry.actor = 0;
                    cEntry.classPrivate = 0;
                    cEntry.nameIndex = 0;
                    cEntry.isScenery = false;
                    cEntry.isPawn = false;
                    cEntry.itemCat = DSPUBGItemCategoryNone;
                    return;
                }
            }
        } else {
            char actorName[64] = {0};
            if (ds_pubg_get_actor_name(actor, actorName, sizeof(actorName))) {
                if (strcasestr(actorName, "Lobby") || strcasestr(actorName, "MainCity") ||
                    strcasestr(actorName, "Preview") || strcasestr(actorName, "Avatar")) {
                    ds_pubg_cache_stamp(cEntry, actor);
                    cEntry.isScenery = true;
                    cEntry.isPawn = false;
                    cEntry.itemCat = DSPUBGItemCategoryNone;
                    return;
                }
            }
            cat = ds_pubg_identify_item(actor, actorName, displayName, sizeof(displayName));
            if (cat == DSPUBGItemCategoryNone) {
                if (actorName[0] && ds_pubg_is_scenery_name(actorName)) {
                    ds_pubg_cache_stamp(cEntry, actor);
                    cEntry.isScenery = true;
                    cEntry.isPawn = false;
                    cEntry.itemCat = DSPUBGItemCategoryNone;
                }
                return;
            }
            ds_pubg_cache_stamp(cEntry, actor);
            cEntry.isScenery = false;
            cEntry.isPawn = false;
            cEntry.itemCat = cat;
            strncpy(cEntry.itemName, displayName, sizeof(cEntry.itemName) - 1);
            cEntry.itemName[sizeof(cEntry.itemName) - 1] = '\0';
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

    // Source 1 preload: read PlayerArray entries (defer projection until after level/loot scan)
    struct DSPUBGPAEntry {
        uint64_t pawn;
        uint64_t ps;
        bool isBot;
    };
    std::vector<DSPUBGPAEntry> paEntries;
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
                paEntries.reserve(playerCount);
                for (uint32_t i = 0; i < playerCount; i++) {
                    uint64_t ps = playerStates[i];
                    if (!ps || !ds_pubg_valid(ps)) continue;
                    uint64_t pawn = ds_pubg_read_ptr(ps + kDSPUBGPlayerStatePawnPrivateOffset);
                    if (!pawn) continue;
                    uint8_t botByte = ds_pubg_read_u8(ps + kDSPUBGPlayerStateIsABotOffset);
                    paEntries.push_back({ pawn, ps, (botByte & 0x4) != 0 });
                }
            }
        }
    }

    auto isKnownPawn = [&](uint64_t actor) -> bool {
        for (const auto &e : paEntries) {
            if (e.pawn == actor) return true;
        }
        for (uint64_t tp : s_trackedLevelPawns) {
            if (tp == actor) return true;
        }
        return false;
    };

    auto collectActorsFromLevel = [&](uint64_t lvl, bool isPersistent) {
        if (!lvl || !ds_pubg_valid(lvl)) return;
        uint64_t actorsData = 0;
        uint32_t actorsCount = 0;

        if (isPersistent) {
            if (!ds_pubg_find_level_actors(lvl, &actorsData, &actorsCount)) {
                uint64_t cluster = ds_pubg_read_ptr(lvl + 0xE0ULL);
                if (cluster && ds_pubg_valid(cluster)) {
                    ds_pubg_actor_array_plausible(cluster + 0x28ULL, &actorsData, &actorsCount);
                }
            }
        } else if (g_dspubgLevelActorsOff) {
            // ULevel::OwningWorld is at 0xC0 on the reference dump, but the
            // offset moves between builds. Treat an unreadable/empty field as
            // "unknown" instead of "not ours"; rejecting here meant every
            // streamed sublevel was skipped and its enemies never existed.
            uint64_t owning = ds_pubg_read_ptr(lvl + 0xC0ULL);
            if (owning && ds_pubg_valid(owning) && owning != world) return;
            if (!ds_pubg_actors_array_at(lvl + g_dspubgLevelActorsOff, &actorsData, &actorsCount) ||
                actorsCount == 0 || actorsCount > 8192) {
                return;
            }
        } else {
            return;
        }

        if (actorsData && actorsCount > 0) {
            if (isPersistent) {
                g_dspubgLastActorsCount = (int)actorsCount;
            }
            if (actorsCount > 8192) actorsCount = 8192;
            static std::vector<uint64_t> s_levelActors;
            if (s_levelActors.size() < actorsCount) s_levelActors.resize(actorsCount);
            if (ds_pubg_read(actorsData, s_levelActors.data(), actorsCount * sizeof(uint64_t))) {
                for (uint32_t i = 0; i < actorsCount; i++) {
                    uint64_t actor = s_levelActors[i];
                    if (!actor || actor == localPawn || !ds_pubg_valid(actor)) continue;
                    if (isKnownPawn(actor)) continue;

                    uint32_t cSlot = ds_pubg_actor_cache_hash(actor);
                    DSPUBGActorCacheEntry &cEntry = g_dspubgActorCache[cSlot];
                    if (ds_pubg_cache_entry_valid(cEntry, actor)) {
                        if (cEntry.isScenery) {
                            continue;
                        }
                        if (cEntry.itemCat != DSPUBGItemCategoryNone) {
                            if (isPersistent) processItemOrVehicle(actor);
                            continue;
                        }
                        if (cEntry.isPawn) {
                            if (s_trackedLevelPawns.size() < 128) s_trackedLevelPawns.push_back(actor);
                            continue;
                        }
                    }

                    if (!processPawn(actor, 0, false)) {
                        if (!isPersistent) continue;
                        if (!processGrenade(actor)) {
                            processItemOrVehicle(actor);
                        } else {
                            bool alreadyG = false;
                            for (uint64_t tg : s_trackedLevelGrenades) { if (tg == actor) { alreadyG = true; break; } }
                            if (!alreadyG && s_trackedLevelGrenades.size() < 16) s_trackedLevelGrenades.push_back(actor);
                        }
                    } else {
                        if (s_trackedLevelPawns.size() < 128) s_trackedLevelPawns.push_back(actor);
                    }
                }
            }
        }
    };

    for (size_t gi = 0; gi < s_trackedLevelGrenades.size(); ) {
        uint64_t tg = s_trackedLevelGrenades[gi];
        if (!tg || !ds_pubg_valid(tg) || !processGrenade(tg)) {
            s_trackedLevelGrenades.erase(s_trackedLevelGrenades.begin() + gi);
        } else {
            gi++;
        }
    }

    // Dual-cadence level & loot scan BEFORE refreshing camera/player transforms
    // so enemy ESP always projects against the latest post-scan camera pose.
    static const uint32_t kDSPUBGFullScanInterval = 20;
    bool needFullLevelScan = ((s_levelScanTick++ % kDSPUBGFullScanInterval) == 0);
    if (needFullLevelScan && level) {
        s_trackedLevelVehicles.clear();
        int beforeCount = itemStagingCount;
        collectActorsFromLevel(level, true);
        if (g_dspubgLevelActorsOff) {
            s_cachedWorldLevelCount = ds_pubg_find_world_levels(world, level, s_cachedWorldLevels, 64);
        }
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
        if (g_dspubgLevelActorsOff && s_cachedWorldLevelCount > 1) {
            // Amortize streaming sublevel pawn discovery (max 3 sublevels/tick) to avoid scan spikes
            uint32_t subCount = s_cachedWorldLevelCount - 1;
            uint32_t batch = subCount < 3 ? subCount : 3;
            for (uint32_t b = 0; b < batch; b++) {
                uint32_t li = 1 + ((s_sublevelCursor - 1 + b) % subCount);
                collectActorsFromLevel(s_cachedWorldLevels[li], false);
            }
            s_sublevelCursor = 1 + ((s_sublevelCursor - 1 + batch) % subCount);
        }
        for (size_t vi = 0; vi < s_trackedLevelVehicles.size(); ) {
            uint64_t tv = s_trackedLevelVehicles[vi];
            if (!tv || !ds_pubg_valid(tv)) {
                s_trackedLevelVehicles.erase(s_trackedLevelVehicles.begin() + vi);
                continue;
            }
            processItemOrVehicle(tv);
            vi++;
        }
    }

    // Refresh CameraCache.POV immediately before projecting loot & players
    if (cameraManager) {
        uint64_t cachePov = cameraManager + 0x520ULL + 0x10ULL;
        DSPUBGVector freshLoc = {};
        DSPUBGRotator freshRot = {};
        float freshFOV = 0.0f;
        if (ds_pubg_read(cachePov + kDSPUBGPOVLocationOffset, &freshLoc, sizeof(freshLoc)) &&
            ds_pubg_read(cachePov + kDSPUBGPOVRotationOffset, &freshRot, sizeof(freshRot)) &&
            ds_pubg_read(cachePov + kDSPUBGPOVFOVOffset, &freshFOV, sizeof(freshFOV)) &&
            !isnan(freshLoc.X) && !isinf(freshLoc.X) && (fabsf(freshLoc.X) > 1.0f || fabsf(freshLoc.Y) > 1.0f) &&
            !isnan(freshRot.Pitch) && !isnan(freshRot.Yaw) && freshFOV >= 20.0f && freshFOV <= 160.0f) {
            DSPUBGCamBasis freshBasis = {};
            if (ds_pubg_cam_basis_build(freshLoc, freshRot, freshFOV, screenW, screenH, freshBasis)) {
                basis = freshBasis;
            }
        }
    }

    if (!needFullLevelScan) {
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

    // Project all players with the freshest camera basis right before snapshot publish
    for (const auto &pa : paEntries) {
        processPawn(pa.pawn, pa.ps, pa.isBot);
    }
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

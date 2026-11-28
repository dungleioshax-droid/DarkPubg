// DSBridgeESP.inc.mm — shared-page kernel memory reader + AOV hosted overlay.
// Included by DSBridge.mm.
//
// Hạ tầng dùng chung (Fl0rkFF style): vm region cache, shared-page cache qua
// vmmapremotepage, read/write helpers, Mach-O main-image identity. Reader AOV
// nằm ở DSBridgeLienQuan.inc.mm; file này giữ hosted overlay và render loop.

static BOOL ds_debug_user_address(uint64_t address) {
    return address >= 0x100000000ULL && address < 0x300000000000ULL;
}

typedef struct {
    uint64_t start;
    uint64_t end;
    uint64_t entryAddress;
} DSDebugVMRegion;

enum class DSDebugShmemOwner : uint8_t {
    None = 0,
    PUBG = 1,
};

// Mapper ownership is confined to ds_bridge_queue.
static DSDebugShmemOwner g_debugShmemOwner = DSDebugShmemOwner::None;
static pid_t g_debugShmemPid = 0;
static uint64_t g_debugShmemOwnerVmMap = 0;

static bool ds_debug_shmem_target_matches(DSDebugShmemOwner owner, pid_t pid,
                                          uint64_t vmMap) {
    return owner != DSDebugShmemOwner::None &&
           g_debugShmemOwner == owner && g_debugShmemPid == pid && pid > 0 &&
           g_debugShmemOwnerVmMap == vmMap && vmMap != 0;
}

static std::vector<DSDebugVMRegion> g_debugVMRegions;
static uint64_t g_debugVMRegionsMap = 0;
static pid_t g_debugVMRegionsPid = 0;
static CFAbsoluteTime g_debugVMRegionsBuiltAt = 0;
static CFAbsoluteTime g_debugVMRegionsLastForcedAt = 0;
static uint32_t g_debugVMRegionEntryCount = 0;
// The vector above is swapped in from a background rebuild queue; every access
// goes through this lock. Generation rejects rebuild results that were started
// before a flush/reset (their entries belong to a dead topology).
static os_unfair_lock g_debugVMRegionsLock = OS_UNFAIR_LOCK_INIT;
static uint64_t g_debugVMRegionsGeneration = 0;
static BOOL g_debugVMRegionsRebuildQueued = NO;

static void ds_debug_vm_regions_reset(void) {
    os_unfair_lock_lock(&g_debugVMRegionsLock);
    g_debugVMRegions.clear();
    g_debugVMRegionsMap = 0;
    g_debugVMRegionsPid = 0;
    g_debugVMRegionsBuiltAt = 0;
    g_debugVMRegionsLastForcedAt = 0;
    g_debugVMRegionEntryCount = 0;
    g_debugVMRegionsGeneration++;
    os_unfair_lock_unlock(&g_debugVMRegionsLock);
}

// Walk the target vm_map entry list into a fresh vector. Runs WITHOUT the
// regions lock so a background queue can absorb the multi-millisecond
// kernel-read burst while the ESP reader keeps using the last good index.
// ds_kread* is mutex-serialized per primitive call, so the reader only ever
// waits one call, never the whole walk.
static BOOL ds_debug_vm_regions_walk(uint64_t vmMap,
                                     std::vector<DSDebugVMRegion> *out,
                                     uint32_t *outEntryCount) {
    if (!vmMap || !off_vm_map_hdr || !off_vm_map_header_links_next ||
        !off_vm_map_header_nentries || !off_vm_map_entry_links_next) {
        return NO;
    }
    std::vector<DSDebugVMRegion> regions;
    uint32_t nentries = 0;
    @try {
        uint64_t header = vmMap + off_vm_map_hdr;
        nentries = ds_kread32(header + off_vm_map_header_nentries);
        uint64_t entry = ds_kreadptr(header + off_vm_map_header_links_next);
        // Long-running game sessions can exceed 9,000 entries after loading
        // gameplay assets. Keep enough headroom to cover the active heap.
        uint32_t limit = MIN(nentries, (uint32_t)16384);
        regions.reserve(limit);
        for (uint32_t index = 0; ds_isvalid(entry) && index < limit; index++) {
            uint64_t range[2] = {0, 0};
            ds_kreadbuf(entry + 0x10, range, sizeof(range));
            if (range[1] > range[0] && ds_debug_user_address(range[0]) &&
                ds_debug_user_address(range[1] - 1)) {
                regions.push_back({range[0], range[1], entry});
            }
            uint64_t next = ds_kreadptr(entry + off_vm_map_entry_links_next);
            if (!ds_isvalid(next) || next == entry) break;
            entry = next;
        }
    } @catch (__unused NSException *exception) {
        return NO;
    }
    if (regions.empty()) return NO;
    out->swap(regions);
    if (outEntryCount) *outEntryCount = nentries;
    return YES;
}

// Synchronous build — attach path only (once per target lifetime), where a
// one-time stall is acceptable and the reader has nothing to show yet anyway.
static BOOL ds_debug_vm_regions_rebuild(uint64_t vmMap, pid_t pid, BOOL forced) {
    (void)forced;
    std::vector<DSDebugVMRegion> regions;
    uint32_t nentries = 0;
    if (!ds_debug_vm_regions_walk(vmMap, &regions, &nentries)) return NO;
    os_unfair_lock_lock(&g_debugVMRegionsLock);
    g_debugVMRegions.swap(regions);
    g_debugVMRegionsMap = vmMap;
    g_debugVMRegionsPid = pid;
    g_debugVMRegionsBuiltAt = CFAbsoluteTimeGetCurrent();
    g_debugVMRegionEntryCount = nentries;
    g_debugVMRegionsGeneration++;
    os_unfair_lock_unlock(&g_debugVMRegionsLock);
    return YES;
}

static dispatch_queue_t ds_debug_regions_queue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.darkspeed.aov.vmregions",
                                      DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Hot-path policy: NEVER walk the target vm_map on the reader queue. A large
// map walk can freeze the serial reader for tens-to-hundreds of milliseconds
// when the game maps a fresh region mid-match. A miss fails the current read
// and refreshes the index asynchronously here.
static void ds_debug_vm_regions_request_async(uint64_t vmMap, pid_t pid) {
    if (!vmMap || !pid) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&g_debugVMRegionsLock);
    if (g_debugVMRegionsRebuildQueued ||
        now - g_debugVMRegionsLastForcedAt < 1.0) {
        os_unfair_lock_unlock(&g_debugVMRegionsLock);
        return;
    }
    g_debugVMRegionsRebuildQueued = YES;
    g_debugVMRegionsLastForcedAt = now;
    uint64_t generation = g_debugVMRegionsGeneration;
    os_unfair_lock_unlock(&g_debugVMRegionsLock);

    dispatch_async(ds_debug_regions_queue(), ^{
        std::vector<DSDebugVMRegion> regions;
        uint32_t nentries = 0;
        BOOL ok = ds_debug_vm_regions_walk(vmMap, &regions, &nentries);
        os_unfair_lock_lock(&g_debugVMRegionsLock);
        g_debugVMRegionsRebuildQueued = NO;
        if (ok && generation == g_debugVMRegionsGeneration) {
            g_debugVMRegions.swap(regions);
            g_debugVMRegionsMap = vmMap;
            g_debugVMRegionsPid = pid;
            g_debugVMRegionsBuiltAt = CFAbsoluteTimeGetCurrent();
            g_debugVMRegionEntryCount = nentries;
            g_debugVMRegionsGeneration++;
        }
        os_unfair_lock_unlock(&g_debugVMRegionsLock);
    });
}

// The vm_map walk preserves address order. Binary search keeps a page miss
// from scanning thousands of regions while holding the shared lock.
static int ds_debug_vm_region_index_locked(uint64_t address, uint64_t endAddress) {
    size_t low = 0;
    size_t high = g_debugVMRegions.size();
    while (low < high) {
        size_t mid = low + (high - low) / 2;
        if (g_debugVMRegions[mid].end <= address) low = mid + 1;
        else high = mid;
    }
    if (low >= g_debugVMRegions.size()) return -1;
    const DSDebugVMRegion &region = g_debugVMRegions[low];
    return address >= region.start && endAddress < region.end ? (int)low : -1;
}

static BOOL ds_debug_vm_regions_contains(uint64_t address, uint64_t endAddress) {
    os_unfair_lock_lock(&g_debugVMRegionsLock);
    BOOL found = ds_debug_vm_region_index_locked(address, endAddress) >= 0;
    os_unfair_lock_unlock(&g_debugVMRegionsLock);
    return found;
}

static uint64_t ds_debug_vm_region_entry(uint64_t address, uint64_t endAddress) {
    os_unfair_lock_lock(&g_debugVMRegionsLock);
    int index = ds_debug_vm_region_index_locked(address, endAddress);
    uint64_t entryAddress = index >= 0 ? g_debugVMRegions[(size_t)index].entryAddress : 0;
    os_unfair_lock_unlock(&g_debugVMRegionsLock);
    return entryAddress;
}

static BOOL ds_debug_address_mapped(uint64_t vmMap, uint64_t address, size_t length) {
    if (!vmMap || length == 0 || !ds_debug_user_address(address)) return NO;
    uint64_t endAddress = address + (uint64_t)length - 1ULL;
    if (endAddress < address || !ds_debug_user_address(endAddress)) return NO;
    if (!off_vm_map_hdr || !off_vm_map_header_links_next ||
        !off_vm_map_header_nentries || !off_vm_map_entry_links_next) {
        return YES;
    }

    // Index lookup only. Any miss (stale target or genuinely new region) defers
    // to a background rebuild and fails this frame — the reader must never eat
    // a vm_map walk mid-match.
    BOOL stale;
    os_unfair_lock_lock(&g_debugVMRegionsLock);
    stale = g_debugVMRegionsMap != vmMap ||
            g_debugVMRegionsPid != g_debugShmemPid;
    os_unfair_lock_unlock(&g_debugVMRegionsLock);
    if (stale) {
        ds_debug_vm_regions_request_async(vmMap, g_debugShmemPid);
        return NO;
    }
    if (ds_debug_vm_regions_contains(address, endAddress)) return YES;
    ds_debug_vm_regions_request_async(vmMap, g_debugShmemPid);
    return NO;
}

static void ds_debug_release_shmem(struct vmshmem shmem) {
    // Intentionally leak everything: deallocating the named entry makes the
    // kernel tear down a vm_map_entry we crafted to point at the target's
    // vm_object. If the target already died, that teardown dereferences a
    // freed object → kernel panic (this was the quit-game panic). The leaked
    // port + pinned object cost a few KB each and vanish on reboot.
    (void)shmem;
}

// Release path for when the target process is VERIFIED alive: the crafted
// vm_map_entry teardown then references a live vm_object, which is exactly
// the normal named-entry teardown path — safe. Use this to keep the pinned
// page/port footprint from growing forever across matches and toggles.
static void ds_debug_release_shmem_live(struct vmshmem shmem) {
    if (shmem.localAddress) {
        mach_vm_deallocate(mach_task_self_, shmem.localAddress, PAGE_SIZE);
    }
    if (shmem.port) {
        mach_port_deallocate(mach_task_self_, (mach_port_t)shmem.port);
    }
}

// Kernel proc address of the cached AOV target, set by the attach path.
// Lets the alive check read one word instead of walking the whole allproc
// list (hundreds of KRW round trips) on every flush.
static uint64_t g_debugShmemProc = 0;

// Userspace liveness probe with NO kernel reads. This gate is mandatory
// before any kread of a cached proc address: a cached proc points into the
// proc_task zone, and after the target exits zalloc GC can return the whole
// page to the VM under memory pressure. Reading it then faults inside the
// ICMPv6 copy path -> kernel data abort (panic log: "Zone: proc_task,
// use-after-free"). kill(pid, 0) never dereferences our cached pointer.
static BOOL ds_pid_alive_userspace(pid_t pid) {
    if (pid <= 0) return NO;
    return (kill(pid, 0) == 0 || errno == EPERM) ? YES : NO;
}

// True only when the cached target still resolves to a live proc. The pid
// must be alive in userspace first; only then is one kread of p_pid at the
// cached proc address allowed. A reused slot yields a mismatched pid. Falls
// back to the full walk only when no proc address is cached.
static BOOL ds_debug_target_alive(void) {
    pid_t pid = g_debugShmemPid;
    if (!pid || !ds_is_ready()) return NO;
    if (!ds_pid_alive_userspace(pid)) return NO;
    @try {
        if (ds_isvalid(g_debugShmemProc) && off_proc_p_pid) {
            return ds_kread32(g_debugShmemProc + off_proc_p_pid) == (uint32_t)pid ? YES : NO;
        }
        uint64_t proc = procbypid(pid);
        return ds_isvalid(proc) ? YES : NO;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

// Fl0rkFF-style shared-page cache. vmmapremotepage() performs kernel WRITES
// (vm_object refcount++, crafted zone element) on every call; hundreds of
// those per second while the target mutates its vm_map corrupt kernel zone
// memory and panic the device a few minutes later. Map each page at most once
// per target topology generation; per-tick reads then become plain local
// memcpy. Keep enough mappings for a complete match working set so active
// pages do not churn through repeated evict+remap cycles.
#define DS_DEBUG_SHMEM_SLOTS 2048
static struct {
    uint64_t vmMap;
    uint64_t pageAddress;
    struct vmshmem shmem;
    uint64_t tick;
} g_debugShmemCache[DS_DEBUG_SHMEM_SLOTS];
static uint64_t g_debugShmemTick = 0;
static int g_debugShmemCount = 0;
static std::unordered_map<uint64_t, int> g_debugShmemIndex;

static void ds_debug_shmem_flush_ex(BOOL targetAlive) {
    // Clear every published span even when the dead target's mappings must be
    // leaked. A leaked local address is still the wrong process generation.
    for (int index = 0; index < DS_DEBUG_SHMEM_SLOTS; index++) {
        if (g_debugShmemCache[index].shmem.used) {
            if (targetAlive) {
                ds_debug_release_shmem_live(g_debugShmemCache[index].shmem);
            } else {
                ds_debug_release_shmem(g_debugShmemCache[index].shmem);
            }
        }
        g_debugShmemCache[index].vmMap = 0;
        g_debugShmemCache[index].pageAddress = 0;
        g_debugShmemCache[index].shmem = (struct vmshmem){0};
        g_debugShmemCache[index].tick = 0;
    }
    g_debugShmemTick = 0;
    g_debugShmemOwner = DSDebugShmemOwner::None;
    g_debugShmemPid = 0;
    g_debugShmemOwnerVmMap = 0;
    g_debugShmemProc = 0;
    g_debugShmemCount = 0;
    g_debugShmemIndex.clear();
    ds_debug_vm_regions_reset();
}

// Claiming a different backend/process invalidates every mapping and live span
// from the previous owner. Callers rebuild the VM-region index after a claim.
static bool ds_debug_shmem_claim_target(DSDebugShmemOwner owner, pid_t pid,
                                        uint64_t proc, uint64_t vmMap) {
    if (owner == DSDebugShmemOwner::None || pid <= 0 ||
        !ds_isvalid(proc) || !ds_isvalid(vmMap)) {
        return false;
    }
    if (ds_debug_shmem_target_matches(owner, pid, vmMap)) {
        g_debugShmemProc = proc;
        return true;
    }

    BOOL previousTargetAlive = ds_debug_target_alive();
    ds_debug_shmem_flush_ex(previousTargetAlive);
    g_debugShmemOwner = owner;
    g_debugShmemPid = pid;
    g_debugShmemOwnerVmMap = vmMap;
    g_debugShmemProc = proc;
    return true;
}

static uint64_t ds_debug_map_page(uint64_t vmMap, uint64_t pageAddress) {
    if (!ds_isvalid(vmMap) || !ds_debug_user_address(pageAddress)) return 0;
    if (g_debugShmemOwner == DSDebugShmemOwner::None ||
        g_debugShmemOwnerVmMap != vmMap || !g_debugShmemPid) return 0;

    if (g_debugShmemIndex.bucket_count() < DS_DEBUG_SHMEM_SLOTS) {
        g_debugShmemIndex.reserve(DS_DEBUG_SHMEM_SLOTS);
    }
    g_debugShmemTick++;
    auto cached = g_debugShmemIndex.find(pageAddress);
    if (cached != g_debugShmemIndex.end()) {
        int index = cached->second;
        if (index >= 0 && index < g_debugShmemCount &&
            g_debugShmemCache[index].shmem.used &&
            g_debugShmemCache[index].vmMap == vmMap &&
            g_debugShmemCache[index].pageAddress == pageAddress) {
            g_debugShmemCache[index].tick = g_debugShmemTick;
            return g_debugShmemCache[index].shmem.localAddress;
        }
        g_debugShmemIndex.erase(cached);
    }

    // One-time per page: the mapping check plus the vm_object craft. The walk
    // and the kernel writes must not race a dying target — the reader proves
    // the pid at the start of every tick; never map without a live target.
    if (!g_debugShmemPid) return 0;
    if (!ds_debug_address_mapped(vmMap, pageAddress, PAGE_SIZE)) return 0;
    uint64_t entryAddress = ds_debug_vm_region_entry(
        pageAddress, pageAddress + (uint64_t)PAGE_SIZE - 1ULL);
    if (!entryAddress) return 0;

    int slot = -1;
    BOOL appendedSlot = NO;
    if (g_debugShmemCount < DS_DEBUG_SHMEM_SLOTS) {
        slot = g_debugShmemCount++;
        appendedSlot = YES;
    } else {
        uint64_t oldestTick = UINT64_MAX;
        for (int index = 0; index < g_debugShmemCount; index++) {
            if (!g_debugShmemCache[index].shmem.used) {
                slot = index;
                break;
            }
            if (g_debugShmemCache[index].tick <= oldestTick) {
                oldestTick = g_debugShmemCache[index].tick;
                slot = index;
            }
        }
    }
    if (slot < 0) return 0;

    // Use the entry captured by the region-index pass. Calling the legacy
    // vmmapremotepage() here would walk up to 9,000 kernel entries again for
    // every newly observed pawn/mesh/bone page.
    struct vmshmem shmem = {0};
    @try {
        shmem = vmmapremotepagefromentry(entryAddress, pageAddress);
    } @catch (__unused NSException *exception) {
        shmem = (struct vmshmem){0};
    }
    if (!shmem.used || !shmem.localAddress) {
        // The target may have mutated its vm_map after the index was built.
        // Refresh the index in the background rather than re-walking it here
        // on the reader queue; this page maps on a later frame once it lands.
        ds_debug_vm_regions_request_async(vmMap, g_debugShmemPid);
    }
    if (!shmem.used || !shmem.localAddress) {
        if (appendedSlot) g_debugShmemCount--;
        ds_debug_release_shmem(shmem);
        return 0;
    }
    if (g_debugShmemCache[slot].shmem.used) {
        auto indexed = g_debugShmemIndex.find(g_debugShmemCache[slot].pageAddress);
        if (indexed != g_debugShmemIndex.end() && indexed->second == slot) {
            g_debugShmemIndex.erase(indexed);
        }
        // Mid-match churn: the target is alive (attach validated this tick),
        // so actually release the mapping instead of leaking it. Without this,
        // every eviction past 1024 pages pins another vm_object + wired page
        // forever, and the footprint only stops growing at a jetsam/panic.
        ds_debug_release_shmem_live(g_debugShmemCache[slot].shmem);
    }
    g_debugShmemCache[slot].vmMap = vmMap;
    g_debugShmemCache[slot].pageAddress = pageAddress;
    g_debugShmemCache[slot].shmem = shmem;
    g_debugShmemCache[slot].tick = g_debugShmemTick;
    g_debugShmemIndex[pageAddress] = slot;
    return shmem.localAddress;
}

static BOOL ds_debug_read_bytes(uint64_t vmMap, uint64_t address, void *buffer, size_t length) {
    if (!vmMap || !address || !buffer || length == 0) return NO;

    @try {
    uint8_t *dst = (uint8_t *)buffer;
    uint64_t current = address;
    size_t remaining = length;
    const uint64_t pageSize = (uint64_t)PAGE_SIZE;
    const uint64_t pageMask = pageSize - 1ULL;

    while (remaining > 0) {
        if (!ds_debug_user_address(current)) return NO;

        uint64_t pageAddress = current & ~pageMask;
        uint64_t pageOffset = current & pageMask;
        size_t copySize = (size_t)MIN((uint64_t)remaining, pageSize - pageOffset);

        // Cached page mapping: no per-read vm_map walk, no kernel writes.
        uint64_t localPage = ds_debug_map_page(vmMap, pageAddress);
        if (!localPage) return NO;

        memcpy(dst, (const void *)(uintptr_t)(localPage + pageOffset), copySize);

        dst += copySize;
        current += copySize;
        remaining -= copySize;
    }

    return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}


#pragma mark - Floating camera menu (hosted in SpringBoard, DarkSpeed pattern)

static void ds_hosted_pubg_hide_all(void);

static NSString * const kDSHostedEspEnabledKey = @"pubg_esp_enabled";
static const double kDSHostedMenuLevel = 10000020.0;

// ESP defaults to on (the overlay always rendered before the switch existed).
static std::atomic<bool> g_hostedEspEnabled(true);
static dispatch_once_t g_hostedEspDefaultsOnce;

static bool ds_hosted_esp_enabled(void) {
    dispatch_once(&g_hostedEspDefaultsOnce, ^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        id stored = [defaults objectForKey:kDSHostedEspEnabledKey];
        if (stored) {
            g_hostedEspEnabled.store([defaults boolForKey:kDSHostedEspEnabledKey],
                                     std::memory_order_release);
        }
    });
    return g_hostedEspEnabled.load(std::memory_order_acquire);
}

static void ds_hosted_esp_set_enabled(bool enabled) {
    (void)ds_hosted_esp_enabled();
    g_hostedEspEnabled.store(enabled, std::memory_order_release);
    [NSUserDefaults.standardUserDefaults setBool:enabled
                                          forKey:kDSHostedEspEnabledKey];
    if (enabled) return;
    void (^hideEsp)(void) = ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        ds_hosted_pubg_hide_all();
        [CATransaction commit];
    };
    if (NSThread.isMainThread) {
        hideEsp();
    } else {
        dispatch_async(dispatch_get_main_queue(), hideEsp);
    }
}

// Interactive sibling of DSESPHostedWindow: touchable, still system/secure so
// SpringBoard can host it above the game.
@interface DSESPMenuWindow : UIWindow
@end

@interface DSESPMenuViewController : UIViewController
- (void)dsSetExpanded:(BOOL)expanded;
- (void)dsApplyOrientation;
- (void)dsApplyOrientation:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration;
- (BOOL)dsShouldAcceptHitView:(UIView *)hitView;
- (UIButton *)toggleButton;
- (void)dsUpdatePubgLanguage;
- (void)dsUpdateRadarWithPlayers:(const DSPUBGProjectedPlayer *)players count:(int)count;
@end

static UIWindow *g_hostedMenuWindow = nil;
static DSESPMenuViewController *g_hostedMenuViewController = nil;
static uint64_t g_hostedMenuRemoteController = 0;
static unsigned g_hostedMenuContextId = 0;
static BOOL g_hostedMenuExpanded = NO;
static int g_hostedMenuLastOrientation = 0;
static CFAbsoluteTime g_hostedMenuLastSetupTryAt = 0;
static CFAbsoluteTime g_hostedMenuLastRegisterTryAt = 0;

static CGRect ds_hosted_menu_frame(void) {
    // Full screen; hit testing inside the view controller decides what is
    // touchable, everything else falls through to the game.
    return UIScreen.mainScreen.bounds;
}

static void ds_hosted_menu_set_expanded(BOOL expanded);

@implementation DSESPMenuWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return NO; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
- (BOOL)keepContextInBackground { return YES; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!g_hostedMenuExpanded && g_hostedMenuViewController) {
        UIButton *btn = [g_hostedMenuViewController toggleButton];
        if (btn && !btn.hidden) {
            CGPoint ptInBtn = [self convertPoint:point toView:btn];
            CGRect expandHitRect = CGRectInset(btn.bounds, -12.0, -12.0);
            if (CGRectContainsPoint(expandHitRect, ptInBtn)) {
                return btn;
            }
        }
    }
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit || hit == self || hit == self.rootViewController.view) return nil;
    SEL acceptSel = NSSelectorFromString(@"dsShouldAcceptHitView:");
    if ([self.rootViewController respondsToSelector:acceptSel]) {
        BOOL accepted = ((BOOL (*)(id, SEL, UIView *))objc_msgSend)(self.rootViewController,
                                                                    acceptSel, hit);
        if (!accepted) return nil;
    }
    return hit;
}
@end

#include "MadnessMenu/MadnessMascotData.m"
#include "MadnessMenu/MenuWidgets.m"
#include "MadnessMenu/MADSW.m"
#include "MadnessMenu/MadnessMenuView.m"

@implementation DSESPMenuViewController {
    UIView *_contentView;
    MadnessMenuView *_madnessMenu;
    int _appliedOrientation;
    BOOL _hasAppliedOrientation;
    CGRect _appliedWindowBounds;
}

- (void)loadView {
    if (@available(iOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view.opaque = NO;
    self.view.backgroundColor = UIColor.clearColor;

    _contentView = [[UIView alloc] initWithFrame:self.view.bounds];
    _contentView.opaque = NO;
    _contentView.backgroundColor = UIColor.clearColor;
    [self.view addSubview:_contentView];

    _madnessMenu = [[MadnessMenuView alloc] initWithFrame:_contentView.bounds];
    _madnessMenu.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_contentView addSubview:_madnessMenu];

    [self dsApplyOrientation];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self dsApplyOrientation];
}

- (BOOL)prefersStatusBarHidden { return YES; }

- (void)dsSetExpanded:(BOOL)expanded {
    if (!_madnessMenu) return;
    if (expanded) {
        [_madnessMenu previewOpen];
    } else {
        [_madnessMenu previewClose];
    }
}

- (void)dsUpdateRadarWithPlayers:(const DSPUBGProjectedPlayer *)players count:(int)count {
    if (_madnessMenu) {
        [_madnessMenu updateRadarWithPlayers:players count:count];
    }
}

- (void)dsApplyOrientation {
    [self dsApplyOrientation:ds_active_orientation() duration:0.0];
}

- (void)dsApplyOrientation:(UIInterfaceOrientation)targetOrientation duration:(NSTimeInterval)duration {
    if (!_contentView) return;
    CGRect windowBounds = self.view.bounds;
    if (CGRectIsEmpty(windowBounds)) {
        windowBounds = UIScreen.mainScreen.bounds;
    }
    int orientation = (int)targetOrientation;
    if (orientation == (int)UIInterfaceOrientationUnknown) {
        orientation = (int)ds_active_orientation();
    }
    if (_hasAppliedOrientation && _appliedOrientation == orientation &&
        CGRectEqualToRect(_appliedWindowBounds, windowBounds)) return;
    _hasAppliedOrientation = YES;
    _appliedOrientation = orientation;
    _appliedWindowBounds = windowBounds;
    g_hostedMenuLastOrientation = orientation;

    void (^layoutBlock)(void) = ^{
        _contentView.center = CGPointMake(CGRectGetWidth(windowBounds) * 0.5, CGRectGetHeight(windowBounds) * 0.5);
        if (UIInterfaceOrientationIsLandscape((UIInterfaceOrientation)orientation)) {
            _contentView.bounds = CGRectMake(0, 0, CGRectGetHeight(windowBounds), CGRectGetWidth(windowBounds));
            double angle = (orientation == UIInterfaceOrientationLandscapeLeft) ? -M_PI_2 : M_PI_2;
            _contentView.transform = CGAffineTransformMakeRotation(angle);
        } else {
            _contentView.bounds = windowBounds;
            _contentView.transform = CGAffineTransformIdentity;
        }
        if (_madnessMenu) {
            _madnessMenu.frame = _contentView.bounds;
        }
    };

    if (duration > 0.001) {
        [UIView animateWithDuration:duration
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                         animations:layoutBlock
                         completion:nil];
    } else {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layoutBlock();
        [CATransaction commit];
    }
}

- (BOOL)dsShouldAcceptHitView:(UIView *)hitView {
    if (!hitView || hitView == self.view || hitView == _contentView || hitView == _madnessMenu) return NO;
    for (UIView *view = hitView; view; view = view.superview) {
        if (view == _madnessMenu.panel || view == _madnessMenu.dragMap) return YES;
    }
    return NO;
}

- (UIButton *)toggleButton {
    return _madnessMenu.handle ?: _madnessMenu.panel;
}

- (void)dsUpdatePubgLanguage {
}

@end

static void ds_hosted_menu_set_expanded(BOOL expanded) {
    g_hostedMenuExpanded = expanded;
    if (!g_hostedMenuWindow) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGRect windowFrame = ds_hosted_menu_frame();
    if (!CGRectEqualToRect(g_hostedMenuWindow.frame, windowFrame))
        g_hostedMenuWindow.frame = windowFrame;
    UIView *rootView = g_hostedMenuWindow.rootViewController.view;
    if (!CGRectEqualToRect(rootView.frame, g_hostedMenuWindow.bounds))
        rootView.frame = g_hostedMenuWindow.bounds;
    [g_hostedMenuViewController dsSetExpanded:expanded];
    [g_hostedMenuViewController dsApplyOrientation];
    [CATransaction commit];
}

static void ds_hosted_menu_register(unsigned contextId) {
    RemoteCall *process = g_springBoard;
    if (!process || !process.trojanMem || !contextId) return;
    if (g_hostedMenuRemoteController) return;
    uint64_t hostClass = ds_remote_class(process, "SBSAccessibilityWindowHostingController");
    if (!hostClass) return;
    uint64_t host = remote_msg(process, hostClass, ds_remote_sel(process, "alloc"), 0, 0, 0, 0);
    if (!host || !ds_remote_invoke_noarg_on_main(process, host, "init")) return;
    uint32_t cid = contextId;
    double level = kDSHostedMenuLevel;
    DSRemoteArgument args[2] = {
        { &cid, sizeof(cid) },
        { &level, sizeof(level) },
    };
    if (ds_remote_invoke_on_main(process, host,
                                 ds_remote_sel(process, "registerWindowWithContextID:atLevel:"),
                                 args, 2)) {
        g_hostedMenuRemoteController = host;
    }
}



// Main thread, all local UIKit. Returns the window's render-server context id.
static unsigned ds_hosted_menu_setup_on_main(void) {
    if (g_hostedMenuWindow) {
        g_hostedMenuWindow.hidden = NO;
        return g_hostedMenuContextId;
    }

    DSESPMenuWindow *window = [[DSESPMenuWindow alloc] initWithFrame:ds_hosted_menu_frame()];
    window.backgroundColor = UIColor.clearColor;
    window.windowLevel = kDSHostedMenuLevel;
    if (@available(iOS 13.0, *)) {
        window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    DSESPMenuViewController *rootVC = [[DSESPMenuViewController alloc] init];
    window.rootViewController = rootVC;
    window.hidden = NO;
    [window makeKeyAndVisible];

    unsigned contextId = ((unsigned (*)(id, SEL))objc_msgSend)(window, NSSelectorFromString(@"_contextId"));
    if (!contextId) {
        window.hidden = YES;
        return 0;
    }

    g_hostedMenuWindow = window;
    g_hostedMenuViewController = rootVC;
    g_hostedMenuContextId = contextId;
    ds_hosted_menu_set_expanded(g_hostedMenuExpanded);



    return contextId;
}

static void ds_hosted_menu_ensure(void) {
    if (g_hostedMenuWindow) {
        if (g_hostedMenuContextId && !g_hostedMenuRemoteController) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - g_hostedMenuLastRegisterTryAt >= 2.0) {
                g_hostedMenuLastRegisterTryAt = now;
                ds_hosted_menu_register(g_hostedMenuContextId);
            }
        }
        return;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - g_hostedMenuLastSetupTryAt < 2.0) return;
    g_hostedMenuLastSetupTryAt = now;
    dispatch_async(dispatch_get_main_queue(), ^{
        unsigned contextId = ds_hosted_menu_setup_on_main();
        if (contextId) {
            dispatch_async(ds_bridge_queue(), ^{
                ds_hosted_menu_register(contextId);
            });
        }
    });
}

#pragma mark - Mach-O main image identity

static BOOL ds_debug_macho_main_identity(uint64_t vmMap, uint64_t base) {
    struct mach_header_64 header = {};
    if (!ds_debug_read_bytes(vmMap, base, &header, sizeof(header)) ||
        header.magic != MH_MAGIC_64 || header.ncmds == 0 ||
        header.ncmds > 1024 || header.sizeofcmds == 0 ||
        header.sizeofcmds > (64U * 1024U)) {
        return NO;
    }

    std::vector<uint8_t> commands(header.sizeofcmds);
    if (!ds_debug_read_bytes(vmMap, base + sizeof(header),
                             commands.data(), commands.size())) {
        return NO;
    }

    size_t cursor = 0;
    for (uint32_t index = 0; index < header.ncmds; index++) {
        if (cursor + sizeof(struct load_command) > commands.size()) return NO;
        const struct load_command *command =
            (const struct load_command *)(commands.data() + cursor);
        if (command->cmdsize < sizeof(struct load_command) ||
            cursor + command->cmdsize > commands.size()) {
            return NO;
        }
        cursor += command->cmdsize;
    }
    return header.filetype == MH_EXECUTE;
}

static uint64_t ds_debug_find_main_image_base(uint64_t vmMap) {
    // Snapshot region starts under the lock; the identity probes below read
    // target memory and would deadlock on the (non-recursive) regions lock.
    std::vector<uint64_t> starts;
    os_unfair_lock_lock(&g_debugVMRegionsLock);
    for (const DSDebugVMRegion &region : g_debugVMRegions) {
        starts.push_back(region.start);
    }
    os_unfair_lock_unlock(&g_debugVMRegionsLock);
    for (uint64_t start : starts) {
        if (ds_debug_macho_main_identity(vmMap, start)) return start;
    }
    return 0;
}

#pragma mark - Hosted overlay window (registration performed inside SpringBoard)

// The window must be a real UIWindow with these overrides
// (sources/HUDMainWindow.mm — TrollSpeed's proven pattern).
@interface DSESPHostedWindow : UIWindow
@end

@implementation DSESPHostedWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
// Keep the render-server context alive when our app backgrounds.
- (BOOL)keepContextInBackground { return YES; }
@end

@interface DSESPHostedViewController : UIViewController
@end

@implementation DSESPHostedViewController
- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view.userInteractionEnabled = NO;
    self.view.opaque = NO;
    self.view.backgroundColor = UIColor.clearColor;
}
- (BOOL)prefersStatusBarHidden { return YES; }
@end

typedef struct {
    uint64_t generation;
    BOOL pubgRenderSourceReady;
} DSHostedRenderSnapshot;

static os_unfair_lock g_hostedSnapshotLock = OS_UNFAIR_LOCK_INIT;
static DSHostedRenderSnapshot g_hostedSnapshots[2] = {};
static int g_hostedPublishedSnapshot = -1;
static uint64_t g_hostedSnapshotGeneration = 0;
static uint64_t g_hostedConsumedGeneration = 0;
static BOOL g_hostedFallbackApplyQueued = NO;
static uint64_t g_hostedFallbackToken = 0;
static std::atomic<double> g_hostedLastDisplayLinkTick(0.0);
static std::atomic<uint32_t> g_hostedMaximumFrameRate(60);
static std::atomic<uint64_t> g_hostedDisplayPulse(0);
// Accessed only by ds_bridge_queue. UINT64_MAX permits the initial setup tick
// before CADisplayLink has delivered its first pulse.
static uint64_t g_hostedConsumedDisplayPulse = UINT64_MAX;
static std::atomic<bool> g_hostedLayerReady(false);
static CADisplayLink *g_hostedDisplayLink = nil;
static CGFloat g_hostedPortraitNotchHeight = 0.0;


static void ds_hosted_consume_render_snapshot(bool fallback,
                                              double timestamp,
                                              double targetTimestamp,
                                              double startedAt);
static void ds_hosted_overlay_frame(void);

static std::atomic<bool> g_hostedPubgFramePending(false);

static void ds_hosted_schedule_frame_tick(void) {
    if (!g_hostedPubgFramePending.exchange(true, std::memory_order_acq_rel)) {
        dispatch_async(ds_bridge_queue(), ^{
            @autoreleasepool {
                ds_hosted_overlay_frame();
            }
            g_hostedPubgFramePending.store(false, std::memory_order_release);
        });
    }
}

static void ds_hosted_configure_display_link(CADisplayLink *displayLink) {
    if (!displayLink) return;
    NSInteger maximum = MAX((NSInteger)UIScreen.mainScreen.maximumFramesPerSecond,
                            (NSInteger)60);
    // Cap ESP compositor updates to 60 Hz so ProMotion devices do not burn
    // double CPU/backboardd bandwidth and get throttled/killed in background.
    NSInteger targetFPS = MIN(maximum, (NSInteger)60);
    g_hostedMaximumFrameRate.store((uint32_t)targetFPS,
                                   std::memory_order_release);
    displayLink.preferredFramesPerSecond = targetFPS;
    if (@available(iOS 15.0, *)) {
        displayLink.preferredFrameRateRange =
            CAFrameRateRangeMake(60.0, (float)targetFPS, (float)targetFPS);
    }
}

@interface DSHostedDisplayLinkDriver : NSObject
- (void)displayLinkDidFire:(CADisplayLink *)displayLink;
@end

@implementation DSHostedDisplayLinkDriver
- (void)displayLinkDidFire:(CADisplayLink *)displayLink {
    double startedAt = CACurrentMediaTime();
    g_hostedDisplayPulse.fetch_add(1, std::memory_order_release);
    g_hostedLastDisplayLinkTick.store(startedAt, std::memory_order_relaxed);
    ds_hosted_consume_render_snapshot(false, displayLink.timestamp,
                                      displayLink.targetTimestamp, startedAt);
    g_hostedLastDisplayLinkTick.store(CACurrentMediaTime(),
                                      std::memory_order_relaxed);

    ds_hosted_schedule_frame_tick();
}
@end

static DSHostedDisplayLinkDriver *g_hostedDisplayLinkDriver = nil;

static void ds_hosted_apply_orientation(UIInterfaceOrientation orientation, double duration = 0.0) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ds_hosted_apply_orientation(orientation, duration);
        });
        return;
    }

    // 1. ESP Overlay Layer
    if (g_hostedLayer && (int)orientation != g_hostedLastOrientation) {
        g_hostedLastOrientation = (int)orientation;
        CGRect windowBounds = g_hostedWindow.bounds;
        [CATransaction begin];
        if (duration > 0.001) {
            [CATransaction setAnimationDuration:duration];
        } else {
            [CATransaction setDisableActions:YES];
        }
        if (UIInterfaceOrientationIsLandscape(orientation)) {
            g_hostedLayer.bounds = CGRectMake(0, 0, windowBounds.size.height,
                                              windowBounds.size.width);
            g_hostedLayer.position = CGPointMake(windowBounds.size.width * 0.5,
                                                 windowBounds.size.height * 0.5);
            double angle = orientation == UIInterfaceOrientationLandscapeLeft
                ? -M_PI_2 : M_PI_2;
            g_hostedLayer.affineTransform = CGAffineTransformMakeRotation(angle);
        } else {
            g_hostedLayer.bounds = windowBounds;
            g_hostedLayer.position = CGPointMake(windowBounds.size.width * 0.5,
                                                 windowBounds.size.height * 0.5);
            g_hostedLayer.affineTransform = CGAffineTransformIdentity;
        }
        [CATransaction commit];
    }

    // 2. Floating Menu View Controller
    if (g_hostedMenuViewController) {
        [g_hostedMenuViewController dsApplyOrientation:orientation duration:duration];
    }
}

#pragma mark - PUBG ESP render

// Batched player shape layers (alive vs knocked) replace 500+ per-player
// CAShapeLayers, avoiding hundreds of screen-spanning bitmap allocations.
static CAShapeLayer *g_hostedPUBGBoxAliveLayer = nil;
static CAShapeLayer *g_hostedPUBGBoxKnockedLayer = nil;
static CAShapeLayer *g_hostedPUBGSkeletonAliveLayer = nil;
static CAShapeLayer *g_hostedPUBGSkeletonKnockedLayer = nil;
static CAShapeLayer *g_hostedPUBGLineAliveLayer = nil;
static CAShapeLayer *g_hostedPUBGLineKnockedLayer = nil;
static CAShapeLayer *g_hostedPUBGHealthBgLayer = nil;
static CAShapeLayer *g_hostedPUBGHealthAliveLayer = nil;
static CAShapeLayer *g_hostedPUBGHealthKnockedLayer = nil;
static CATextLayer *g_hostedPUBGInfoLabels[kDSPUBGMaxPlayers] = {};
static CATextLayer *g_hostedPUBGWeaponLabels[kDSPUBGMaxPlayers] = {};
static CAShapeLayer *g_hostedPUBGArrowLayers[kDSPUBGMaxPlayers] = {};
static CATextLayer *g_hostedPUBGArrowTextLayers[kDSPUBGMaxPlayers] = {};
static CATextLayer *g_hostedPUBGItemLabels[kDSPUBGMaxItems] = {};
static CAShapeLayer *g_hostedPUBGGrenadeTrajLayers[kDSPUBGMaxGrenades] = {};
static CAShapeLayer *g_hostedPUBGGrenadeCircleLayers[kDSPUBGMaxGrenades] = {};
static CAShapeLayer *g_hostedPUBGGrenadeCircleMidLayers[kDSPUBGMaxGrenades] = {};
static CAShapeLayer *g_hostedPUBGGrenadeCircleInnerLayers[kDSPUBGMaxGrenades] = {};
static CAShapeLayer *g_hostedPUBGGrenadeBoxLayers[kDSPUBGMaxGrenades] = {};
static CATextLayer *g_hostedPUBGGrenadeLabels[kDSPUBGMaxGrenades] = {};
static CAShapeLayer *g_hostedPUBGGrenadeDropLineLayers[kDSPUBGMaxGrenades] = {};
static CALayer *g_hostedPUBGGrenadeMarkerLayers[kDSPUBGMaxGrenades] = {};
static CALayer *g_hostedPUBGGrenadeFragLayers[kDSPUBGMaxGrenades] = {};
static CALayer *g_hostedPUBGGrenadeSmokeLayers[kDSPUBGMaxGrenades] = {};
static CALayer *g_hostedPUBGGrenadeBurnLayers[kDSPUBGMaxGrenades] = {};
static CALayer *g_hostedPUBGGrenadeStunLayers[kDSPUBGMaxGrenades] = {};
static CALayer *g_hostedPUBGGrenadeMarkerBgLayers[kDSPUBGMaxGrenades] = {};
static CALayer *g_hostedPUBGGrenadeMarkerFillLayers[kDSPUBGMaxGrenades] = {};
static CATextLayer *g_hostedPUBGGrenadeDangerBanner = nil;
static CAShapeLayer *g_hostedPUBGTopCountBgLayer = nil;
static CATextLayer *g_hostedPUBGTopCountLabel = nil;

// Per-frame draw budget. The player snapshot is sorted nearest-first, so the
// long tail past this index costs raster time without tactical value. Enemy
// counts in a hot drop can exceed this easily; drawing all of them is what
// drove the frame drop.
static const int kDSPUBGDrawMaxPlayers = 48;

static void ds_hosted_pubg_hide_all(void) {
    if (g_hostedMenuViewController) {
        [g_hostedMenuViewController dsUpdateRadarWithPlayers:NULL count:0];
    }
    if (g_hostedPUBGBoxAliveLayer && !g_hostedPUBGBoxAliveLayer.hidden) g_hostedPUBGBoxAliveLayer.hidden = YES;
    if (g_hostedPUBGBoxKnockedLayer && !g_hostedPUBGBoxKnockedLayer.hidden) g_hostedPUBGBoxKnockedLayer.hidden = YES;
    if (g_hostedPUBGSkeletonAliveLayer && !g_hostedPUBGSkeletonAliveLayer.hidden) g_hostedPUBGSkeletonAliveLayer.hidden = YES;
    if (g_hostedPUBGSkeletonKnockedLayer && !g_hostedPUBGSkeletonKnockedLayer.hidden) g_hostedPUBGSkeletonKnockedLayer.hidden = YES;
    if (g_hostedPUBGLineAliveLayer && !g_hostedPUBGLineAliveLayer.hidden) g_hostedPUBGLineAliveLayer.hidden = YES;
    if (g_hostedPUBGLineKnockedLayer && !g_hostedPUBGLineKnockedLayer.hidden) g_hostedPUBGLineKnockedLayer.hidden = YES;
    if (g_hostedPUBGHealthBgLayer && !g_hostedPUBGHealthBgLayer.hidden) g_hostedPUBGHealthBgLayer.hidden = YES;
    if (g_hostedPUBGHealthAliveLayer && !g_hostedPUBGHealthAliveLayer.hidden) g_hostedPUBGHealthAliveLayer.hidden = YES;
    if (g_hostedPUBGHealthKnockedLayer && !g_hostedPUBGHealthKnockedLayer.hidden) g_hostedPUBGHealthKnockedLayer.hidden = YES;
    for (int i = 0; i < kDSPUBGMaxPlayers; i++) {
        if (g_hostedPUBGInfoLabels[i] && !g_hostedPUBGInfoLabels[i].hidden) g_hostedPUBGInfoLabels[i].hidden = YES;
        if (g_hostedPUBGWeaponLabels[i] && !g_hostedPUBGWeaponLabels[i].hidden) g_hostedPUBGWeaponLabels[i].hidden = YES;
        if (g_hostedPUBGArrowLayers[i] && !g_hostedPUBGArrowLayers[i].hidden) g_hostedPUBGArrowLayers[i].hidden = YES;
        if (g_hostedPUBGArrowTextLayers[i] && !g_hostedPUBGArrowTextLayers[i].hidden) g_hostedPUBGArrowTextLayers[i].hidden = YES;
    }
    for (int i = 0; i < kDSPUBGMaxItems; i++) {
        if (g_hostedPUBGItemLabels[i] && !g_hostedPUBGItemLabels[i].hidden) g_hostedPUBGItemLabels[i].hidden = YES;
    }
    for (int i = 0; i < kDSPUBGMaxGrenades; i++) {
        if (g_hostedPUBGGrenadeTrajLayers[i] && !g_hostedPUBGGrenadeTrajLayers[i].hidden) g_hostedPUBGGrenadeTrajLayers[i].hidden = YES;
        if (g_hostedPUBGGrenadeCircleLayers[i] && !g_hostedPUBGGrenadeCircleLayers[i].hidden) g_hostedPUBGGrenadeCircleLayers[i].hidden = YES;
        if (g_hostedPUBGGrenadeCircleMidLayers[i] && !g_hostedPUBGGrenadeCircleMidLayers[i].hidden) g_hostedPUBGGrenadeCircleMidLayers[i].hidden = YES;
        if (g_hostedPUBGGrenadeCircleInnerLayers[i] && !g_hostedPUBGGrenadeCircleInnerLayers[i].hidden) g_hostedPUBGGrenadeCircleInnerLayers[i].hidden = YES;
        if (g_hostedPUBGGrenadeBoxLayers[i] && !g_hostedPUBGGrenadeBoxLayers[i].hidden) g_hostedPUBGGrenadeBoxLayers[i].hidden = YES;
        if (g_hostedPUBGGrenadeLabels[i] && !g_hostedPUBGGrenadeLabels[i].hidden) g_hostedPUBGGrenadeLabels[i].hidden = YES;
        if (g_hostedPUBGGrenadeDropLineLayers[i] && !g_hostedPUBGGrenadeDropLineLayers[i].hidden) g_hostedPUBGGrenadeDropLineLayers[i].hidden = YES;
        if (g_hostedPUBGGrenadeMarkerLayers[i] && !g_hostedPUBGGrenadeMarkerLayers[i].hidden) g_hostedPUBGGrenadeMarkerLayers[i].hidden = YES;
    }
    if (g_hostedPUBGGrenadeDangerBanner && !g_hostedPUBGGrenadeDangerBanner.hidden) g_hostedPUBGGrenadeDangerBanner.hidden = YES;
    if (g_hostedPUBGTopCountBgLayer && !g_hostedPUBGTopCountBgLayer.hidden) g_hostedPUBGTopCountBgLayer.hidden = YES;
    if (g_hostedPUBGTopCountLabel && !g_hostedPUBGTopCountLabel.hidden) g_hostedPUBGTopCountLabel.hidden = YES;
}

static CGColorRef ds_pubg_cgcolor_from_rgba(uint32_t rgba) {
    static struct CachedColor {
        uint32_t rgba;
        CGColorRef color;
    } s_colorCache[24] = {};
    static int s_colorCount = 0;

    for (int i = 0; i < s_colorCount; i++) {
        if (s_colorCache[i].rgba == rgba) {
            return s_colorCache[i].color;
        }
    }

    CGFloat r = ((rgba >> 24) & 0xFF) / 255.0;
    CGFloat g = ((rgba >> 16) & 0xFF) / 255.0;
    CGFloat b = ((rgba >> 8) & 0xFF) / 255.0;
    CGFloat a = (rgba & 0xFF) / 255.0;
    CGColorRef newColor = [UIColor colorWithRed:r green:g blue:b alpha:a].CGColor;
    if (s_colorCount < 24) {
        s_colorCache[s_colorCount].rgba = rgba;
        s_colorCache[s_colorCount].color = CGColorRetain(newColor);
        s_colorCount++;
        return newColor;
    }
    return newColor;
}

static inline NSString *ds_safe_utf8_string(const char *str, NSString *fallback) {
    if (!str || str[0] == '\0') return fallback ?: @"";
    NSString *s = [NSString stringWithUTF8String:str];
    if (s && s.length > 0) return s;
    s = [[NSString alloc] initWithCString:str encoding:NSASCIIStringEncoding];
    if (s && s.length > 0) return s;
    s = [[NSString alloc] initWithBytes:str length:strlen(str) encoding:NSISOLatin1StringEncoding];
    return (s && s.length > 0) ? s : (fallback ?: @"");
}

static NSString *ds_country_code_to_flag_emoji(const char *code) {
    if (!code || strlen(code) < 2) return nil;
    char c1 = (char)toupper((unsigned char)code[0]);
    char c2 = (char)toupper((unsigned char)code[1]);
    if (c1 < 'A' || c1 > 'Z' || c2 < 'A' || c2 > 'Z') return nil;
    unichar chars[4] = {
        0xD83C, (unichar)(0xDDE6 + (c1 - 'A')),
        0xD83C, (unichar)(0xDDE6 + (c2 - 'A'))
    };
    return [NSString stringWithCharacters:chars length:4];
}

// CoreAnimation commits a property write even when the value is identical, so
// a per-frame write of an unchanged path/frame/string forces the render server
// to re-rasterize that layer. These setters drop no-op writes. With ~40
// properties across 96 slots this is the difference between one cheap commit
// and a full re-raster storm when the screen is full of enemies.
static inline void ds_layer_set_hidden(CALayer *layer, BOOL hidden) {
    if (layer && layer.hidden != hidden) layer.hidden = hidden;
}

static inline void ds_layer_set_frame(CALayer *layer, CGRect frame) {
    if (!layer) return;
    if (!CGRectEqualToRect(layer.frame, frame)) layer.frame = frame;
}

static inline CGFloat ds_q05(CGFloat v) {
    return (CGFloat)(roundf((float)v * 2.0f) * 0.5f);
}

static inline CGRect ds_q1_rect(CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    return CGRectMake((CGFloat)roundf((float)x), (CGFloat)roundf((float)y), w, h);
}

static inline void ds_layer_set_cgpath(CAShapeLayer *layer, CGMutablePathRef path, BOOL nonEmpty) {
    if (!layer) return;
    if (!nonEmpty || !path) {
        ds_layer_set_hidden(layer, YES);
        return;
    }
    CGPathRef current = layer.path;
    if (current != path && (!current || !CGPathEqualToPath(current, path))) {
        layer.path = path;
    }
    ds_layer_set_hidden(layer, NO);
}

static inline void ds_layer_set_path(CAShapeLayer *layer, UIBezierPath *path) {
    if (!layer || !path) return;
    CGPathRef next = path.CGPath;
    CGPathRef current = layer.path;
    if (current == next) return;
    if (current && CGPathEqualToPath(current, next)) return;
    layer.path = next;
}

static inline void ds_layer_set_stroke(CAShapeLayer *layer, CGColorRef color, CGFloat width) {
    if (!layer) return;
    if (layer.strokeColor != color) layer.strokeColor = color;
    if (layer.lineWidth != width) layer.lineWidth = width;
}

static inline void ds_layer_set_fill(CAShapeLayer *layer, CGColorRef color) {
    if (layer && layer.fillColor != color) layer.fillColor = color;
}

enum DSGrenadeColor {
    DSGrenadeColorTrajectory = 0,
    DSGrenadeColorCircle,
    DSGrenadeColorDropLine,
};

static CGColorRef ds_grenade_color(enum DSGrenadeColor slot) {
    static CGColorRef cache[3] = {NULL, NULL, NULL};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache[DSGrenadeColorTrajectory] = CGColorRetain([UIColor colorWithWhite:1.0 alpha:0.75].CGColor);
        cache[DSGrenadeColorCircle] = CGColorRetain([UIColor colorWithRed:0.90f green:1.0f blue:0.10f alpha:1.0f].CGColor);
        cache[DSGrenadeColorDropLine] = CGColorRetain([UIColor colorWithRed:0.92f green:1.0f blue:0.12f alpha:1.0f].CGColor);
    });
    return (slot >= 0 && slot < 3) ? cache[slot] : NULL;
}

static inline void ds_layer_set_string(CATextLayer *layer, NSString *text) {
    if (!layer || !text) return;
    if (layer.string == (id)text) return;
    NSString *current = [layer.string isKindOfClass:NSString.class] ? (NSString *)layer.string : nil;
    if (current && [current isEqualToString:text]) return;
    layer.string = text;
}

static inline void ds_pubg_draw_radar_arrow(CAShapeLayer *arrow,
                                             CATextLayer *arrowText,
                                             CGFloat cx, CGFloat cy,
                                             float dirX, float dirY,
                                             float distanceMeters,
                                             BOOL isOffScreen) {
    if (!arrow) return;

    float dirLen = hypotf(dirX, dirY);
    if (dirLen < 0.001f) {
        dirX = 0.0f;
        dirY = 1.0f;
    } else {
        dirX /= dirLen;
        dirY /= dirLen;
    }

    CGFloat angle = atan2f(dirY, dirX);
    CGFloat cosA = cosf(angle);
    CGFloat sinA = sinf(angle);

    // Radar perimeter: R = 85 pt from screen center / crosshair (compact & sleek)
    const CGFloat R = 85.0f;
    const CGFloat arrowLen = 13.0f;
    const CGFloat halfBase = 4.5f;

    // Outward-pointing triangle:
    // Base center lies on circle of radius R
    CGFloat baseCX = cx + R * cosA;
    CGFloat baseCY = cy + R * sinA;
    // Apex points radially outwards at R + arrowLen
    CGFloat tipX = cx + (R + arrowLen) * cosA;
    CGFloat tipY = cy + (R + arrowLen) * sinA;

    // Tangent perpendicular vector
    CGFloat normX = -sinA;
    CGFloat normY = cosA;

    CGFloat p1X = baseCX + normX * halfBase;
    CGFloat p1Y = baseCY + normY * halfBase;
    CGFloat p2X = baseCX - normX * halfBase;
    CGFloat p2Y = baseCY - normY * halfBase;

    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(tipX, tipY)];
    [path addLineToPoint:CGPointMake(p1X, p1Y)];
    [path addLineToPoint:CGPointMake(p2X, p2Y)];
    [path closePath];

    static CGColorRef s_arrowStroke = NULL;
    static dispatch_once_t s_arrowOnce;
    dispatch_once(&s_arrowOnce, ^{
        s_arrowStroke = CGColorRetain([UIColor colorWithRed:1.0f green:0.18f blue:0.18f alpha:0.95f].CGColor);
    });

    ds_layer_set_path(arrow, path);
    if (arrow.strokeColor != s_arrowStroke) arrow.strokeColor = s_arrowStroke;
    if (arrow.lineWidth != 1.2f) arrow.lineWidth = 1.2f;
    ds_layer_set_hidden(arrow, NO);

    if (arrowText) {
        if (isOffScreen) {
            CGFloat textDist = R + arrowLen + 8.0f;
            CGFloat textCX = cx + textDist * cosA;
            CGFloat textCY = cy + textDist * sinA;
            CGFloat lblW = 40.0f;
            CGFloat lblH = 12.0f;
            ds_layer_set_frame(arrowText, CGRectMake(textCX - lblW * 0.5f, textCY - lblH * 0.5f, lblW, lblH));
            ds_layer_set_string(arrowText, [NSString stringWithFormat:@"%.0fm", distanceMeters]);
            if (arrowText.foregroundColor != s_arrowStroke) arrowText.foregroundColor = s_arrowStroke;
            ds_layer_set_hidden(arrowText, NO);
        } else {
            ds_layer_set_hidden(arrowText, YES);
        }
    }
}

static void ds_hosted_apply_pubg(void) {
    @try {
    if (!g_hostedLayer) return;
    if (!ds_hosted_esp_enabled()) {
        ds_hosted_pubg_hide_all();
        return;
    }
    UIInterfaceOrientation orientation = ds_active_orientation();
    if (!UIInterfaceOrientationIsLandscape(orientation)) {
        if (ds_pubg_has_render_source()) {
            orientation = UIInterfaceOrientationLandscapeRight;
        } else {
            ds_hosted_pubg_hide_all();
            return;
        }
    }

    DSPUBGProjectedPlayer players[kDSPUBGMaxPlayers] = {};
    uint64_t epoch = 0;
    int count = ds_pubg_copy_projected_players(players, &epoch);
    if (count < 0) return;
    if (count > kDSPUBGMaxPlayers) count = kDSPUBGMaxPlayers;

    const CGFloat width = CGRectGetWidth(g_hostedLayer.bounds);
    const CGFloat height = CGRectGetHeight(g_hostedLayer.bounds);
    const CGFloat cx = width * 0.5f;
    const CGFloat cy = height * 0.5f;

    // Keep the batched paths sized to the live overlay in case the window
    // geometry changed after the layers were created (rotation, split view).
    if (g_hostedPUBGBoxAliveLayer) {
        CGRect batchBounds = g_hostedLayer.bounds;
        CAShapeLayer *const batchLayers[] = {
            g_hostedPUBGBoxAliveLayer, g_hostedPUBGBoxKnockedLayer,
            g_hostedPUBGSkeletonAliveLayer, g_hostedPUBGSkeletonKnockedLayer,
            g_hostedPUBGLineAliveLayer, g_hostedPUBGLineKnockedLayer,
            g_hostedPUBGHealthBgLayer, g_hostedPUBGHealthAliveLayer,
            g_hostedPUBGHealthKnockedLayer
        };
        for (CAShapeLayer *batchLayer : batchLayers) {
            if (batchLayer && !CGRectEqualToRect(batchLayer.frame, batchBounds)) {
                batchLayer.frame = batchBounds;
            }
        }
    }

    static UIFont *s_infoFont = nil;
    static UIFont *s_wFont = nil;
    static UIFont *s_itemTitleFont = nil;
    static UIFont *s_itemSubFont = nil;
    static UIFont *s_itemFont = nil;
    static UIFont *s_itemBigWeaponFont = nil;
    static NSMutableParagraphStyle *s_centerStyle = nil;
    static CGColorRef s_aliveColor = NULL;
    static CGColorRef s_knockedColor = NULL;
    static CGColorRef s_skeletonAliveColor = NULL;
    static CGColorRef s_skeletonKnockedColor = NULL;
    static CFTypeRef s_distFont = NULL;
    static dispatch_once_t s_pubgFontOnce;
    dispatch_once(&s_pubgFontOnce, ^{
        s_infoFont = [UIFont systemFontOfSize:8.5 weight:UIFontWeightBold];
        s_wFont = [UIFont systemFontOfSize:8.0 weight:UIFontWeightBold];
        s_itemTitleFont = [UIFont systemFontOfSize:9.0 weight:UIFontWeightBold];
        s_itemSubFont = [UIFont systemFontOfSize:8.0 weight:UIFontWeightBold];
        s_itemFont = [UIFont systemFontOfSize:8.5 weight:UIFontWeightBold];
        s_itemBigWeaponFont = [UIFont systemFontOfSize:12.5 weight:UIFontWeightHeavy];
        s_centerStyle = [[NSMutableParagraphStyle alloc] init];
        s_centerStyle.alignment = NSTextAlignmentCenter;
        s_centerStyle.lineBreakMode = NSLineBreakByClipping;
        s_centerStyle.lineSpacing = -1.5;

        // Retained once; assigning these per frame re-created a UIColor and its
        // CGColor for every visible player.
        s_aliveColor = CGColorRetain([UIColor colorWithRed:0.0 green:1.0 blue:0.0 alpha:0.95].CGColor);
        s_knockedColor = CGColorRetain([UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:0.95].CGColor);
        s_skeletonAliveColor = CGColorRetain([UIColor colorWithWhite:1.0 alpha:0.95].CGColor);
        s_skeletonKnockedColor = CGColorRetain([UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:0.95].CGColor);
        s_distFont = (__bridge_retained CFTypeRef)[UIFont boldSystemFontOfSize:9.0];
    });

    int totalEnemies = 0;
    int totalBots = 0;
    ds_pubg_get_total_counts(&totalEnemies, &totalBots);

    DSPUBGProjectedItem items[kDSPUBGMaxItems];
    uint64_t itemEpoch = 0;
    int itemCount = ds_pubg_copy_projected_items(items, &itemEpoch);
    if (itemCount < 0) itemCount = 0;
    if (itemCount > kDSPUBGMaxItems) itemCount = kDSPUBGMaxItems;

    DSPUBGProjectedGrenade grenades[kDSPUBGMaxGrenades];
    uint64_t grenadeEpoch = 0;
    int grenadeCount = ds_pubg_copy_projected_grenades(grenades, &grenadeEpoch);
    if (grenadeCount < 0) grenadeCount = 0;
    if (grenadeCount > kDSPUBGMaxGrenades) grenadeCount = kDSPUBGMaxGrenades;

    if (count == 0 && itemCount == 0 && grenadeCount == 0 && (totalEnemies + totalBots) <= 0) {
        ds_hosted_pubg_hide_all();
        return;
    }

    // Snapshot is sorted nearest-first, so this keeps the players that matter
    // and drops the raster cost of the tail.
    const int drawCount = (count > kDSPUBGDrawMaxPlayers) ? kDSPUBGDrawMaxPlayers : count;

    CGMutablePathRef boxAlivePath = CGPathCreateMutable();
    CGMutablePathRef boxKnockedPath = CGPathCreateMutable();
    CGMutablePathRef skelAlivePath = CGPathCreateMutable();
    CGMutablePathRef skelKnockedPath = CGPathCreateMutable();
    CGMutablePathRef lineAlivePath = CGPathCreateMutable();
    CGMutablePathRef lineKnockedPath = CGPathCreateMutable();
    CGMutablePathRef hpBgPath = CGPathCreateMutable();
    CGMutablePathRef hpAlivePath = CGPathCreateMutable();
    CGMutablePathRef hpKnockedPath = CGPathCreateMutable();
    BOOL hasBoxAlive = NO, hasBoxKnocked = NO;
    BOOL hasSkelAlive = NO, hasSkelKnocked = NO;
    BOOL hasLineAlive = NO, hasLineKnocked = NO;
    BOOL hasHpBg = NO, hasHpAlive = NO, hasHpKnocked = NO;

    CGFloat snapOriginX = ds_q05(width * 0.5f);
    CGFloat snapOriginY = 25.0f;

    for (int i = 0; i < drawCount; i++) {
        const DSPUBGProjectedPlayer &p = players[i];
        CATextLayer *info = g_hostedPUBGInfoLabels[i];
        CATextLayer *wLabel = g_hostedPUBGWeaponLabels[i];
        CAShapeLayer *arrow = g_hostedPUBGArrowLayers[i];
        CATextLayer *arrowText = g_hostedPUBGArrowTextLayers[i];
        if (!info) continue;

        BOOL ai = p.isAI;

        const BOOL outsideBounds = (p.screenX < -150 || p.screenX > width + 150 ||
                                    p.screenY < -150 || p.screenY > height + 150);
        const BOOL isOffScreen = (!p.isVisible || outsideBounds || p.boxWidth <= 0.0f || p.boxHeight <= 0.0f);

        if (isOffScreen) {
            ds_layer_set_hidden(info, YES);
            ds_layer_set_hidden(wLabel, YES);

            // Arrow only shows for enemies BEHIND the player ("ở sau lưng", camRelZ <= 0.0f)
            // Enemies in front do not show arrow ("còn trước đừng hiện")
            if (!g_pubgEspArrow || !arrow || p.camRelZ > 0.0f) {
                ds_layer_set_hidden(arrow, YES);
                ds_layer_set_hidden(arrowText, YES);
                continue;
            }

            // Behind camera
            float dirX = p.camRelX;
            float dirY = -p.camRelZ; // When camRelZ <= 0, -camRelZ >= 0 (points DOWN/behind in screen coords)
            float h = hypotf(dirX, dirY);
            if (h < 0.001f) {
                dirX = 0.0f;
                dirY = 1.0f;
            } else {
                dirX /= h;
                dirY /= h;
            }

            ds_pubg_draw_radar_arrow(arrow, arrowText, cx, cy, dirX, dirY, p.distanceMeters, YES);
            continue;
        }

        CGFloat centerX = ds_q05(p.screenX + p.boxWidth * 0.5f);
        CGFloat topY = ds_q05(p.screenY);

        // On-screen player is in front ("còn trước đừng hiện"): always hide arrow
        ds_layer_set_hidden(arrow, YES);
        ds_layer_set_hidden(arrowText, YES);

        // 1. 3D Bounding Box (batched into alive / knocked CGPath)
        if (g_pubgEspBox) {
            CGMutablePathRef bTarget = p.isKnocked ? boxKnockedPath : boxAlivePath;
            if (p.has3DBox) {
                CGPoint c[8];
                for (int k = 0; k < 8; k++) {
                    c[k] = CGPointMake(ds_q05(p.boxCorners[k].x), ds_q05(p.boxCorners[k].y));
                }
                CGPathMoveToPoint(bTarget, NULL, c[0].x, c[0].y);
                CGPathAddLineToPoint(bTarget, NULL, c[1].x, c[1].y);
                CGPathAddLineToPoint(bTarget, NULL, c[2].x, c[2].y);
                CGPathAddLineToPoint(bTarget, NULL, c[3].x, c[3].y);
                CGPathCloseSubpath(bTarget);

                CGPathMoveToPoint(bTarget, NULL, c[4].x, c[4].y);
                CGPathAddLineToPoint(bTarget, NULL, c[5].x, c[5].y);
                CGPathAddLineToPoint(bTarget, NULL, c[6].x, c[6].y);
                CGPathAddLineToPoint(bTarget, NULL, c[7].x, c[7].y);
                CGPathCloseSubpath(bTarget);

                for (int k = 0; k < 4; k++) {
                    CGPathMoveToPoint(bTarget, NULL, c[k].x, c[k].y);
                    CGPathAddLineToPoint(bTarget, NULL, c[k + 4].x, c[k + 4].y);
                }
            } else {
                CGPathAddRect(bTarget, NULL, CGRectMake(ds_q05(p.screenX), ds_q05(p.screenY),
                                                        ds_q05(p.boxWidth), ds_q05(p.boxHeight)));
            }
            if (p.isKnocked) hasBoxKnocked = YES; else hasBoxAlive = YES;
        }

        BOOL haveNick = (p.name[0] != '\0' && strncmp(p.name, "Unknown", 7) != 0);
        BOOL isBot = ai || (haveNick && (strstr(p.name, "ModelTarget") != NULL || strstr(p.name, "Target") != NULL || strstr(p.name, "AI") != NULL || strstr(p.name, "Bot") != NULL || strstr(p.name, "bot") != NULL));
        NSString *fallbackNick = (g_pubgLanguage == 1) ? @"ENEMY" : @"ĐỊCH";
        NSString *nameStr = isBot ? @"BOT" : (haveNick ? ds_safe_utf8_string(p.name, fallbackNick) : fallbackNick);
        if (!isBot && g_pubgEspFlag && p.nation[0] != '\0') {
            NSString *flagEmoji = ds_country_code_to_flag_emoji(p.nation);
            if (flagEmoji && flagEmoji.length > 0) {
                nameStr = [NSString stringWithFormat:@"%@ %@", flagEmoji, nameStr];
            } else {
                nameStr = [NSString stringWithFormat:@"[%s] %@", p.nation, nameStr];
            }
        }
        if (p.isKnocked) {
            nameStr = [NSString stringWithFormat:@"⚠️ %@", nameStr];
        }

        // 4. MADNESS Player Info Tag
        CGFloat headerW = 76.0f;
        if (!isBot && g_pubgEspFlag && p.nation[0] != '\0') {
            headerW = 92.0f;
        }
        CGFloat headerX = ds_q05(centerX - headerW * 0.5f);

        CGFloat anchorY = topY;
        if (p.hasSkeleton && p.skeleton[0].valid && p.skeleton[0].y > 0.0f) {
            anchorY = fminf(topY, p.skeleton[0].y - 6.0f);
        }
        if (p.has3DBox) {
            CGFloat min3DY = p.boxCorners[4].y;
            for (int c = 5; c < 8; c++) {
                if (p.boxCorners[c].y < min3DY) min3DY = p.boxCorners[c].y;
            }
            anchorY = fminf(anchorY, min3DY - 2.0f);
        }
        anchorY = ds_q05(anchorY);

        // Tầng 3: Badge đen chứa tên / BOT
        CGFloat badgeH = 13.0f;
        CGFloat badgeY = anchorY - badgeH - 3.0f;

        ds_layer_set_frame(info, ds_q1_rect(headerX, badgeY, headerW, badgeH));
        ds_layer_set_string(info, nameStr);
        ds_layer_set_hidden(info, NO);

        // Tầng 2: Thanh máu 3 vạch liền kề (batched into shared bg + alive/knocked fill paths)
        BOOL showHp = (g_pubgEspHealth && p.healthMax > 0 && p.health >= 0);
        CGFloat barH = 3.6f;
        CGFloat barY = ds_q05(badgeY - barH - 1.5f);

        if (showHp) {
            float hpVal = p.health;
            float hpMax = (p.healthMax > 0.0f) ? p.healthMax : 100.0f;
            float hpRatio = hpVal / hpMax;
            if (hpRatio < 0.0f) hpRatio = 0.0f;
            if (hpRatio > 1.0f) hpRatio = 1.0f;

            CGFloat segW = headerW / 3.0f;
            CGFloat radius = barH * 0.5f;

            CGPathAddRoundedRect(hpBgPath, NULL, CGRectMake(headerX, barY, headerW, barH), radius, radius);
            CGPathMoveToPoint(hpBgPath, NULL, headerX + segW, barY);
            CGPathAddLineToPoint(hpBgPath, NULL, headerX + segW, barY + barH);
            CGPathMoveToPoint(hpBgPath, NULL, headerX + segW * 2.0f, barY);
            CGPathAddLineToPoint(hpBgPath, NULL, headerX + segW * 2.0f, barY + barH);
            hasHpBg = YES;

            if (hpRatio > 0.01f) {
                CGFloat fillW = ds_q05(fmaxf(barH, headerW * hpRatio));
                CGMutablePathRef hpTarget = p.isKnocked ? hpKnockedPath : hpAlivePath;
                CGPathAddRoundedRect(hpTarget, NULL, CGRectMake(headerX, barY, fillW, barH), radius, radius);
                if (fillW > segW) {
                    CGPathMoveToPoint(hpTarget, NULL, headerX + segW, barY);
                    CGPathAddLineToPoint(hpTarget, NULL, headerX + segW, barY + barH);
                }
                if (fillW > segW * 2.0f) {
                    CGPathMoveToPoint(hpTarget, NULL, headerX + segW * 2.0f, barY);
                    CGPathAddLineToPoint(hpTarget, NULL, headerX + segW * 2.0f, barY + barH);
                }
                if (p.isKnocked) hasHpKnocked = YES; else hasHpAlive = YES;
            }
        }

        // Tầng 1: Khoảng cách và Team ID
        CGFloat distH = 11.0f;
        CGFloat distY = (showHp ? barY : badgeY) - distH - 1.5f;
        if (wLabel) {
            int tId = (p.teamId > 0 && p.teamId <= 99) ? p.teamId : (int)(p.playerKey % 89 + 10);
            NSString *dtStr = @"";
            if (g_pubgEspDist && g_pubgEspTeam) {
                dtStr = [NSString stringWithFormat:@"[%.0fM]        [%d]", p.distanceMeters, tId];
            } else if (g_pubgEspDist) {
                dtStr = [NSString stringWithFormat:@"[%.0fM]", p.distanceMeters];
            } else if (g_pubgEspTeam) {
                dtStr = [NSString stringWithFormat:@"[%d]", tId];
            }
            if (dtStr.length > 0) {
                ds_layer_set_frame(wLabel, ds_q1_rect(headerX - 8.0f, distY, headerW + 16.0f, distH));
                if (wLabel.font != s_distFont) wLabel.font = s_distFont;
                ds_layer_set_string(wLabel, dtStr);
                ds_layer_set_hidden(wLabel, NO);
            } else {
                ds_layer_set_hidden(wLabel, YES);
            }
        }

        // 2. Snapline (batched into alive / knocked CGPath)
        if (g_pubgEspLine) {
            CGMutablePathRef lTarget = p.isKnocked ? lineKnockedPath : lineAlivePath;
            CGPathMoveToPoint(lTarget, NULL, snapOriginX, snapOriginY);
            CGPathAddLineToPoint(lTarget, NULL, centerX, ds_q05(distY - 1.0f));
            if (p.isKnocked) hasLineKnocked = YES; else hasLineAlive = YES;
        }

        // 5. Skeleton ESP (batched into alive / knocked CGPath)
        if (g_pubgEspSkeleton && p.hasSkeleton) {
            static const int bonePairs[][2] = {
                {1, 2},                     // Neck <-> Pelvis (Spine)
                {1, 3}, {3, 4}, {4, 5},     // Neck <-> UprR <-> LwrR <-> HandR
                {1, 6}, {6, 7}, {7, 8},     // Neck <-> UprL <-> LwrL <-> HandL
                {2, 9}, {9, 10}, {10, 11},  // Pelvis <-> ThighR <-> CalfR <-> FootR
                {2, 12}, {12, 13}, {13, 14} // Pelvis <-> ThighL <-> CalfL <-> FootL
            };
            const int boneCount = (int)(sizeof(bonePairs) / sizeof(bonePairs[0]));
            const float maxAllowed = fmaxf(fmaxf(p.boxHeight, p.boxWidth) * 1.25f, 120.0f);
            auto validJoint = [](const DSPUBGJoint &j) -> bool {
                return j.valid && isfinite(j.x) && isfinite(j.y) &&
                       fabsf(j.x) < 10000.0f && fabsf(j.y) < 10000.0f;
            };
            CGMutablePathRef sTarget = p.isKnocked ? skelKnockedPath : skelAlivePath;
            BOOL drewSkel = NO;
            for (int b = 0; b < boneCount; b++) {
                int u = bonePairs[b][0];
                int v = bonePairs[b][1];
                if (validJoint(p.skeleton[u]) && validJoint(p.skeleton[v])) {
                    float ux = p.skeleton[u].x, uy = p.skeleton[u].y;
                    float vx = p.skeleton[v].x, vy = p.skeleton[v].y;
                    float segDist = hypotf(ux - vx, uy - vy);
                    if (segDist <= maxAllowed) {
                        CGPathMoveToPoint(sTarget, NULL, ds_q05(ux), ds_q05(uy));
                        CGPathAddLineToPoint(sTarget, NULL, ds_q05(vx), ds_q05(vy));
                        drewSkel = YES;
                    }
                }
            }

            if (validJoint(p.skeleton[0]) || validJoint(p.skeleton[15])) {
                float hcx = validJoint(p.skeleton[0]) ? p.skeleton[0].x : p.skeleton[15].x;
                float hcy = validJoint(p.skeleton[0]) ? p.skeleton[0].y : p.skeleton[15].y;

                // Match PUBGDS 3D-perspective head circle size from Head <-> HeadTop,
                // keep it centered on the real head joint, and stop the neck line
                // at the circle rim so no bone pierces inside.
                float r = p.boxHeight / 18.0f;
                if (validJoint(p.skeleton[15]) && validJoint(p.skeleton[0])) {
                    float d = hypotf(p.skeleton[15].x - p.skeleton[0].x,
                                     p.skeleton[15].y - p.skeleton[0].y) * 1.1f;
                    if (d >= 0.6f && d <= 30.0f) {
                        r = d;
                    }
                }
                if (r < 2.0f) r = 2.0f;
                if (r > 24.0f) r = 24.0f;

                if (validJoint(p.skeleton[1])) {
                    float nx = p.skeleton[1].x;
                    float ny = p.skeleton[1].y;
                    float dx = hcx - nx;
                    float dy = hcy - ny;
                    float neckDist = hypotf(dx, dy);
                    if (neckDist <= maxAllowed && neckDist > r + 0.25f) {
                        float rimX = hcx - (dx / neckDist) * r;
                        float rimY = hcy - (dy / neckDist) * r;
                        CGPathMoveToPoint(sTarget, NULL, ds_q05(nx), ds_q05(ny));
                        CGPathAddLineToPoint(sTarget, NULL, ds_q05(rimX), ds_q05(rimY));
                    }
                }

                CGFloat qx = ds_q05(hcx), qy = ds_q05(hcy), qr = ds_q05(r);
                // CGPathAddArc flattens a 0..2PI sweep to a zero-length arc
                // (start and end angle normalise to the same point), so the
                // head ring vanished once the skeleton moved to a batched
                // CGPath. An explicit ellipse subpath always closes.
                CGPathAddEllipseInRect(sTarget, NULL,
                                       CGRectMake(qx - qr, qy - qr, qr * 2.0f, qr * 2.0f));
                drewSkel = YES;
            }
            if (drewSkel) {
                if (p.isKnocked) hasSkelKnocked = YES; else hasSkelAlive = YES;
            }
        }
    }

    ds_layer_set_stroke(g_hostedPUBGBoxAliveLayer, s_aliveColor, g_pubgEspThickness);
    ds_layer_set_cgpath(g_hostedPUBGBoxAliveLayer, boxAlivePath, hasBoxAlive);
    ds_layer_set_stroke(g_hostedPUBGBoxKnockedLayer, s_knockedColor, g_pubgEspThickness);
    ds_layer_set_cgpath(g_hostedPUBGBoxKnockedLayer, boxKnockedPath, hasBoxKnocked);

    ds_layer_set_stroke(g_hostedPUBGSkeletonAliveLayer, s_skeletonAliveColor, g_pubgEspThickness);
    ds_layer_set_cgpath(g_hostedPUBGSkeletonAliveLayer, skelAlivePath, hasSkelAlive);
    ds_layer_set_stroke(g_hostedPUBGSkeletonKnockedLayer, s_skeletonKnockedColor, g_pubgEspThickness);
    ds_layer_set_cgpath(g_hostedPUBGSkeletonKnockedLayer, skelKnockedPath, hasSkelKnocked);

    ds_layer_set_stroke(g_hostedPUBGLineAliveLayer, s_aliveColor, g_pubgEspThickness);
    ds_layer_set_cgpath(g_hostedPUBGLineAliveLayer, lineAlivePath, hasLineAlive);
    ds_layer_set_stroke(g_hostedPUBGLineKnockedLayer, s_knockedColor, g_pubgEspThickness);
    ds_layer_set_cgpath(g_hostedPUBGLineKnockedLayer, lineKnockedPath, hasLineKnocked);

    ds_layer_set_cgpath(g_hostedPUBGHealthBgLayer, hpBgPath, hasHpBg);
    ds_layer_set_cgpath(g_hostedPUBGHealthAliveLayer, hpAlivePath, hasHpAlive);
    ds_layer_set_cgpath(g_hostedPUBGHealthKnockedLayer, hpKnockedPath, hasHpKnocked);

    CGPathRelease(boxAlivePath);
    CGPathRelease(boxKnockedPath);
    CGPathRelease(skelAlivePath);
    CGPathRelease(skelKnockedPath);
    CGPathRelease(lineAlivePath);
    CGPathRelease(lineKnockedPath);
    CGPathRelease(hpBgPath);
    CGPathRelease(hpAlivePath);
    CGPathRelease(hpKnockedPath);

    for (int i = drawCount; i < kDSPUBGMaxPlayers; i++) {
        ds_layer_set_hidden(g_hostedPUBGInfoLabels[i], YES);
        ds_layer_set_hidden(g_hostedPUBGWeaponLabels[i], YES);
        ds_layer_set_hidden(g_hostedPUBGArrowLayers[i], YES);
        ds_layer_set_hidden(g_hostedPUBGArrowTextLayers[i], YES);
    }

    if (g_hostedPUBGTopCountLabel) {
        if (g_hostedPUBGTopCountBgLayer) {
            g_hostedPUBGTopCountBgLayer.hidden = YES;
        }

        static UIFont *s_topCountFont = nil;
        static dispatch_once_t s_topCountOnce;
        dispatch_once(&s_topCountOnce, ^{
            UIFont *f = [UIFont fontWithName:@"Helvetica-Bold" size:10.5];
            if (!f) f = [UIFont boldSystemFontOfSize:10.5];
            s_topCountFont = f;
        });

        if (g_pubgEspEnemyNumber && ds_pubg_has_render_source() && (totalEnemies + totalBots > 0)) {
            CGFloat lblW = 230.0f;
            CGFloat lblH = 14.0f;
            CGFloat lblX = (width - lblW) * 0.5f;
            CGFloat lblY = 24.0f;

            ds_layer_set_frame(g_hostedPUBGTopCountLabel, ds_q1_rect(lblX, lblY, lblW, lblH));
            if (g_hostedPUBGTopCountLabel.font != (__bridge CFTypeRef)s_topCountFont) {
                g_hostedPUBGTopCountLabel.font = (__bridge CFTypeRef)s_topCountFont;
            }
            if (g_hostedPUBGTopCountLabel.fontSize != 10.5) {
                g_hostedPUBGTopCountLabel.fontSize = 10.5;
            }
            NSString *topCountStr = [NSString stringWithFormat:@"PLAYER AROUND [%d]  BOT AROUND [%d]", totalEnemies, totalBots];
            ds_layer_set_string(g_hostedPUBGTopCountLabel, topCountStr);
            ds_layer_set_hidden(g_hostedPUBGTopCountLabel, NO);
        } else {
            ds_layer_set_hidden(g_hostedPUBGTopCountLabel, YES);
        }
    }

    // Render Items / Loot ESP (copied above)

    // Labels are drawn at the projected screen position of their actor. There
    // is deliberately no overlap stacking: shifting a label moved it away from
    // the loot it describes, which made dense areas unreadable.

    for (int i = 0; i < kDSPUBGMaxItems; i++) {
        CATextLayer *lbl = g_hostedPUBGItemLabels[i];
        if (!lbl) continue;

        if (i >= itemCount) {
            if (!lbl.hidden) lbl.hidden = YES;
            continue;
        }

        const DSPUBGProjectedItem &it = items[i];
        bool show = ds_pubg_is_item_type_enabled(it.category, it.name);

        float maxDist = (it.category == DSPUBGItemCategoryVehicle) ? fminf(fmaxf(g_pubgItemMaxDistance * 1.6f, 200.0f), 280.0f) :
                        ((it.category == DSPUBGItemCategoryCrate) ? (g_pubgItemMaxDistance * 2.0f) : g_pubgItemMaxDistance);
        if (!show || !it.isVisible || it.distanceMeters > maxDist) {
            if (!lbl.hidden) lbl.hidden = YES;
            continue;
        }

        NSString *nameStr = ds_safe_utf8_string(it.name, @"Vật Phẩm");

        CGFloat posX = it.screenX;
        CGFloat posY = it.screenY;

        if (it.category == DSPUBGItemCategoryVehicle) {
            NSString *titleStr = [NSString stringWithFormat:@"[%@ %.0fM]", nameStr, it.distanceMeters];
            CGFloat strW = 120.0f;
            CGFloat strH = 14.0f;
            ds_layer_set_frame(lbl, ds_q1_rect(posX - strW * 0.5f, posY - strH * 0.5f, strW, strH));
            if (lbl.fontSize != 9.5) lbl.fontSize = 9.5;
            // Vehicles were white in the build the user considers correct; the
            // gold tint came from the per-item colour payload.
            static CGColorRef s_vehicleWhite = NULL;
            static dispatch_once_t s_vehicleWhiteOnce;
            dispatch_once(&s_vehicleWhiteOnce, ^{
                s_vehicleWhite = CGColorRetain([UIColor whiteColor].CGColor);
            });
            if (lbl.foregroundColor != s_vehicleWhite) lbl.foregroundColor = s_vehicleWhite;
            ds_layer_set_string(lbl, titleStr);
            ds_layer_set_hidden(lbl, NO);
        } else {
            NSString *itemText = [NSString stringWithFormat:@"[%@ %.0fM]", nameStr, it.distanceMeters];
            CGFloat strW = it.isPriority ? 115.0f : 100.0f;
            CGFloat strH = it.isPriority ? 16.0f : 13.0f;
            ds_layer_set_frame(lbl, ds_q1_rect(posX - strW * 0.5f, posY - strH * 0.5f, strW, strH));
            if (lbl.fontSize != (it.isPriority ? 10.0 : 8.5)) {
                lbl.fontSize = it.isPriority ? 10.0 : 8.5;
            }

            // MADNESS color mapping
            static CGColorRef s_itemWeaponColor = NULL;
            static CGColorRef s_itemArmorColor = NULL;
            static CGColorRef s_itemScopeColor = NULL;
            static CGColorRef s_itemCrateColor = NULL;
            static dispatch_once_t s_itemColorOnce;
            dispatch_once(&s_itemColorOnce, ^{
                s_itemWeaponColor = CGColorRetain([UIColor colorWithRed:1.0 green:0.25 blue:0.25 alpha:1.0].CGColor);
                s_itemArmorColor = CGColorRetain([UIColor colorWithRed:0.0 green:1.0 blue:0.4 alpha:1.0].CGColor);
                s_itemScopeColor = CGColorRetain([UIColor colorWithRed:1.0 green:1.0 blue:0.0 alpha:1.0].CGColor);
                s_itemCrateColor = CGColorRetain([UIColor colorWithRed:1.0 green:0.55 blue:0.0 alpha:1.0].CGColor);
            });

            CGColorRef itemColor;
            if (it.category == DSPUBGItemCategoryWeapon) {
                itemColor = s_itemWeaponColor;
            } else if (it.category == DSPUBGItemCategoryArmor || it.category == DSPUBGItemCategoryBag) {
                itemColor = s_itemArmorColor;
            } else if (it.category == DSPUBGItemCategoryScope) {
                itemColor = s_itemScopeColor;
            } else if (it.category == DSPUBGItemCategoryCrate) {
                itemColor = s_itemCrateColor;
            } else {
                itemColor = ds_pubg_cgcolor_from_rgba(it.colorRGBA);
            }

            if (lbl.foregroundColor != itemColor) lbl.foregroundColor = itemColor;
            ds_layer_set_string(lbl, itemText);
            ds_layer_set_hidden(lbl, NO);
        }
    }

    // --- GRENADE WARNING RENDERING (Flight Line, Dynamic 3D Bomb Icon, Drop Line, Damage Circle) ---

    for (int i = 0; i < kDSPUBGMaxGrenades; i++) {
        CAShapeLayer *trajLayer = g_hostedPUBGGrenadeTrajLayers[i];
        CAShapeLayer *circleOutLayer = g_hostedPUBGGrenadeCircleLayers[i];
        CAShapeLayer *circleMidLayer = g_hostedPUBGGrenadeCircleMidLayers[i];
        CAShapeLayer *circleInLayer = g_hostedPUBGGrenadeCircleInnerLayers[i];
        CAShapeLayer *boxLayer = g_hostedPUBGGrenadeBoxLayers[i];
        CATextLayer *badgeLbl = g_hostedPUBGGrenadeLabels[i];
        CAShapeLayer *dropLineLayer = g_hostedPUBGGrenadeDropLineLayers[i];
        CALayer *markerLayer = g_hostedPUBGGrenadeMarkerLayers[i];

        if (i >= grenadeCount || !g_pubgEspGrenade || !g_hostedEspEnabled) {
            if (trajLayer) trajLayer.hidden = YES;
            if (circleOutLayer) circleOutLayer.hidden = YES;
            if (circleMidLayer) circleMidLayer.hidden = YES;
            if (circleInLayer) circleInLayer.hidden = YES;
            if (boxLayer) boxLayer.hidden = YES;
            if (badgeLbl) badgeLbl.hidden = YES;
            if (dropLineLayer) dropLineLayer.hidden = YES;
            if (markerLayer) markerLayer.hidden = YES;
            continue;
        }

        const DSPUBGProjectedGrenade &g = grenades[i];

        bool hasCircleOnScreen = false;
        for (int k = 0; k < g.circlePointCount; k++) {
            if (g.circlePointsValid[k] || g.circlePointsMidValid[k] || g.circlePointsInnerValid[k]) {
                hasCircleOnScreen = true;
                break;
            }
        }

        if (!g.isVisible && g.trajCount == 0 && !hasCircleOnScreen && !g.hasBox) {
            if (trajLayer) trajLayer.hidden = YES;
            if (circleOutLayer) circleOutLayer.hidden = YES;
            if (circleMidLayer) circleMidLayer.hidden = YES;
            if (circleInLayer) circleInLayer.hidden = YES;
            if (boxLayer) boxLayer.hidden = YES;
            if (badgeLbl) badgeLbl.hidden = YES;
            if (dropLineLayer) dropLineLayer.hidden = YES;
            if (markerLayer) markerLayer.hidden = YES;
            continue;
        }

        // 1. Line bom ném ra (Đường bay & vệt quỹ đạo bay màu trắng mờ mượt mà phía sau quả bom)
        if (trajLayer) {
            if (g.trajCount >= 2) {
                UIBezierPath *linePath = [UIBezierPath bezierPath];
                [linePath moveToPoint:g.trajPoints[0]];
                for (int t = 1; t < g.trajCount; t++) {
                    [linePath addLineToPoint:g.trajPoints[t]];
                }
                ds_layer_set_path(trajLayer, linePath);
                ds_layer_set_stroke(trajLayer, ds_grenade_color(DSGrenadeColorTrajectory), 2.0f);
                ds_layer_set_hidden(trajLayer, NO);
            } else {
                ds_layer_set_hidden(trajLayer, YES);
            }
        }

        // Helper lambda to build smooth circle path matching Circle3D
        auto buildCirclePath = [&](const CGPoint *pts, const bool *validPts, int count) -> UIBezierPath * {
            UIBezierPath *p = [UIBezierPath bezierPath];
            int validSegments = 0;
            for (int k = 0; k < count; k++) {
                int next = (k + 1) % count;
                if (validPts[k] && validPts[next]) {
                    [p moveToPoint:pts[k]];
                    [p addLineToPoint:pts[next]];
                    validSegments++;
                }
            }
            return validSegments >= 3 ? p : nil;
        };

        // 2. 3D Damage Circle (Vòng tròn sát thương 3D màu vàng chanh sáng rõ nét như trong ảnh)
        if (circleOutLayer) {
            UIBezierPath *cp = buildCirclePath(g.circlePoints, g.circlePointsValid, g.circlePointCount);
            if (cp) {
                ds_layer_set_path(circleOutLayer, cp);
                ds_layer_set_stroke(circleOutLayer, ds_grenade_color(DSGrenadeColorCircle), 1.8f);
                ds_layer_set_hidden(circleOutLayer, NO);
            } else {
                ds_layer_set_hidden(circleOutLayer, YES);
            }
        }
        ds_layer_set_hidden(circleMidLayer, YES);
        ds_layer_set_hidden(circleInLayer, YES);

        // 3. Altitude Drop Line to Ground (Đường line vàng thẳng đứng hạ từ quả bom xuống mặt đất)
        if (dropLineLayer) {
            if (g.hasDropLine && g.isVisible) {
                UIBezierPath *dp = [UIBezierPath bezierPath];
                [dp moveToPoint:CGPointMake(g.screenX, g.screenY + 12.0f)];
                [dp addLineToPoint:g.groundPoint];

                ds_layer_set_path(dropLineLayer, dp);
                ds_layer_set_stroke(dropLineLayer, ds_grenade_color(DSGrenadeColorDropLine), 1.6f);
                ds_layer_set_hidden(dropLineLayer, NO);
            } else {
                ds_layer_set_hidden(dropLineLayer, YES);
            }
        }

        // 4. Distinct 3D Throwable Icons (Frag, Smoke, Burn, Stun)
        if (markerLayer) {
            if (g.isVisible) {
                if (!CGPointEqualToPoint(markerLayer.position, CGPointMake(g.screenX, g.screenY))) {
                    markerLayer.position = CGPointMake(g.screenX, g.screenY);
                }
                markerLayer.hidden = NO;

                CALayer *fragL = g_hostedPUBGGrenadeFragLayers[i];
                CALayer *smokeL = g_hostedPUBGGrenadeSmokeLayers[i];
                CALayer *burnL = g_hostedPUBGGrenadeBurnLayers[i];
                CALayer *stunL = g_hostedPUBGGrenadeStunLayers[i];

                if (g.type == DSPUBGGrenadeTypeSmoke) {
                    ds_layer_set_hidden(fragL, YES);
                    ds_layer_set_hidden(smokeL, NO);
                    ds_layer_set_hidden(burnL, YES);
                    ds_layer_set_hidden(stunL, YES);
                } else if (g.type == DSPUBGGrenadeTypeBurn) {
                    ds_layer_set_hidden(fragL, YES);
                    ds_layer_set_hidden(smokeL, YES);
                    ds_layer_set_hidden(burnL, NO);
                    ds_layer_set_hidden(stunL, YES);
                } else if (g.type == DSPUBGGrenadeTypeStun) {
                    ds_layer_set_hidden(fragL, YES);
                    ds_layer_set_hidden(smokeL, YES);
                    ds_layer_set_hidden(burnL, YES);
                    ds_layer_set_hidden(stunL, NO);
                } else {
                    ds_layer_set_hidden(fragL, NO);
                    ds_layer_set_hidden(smokeL, YES);
                    ds_layer_set_hidden(burnL, YES);
                    ds_layer_set_hidden(stunL, YES);

                    float total = (g.totalFuseSeconds > 0.1f) ? g.totalFuseSeconds : 7.0f;
                    float progress = 1.0f - (g.cookSeconds / total);
                    if (progress < 0.0f) progress = 0.0f;
                    if (progress > 1.0f) progress = 1.0f;

                    CALayer *redFill = g_hostedPUBGGrenadeMarkerFillLayers[i];
                    CALayer *bgYellow = g_hostedPUBGGrenadeMarkerBgLayers[i];
                    if (redFill) {
                        CGFloat redH = ds_q05(22.0f * progress);
                        ds_layer_set_frame(redFill, CGRectMake(0, 22.0f - redH, 22.0f, redH));
                    }
                    if (bgYellow) {
                        CGFloat gVal = (CGFloat)(roundf((0.95f - (0.87f * progress)) * 50.0f) * 0.02f);
                        if (gVal < 0.08f) gVal = 0.08f;
                        if (gVal > 0.95f) gVal = 0.95f;
                        static CGFloat s_lastBgG[kDSPUBGMaxGrenades] = {-1, -1, -1, -1, -1, -1, -1, -1};
                        if (fabs(s_lastBgG[i] - gVal) > 0.005f) {
                            s_lastBgG[i] = gVal;
                            bgYellow.backgroundColor = [UIColor colorWithRed:1.0f green:gVal blue:0.05f alpha:1.0f].CGColor;
                        }
                    }
                }
            } else {
                ds_layer_set_hidden(markerLayer, YES);
            }
        }

        // 6. 3D Bounding Box around grenade (< 13m)
        if (boxLayer) {
            if (g.hasBox) {
                UIBezierPath *bp = [UIBezierPath bezierPath];
                [bp moveToPoint:g.boxCorners[0]];
                [bp addLineToPoint:g.boxCorners[1]];
                [bp addLineToPoint:g.boxCorners[2]];
                [bp addLineToPoint:g.boxCorners[3]];
                [bp closePath];
                [bp moveToPoint:g.boxCorners[4]];
                [bp addLineToPoint:g.boxCorners[5]];
                [bp addLineToPoint:g.boxCorners[6]];
                [bp addLineToPoint:g.boxCorners[7]];
                [bp closePath];
                [bp moveToPoint:g.boxCorners[0]]; [bp addLineToPoint:g.boxCorners[4]];
                [bp moveToPoint:g.boxCorners[1]]; [bp addLineToPoint:g.boxCorners[5]];
                [bp moveToPoint:g.boxCorners[2]]; [bp addLineToPoint:g.boxCorners[6]];
                [bp moveToPoint:g.boxCorners[3]]; [bp addLineToPoint:g.boxCorners[7]];

                static CGColorRef s_grenadeBoxColor = NULL;
                static dispatch_once_t s_grenadeBoxOnce;
                dispatch_once(&s_grenadeBoxOnce, ^{
                    s_grenadeBoxColor = CGColorRetain([UIColor colorWithRed:1.0f green:0.2f blue:0.2f alpha:1.0f].CGColor);
                });

                ds_layer_set_path(boxLayer, bp);
                if (boxLayer.strokeColor != s_grenadeBoxColor) boxLayer.strokeColor = s_grenadeBoxColor;
                if (boxLayer.lineWidth != 1.3f) boxLayer.lineWidth = 1.3f;
                ds_layer_set_hidden(boxLayer, NO);
            } else {
                ds_layer_set_hidden(boxLayer, YES);
            }
        }

        // 7. Distance & Countdown tag
        if (badgeLbl && g.isVisible) {
            NSString *titleStr = ds_safe_utf8_string(g.name, @"Bomb");
            NSString *fullBadge;
            if (g.totalFuseSeconds <= 8.0f && g.cookSeconds > 0.0f) {
                fullBadge = [NSString stringWithFormat:@"%@ [%.0fm] %.1fs", titleStr, g.distanceMeters, g.cookSeconds];
            } else {
                fullBadge = [NSString stringWithFormat:@"%@ [%.0fm]", titleStr, g.distanceMeters];
            }

            static NSDictionary *s_badgeAttrs = nil;
            static dispatch_once_t s_badgeAttrsOnce;
            dispatch_once(&s_badgeAttrsOnce, ^{
                s_badgeAttrs = @{
                    NSFontAttributeName: [UIFont systemFontOfSize:11.0 weight:UIFontWeightHeavy],
                    NSForegroundColorAttributeName: [UIColor colorWithRed:1.0f green:0.2f blue:0.2f alpha:1.0f],
                    NSStrokeColorAttributeName: [UIColor blackColor],
                    NSStrokeWidthAttributeName: @(-2.2),
                    NSParagraphStyleAttributeName: s_centerStyle
                };
            });

            CGFloat bw = 160.0f;
            CGFloat bh = 18.0f;
            ds_layer_set_frame(badgeLbl, CGRectMake(g.screenX - bw * 0.5f, g.screenY + 22.0f, bw, bh));

            // The countdown text changes every frame, so the attributed string
            // has to be rebuilt — but only when the rendered text actually differs.
            NSString *currentText = [badgeLbl.string isKindOfClass:NSAttributedString.class]
                ? [(NSAttributedString *)badgeLbl.string string] : nil;
            if (!currentText || ![currentText isEqualToString:fullBadge]) {
                badgeLbl.string = [[NSAttributedString alloc] initWithString:fullBadge attributes:s_badgeAttrs];
            }
            ds_layer_set_hidden(badgeLbl, NO);
        } else if (badgeLbl) {
            ds_layer_set_hidden(badgeLbl, YES);
        }
    }

    // Banner removed per user request: "không cần làm cái thông báo địch rút bom đâu xoá đi cho tôi"
    if (g_hostedPUBGGrenadeDangerBanner) {
        g_hostedPUBGGrenadeDangerBanner.hidden = YES;
    }

    // Update circular radar HUD with live enemy dots
    if (g_hostedMenuViewController) {
        [g_hostedMenuViewController dsUpdateRadarWithPlayers:players count:count];
    }
    } @catch (NSException *ex) {
        // Guard against any UIKit / CoreAnimation unexpected exception
    }
}

static void ds_hosted_consume_render_snapshot(bool fallback,
                                              double timestamp,
                                              double targetTimestamp,
                                              double startedAt) {
    (void)fallback;
    (void)timestamp;
    (void)targetTimestamp;
    (void)startedAt;
    if (!NSThread.isMainThread || !g_hostedLayer) return;
    DSHostedRenderSnapshot snapshot = {};
    BOOL shouldRender = NO;
    os_unfair_lock_lock(&g_hostedSnapshotLock);
    if (g_hostedPublishedSnapshot >= 0) {
        snapshot = g_hostedSnapshots[g_hostedPublishedSnapshot];
    }
    if (snapshot.generation &&
        snapshot.generation != g_hostedConsumedGeneration) {
        g_hostedConsumedGeneration = snapshot.generation;
        shouldRender = YES;
    }
    os_unfair_lock_unlock(&g_hostedSnapshotLock);
    if (!shouldRender) return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    UIInterfaceOrientation renderOri = ds_active_orientation();
    if (!UIInterfaceOrientationIsLandscape(renderOri)) {
        if (ds_pubg_has_render_source()) {
            renderOri = UIInterfaceOrientationLandscapeRight;
        }
    }
    ds_hosted_apply_orientation(renderOri);
    ds_hosted_apply_pubg();
    [CATransaction commit];
}

static void ds_hosted_publish_render_snapshot(const DSHostedRenderSnapshot &next) {
    BOOL queueFallback = NO;
    uint64_t fallbackToken = 0;
    double now = CACurrentMediaTime();
    os_unfair_lock_lock(&g_hostedSnapshotLock);
    int writeIndex = g_hostedPublishedSnapshot == 0 ? 1 : 0;
    g_hostedSnapshots[writeIndex] = next;
    g_hostedSnapshots[writeIndex].generation = ++g_hostedSnapshotGeneration;
    g_hostedPublishedSnapshot = writeIndex;
    if (now - g_hostedLastDisplayLinkTick.load(std::memory_order_relaxed) > 0.025 &&
        !g_hostedFallbackApplyQueued) {
        g_hostedFallbackApplyQueued = YES;
        fallbackToken = ++g_hostedFallbackToken;
        queueFallback = YES;
    }
    os_unfair_lock_unlock(&g_hostedSnapshotLock);
    if (queueFallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            double startedAt = CACurrentMediaTime();
            os_unfair_lock_lock(&g_hostedSnapshotLock);
            BOOL validToken = g_hostedFallbackApplyQueued &&
                              fallbackToken == g_hostedFallbackToken;
            BOOL displayLinkResumed =
                g_hostedLastDisplayLinkTick.load(std::memory_order_relaxed) > now;
            os_unfair_lock_unlock(&g_hostedSnapshotLock);
            if (validToken && !displayLinkResumed) {
                ds_hosted_consume_render_snapshot(true, 0.0, 0.0, startedAt);
            }
            os_unfair_lock_lock(&g_hostedSnapshotLock);
            if (fallbackToken == g_hostedFallbackToken) {
                g_hostedFallbackApplyQueued = NO;
            }
            os_unfair_lock_unlock(&g_hostedSnapshotLock);
        });
    }
}

// Registration executed INSIDE SpringBoard via the existing RemoteCall — the
// caller's audit token is then SpringBoard's own, so the accessibility-window
// entitlement check passes without any entitlement patching. One-time setup.
static void ds_hosted_overlay_register(unsigned contextId) {
    RemoteCall *process = g_springBoard;
    if (!process || !process.trojanMem || !contextId) return;
    if (g_hostedRemoteController) return;
    uint64_t hostClass = ds_remote_class(process, "SBSAccessibilityWindowHostingController");
    if (!hostClass) return;
    uint64_t host = remote_msg(process, hostClass, ds_remote_sel(process, "alloc"), 0, 0, 0, 0);
    if (!host || !ds_remote_invoke_noarg_on_main(process, host, "init")) return;
    uint32_t cid = contextId;  // signature "v@:Id": unsigned int + double
    double level = 10000010.0;
    DSRemoteArgument args[2] = {
        { &cid, sizeof(cid) },
        { &level, sizeof(level) },
    };
    if (ds_remote_invoke_on_main(process, host,
                                 ds_remote_sel(process, "registerWindowWithContextID:atLevel:"),
                                 args, 2)) {
        g_hostedRemoteController = host;  // keep the controller alive in SpringBoard
        g_hostedSBPid = (pid_t)process.pid;
    }
}

// Main thread, all local UIKit. Returns the window's render-server context id.
static void ds_hosted_overlay_start_display_link(void) {
    if (g_hostedDisplayLink) return;
    g_hostedDisplayLinkDriver = [[DSHostedDisplayLinkDriver alloc] init];
    g_hostedDisplayLink = [CADisplayLink displayLinkWithTarget:g_hostedDisplayLinkDriver
                                                      selector:@selector(displayLinkDidFire:)];
    ds_hosted_configure_display_link(g_hostedDisplayLink);
    [g_hostedDisplayLink addToRunLoop:NSRunLoop.mainRunLoop
                              forMode:NSRunLoopCommonModes];
}

static unsigned ds_hosted_overlay_setup_on_main(void) {
    if (g_hostedLayer) {
        // Paused earlier: window/context/layers survived — just relink frames.
        g_hostedWindow.hidden = NO;
        g_hostedLayerReady.store(true, std::memory_order_release);
        ds_hosted_overlay_start_display_link();
        return g_hostedContextId;
    }
    g_hostedSetupAttempts++;

    // Read the device cutout from the normal app scene before the secure,
    // status-bar-less hosted window becomes key. Keep this value immutable
    // for the lifetime of the overlay; minimap rendering only consumes it.
    g_hostedPortraitNotchHeight = 0.0;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached)
            continue;
        for (UIWindow *candidate in windowScene.windows) {
            // In landscape the device cutout is reported on left/right,
            // not top. Keep the largest safe-area edge as the portrait
            // notch-equivalent used by the manually rotated overlay.
            UIEdgeInsets insets = candidate.safeAreaInsets;
            CGFloat cutout = MAX(MAX(insets.top, insets.bottom),
                                 MAX(insets.left, insets.right));
            g_hostedPortraitNotchHeight = MAX(
                g_hostedPortraitNotchHeight, cutout);
        }
    }

    // Scene-less window (TrollSpeed pattern): this app has no scene manifest,
    // so the window is not tied to any scene's lifecycle.
    CGRect sceneBounds = UIScreen.mainScreen.bounds;
    CGRect content = sceneBounds;
    if (CGRectGetWidth(content) < CGRectGetHeight(content)) {
        content = CGRectMake(0, 0, CGRectGetHeight(content), CGRectGetWidth(content));
    }
    g_hostedContentBounds = content;

    DSESPHostedWindow *window = [[DSESPHostedWindow alloc] initWithFrame:sceneBounds];
    window.backgroundColor = UIColor.clearColor;
    window.windowLevel = 10000010.0;
    DSESPHostedViewController *rootVC = [[DSESPHostedViewController alloc] init];
    window.rootViewController = rootVC;
    UIView *espView = [[UIView alloc] initWithFrame:content];
    espView.userInteractionEnabled = NO;
    espView.opaque = NO;
    espView.clipsToBounds = YES;
    espView.backgroundColor = UIColor.clearColor;
    [rootVC.view addSubview:espView];
    window.hidden = NO;
    [window makeKeyAndVisible];  // forces the render-server context to exist

    unsigned contextId = ((unsigned (*)(id, SEL))objc_msgSend)(window, NSSelectorFromString(@"_contextId"));
    if (!contextId) {
        window.hidden = YES;
        return 0;
    }

    g_hostedWindow = window;
    g_hostedESPView = espView;
    g_hostedLayer = espView.layer;
    g_hostedLayer.contents = nil;

    NSDictionary *noAnim = @{@"position": [NSNull null], @"hidden": [NSNull null],
                             @"string": [NSNull null], @"bounds": [NSNull null],
                             @"frame": [NSNull null], @"backgroundColor": [NSNull null],
                             @"path": [NSNull null], @"strokeColor": [NSNull null],
                             @"fillColor": [NSNull null], @"lineWidth": [NSNull null],
                             @"lineDashPhase": [NSNull null]};
    CGFloat scale = UIScreen.mainScreen.scale;

    // PUBG-only pool: batched vector layers + per-player labels/arrows
        {
            auto makeBatchShape = [&](CGColorRef fillColor, CGColorRef strokeColor, CGFloat lineWidth) -> CAShapeLayer * {
                CAShapeLayer *layer = [CAShapeLayer layer];
                layer.actions = noAnim;
                layer.contentsScale = scale;
                layer.fillColor = fillColor;
                layer.strokeColor = strokeColor;
                layer.lineWidth = lineWidth;
                layer.lineCap = kCALineCapSquare;
                layer.lineJoin = kCALineJoinMiter;
                layer.hidden = YES;
                [g_hostedLayer addSublayer:layer];
                return layer;
            };

            g_hostedPUBGBoxAliveLayer = makeBatchShape(UIColor.clearColor.CGColor, NULL, 1.5);
            g_hostedPUBGBoxKnockedLayer = makeBatchShape(UIColor.clearColor.CGColor, NULL, 1.5);
            g_hostedPUBGSkeletonAliveLayer = makeBatchShape(UIColor.clearColor.CGColor, NULL, 1.2);
            g_hostedPUBGSkeletonKnockedLayer = makeBatchShape(UIColor.clearColor.CGColor, NULL, 1.2);
            g_hostedPUBGLineAliveLayer = makeBatchShape(UIColor.clearColor.CGColor, NULL, 1.2);
            g_hostedPUBGLineKnockedLayer = makeBatchShape(UIColor.clearColor.CGColor, NULL, 1.2);
            g_hostedPUBGHealthBgLayer = makeBatchShape([UIColor colorWithWhite:0.1 alpha:0.75].CGColor,
                                                       [UIColor blackColor].CGColor, 0.8f);
            g_hostedPUBGHealthAliveLayer = makeBatchShape([UIColor colorWithRed:0.12f green:0.95f blue:0.35f alpha:1.0f].CGColor,
                                                          [UIColor blackColor].CGColor, 0.8f);
            g_hostedPUBGHealthKnockedLayer = makeBatchShape([UIColor colorWithRed:1.0f green:0.20f blue:0.15f alpha:1.0f].CGColor,
                                                            [UIColor blackColor].CGColor, 0.8f);

            // CAShapeLayer draws inside its own bounds; a freshly created layer
            // has a zero rect and silently rasterises nothing even with a valid
            // path. The batch layers span the whole overlay so every projected
            // box / skeleton / snapline point lands on-screen.
            CGRect batchBounds = g_hostedLayer.bounds;
            CAShapeLayer *const batchLayers[] = {
                g_hostedPUBGBoxAliveLayer, g_hostedPUBGBoxKnockedLayer,
                g_hostedPUBGSkeletonAliveLayer, g_hostedPUBGSkeletonKnockedLayer,
                g_hostedPUBGLineAliveLayer, g_hostedPUBGLineKnockedLayer,
                g_hostedPUBGHealthBgLayer, g_hostedPUBGHealthAliveLayer,
                g_hostedPUBGHealthKnockedLayer
            };
            for (CAShapeLayer *batchLayer : batchLayers) {
                if (batchLayer && !CGRectEqualToRect(batchLayer.frame, batchBounds)) {
                    batchLayer.frame = batchBounds;
                }
            }

            for (int i = 0; i < kDSPUBGMaxPlayers; i++) {
                // Every property below is constant for the lifetime of the
                // layer. Writing them from the frame loop was pure raster churn.
                CATextLayer *info = [CATextLayer layer];
                info.actions = noAnim;
                info.contentsScale = scale;
                info.alignmentMode = kCAAlignmentCenter;
                info.wrapped = YES;
                info.fontSize = 10.0;
                info.font = (__bridge CFTypeRef)[UIFont boldSystemFontOfSize:10.0];
                info.foregroundColor = [UIColor whiteColor].CGColor;
                info.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.80].CGColor;
                info.cornerRadius = 2.0f;
                info.borderWidth = 0.5f;
                info.borderColor = [UIColor colorWithWhite:0.25 alpha:0.8].CGColor;
                info.shadowColor = [UIColor blackColor].CGColor;
                info.shadowOpacity = 0.0f;
                info.shadowRadius = 0.0f;
                info.shadowOffset = CGSizeZero;
                info.hidden = YES;
                [g_hostedLayer addSublayer:info];
                g_hostedPUBGInfoLabels[i] = info;

                CATextLayer *wLabel = [CATextLayer layer];
                wLabel.actions = noAnim;
                wLabel.contentsScale = scale;
                wLabel.alignmentMode = kCAAlignmentCenter;
                wLabel.fontSize = 9.0;
                wLabel.font = (__bridge CFTypeRef)[UIFont boldSystemFontOfSize:9.0];
                wLabel.foregroundColor = [UIColor whiteColor].CGColor;
                wLabel.shadowColor = [UIColor blackColor].CGColor;
                wLabel.shadowOpacity = 0.0f;
                wLabel.shadowRadius = 0.0f;
                wLabel.shadowOffset = CGSizeZero;
                wLabel.hidden = YES;
                [g_hostedLayer addSublayer:wLabel];
                g_hostedPUBGWeaponLabels[i] = wLabel;

                CAShapeLayer *arrow = [CAShapeLayer layer];
                arrow.actions = noAnim;
                arrow.contentsScale = scale;
                arrow.fillColor = UIColor.clearColor.CGColor;  // hollow outline
                arrow.lineJoin = kCALineJoinMiter;
                arrow.hidden = YES;
                [g_hostedLayer addSublayer:arrow];
                g_hostedPUBGArrowLayers[i] = arrow;

                CATextLayer *arrowText = [CATextLayer layer];
                arrowText.actions = noAnim;
                arrowText.contentsScale = scale;
                arrowText.alignmentMode = kCAAlignmentCenter;
                arrowText.fontSize = 8.5;
                arrowText.font = (__bridge CFTypeRef)[UIFont monospacedDigitSystemFontOfSize:8.5 weight:UIFontWeightHeavy];
                arrowText.shadowColor = [UIColor blackColor].CGColor;
                arrowText.shadowOpacity = 0.0f;
                arrowText.shadowRadius = 0.0f;
                arrowText.shadowOffset = CGSizeZero;
                arrowText.hidden = YES;
                [g_hostedLayer addSublayer:arrowText];
                g_hostedPUBGArrowTextLayers[i] = arrowText;
            }

            for (int i = 0; i < kDSPUBGMaxItems; i++) {
                CATextLayer *itemLbl = [CATextLayer layer];
                itemLbl.actions = noAnim;
                itemLbl.contentsScale = scale;
                itemLbl.alignmentMode = kCAAlignmentCenter;
                itemLbl.wrapped = NO;
                itemLbl.font = (__bridge CFTypeRef)[UIFont systemFontOfSize:8.5 weight:UIFontWeightBold];
                itemLbl.fontSize = 8.5;
                itemLbl.shadowColor = UIColor.blackColor.CGColor;
                itemLbl.shadowRadius = 0.0;
                itemLbl.shadowOpacity = 0.0;
                itemLbl.shadowOffset = CGSizeZero;
                itemLbl.backgroundColor = UIColor.clearColor.CGColor;
                itemLbl.cornerRadius = 0.0;
                itemLbl.foregroundColor = UIColor.whiteColor.CGColor;
                itemLbl.hidden = YES;
                [g_hostedLayer addSublayer:itemLbl];
                g_hostedPUBGItemLabels[i] = itemLbl;
            }

            for (int i = 0; i < kDSPUBGMaxGrenades; i++) {
                CAShapeLayer *traj = [CAShapeLayer layer];
                traj.actions = noAnim;
                traj.contentsScale = scale;
                traj.fillColor = UIColor.clearColor.CGColor;
                traj.lineCap = kCALineCapRound;
                traj.lineJoin = kCALineJoinRound;
                traj.lineWidth = 2.0;
                traj.hidden = YES;
                [g_hostedLayer addSublayer:traj];
                g_hostedPUBGGrenadeTrajLayers[i] = traj;

                CAShapeLayer *circOut = [CAShapeLayer layer];
                circOut.actions = noAnim;
                circOut.contentsScale = scale;
                circOut.fillColor = UIColor.clearColor.CGColor;
                circOut.lineCap = kCALineCapRound;
                circOut.lineJoin = kCALineJoinRound;
                circOut.lineWidth = 1.8;
                circOut.hidden = YES;
                [g_hostedLayer addSublayer:circOut];
                g_hostedPUBGGrenadeCircleLayers[i] = circOut;

                CAShapeLayer *circMid = [CAShapeLayer layer];
                circMid.actions = noAnim;
                circMid.contentsScale = scale;
                circMid.fillColor = UIColor.clearColor.CGColor;
                circMid.hidden = YES;
                [g_hostedLayer addSublayer:circMid];
                g_hostedPUBGGrenadeCircleMidLayers[i] = circMid;

                CAShapeLayer *circIn = [CAShapeLayer layer];
                circIn.actions = noAnim;
                circIn.contentsScale = scale;
                circIn.fillColor = UIColor.clearColor.CGColor;
                circIn.hidden = YES;
                [g_hostedLayer addSublayer:circIn];
                g_hostedPUBGGrenadeCircleInnerLayers[i] = circIn;

                CAShapeLayer *dropLine = [CAShapeLayer layer];
                dropLine.actions = noAnim;
                dropLine.contentsScale = scale;
                dropLine.fillColor = UIColor.clearColor.CGColor;
                dropLine.lineCap = kCALineCapRound;
                dropLine.lineJoin = kCALineJoinRound;
                dropLine.lineWidth = 1.6;
                dropLine.hidden = YES;
                [g_hostedLayer addSublayer:dropLine];
                g_hostedPUBGGrenadeDropLineLayers[i] = dropLine;

                // Container for Distinct Throwable 3D Markers (32x32 pt)
                CALayer *markerContainer = [CALayer layer];
                markerContainer.actions = noAnim;
                markerContainer.contentsScale = scale;
                markerContainer.bounds = CGRectMake(0, 0, 32.0, 32.0);
                markerContainer.hidden = YES;

                // --- 1. FRAG GRENADE GROUP (Lựu Đạn: Circular bomb with dynamic yellow-to-red countdown) ---
                CALayer *fragGroup = [CALayer layer];
                fragGroup.actions = noAnim;
                fragGroup.contentsScale = scale;
                fragGroup.frame = CGRectMake(0, 0, 32.0, 32.0);

                CALayer *fusePin = [CALayer layer];
                fusePin.actions = noAnim;
                fusePin.contentsScale = scale;
                fusePin.frame = CGRectMake(20.5, 2.5, 5.0, 5.5);
                fusePin.cornerRadius = 1.0;
                fusePin.backgroundColor = [UIColor colorWithRed:0.85f green:1.0f blue:0.20f alpha:1.0f].CGColor;
                [fragGroup addSublayer:fusePin];

                CALayer *circleBody = [CALayer layer];
                circleBody.actions = noAnim;
                circleBody.contentsScale = scale;
                circleBody.frame = CGRectMake(5.0, 5.0, 22.0, 22.0);
                circleBody.cornerRadius = 11.0;
                circleBody.masksToBounds = YES;
                circleBody.backgroundColor = [UIColor colorWithRed:1.0f green:0.95f blue:0.05f alpha:1.0f].CGColor;
                [fragGroup addSublayer:circleBody];
                g_hostedPUBGGrenadeMarkerBgLayers[i] = circleBody;

                CALayer *redFill = [CALayer layer];
                redFill.actions = noAnim;
                redFill.contentsScale = scale;
                redFill.backgroundColor = [UIColor colorWithRed:0.95f green:0.08f blue:0.08f alpha:1.0f].CGColor;
                redFill.frame = CGRectMake(0, 22.0, 22.0, 0);
                [circleBody addSublayer:redFill];
                g_hostedPUBGGrenadeMarkerFillLayers[i] = redFill;

                CAShapeLayer *borderLayer = [CAShapeLayer layer];
                borderLayer.actions = noAnim;
                borderLayer.contentsScale = scale;
                UIBezierPath *bPath = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(5.0, 5.0, 22.0, 22.0)];
                borderLayer.path = bPath.CGPath;
                borderLayer.fillColor = UIColor.clearColor.CGColor;
                borderLayer.strokeColor = UIColor.whiteColor.CGColor;
                borderLayer.lineWidth = 1.6;
                [fragGroup addSublayer:borderLayer];

                CAShapeLayer *shineLayer = [CAShapeLayer layer];
                shineLayer.actions = noAnim;
                shineLayer.contentsScale = scale;
                UIBezierPath *sPath = [UIBezierPath bezierPath];
                [sPath addArcWithCenter:CGPointMake(16.0, 16.0) radius:8.5 startAngle:3.4 endAngle:4.3 clockwise:YES];
                shineLayer.path = sPath.CGPath;
                shineLayer.fillColor = UIColor.clearColor.CGColor;
                shineLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
                shineLayer.lineWidth = 1.8;
                shineLayer.lineCap = kCALineCapRound;
                [fragGroup addSublayer:shineLayer];
                [markerContainer addSublayer:fragGroup];
                g_hostedPUBGGrenadeFragLayers[i] = fragGroup;

                // --- 2. SMOKE GRENADE GROUP (Bom Khói: Canister with cyan/white band) ---
                CALayer *smokeGroup = [CALayer layer];
                smokeGroup.actions = noAnim;
                smokeGroup.contentsScale = scale;
                smokeGroup.frame = CGRectMake(0, 0, 32.0, 32.0);
                smokeGroup.hidden = YES;

                CALayer *smkCap = [CALayer layer];
                smkCap.actions = noAnim;
                smkCap.contentsScale = scale;
                smkCap.frame = CGRectMake(12.0, 3.5, 8.0, 4.0);
                smkCap.cornerRadius = 1.5;
                smkCap.backgroundColor = [UIColor colorWithWhite:0.88 alpha:1.0].CGColor;
                [smokeGroup addSublayer:smkCap];

                CALayer *smkBody = [CALayer layer];
                smkBody.actions = noAnim;
                smkBody.contentsScale = scale;
                smkBody.frame = CGRectMake(8.0, 7.0, 16.0, 21.0);
                smkBody.cornerRadius = 3.5;
                smkBody.masksToBounds = YES;
                smkBody.backgroundColor = [UIColor colorWithRed:0.22f green:0.28f blue:0.35f alpha:0.95f].CGColor;

                CALayer *smkStripe = [CALayer layer];
                smkStripe.actions = noAnim;
                smkStripe.contentsScale = scale;
                smkStripe.frame = CGRectMake(0, 7.0, 16.0, 6.5);
                smkStripe.backgroundColor = [UIColor colorWithRed:0.0f green:0.85f blue:0.90f alpha:1.0f].CGColor;
                [smkBody addSublayer:smkStripe];
                [smokeGroup addSublayer:smkBody];

                CAShapeLayer *smkBorder = [CAShapeLayer layer];
                smkBorder.actions = noAnim;
                smkBorder.contentsScale = scale;
                UIBezierPath *smkPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(8.0, 7.0, 16.0, 21.0) cornerRadius:3.5];
                smkBorder.path = smkPath.CGPath;
                smkBorder.fillColor = UIColor.clearColor.CGColor;
                smkBorder.strokeColor = UIColor.whiteColor.CGColor;
                smkBorder.lineWidth = 1.4;
                [smokeGroup addSublayer:smkBorder];

                CATextLayer *smkText = [CATextLayer layer];
                smkText.actions = noAnim;
                smkText.contentsScale = scale;
                smkText.alignmentMode = kCAAlignmentCenter;
                smkText.fontSize = 7.5;
                smkText.font = (__bridge CFTypeRef)[UIFont monospacedDigitSystemFontOfSize:7.5 weight:UIFontWeightHeavy];
                smkText.foregroundColor = UIColor.whiteColor.CGColor;
                smkText.frame = CGRectMake(7.0, 15.0, 18.0, 10.0);
                smkText.string = @"SMK";
                [smokeGroup addSublayer:smkText];
                [markerContainer addSublayer:smokeGroup];
                g_hostedPUBGGrenadeSmokeLayers[i] = smokeGroup;

                // --- 3. BURN / MOLOTOV GROUP (Bom Lửa: Glass bottle with bright fire flames) ---
                CALayer *burnGroup = [CALayer layer];
                burnGroup.actions = noAnim;
                burnGroup.contentsScale = scale;
                burnGroup.frame = CGRectMake(0, 0, 32.0, 32.0);
                burnGroup.hidden = YES;

                CAShapeLayer *flameLayer = [CAShapeLayer layer];
                flameLayer.actions = noAnim;
                flameLayer.contentsScale = scale;
                UIBezierPath *flamePath = [UIBezierPath bezierPath];
                [flamePath moveToPoint:CGPointMake(16.0, 2.0)];
                [flamePath addCurveToPoint:CGPointMake(20.5, 8.5) controlPoint1:CGPointMake(19.0, 4.0) controlPoint2:CGPointMake(21.0, 6.5)];
                [flamePath addCurveToPoint:CGPointMake(16.0, 10.0) controlPoint1:CGPointMake(20.0, 10.0) controlPoint2:CGPointMake(18.0, 10.0)];
                [flamePath addCurveToPoint:CGPointMake(11.5, 8.5) controlPoint1:CGPointMake(14.0, 10.0) controlPoint2:CGPointMake(12.0, 10.0)];
                [flamePath addCurveToPoint:CGPointMake(16.0, 2.0) controlPoint1:CGPointMake(11.0, 6.5) controlPoint2:CGPointMake(13.0, 4.0)];
                flameLayer.path = flamePath.CGPath;
                flameLayer.fillColor = [UIColor colorWithRed:1.0f green:0.45f blue:0.0f alpha:1.0f].CGColor;
                flameLayer.strokeColor = [UIColor colorWithRed:1.0f green:0.90f blue:0.10f alpha:1.0f].CGColor;
                flameLayer.lineWidth = 1.0;
                [burnGroup addSublayer:flameLayer];

                CALayer *bNeck = [CALayer layer];
                bNeck.actions = noAnim;
                bNeck.contentsScale = scale;
                bNeck.frame = CGRectMake(13.5, 9.5, 5.0, 5.0);
                bNeck.backgroundColor = [UIColor colorWithRed:0.50f green:0.25f blue:0.05f alpha:0.9f].CGColor;
                [burnGroup addSublayer:bNeck];

                CALayer *bBody = [CALayer layer];
                bBody.actions = noAnim;
                bBody.contentsScale = scale;
                bBody.frame = CGRectMake(9.0, 14.0, 14.0, 14.5);
                bBody.cornerRadius = 3.0;
                bBody.masksToBounds = YES;
                bBody.backgroundColor = [UIColor colorWithRed:0.40f green:0.18f blue:0.04f alpha:0.95f].CGColor;

                CALayer *bLiquid = [CALayer layer];
                bLiquid.actions = noAnim;
                bLiquid.contentsScale = scale;
                bLiquid.frame = CGRectMake(0, 5.0, 14.0, 9.5);
                bLiquid.backgroundColor = [UIColor colorWithRed:1.0f green:0.55f blue:0.0f alpha:0.95f].CGColor;
                [bBody addSublayer:bLiquid];
                [burnGroup addSublayer:bBody];

                CAShapeLayer *bBorder = [CAShapeLayer layer];
                bBorder.actions = noAnim;
                bBorder.contentsScale = scale;
                UIBezierPath *bBPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(9.0, 14.0, 14.0, 14.5) cornerRadius:3.0];
                bBorder.path = bBPath.CGPath;
                bBorder.fillColor = UIColor.clearColor.CGColor;
                bBorder.strokeColor = UIColor.whiteColor.CGColor;
                bBorder.lineWidth = 1.3;
                [burnGroup addSublayer:bBorder];
                [markerContainer addSublayer:burnGroup];
                g_hostedPUBGGrenadeBurnLayers[i] = burnGroup;

                // --- 4. STUN GRENADE GROUP (Bom Choáng: Silver-blue canister with flash icon) ---
                CALayer *stunGroup = [CALayer layer];
                stunGroup.actions = noAnim;
                stunGroup.contentsScale = scale;
                stunGroup.frame = CGRectMake(0, 0, 32.0, 32.0);
                stunGroup.hidden = YES;

                CALayer *stnCap = [CALayer layer];
                stnCap.actions = noAnim;
                stnCap.contentsScale = scale;
                stnCap.frame = CGRectMake(12.0, 3.5, 8.0, 4.0);
                stnCap.cornerRadius = 1.5;
                stnCap.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1.0].CGColor;
                [stunGroup addSublayer:stnCap];

                CALayer *stnBody = [CALayer layer];
                stnBody.actions = noAnim;
                stnBody.contentsScale = scale;
                stnBody.frame = CGRectMake(8.5, 7.0, 15.0, 21.0);
                stnBody.cornerRadius = 3.0;
                stnBody.masksToBounds = YES;
                stnBody.backgroundColor = [UIColor colorWithRed:0.30f green:0.38f blue:0.52f alpha:0.95f].CGColor;

                CALayer *stnStripe = [CALayer layer];
                stnStripe.actions = noAnim;
                stnStripe.contentsScale = scale;
                stnStripe.frame = CGRectMake(0, 6.0, 15.0, 8.0);
                stnStripe.backgroundColor = [UIColor colorWithRed:0.75f green:0.80f blue:0.90f alpha:1.0f].CGColor;
                [stnBody addSublayer:stnStripe];
                [stunGroup addSublayer:stnBody];

                CAShapeLayer *stnBorder = [CAShapeLayer layer];
                stnBorder.actions = noAnim;
                stnBorder.contentsScale = scale;
                UIBezierPath *stnPath = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(8.5, 7.0, 15.0, 21.0) cornerRadius:3.0];
                stnBorder.path = stnPath.CGPath;
                stnBorder.fillColor = UIColor.clearColor.CGColor;
                stnBorder.strokeColor = UIColor.whiteColor.CGColor;
                stnBorder.lineWidth = 1.4;
                [stunGroup addSublayer:stnBorder];

                CATextLayer *stnText = [CATextLayer layer];
                stnText.actions = noAnim;
                stnText.contentsScale = scale;
                stnText.alignmentMode = kCAAlignmentCenter;
                stnText.fontSize = 8.5;
                stnText.font = (__bridge CFTypeRef)[UIFont boldSystemFontOfSize:8.5];
                stnText.foregroundColor = [UIColor colorWithRed:1.0f green:0.85f blue:0.10f alpha:1.0f].CGColor;
                stnText.frame = CGRectMake(6.0, 14.5, 20.0, 11.0);
                stnText.string = @"⚡";
                [stunGroup addSublayer:stnText];
                [markerContainer addSublayer:stunGroup];
                g_hostedPUBGGrenadeStunLayers[i] = stunGroup;

                [g_hostedLayer addSublayer:markerContainer];
                g_hostedPUBGGrenadeMarkerLayers[i] = markerContainer;

                CAShapeLayer *box = [CAShapeLayer layer];
                box.actions = noAnim;
                box.contentsScale = scale;
                box.fillColor = UIColor.clearColor.CGColor;
                box.lineCap = kCALineCapRound;
                box.lineJoin = kCALineJoinRound;
                box.lineWidth = 1.3;
                box.hidden = YES;
                [g_hostedLayer addSublayer:box];
                g_hostedPUBGGrenadeBoxLayers[i] = box;

                CATextLayer *gLbl = [CATextLayer layer];
                gLbl.actions = noAnim;
                gLbl.contentsScale = scale;
                gLbl.alignmentMode = kCAAlignmentCenter;
                gLbl.wrapped = NO;
                gLbl.shadowColor = UIColor.blackColor.CGColor;
                gLbl.shadowRadius = 0.0;
                gLbl.shadowOpacity = 0.0;
                gLbl.hidden = YES;
                [g_hostedLayer addSublayer:gLbl];
                g_hostedPUBGGrenadeLabels[i] = gLbl;
            }

            CATextLayer *dangerBanner = [CATextLayer layer];
            dangerBanner.actions = noAnim;
            dangerBanner.contentsScale = scale;
            dangerBanner.alignmentMode = kCAAlignmentCenter;
            dangerBanner.wrapped = NO;
            dangerBanner.hidden = YES;
            [g_hostedLayer addSublayer:dangerBanner];
            g_hostedPUBGGrenadeDangerBanner = dangerBanner;

            CAShapeLayer *topBg = [CAShapeLayer layer];
            topBg.actions = noAnim;
            topBg.contentsScale = scale;
            topBg.fillColor = [UIColor colorWithRed:12/255.0 green:15/255.0 blue:24/255.0 alpha:0.88].CGColor;
            topBg.lineWidth = 1.2;
            topBg.hidden = YES;
            [g_hostedLayer addSublayer:topBg];
            g_hostedPUBGTopCountBgLayer = topBg;

            CATextLayer *topLabel = [CATextLayer layer];
            topLabel.actions = noAnim;
            topLabel.contentsScale = scale;
            topLabel.alignmentMode = kCAAlignmentCenter;
            topLabel.fontSize = 10.5;
            topLabel.font = (__bridge CFTypeRef)[UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightHeavy];
            topLabel.foregroundColor = [UIColor colorWithRed:255.0/255.0 green:59.0/255.0 blue:48.0/255.0 alpha:1.0].CGColor;
            topLabel.backgroundColor = UIColor.clearColor.CGColor;
            topLabel.shadowColor = UIColor.blackColor.CGColor;
            topLabel.shadowRadius = 0.0;
            topLabel.shadowOpacity = 0.0;
            topLabel.shadowOffset = CGSizeZero;
            topLabel.hidden = YES;
            [g_hostedLayer addSublayer:topLabel];
            g_hostedPUBGTopCountLabel = topLabel;
        }

    g_hostedLayerReady.store(true, std::memory_order_release);
    ds_hosted_overlay_start_display_link();
    g_hostedContextId = contextId;
    g_hostedLastOrientation = 0;  // force the first transform update
    return contextId;
}

static void ds_hosted_overlay_frame(void) {
    static CFAbsoluteTime s_lastMenuEnsureAt = 0;
    static CFAbsoluteTime s_lastIdleTickAt = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - s_lastMenuEnsureAt >= 1.0) {
        s_lastMenuEnsureAt = now;
        ds_hosted_menu_ensure();
        if (g_hostedLayerReady.load(std::memory_order_acquire) &&
            g_hostedContextId && !g_hostedRemoteController) {
            ds_hosted_overlay_register(g_hostedContextId);
        }
    }
    if (!g_hostedLayerReady.load(std::memory_order_acquire)) {
        if (now - g_hostedLastSetupTryAt >= 2.0) {
            g_hostedLastSetupTryAt = now;
            dispatch_async(dispatch_get_main_queue(), ^{
                unsigned contextId = ds_hosted_overlay_setup_on_main();
                if (contextId) {
                    dispatch_async(ds_bridge_queue(), ^{
                        ds_hosted_overlay_register(contextId);
                    });
                }
            });
        }
        return;
    }

    // While waiting for PUBG to launch or sitting outside an active match
    // (splash/lobby), poll at ~5 Hz instead of spinning 60 Hz in background.
    if (!ds_pubg_has_active_match() && (now - s_lastIdleTickAt < 0.18)) {
        return;
    }
    s_lastIdleTickAt = now;

    DSHostedRenderSnapshot snapshot = {};
    ds_pubg_tick();
    snapshot.pubgRenderSourceReady = ds_pubg_has_render_source();
    g_hostedPushedFrames++;
    ds_hosted_publish_render_snapshot(snapshot);
}

static void ds_hosted_overlay_start(void) {
    if (g_hostedTimer) return;
    g_hostedLastSetupTryAt = 0;
    os_unfair_lock_lock(&g_hostedSnapshotLock);
    g_hostedSnapshots[0] = {};
    g_hostedSnapshots[1] = {};
    g_hostedPublishedSnapshot = -1;
    g_hostedSnapshotGeneration = 0;
    g_hostedConsumedGeneration = 0;
    g_hostedFallbackApplyQueued = NO;
    ++g_hostedFallbackToken;
    os_unfair_lock_unlock(&g_hostedSnapshotLock);
    g_hostedLastDisplayLinkTick.store(0.0, std::memory_order_relaxed);
    g_hostedDisplayPulse.store(0, std::memory_order_release);
    g_hostedConsumedDisplayPulse = UINT64_MAX;
    [NSUserDefaults.standardUserDefaults setInteger:1 forKey:@"active_game"];
    [NSUserDefaults.standardUserDefaults synchronize];
    ds_pubg_overlay_reset();
    dispatch_async(dispatch_get_main_queue(), ^{
        unsigned contextId = ds_hosted_overlay_setup_on_main();
        unsigned menuContextId = ds_hosted_menu_setup_on_main();
        if (g_hostedMenuWindow) {
            g_hostedMenuWindow.hidden = NO;
        }
        if (g_hostedMenuViewController) {
            [g_hostedMenuViewController dsApplyOrientation];
        }
        if (contextId || menuContextId) {
            dispatch_async(ds_bridge_queue(), ^{
                if (contextId) ds_hosted_overlay_register(contextId);
                if (menuContextId) ds_hosted_menu_register(menuContextId);
                if (g_hostedTimer) {
                    uint32_t targetFPS = MIN(MAX(
                        g_hostedMaximumFrameRate.load(std::memory_order_acquire),
                        30u), 60u);
                    dispatch_source_set_timer(
                        g_hostedTimer, DISPATCH_TIME_NOW,
                        (uint64_t)(NSEC_PER_SEC / targetFPS),
                        1 * NSEC_PER_MSEC);
                }
            });
        }
    });
    g_hostedTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                           ds_bridge_queue());
    uint32_t targetFPS = MIN(MAX(
        g_hostedMaximumFrameRate.load(std::memory_order_acquire), 30u), 60u);
    dispatch_source_set_timer(g_hostedTimer, DISPATCH_TIME_NOW,
                              (uint64_t)(NSEC_PER_SEC / targetFPS),
                              1 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_hostedTimer, ^{
        @autoreleasepool {
            if (g_hostedLayerReady.load(std::memory_order_acquire)) {
                uint64_t pulse = g_hostedDisplayPulse.load(std::memory_order_acquire);
                if (pulse == g_hostedConsumedDisplayPulse) {
                    double lastTick = g_hostedLastDisplayLinkTick.load(
                        std::memory_order_relaxed);
                    if (lastTick > 0.0 &&
                        CACurrentMediaTime() - lastTick <= 0.025) {
                        return;
                    }
                } else {
                    g_hostedConsumedDisplayPulse = pulse;
                }
            }
            if (!g_hostedPubgFramePending.exchange(true, std::memory_order_acq_rel)) {
                ds_hosted_overlay_frame();
                g_hostedPubgFramePending.store(false, std::memory_order_release);
            }
        }
    });
    dispatch_resume(g_hostedTimer);
}

// Pause rendering without dropping the local window/CAContext or the
// SpringBoard-side registration: the next enable is then fully local
// (one-shot channel design). Every ESP layer is hidden so the hosted window
// commits one transparent frame before the display link stops.
static void ds_hosted_overlay_pause(void) {
    if (g_hostedTimer) {
        dispatch_source_cancel(g_hostedTimer);
        g_hostedTimer = nil;
    }
    os_unfair_lock_lock(&g_hostedSnapshotLock);
    g_hostedSnapshots[0] = {};
    g_hostedSnapshots[1] = {};
    g_hostedPublishedSnapshot = -1;
    g_hostedSnapshotGeneration = 0;
    g_hostedConsumedGeneration = 0;
    g_hostedFallbackApplyQueued = NO;
    ++g_hostedFallbackToken;
    os_unfair_lock_unlock(&g_hostedSnapshotLock);
    g_hostedLastDisplayLinkTick.store(0.0, std::memory_order_relaxed);
    g_hostedDisplayPulse.store(0, std::memory_order_release);
    g_hostedConsumedDisplayPulse = UINT64_MAX;
    g_hostedLastOrientation = 0;
    g_hostedMenuLastOrientation = 0;
    ds_pubg_overlay_reset();
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_hostedDisplayLink invalidate];
        g_hostedDisplayLink = nil;
        g_hostedDisplayLinkDriver = nil;
        ds_hosted_menu_set_expanded(NO);
        g_hostedMenuWindow.hidden = YES;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        ds_hosted_pubg_hide_all();
        [CATransaction commit];
    });
}

static void ds_hosted_overlay_stop(void) {
    if (g_hostedTimer) {
        dispatch_source_cancel(g_hostedTimer);
        g_hostedTimer = nil;
    }
    g_hostedRemoteController = 0;
    g_hostedMenuRemoteController = 0;
    g_hostedMenuLastSetupTryAt = 0;
    g_hostedMenuLastRegisterTryAt = 0;
    g_hostedMenuLastOrientation = 0;
    g_hostedSBPid = 0;
    g_hostedLayerReady.store(false, std::memory_order_release);
    os_unfair_lock_lock(&g_hostedSnapshotLock);
    g_hostedSnapshots[0] = {};
    g_hostedSnapshots[1] = {};
    g_hostedPublishedSnapshot = -1;
    g_hostedSnapshotGeneration = 0;
    g_hostedConsumedGeneration = 0;
    g_hostedFallbackApplyQueued = NO;
    ++g_hostedFallbackToken;
    os_unfair_lock_unlock(&g_hostedSnapshotLock);
    g_hostedLastDisplayLinkTick.store(0.0, std::memory_order_relaxed);
    g_hostedDisplayPulse.store(0, std::memory_order_release);
    g_hostedConsumedDisplayPulse = UINT64_MAX;
    g_hostedLastOrientation = 0;
    g_hostedMenuLastOrientation = 0;
    ds_pubg_overlay_reset();
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_hostedDisplayLink invalidate];
        g_hostedDisplayLink = nil;
        g_hostedDisplayLinkDriver = nil;
        g_hostedWindow.hidden = YES;
        g_hostedWindow = nil;   // drops the window + its hosted context
        g_hostedESPView = nil;
        g_hostedLayer = nil;
        g_hostedMenuWindow.hidden = YES;
        g_hostedMenuWindow = nil;
        g_hostedMenuViewController = nil;
        g_hostedMenuContextId = 0;
        g_hostedMenuExpanded = NO;
        g_hostedPortraitNotchHeight = 0.0;
        g_hostedContentBounds = CGRectNull;
    });
}

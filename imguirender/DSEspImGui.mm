//
//  DSEspImGui.mm
//  Renderer ESP bằng Dear ImGui + Metal, chạy trong process overlay
//  `DarkSpeed -espgui <shmPath>` (xem imguirender/DSEspImGui.h).
//
//  Toàn bộ file này là MỘT translation unit có chứa implementation của ImGui
//  (include imgui*.cpp) để khỏi phải thêm 5 file vào Xcode target. ImGui core
//  không phụ thuộc UIKit nên include .cpp ở đây là hợp lệ.
//
//  Luồng 1 frame:
//    1. CADisplayLink (main runloop) -> tick.
//    2. ESPRsShmRead() lấy frame mới nhất app vừa publish (memcpy, không lock,
//       không remote call).
//    3. ESPImGuiAppendFrame() biến commands thành ImGui background draw list
//       (map toạ độ landscape -> cửa sổ overlay, cull NaN/ngoài màn hình).
//    4. ImGui::Render() -> ImGui_ImplMetal_RenderDrawData() vào drawable của
//       CAMetalLayer rồi present. 1 command buffer/frame, không IPC.
//
//  So với renderer cũ (RemoteCall dựng CAShapeLayer/UILabel trong SpringBoard):
//  không còn chục remote call + performSelector trên main thread của
//  SpringBoard mỗi frame — đó là nguồn watchdog 0x8badf00d/respring.
//

// PHẢI định nghĩa trước khi bất kỳ header ImGui nào được include: imgui.cpp
// include imgui_internal.h và nó #error nếu imgui.h đã được include từ trước
// mà thiếu define này (chính là lỗi build CI đầu tiên: "Please
// '#define IMGUI_DEFINE_MATH_OPERATORS' _BEFORE_ including imgui.h").
#define IMGUI_DEFINE_MATH_OPERATORS 1

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <notify.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdlib.h>

#import "DSEspImGui.h"
#import "../sources/HUDMainWindow.h"
#import "../headers/UIWindow+Private.h"
#include "../ESP/ESPRenderShm.h"
#include "../ESP/ESPRenderImGuiDraw.h"

// ---- Dear ImGui (implementation trong chính TU này) ------------------------
#include "../Vendor/imgui/imgui.cpp"
#include "../Vendor/imgui/imgui_draw.cpp"
#include "../Vendor/imgui/imgui_tables.cpp"
#include "../Vendor/imgui/imgui_widgets.cpp"
#include "../Vendor/imgui/backends/imgui_impl_metal.mm"

static const double kDSESPWindowLevel = 10000010.0;
// Renderer tự thoát nếu app ngừng publish quá lâu (app bị kill/tắt ESP) để
// không để lại một process overlay nằm trên game mãi.
static const double kDSESPStaleExitSeconds = 8.0;
static const double kDSESPFadeSeconds = 0.25;

#pragma mark - Metal host view

@interface DSEspMetalView : UIView
@end

@implementation DSEspMetalView

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (BOOL)isOpaque {
    return NO;
}

@end

#pragma mark - Renderer

@interface DSEspGuiRenderer : NSObject
- (instancetype)initWithShmPath:(NSString *)shmPath;
- (UIView *)hostView;
- (BOOL)start;
- (void)stop;
@end

@implementation DSEspGuiRenderer {
    NSString *_shmPath;
    DSEspMetalView *_view;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    CAMetalLayer *_layer;
    CADisplayLink *_link;
    ESPRsShm *_shm;
    ESPRsFrame _frame;
    ImFont *_font;
    CGFloat _scale;
    CFTimeInterval _lastTick;
    CFTimeInterval _lastPublish;
    uint64_t _frames;
    uint64_t _drawnFrames;
    uint64_t _lastFrameId;
    // Đã vẽ 1 frame trong suốt sau khi ESP tắt -> nghỉ vẽ (không đốt GPU 60Hz
    // chỉ để clear một layer rỗng).
    BOOL _hiddenCleared;
}

- (instancetype)initWithShmPath:(NSString *)shmPath {
    if ((self = [super init])) {
        _shmPath = [shmPath copy];
        _scale = 1.0;
    }
    return self;
}

- (UIView *)hostView {
    if (_view) return _view;
    _view = [[DSEspMetalView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _view.backgroundColor = [UIColor clearColor];
    _view.userInteractionEnabled = NO;
    _view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _layer = (CAMetalLayer *)_view.layer;
    _layer.opaque = NO;
    _layer.framebufferOnly = YES;
    _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _layer.backgroundColor = CGColorGetConstantColor(kCGColorClear);
    return _view;
}

- (BOOL)start {
    if (_link) return YES;

    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        os_log_error(OS_LOG_DEFAULT, "[ESPImGui] no Metal device");
        return NO;
    }
    _queue = [_device newCommandQueue];
    [self hostView];
    _layer.device = _device;

    if (!_shmPath.length) {
        os_log_error(OS_LOG_DEFAULT, "[ESPImGui] missing shm path");
        return NO;
    }
    _shm = ESPRsShmOpen(_shmPath.fileSystemRepresentation);
    if (!_shm) {
        os_log_error(OS_LOG_DEFAULT, "[ESPImGui] cannot map %{public}@",
                     _shmPath);
        return NO;
    }

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = NULL; // overlay: không ghi imgui.ini
    io.LogFilename = NULL;
    io.DisplaySize = ImVec2(1, 1);
    ImFontConfig cfg;
    cfg.SizePixels = 13.0f;
    _font = io.Fonts->AddFontDefault(&cfg);
    if (!ImGui_ImplMetal_Init(_device)) {
        os_log_error(OS_LOG_DEFAULT, "[ESPImGui] ImGui_ImplMetal_Init failed");
        ImGui::DestroyContext();
        ESPRsShmClose(_shm);
        _shm = NULL;
        return NO;
    }

    _lastTick = CACurrentMediaTime();
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

    os_log(OS_LOG_DEFAULT, "[ESPImGui] started shm=%{public}@ size=%zu",
           _shmPath, ESPRsShmSize());
    return YES;
}

- (void)stop {
    if (_link) {
        [_link invalidate];
        _link = nil;
    }
    if (_shm) {
        ESPRsShmClose(_shm);
        _shm = NULL;
    }
    if (ImGui::GetCurrentContext()) {
        ImGui_ImplMetal_Shutdown();
        ImGui::DestroyContext();
    }
}

- (void)tick:(CADisplayLink *)link {
    @autoreleasepool {
        [self renderFrame];
    }
}

- (void)renderFrame {
    if (!_shm || !_layer || !_device) return;

    CGSize size = _view.bounds.size;
    if (size.width < 8.0 || size.height < 8.0) return;
    CGFloat scale = _view.window.screen.scale ?: UIScreen.mainScreen.scale;
    if (scale <= 0.0) scale = 1.0;
    _scale = scale;
    CGSize drawableSize = CGSizeMake(round(size.width * scale), round(size.height * scale));
    if (!CGSizeEqualToSize(_layer.drawableSize, drawableSize)) {
        _layer.drawableSize = drawableSize;
        _layer.frame = _view.bounds;
        _layer.contentsScale = scale;
    }

    // ---- đọc frame mới nhất (1 memcpy, không lock) ----
    ESPRsFrame frame;
    BOOL fresh = ESPRsShmRead(_shm, &frame);
    CFTimeInterval now = CACurrentMediaTime();
    if (fresh && frame.publishTime > 0.0) {
        _lastPublish = now;
        _lastFrameId = frame.frameId;
        _frame = frame;
    } else if (_lastPublish == 0.0) {
        _lastPublish = now; // chưa frame nào: cho watchdog chạy từ lúc start
    }

    // App chết / tắt ESP mà không kịp kill: tự thoát.
    if (_lastPublish > 0.0 && (now - _lastPublish) > kDSESPStaleExitSeconds) {
        os_log(OS_LOG_DEFAULT, "[ESPImGui] stale %.1fs -> exit (frames=%llu)",
               now - _lastPublish, (unsigned long long)_frames);
        [self stop];
        exit(0);
    }
    BOOL visible = (_frame.flags & ESP_RSHM_FLAG_VISIBLE) != 0 && _frame.cmdCount > 0;

    // ESP tắt: hạ nhịp display link và chỉ vẽ đúng 1 frame trong suốt để xoá
    // hình cũ, sau đó nghỉ hẳn cho tới khi có frame mới.
    NSInteger wantFps = visible ? 60 : 5;
    if (_link.preferredFramesPerSecond != wantFps) {
        _link.preferredFramesPerSecond = wantFps;
    }
    if (!visible) {
        if (_hiddenCleared) return;
        _hiddenCleared = YES;
    } else {
        _hiddenCleared = NO;
    }

    id<CAMetalDrawable> drawable = [_layer nextDrawable];
    if (!drawable) return; // không có drawable (màn hình tắt/đang chuyển app)

    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)size.width, (float)size.height);
    io.DisplayFramebufferScale = ImVec2((float)scale, (float)scale);
    double dt = now - _lastTick;
    if (dt <= 0.0 || dt > 0.25) dt = 1.0 / 60.0;
    io.DeltaTime = (float)dt;
    _lastTick = now;

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = drawable.texture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);

    id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();
    if (visible) {
        ESPImGuiAppendFrame(ImGui::GetBackgroundDrawList(), &_frame,
                            (float)size.width, (float)size.height, _font);
    }
    ImGui::Render();

    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, encoder);
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];

    _frames++;
    if (visible) _drawnFrames++;
    if ((_frames % 600) == 0) {
        os_log(OS_LOG_DEFAULT, "[ESPImGui] frames=%llu drawn=%llu frameId=%llu cmds=%u pts=%u",
               (unsigned long long)_frames, (unsigned long long)_drawnFrames,
               (unsigned long long)_lastFrameId, _frame.cmdCount, _frame.pointCount);
    }
}

@end

#pragma mark - App delegate

@implementation DSEspGuiAppDelegate {
    DSEspGuiRenderer *_renderer;
    id _windowHostingController;
    BOOL _terminating;
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;

    UIWindow *window = [[HUDMainWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    _renderer = [[DSEspGuiRenderer alloc] initWithShmPath:self.shmPath ?: @""];
    UIView *host = [_renderer hostView];
    host.frame = root.view.bounds;
    [root.view addSubview:host];
    window.rootViewController = root;
    window.windowLevel = kDSESPWindowLevel;
    window.backgroundColor = [UIColor clearColor];
    window.hidden = NO;
    [window makeKeyAndVisible];
    self.window = window;

    // Đăng ký với SpringBoard để cửa sổ nổi trên game (giống HUD -hud).
    // kernrw84: nếu đăng ký thất bại (không đủ quyền, ví dụ child được spawn
    // không có persona root) thì exit ngay — cửa sổ nền không hiển thị được,
    // process còn lại thì tick render cũng chạy mà không ai nhìn thấy.
    BOOL hostingOk = NO;
    @try {
        Class hosting = objc_getClass("SBSAccessibilityWindowHostingController");
        if (hosting) {
            _windowHostingController = [[hosting alloc] init];
            unsigned int contextId = (unsigned int)[window _contextId];
            double level = window.windowLevel;
            NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:_windowHostingController];
            [inv setSelector:NSSelectorFromString(@"registerWindowWithContextID:atLevel:")];
            [inv setArgument:&contextId atIndex:2];
            [inv setArgument:&level atIndex:3];
            [inv invoke];
            hostingOk = YES;
        } else {
            os_log_error(OS_LOG_DEFAULT, "[ESPImGui] SBSAccessibilityWindowHostingController not available");
        }
    } @catch (NSException *e) {
        os_log_error(OS_LOG_DEFAULT, "[ESPImGui] hosting register failed: %{public}@", e.reason);
    }

    if (!hostingOk) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ exit(0); });
        return NO;
    }

    if (![_renderer start]) {
        os_log_error(OS_LOG_DEFAULT, "[ESPImGui] renderer start failed -> exit");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ exit(0); });
        return YES;
    }

    // App bảo tắt HUD (SetHUDEnabled(NO)): fade rồi thoát như HUD -hud.
    int token = 0;
    notify_register_dispatch(NOTIFY_DISMISSAL_HUD, &token, dispatch_get_main_queue(), ^(int t) {
        notify_cancel(t);
        if (self->_terminating) return;
        self->_terminating = YES;
        [UIView animateWithDuration:kDSESPFadeSeconds animations:^{
            self.window.alpha = 0.0;
        } completion:^(BOOL finished) {
            (void)finished;
            [self->_renderer stop];
            exit(0);
        }];
    });

    return YES;
}

@end

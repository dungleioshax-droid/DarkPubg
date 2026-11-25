#import "MadnessMenuView.h"

/* Injected into host apps. DemoHost attaches explicitly — skip ctor there. */
__attribute__((constructor))
static void MadnessMenu_Load(void) {
    if ([NSProcessInfo.processInfo.arguments containsObject:@"-AutoPreview"]) return;
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.example.MadnessMenuDemo"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^tryAttach)(void) = ^{
            UIWindow *win = nil;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) { win = w; break; }
                }
                if (!win && ws.windows.count) win = ws.windows.firstObject;
                if (win) break;
            }
            if (!win) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                win = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
            }
            if (win) (void)[MadnessMenuView attachToWindow:win];
        };
        tryAttach();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), tryAttach);
    });
}

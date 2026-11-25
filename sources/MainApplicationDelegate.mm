//
//  MainApplicationDelegate.mm
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import "MainApplicationDelegate.h"
#import "MainApplication.h"
#import "RootViewController.h"

#import "HUDHelper.h"
#import "DSBridge.h"
#import "JetsamHelper.h"
#import "DSTheme.h"

@implementation MainApplicationDelegate {
    RootViewController *_rootViewController;
}

- (instancetype)init {
    self = [super init];
    return self;
}

- (BOOL)application:(UIApplication *)application openURL:(nonnull NSURL *)url options:(nonnull NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options
{
    if ([url.scheme isEqualToString:@"darkpubg"]) {
        if ([url.host isEqualToString:@"toggle"]) {
            [self setupAndNotifyToggleHUDAfterLaunchWithAction:nil];
            return YES;
        } else if ([url.host isEqualToString:@"on"]) {
            [self setupAndNotifyToggleHUDAfterLaunchWithAction:kToggleHUDAfterLaunchNotificationActionToggleOn];
            return YES;
        } else if ([url.host isEqualToString:@"off"]) {
            [self setupAndNotifyToggleHUDAfterLaunchWithAction:kToggleHUDAfterLaunchNotificationActionToggleOff];
            return YES;
        }
    }
    return NO;
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Tear down the RemoteCall channel — restores/exits the hijacked
    // SpringBoard thread before our ports die with the process; otherwise
    // SpringBoard crashes on the next exception round trip and the device
    // resprings.
    DSBridgeTeardownForTermination();
}

- (void)application:(UIApplication *)application performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL succeeded))completionHandler
{
    if ([shortcutItem.type isEqualToString:@"ch.xxtou.shortcut.toggle-hud"])
    {
        [self setupAndNotifyToggleHUDAfterLaunchWithAction:nil];
    }
}

- (void)setupAndNotifyToggleHUDAfterLaunchWithAction:(NSString *)action
{
    [RootViewController setShouldToggleHUDAfterLaunch:YES];
    if (action) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kToggleHUDAfterLaunchNotificationName object:nil userInfo:@{
            kToggleHUDAfterLaunchNotificationActionKey: action,
        }];
    } else {
        [[NSNotificationCenter defaultCenter] postNotificationName:kToggleHUDAfterLaunchNotificationName object:nil];
    }
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary <UIApplicationLaunchOptionsKey, id> *)launchOptions {
    _rootViewController = [[RootViewController alloc] init];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    // Opaque window — do not inherit TrollStore HUD transparency.
    self.window.backgroundColor = DSColorInk();
    self.window.opaque = YES;
    [self.window setRootViewController:_rootViewController];
    [self.window makeKeyAndVisible];

    // This process owns the hijacked SpringBoard thread + exception ports.
    // If jetsam kills it under pressure (hours of ESP page pins grow our
    // footprint), SpringBoard keeps a dangling hijack and the next exception
    // hangs it → watchdog panic. Stay jetsam-resistant so that never happens.
    // Non-critical: never crash if the sysctl is denied.
    BypassJetsamByProcess(getpid(), NO);

    // Trigger network access immediately and prepare the current build's
    // kernelcache in the sandbox. The privileged chain still starts only when
    // the user enables the HUD.
    DSBridgeWarmUpNetworkAndPrefetchKernelCache();

    return YES;
}

- (UIInterfaceOrientationMask)application:(UIApplication *)application
        supportedInterfaceOrientationsForWindow:(UIWindow *)window
{
    (void)application;
    (void)window;
    return UIInterfaceOrientationMaskPortrait;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    BypassJetsamByProcess(getpid(), NO);
    if (DSBridgeHUDEnabled() || DSBridgeIsRunning()) {
        DSBridgeStartKeepalive();
    }
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    BypassJetsamByProcess(getpid(), NO);
    if (DSBridgeHUDEnabled()) {
        DSBridgeStartKeepalive();
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf->_rootViewController reloadMainButtonState];
    });
}

@end

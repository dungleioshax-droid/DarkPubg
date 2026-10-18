//
//  MainApplicationDelegate.mm
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import "MainApplicationDelegate.h"
#import "MainApplication.h"
#import "RootViewController.h"
#import "ESPSettingsViewController.h"
#import "ESPSettingsViewController.mm"

#import "HUDHelper.h"
#import "DSBridge.h"

@implementation MainApplicationDelegate {
    RootViewController *_rootViewController;
}

- (instancetype)init {
    if (self = [super init]) {
        log_debug(OS_LOG_DEFAULT, "- [MainApplicationDelegate init]");
    }
    return self;
}

- (BOOL)application:(UIApplication *)application openURL:(nonnull NSURL *)url options:(nonnull NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options
{
    if ([url.scheme isEqualToString:@"darkspeed"]) {
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
    log_debug(OS_LOG_DEFAULT, "- [MainApplicationDelegate application:%{public}@ didFinishLaunchingWithOptions:%{public}@]", application, launchOptions);

    _rootViewController = [[RootViewController alloc] init];
    _rootViewController.title = @"Trang chủ";
    _rootViewController.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Trang chủ" image:[UIImage systemImageNamed:@"house.fill"] selectedImage:[UIImage systemImageNamed:@"house.fill"]];

    ESPSettingsViewController *settingsViewController = [[ESPSettingsViewController alloc] init];
    settingsViewController.title = @"Cài đặt";
    settingsViewController.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Cài đặt" image:[UIImage systemImageNamed:@"slider.horizontal.3"] selectedImage:[UIImage systemImageNamed:@"slider.horizontal.3"]];

    UITabBarController *tabBarController = [[UITabBarController alloc] init];
    tabBarController.viewControllers = @[_rootViewController, settingsViewController];

    UIColor *tabBarBg = [UIColor colorWithRed:16/255.0 green:18/255.0 blue:26/255.0 alpha:1.0];
    UIColor *accentColor = [UIColor colorWithRed:16/255.0 green:185/255.0 blue:170/255.0 alpha:1.0];
    UIColor *unselectedColor = [UIColor colorWithRed:100/255.0 green:116/255.0 blue:139/255.0 alpha:1.0];

    tabBarController.tabBar.tintColor = accentColor;
    tabBarController.tabBar.unselectedItemTintColor = unselectedColor;
    tabBarController.tabBar.barTintColor = tabBarBg;

    if (@available(iOS 15.0, *)) {
        UITabBarAppearance *appearance = [[UITabBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = tabBarBg;
        appearance.shadowColor = [UIColor colorWithRed:31/255.0 green:35/255.0 blue:46/255.0 alpha:1.0];

        appearance.stackedLayoutAppearance.selected.iconColor = accentColor;
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = @{NSForegroundColorAttributeName: accentColor};
        appearance.stackedLayoutAppearance.normal.iconColor = unselectedColor;
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = @{NSForegroundColorAttributeName: unselectedColor};

        tabBarController.tabBar.standardAppearance = appearance;
        tabBarController.tabBar.scrollEdgeAppearance = appearance;
    }

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor colorWithRed:13/255.0 green:15/255.0 blue:20/255.0 alpha:1.0];
    self.window.opaque = YES;
    [self.window setRootViewController:tabBarController];
    [self.window makeKeyAndVisible];

    DSBridgeWarmUpNetworkAndPrefetchKernelCache();

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    log_debug(OS_LOG_DEFAULT, "- [MainApplicationDelegate applicationDidBecomeActive:%{public}@]", application);

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf->_rootViewController reloadMainButtonState];
    });
}

@end

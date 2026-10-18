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
    _rootViewController.title = @"Home";
    _rootViewController.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Home" image:[UIImage systemImageNamed:@"house.fill"] selectedImage:[UIImage systemImageNamed:@"house.fill"]];

    // Settings tab: hosts TSSettingsController inline
    UIViewController *settingsHost = [[UIViewController alloc] init];
    settingsHost.title = @"Settings";
    settingsHost.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Settings" image:[UIImage systemImageNamed:@"gear"] selectedImage:[UIImage systemImageNamed:@"gear"]];
    settingsHost.view.backgroundColor = [UIColor colorWithRed:8/255.0 green:12/255.0 blue:24/255.0 alpha:1.0];

    UITabBarController *tabBarController = [[UITabBarController alloc] init];
    tabBarController.viewControllers = @[_rootViewController, settingsHost];
    tabBarController.delegate = self;

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor colorWithRed:8/255.0 green:12/255.0 blue:24/255.0 alpha:1.0];
    self.window.opaque = YES;
    [self.window setRootViewController:tabBarController];
    [self.window makeKeyAndVisible];

    DSBridgeWarmUpNetworkAndPrefetchKernelCache();

    return YES;
}

- (void)tabBarController:(UITabBarController *)tabBarController didSelectViewController:(UIViewController *)viewController {
    if (viewController != _rootViewController) {
        TSSettingsController *settingsViewController = [[TSSettingsController alloc] init];
        settingsViewController.delegate = _rootViewController;
        settingsViewController.alreadyLaunched = [_rootViewController isHUDEnabled];

        SPLarkTransitioningDelegate *transitioningDelegate = [[SPLarkTransitioningDelegate alloc] init];
        settingsViewController.transitioningDelegate = transitioningDelegate;
        settingsViewController.modalPresentationStyle = UIModalPresentationCustom;
        settingsViewController.modalPresentationCapturesStatusBarAppearance = YES;

        [tabBarController presentViewController:settingsViewController animated:YES completion:^{
            tabBarController.selectedIndex = 0;
        }];
    }
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

//
//  DSEspImGui.h
//  Delegate cho process overlay ImGui (`DarkSpeed -espgui <shmPath>`).
//
//  Process này là chính binary DarkSpeed nhưng chạy ở chế độ UIApplication
//  plugin (giống nhánh `-hud` của TrollSpeed): cửa sổ level 10000010 nằm trên
//  mọi app, bên trong là CAMetalLayer + Dear ImGui (Metal backend).
//
//  Nó KHÔNG đụng vào SpringBoard và KHÔNG cần inject dylib — chỉ đọc frame ESP
//  từ vùng shared memory do app ghi (ESP/ESPRenderShm.h).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSEspGuiAppDelegate : NSObject <UIApplicationDelegate>

/// File shared memory chứa frame ESP (đường dẫn do app truyền qua argv[2]).
@property (nonatomic, copy, nullable) NSString *shmPath;

@property (nonatomic, strong, nullable) UIWindow *window;

@end

NS_ASSUME_NONNULL_END

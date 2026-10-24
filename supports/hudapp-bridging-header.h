//
//  hudapp-bridging-header.h
//  TrollSpeed
//
//  Created by Lessica on 2024/1/25.
//

#ifndef hudapp_bridging_header_h
#define hudapp_bridging_header_h

#import <Foundation/Foundation.h>

#import "HUDHelper.h"
#import "DSBridge.h"

typedef NSString * HUDUserDefaultsKey;

static HUDUserDefaultsKey const HUDUserDefaultsKeySelectedMode = @"selectedMode";
static HUDUserDefaultsKey const HUDUserDefaultsKeySelectedModeLandscape = @"selectedModeLandscape";
static HUDUserDefaultsKey const HUDUserDefaultsKeyCurrentPositionY = @"currentPositionY";
static HUDUserDefaultsKey const HUDUserDefaultsKeyCurrentLandscapePositionY = @"currentLandscapePositionY";
static HUDUserDefaultsKey const HUDUserDefaultsKeyPassthroughMode = @"passthroughMode";
static HUDUserDefaultsKey const HUDUserDefaultsKeySingleLineMode = @"singleLineMode";
static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesBitrate = @"usesBitrate";
static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesArrowPrefixes = @"usesArrowPrefixes";
static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesLargeFont = @"usesLargeFont";
static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesRotation = @"usesRotation";
static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesInvertedColor = @"usesInvertedColor";
static HUDUserDefaultsKey const HUDUserDefaultsKeyKeepInPlace = @"keepInPlace";
static HUDUserDefaultsKey const HUDUserDefaultsKeyHideAtSnapshot = @"hideAtSnapshot";
static HUDUserDefaultsKey const HUDUserDefaultsKeyDisplayMode = @"displayMode";

static HUDUserDefaultsKey const HUDUserDefaultsKeyShowBaseGame = @"showBaseGame";
static HUDUserDefaultsKey const HUDUserDefaultsKeyBaseGameName = @"baseGameName";
static HUDUserDefaultsKey const HUDUserDefaultsKeyShowESPBox = @"showESPBox";
// kernrw51: toggles ESP riêng từng thành phần (Kernel-style)
static HUDUserDefaultsKey const HUDUserDefaultsKeyESPShowLine = @"espShowLine";
static HUDUserDefaultsKey const HUDUserDefaultsKeyESPShowName = @"espShowName";
static HUDUserDefaultsKey const HUDUserDefaultsKeyESPShowHealth = @"espShowHealth";
static HUDUserDefaultsKey const HUDUserDefaultsKeyESPShowDistance = @"espShowDistance";
// qblpack: render pack kiểu QBL (TeamID/HeadDot/AIMark/Bones/Scale).
// TeamID/HeadDot/AIMark mặc định ON; Bones/Scale mặc định OFF (đọc thêm bộ nhớ
// mỗi tick nên để user tự bật).
static HUDUserDefaultsKey const HUDUserDefaultsKeyESPShowTeamID = @"espShowTeamID";
static HUDUserDefaultsKey const HUDUserDefaultsKeyESPShowHeadDot = @"espShowHeadDot";
static HUDUserDefaultsKey const HUDUserDefaultsKeyESPShowAIMark = @"espShowAIMark";
static HUDUserDefaultsKey const HUDUserDefaultsKeyESPShowBones = @"espShowBones";
static HUDUserDefaultsKey const HUDUserDefaultsKeyESPESPScale = @"espESPScale";
/// Renderer ESP: YES = Dear ImGui + Metal trong process overlay riêng,
/// NO = renderer QBL cũ (RemoteCall dựng CAShapeLayer trong SpringBoard).
static HUDUserDefaultsKey const HUDUserDefaultsKeyESPImGui = @"espImGui";

static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesCustomFontSize = @"usesCustomFontSize";
static HUDUserDefaultsKey const HUDUserDefaultsKeyRealCustomFontSize = @"realCustomFontSize";
static HUDUserDefaultsKey const HUDUserDefaultsKeyUsesCustomOffset = @"usesCustomOffset";
static HUDUserDefaultsKey const HUDUserDefaultsKeyRealCustomOffsetX = @"realCustomOffsetX";
static HUDUserDefaultsKey const HUDUserDefaultsKeyRealCustomOffsetY = @"realCustomOffsetY";

#endif /* hudapp_bridging_header_h */

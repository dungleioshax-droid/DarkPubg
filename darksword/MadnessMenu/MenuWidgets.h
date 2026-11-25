#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
UIColor *MADPanelFill(void);
UIColor *MADCardFill(void);
UIColor *MADFieldYellow(void);
UIColor *MADBlack50(void);
UIFont  *MADBtnFont(void);
UIFont  *MADItalicFont(CGFloat size);

@interface MenuToggleButton : UIButton
@property (nonatomic) BOOL on;
@property (nonatomic, copy, nullable) void (^onToggle)(BOOL isOn);
- (instancetype)initWithTitle:(NSString *)title frame:(CGRect)frame;
- (instancetype)initWithTitle:(NSString *)title frame:(CGRect)frame italic:(BOOL)italic;
@end

typedef NS_ENUM(NSInteger, MenuSliderDisplay) {
    MenuSliderDisplayRaw = 0,       // %d of (int)value
    MenuSliderDisplayTimes001,      // %d of (int)(value * 0.001)  — sbeebulletlvalueActionmat
    MenuSliderDisplayMinus80,       // %d of (int)(value - 80)     — changeviewvalueActionmat
};

@interface MenuSliderRow : UIView
@property (nonatomic, copy, nullable) void (^onChange)(float);
@property (nonatomic) MenuSliderDisplay displayMode;
@property (nonatomic, copy) NSString *name;
- (instancetype)initWithFrame:(CGRect)frame min:(float)min max:(float)max value:(float)value name:(NSString *)name;
- (void)setSliderValue:(float)v;
@end

@interface MenuYellowField : UITextField
- (instancetype)initWithFrame:(CGRect)frame placeholder:(NSString *)ph;
@end

@interface MenuSectionHeader : UIView
- (instancetype)initWithTitle:(NSString *)title origin:(CGPoint)origin;
@end
NS_ASSUME_NONNULL_END

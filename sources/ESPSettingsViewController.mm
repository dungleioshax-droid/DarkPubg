//
//  ESPSettingsViewController.mm
//  DarkSpeed
//

#import "ESPSettingsViewController.h"
#import "hudapp-bridging-header.h"
#import <notify.h>

static NSString * const kESPSettingsCellReuse = @"ESPSettingsCell";

@interface ESPSettingsCell : UITableViewCell
@property (nonatomic, strong) UIView *iconContainer;
@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, copy) NSString *key;
@end

@implementation ESPSettingsCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:22/255.0 green:25/255.0 blue:34/255.0 alpha:1.0];
        self.contentView.backgroundColor = [UIColor colorWithRed:22/255.0 green:25/255.0 blue:34/255.0 alpha:1.0];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _iconContainer = [[UIView alloc] init];
        _iconContainer.backgroundColor = [UIColor colorWithRed:32/255.0 green:37/255.0 blue:52/255.0 alpha:1.0];
        _iconContainer.layer.cornerRadius = 9.0;
        _iconContainer.layer.masksToBounds = YES;
        _iconContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_iconContainer];

        _iconImageView = [[UIImageView alloc] init];
        _iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        _iconImageView.tintColor = [UIColor colorWithRed:16/255.0 green:185/255.0 blue:170/255.0 alpha:1.0];
        _iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [_iconContainer addSubview:_iconImageView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.textColor = [UIColor colorWithRed:142/255.0 green:152/255.0 blue:168/255.0 alpha:1.0];
        _subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_subtitleLabel];

        _toggle = [[UISwitch alloc] init];
        _toggle.onTintColor = [UIColor colorWithRed:16/255.0 green:185/255.0 blue:170/255.0 alpha:1.0];
        _toggle.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_toggle];

        [NSLayoutConstraint activateConstraints:@[
            [_iconContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_iconContainer.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconContainer.widthAnchor constraintEqualToConstant:34],
            [_iconContainer.heightAnchor constraintEqualToConstant:34],

            [_iconImageView.centerXAnchor constraintEqualToAnchor:_iconContainer.centerXAnchor],
            [_iconImageView.centerYAnchor constraintEqualToAnchor:_iconContainer.centerYAnchor],
            [_iconImageView.widthAnchor constraintEqualToConstant:18],
            [_iconImageView.heightAnchor constraintEqualToConstant:18],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconContainer.trailingAnchor constant:14],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_toggle.leadingAnchor constant:-12],

            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:3],
            [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_toggle.leadingAnchor constant:-12],
            [_subtitleLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],

            [_toggle.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_toggle.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
    }
    return self;
}

@end

@interface ESPSettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSString *> *sectionTitles;
@property (nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *sectionItems;
@property (nonatomic, strong) NSMutableDictionary *userDefaults;
@end

@implementation ESPSettingsViewController

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view.backgroundColor = [UIColor colorWithRed:13/255.0 green:15/255.0 blue:20/255.0 alpha:1.0];
}

- (NSMutableDictionary *)userDefaults {
    if (!_userDefaults) {
        _userDefaults = [[NSMutableDictionary dictionaryWithContentsOfFile:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH))] mutableCopy] ?: [NSMutableDictionary dictionary];
    }
    return _userDefaults;
}

- (void)loadUserDefaults:(BOOL)forceReload {
    if (forceReload || !self.userDefaults) {
        _userDefaults = [[NSMutableDictionary dictionaryWithContentsOfFile:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH))] mutableCopy] ?: [NSMutableDictionary dictionary];
    }
}

- (void)saveUserDefaults {
    [self.userDefaults writeToFile:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH)) atomically:YES];
    notify_post(NOTIFY_RELOAD_HUD);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Cài đặt";

    self.sectionTitles = @[
        @"TÍNH NĂNG HIỂN THỊ (OVERLAY)"
    ];

    NSArray *espItems = @[
        @{
            @"title": @"ESP Box",
            @"subtitle": @"Khung 2D định vị mục tiêu",
            @"key": HUDUserDefaultsKeyShowESPBox,
            @"default": @YES,
            @"icon": @"viewfinder",
            @"iconColor": [UIColor colorWithRed:16/255.0 green:185/255.0 blue:170/255.0 alpha:1.0]
        },
        @{
            @"title": @"ESP Khoảng cách",
            @"subtitle": @"Hiển thị khoảng cách mét (m)",
            @"key": HUDUserDefaultsKeyESPShowDistance,
            @"default": @YES,
            @"icon": @"ruler",
            @"iconColor": [UIColor colorWithRed:56/255.0 green:189/255.0 blue:248/255.0 alpha:1.0]
        },
        @{
            @"title": @"ESP Lượng máu",
            @"subtitle": @"Thanh máu HP còn lại",
            @"key": HUDUserDefaultsKeyESPShowHealth,
            @"default": @YES,
            @"icon": @"heart.fill",
            @"iconColor": [UIColor colorWithRed:244/255.0 green:63/255.0 blue:94/255.0 alpha:1.0]
        },
        @{
            @"title": @"ESP Tên & Bot",
            @"subtitle": @"Tên người chơi hoặc nhãn Bot",
            @"key": HUDUserDefaultsKeyESPShowName,
            @"default": @YES,
            @"icon": @"person.text.rectangle",
            @"iconColor": [UIColor colorWithRed:251/255.0 green:191/255.0 blue:36/255.0 alpha:1.0]
        },
        @{
            @"title": @"ESP Snapline",
            @"subtitle": @"Đường kẻ chỉ hướng tới địch",
            @"key": HUDUserDefaultsKeyESPShowLine,
            @"default": @YES,
            @"icon": @"line.diagonal",
            @"iconColor": [UIColor colorWithRed:168/255.0 green:85/255.0 blue:247/255.0 alpha:1.0]
        },
        @{
            @"title": @"ESP Team ID",
            @"subtitle": @"Hiện số đội (T<id>) trên đầu mục tiêu — kiểu QBL",
            @"key": HUDUserDefaultsKeyESPShowTeamID,
            @"default": @YES,
            @"icon": @"person.3.fill",
            @"iconColor": [UIColor colorWithRed:52/255.0 green:199/255.0 blue:89/255.0 alpha:1.0]
        },
        @{
            @"title": @"ESP Head Dot",
            @"subtitle": @"Chấm đánh dấu đầu mục tiêu — kiểu QBL",
            @"key": HUDUserDefaultsKeyESPShowHeadDot,
            @"default": @YES,
            @"icon": @"circle.fill",
            @"iconColor": [UIColor colorWithRed:255/255.0 green:214/255.0 blue:10/255.0 alpha:1.0]
        },
        @{
            @"title": @"ESP AI Mark",
            @"subtitle": @"Đổi màu box + tam giác cho bot/AI — kiểu QBL",
            @"key": HUDUserDefaultsKeyESPShowAIMark,
            @"default": @YES,
            @"icon": @"exclamationmark.triangle.fill",
            @"iconColor": [UIColor colorWithRed:255/255.0 green:159/255.0 blue:10/255.0 alpha:1.0]
        },
        @{
            @"title": @"ESP Xương (Bones)",
            @"subtitle": @"Skeleton ESP — tự dò offset xương khi bật (đọc thêm bộ nhớ)",
            @"key": HUDUserDefaultsKeyESPShowBones,
            @"default": @NO,
            @"icon": @"figure.walk",
            @"iconColor": [UIColor colorWithRed:90/255.0 green:200/255.0 blue:250/255.0 alpha:1.0]
        },
        @{
            @"title": @"ESP Scale",
            @"subtitle": @"Phóng to khung box 15% quanh tâm — kiểu QBL ESPScale",
            @"key": HUDUserDefaultsKeyESPESPScale,
            @"default": @NO,
            @"icon": @"arrow.up.left.and.arrow.down.right",
            @"iconColor": [UIColor colorWithRed:191/255.0 green:90/255.0 blue:242/255.0 alpha:1.0]
        }
    ];

    self.sectionItems = @[espItems];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.separatorColor = [UIColor colorWithRed:35/255.0 green:39/255.0 blue:54/255.0 alpha:1.0];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    [self.tableView registerClass:[ESPSettingsCell class] forCellReuseIdentifier:kESPSettingsCellReuse];
    [self.view addSubview:self.tableView];

    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self setupHeaderView];
}

- (void)setupHeaderView {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 70)];
    header.backgroundColor = [UIColor clearColor];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"Cấu Hình ESP";
    titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:titleLabel];

    UILabel *subLabel = [[UILabel alloc] init];
    subLabel.text = @"Bật/tắt các thành phần radar và cửa sổ hệ thống";
    subLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    subLabel.textColor = [UIColor colorWithRed:142/255.0 green:152/255.0 blue:168/255.0 alpha:1.0];
    subLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:subLabel];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [titleLabel.topAnchor constraintEqualToAnchor:header.topAnchor constant:12],
        [subLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
    ]];

    self.tableView.tableHeaderView = header;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sectionItems.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sectionItems[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sectionTitles[section];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        header.textLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
        header.textLabel.textColor = [UIColor colorWithRed:100/255.0 green:116/255.0 blue:139/255.0 alpha:1.0];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ESPSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:kESPSettingsCellReuse forIndexPath:indexPath];
    NSDictionary *item = self.sectionItems[indexPath.section][indexPath.row];

    cell.titleLabel.text = item[@"title"];
    cell.subtitleLabel.text = item[@"subtitle"];
    cell.key = item[@"key"];

    NSString *iconName = item[@"icon"];
    if (iconName.length > 0) {
        cell.iconImageView.image = [UIImage systemImageNamed:iconName];
        UIColor *iconColor = item[@"iconColor"];
        if (iconColor) {
            cell.iconImageView.tintColor = iconColor;
        }
    }

    [self loadUserDefaults:NO];
    NSNumber *val = [self.userDefaults objectForKey:item[@"key"]];
    BOOL on = val ? val.boolValue : [item[@"default"] boolValue];
    cell.toggle.on = on;

    [cell.toggle removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];

    return cell;
}

- (void)toggleChanged:(UISwitch *)sender {
    UIView *v = sender;
    while (v && ![v isKindOfClass:[ESPSettingsCell class]]) v = v.superview;
    ESPSettingsCell *cell = (ESPSettingsCell *)v;
    if (!cell) return;

    [self loadUserDefaults:NO];
    [self.userDefaults setObject:@(sender.on) forKey:cell.key];
    [self.userDefaults writeToFile:(JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH)) atomically:YES];
    notify_post(NOTIFY_RELOAD_HUD);
}

@end
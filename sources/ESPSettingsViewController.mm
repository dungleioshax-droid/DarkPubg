//
//  ESPSettingsViewController.mm
//  DarkSpeed
//

#import "ESPSettingsViewController.h"
#import "hudapp-bridging-header.h"

static NSString * const kESPSettingsCellReuse = @"ESPSettingsCell";

@interface ESPSettingsCell : UITableViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, copy) NSString *key;
@end

@implementation ESPSettingsCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_titleLabel];

        _toggle = [[UISwitch alloc] init];
        _toggle.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_toggle];

        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:20],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_toggle.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-20],
            [_toggle.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
    }
    return self;
}

@end

@interface ESPSettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@property (nonatomic, strong) NSMutableDictionary *userDefaults;
@end

@implementation ESPSettingsViewController

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view.backgroundColor = [UIColor colorWithRed:8/255.0 green:12/255.0 blue:24/255.0 alpha:1.0];
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
    self.title = @"Settings";

    self.items = [NSMutableArray array];
    [self.items addObject:@{@"title": @"ESP Box", @"key": HUDUserDefaultsKeyShowESPBox, @"default": @YES}];
    [self.items addObject:@{@"title": @"ESP Line", @"key": HUDUserDefaultsKeyESPShowLine, @"default": @YES}];
    [self.items addObject:@{@"title": @"ESP Name", @"key": HUDUserDefaultsKeyESPShowName, @"default": @YES}];
    [self.items addObject:@{@"title": @"ESP Health", @"key": HUDUserDefaultsKeyESPShowHealth, @"default": @YES}];
    [self.items addObject:@{@"title": @"ESP Distance", @"key": HUDUserDefaultsKeyESPShowDistance, @"default": @YES}];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 52;
    [self.tableView registerClass:[ESPSettingsCell class] forCellReuseIdentifier:kESPSettingsCellReuse];
    [self.view addSubview:self.tableView];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ESPSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:kESPSettingsCellReuse forIndexPath:indexPath];
    NSDictionary *item = self.items[indexPath.row];
    cell.titleLabel.text = item[@"title"];
    cell.key = item[@"key"];

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
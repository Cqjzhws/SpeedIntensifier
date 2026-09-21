//
//  main.m
//  Helium Max — 配置 App
//
#import <UIKit/UIKit.h>
#import "HUD/HUDManager.h"

#define kPrefPath  @"/var/Managed Preferences/mobile/com.local.heliummax.plist"
#define kNotifyKey @"com.local.heliummax.reload"

static NSString *kColors[] = { @"#FFFFFF", @"#00FF00", @"#FF0000", @"#00FFFF",
                               @"#FFFF00", @"#FF00FF", @"#FFA500", @"#000000" };

static NSDictionary *ReadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (d) return d;
    return @{ @"enabled": @YES,
              @"widgets": @[@(5), @(7)],
              @"position": @(1),
              @"fontSize": @(11),
              @"interval": @(1.0),
              @"color": @"#FFFFFF" };
}

static void WriteConfig(NSDictionary *cfg) {
    mkdir("/var/Managed Preferences", 0755);
    mkdir("/var/Managed Preferences/mobile", 0755);
    [cfg writeToFile:kPrefPath atomically:YES];
    notify_post(kNotifyKey.UTF8String);
}

@interface HMVC : UIViewController
@property (strong, nonatomic) UISwitch *swEnabled;
@property (strong, nonatomic) UISegmentedControl *segPos;
@property (strong, nonatomic) UISlider *slFont;
@property (strong, nonatomic) UISlider *slInterval;
@property (strong, nonatomic) UILabel *lblFont, *lblInterval;
@property (strong, nonatomic) UIStackView *colorStack;
@property (strong, nonatomic) NSMutableArray *widgetSwitches;
@property (strong, nonatomic) UITextField *txtText;
@property (copy, nonatomic) NSString *selectedColor;
@end

@implementation HMVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"Helium Max";
    NSDictionary *cfg = ReadConfig();

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Helium Max · 状态栏小组件";
    title.font = [UIFont boldSystemFontOfSize:22];
    title.textAlignment = NSTextAlignmentCenter;

    self.swEnabled = [[UISwitch alloc] init];
    self.swEnabled.on = [cfg[@"enabled"] boolValue];

    self.segPos = [[UISegmentedControl alloc] initWithItems:@[@"左", @"中", @"右"]];
    self.segPos.selectedSegmentIndex = [cfg[@"position"] integerValue];

    self.slFont = [[UISlider alloc] init];
    self.slFont.minimumValue = 8; self.slFont.maximumValue = 24;
    self.slFont.value = [cfg[@"fontSize"] floatValue];
    [self.slFont addTarget:self action:@selector(fontChanged) forControlEvents:UIControlEventValueChanged];
    self.lblFont = [[UILabel alloc] init];
    self.lblFont.font = [UIFont systemFontOfSize:13];

    self.slInterval = [[UISlider alloc] init];
    self.slInterval.minimumValue = 0.5; self.slInterval.maximumValue = 5;
    self.slInterval.value = [cfg[@"interval"] floatValue];
    [self.slInterval addTarget:self action:@selector(intervalChanged) forControlEvents:UIControlEventValueChanged];
    self.lblInterval = [[UILabel alloc] init];
    self.lblInterval.font = [UIFont systemFontOfSize:13];

    [self fontChanged]; [self intervalChanged];

    // 颜色选择
    self.selectedColor = cfg[@"color"] ?: @"#FFFFFF";
    self.colorStack = [[UIStackView alloc] init];
    self.colorStack.axis = UILayoutConstraintAxisHorizontal;
    self.colorStack.spacing = 8;
    self.colorStack.distribution = UIStackViewDistributionFillEqually;
    for (NSString *hex in kColors) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        unsigned int rgb;
        NSScanner *sc = [NSScanner scannerWithString:[hex substringFromIndex:1]];
        [sc scanHexInt:&rgb];
        b.backgroundColor = [UIColor colorWithRed:((rgb>>16)&0xFF)/255.0
                                             green:((rgb>>8)&0xFF)/255.0
                                              blue:(rgb&0xFF)/255.0 alpha:1.0];
        b.layer.cornerRadius = 14;
        b.tag = [hex hash];
        [b addTarget:self action:@selector(colorTapped:) forControlEvents:UIControlEventTouchUpInside];
        if ([hex isEqualToString:self.selectedColor]) b.layer.borderWidth = 3;
        b.layer.borderColor = [UIColor systemBlueColor].CGColor;
        [b.heightAnchor constraintEqualToConstant:28].active = YES;
        [self.colorStack addArrangedSubview:b];
    }

    // Widget 选择
    NSArray *widgets = [HMWidget allWidgets];
    NSArray *selected = cfg[@"widgets"] ?: @[];
    self.widgetSwitches = [NSMutableArray array];
    NSMutableArray *widgetRows = [NSMutableArray array];
    for (NSDictionary *w in widgets) {
        HMWidgetID wid = (HMWidgetID)[w[@"id"] integerValue];
        UIView *row = [[UIView alloc] init];
        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = [NSString stringWithFormat:@"%@ — %@", w[@"name"], w[@"desc"]];
        lbl.font = [UIFont systemFontOfSize:14];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [selected containsObject:@(wid)];
        sw.tag = wid;
        [self.widgetSwitches addObject:sw];
        UIStackView *sv = [[UIStackView alloc] initWithArrangedSubviews:@[lbl, sw]];
        sv.axis = UILayoutConstraintAxisHorizontal;
        sv.alignment = UIStackViewAlignmentCenter;
        sv.distribution = UIStackViewDistributionEqualSpacing;
        sv.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:sv];
        [NSLayoutConstraint activateConstraints:@[
            [sv.topAnchor constraintEqualToAnchor:row.topAnchor],
            [sv.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
            [sv.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [sv.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        ]];
        [widgetRows addObject:row];
    }

    // 自定义文本
    self.txtText = [[UITextField alloc] init];
    self.txtText.placeholder = @"自定义文本（选了「自定义文本」widget 时显示）";
    self.txtText.borderStyle = UITextBorderStyleRoundedRect;
    self.txtText.text = cfg[@"customText"] ?: @"";

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setTitle:@"保存并应用" forState:UIControlStateNormal];
    save.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    save.backgroundColor = [UIColor systemBlueColor];
    [save setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    save.layer.cornerRadius = 12;
    [save.heightAnchor constraintEqualToConstant:48].active = YES;
    [save addTarget:self action:@selector(onSave) forControlEvents:UIControlEventTouchUpInside];

    UILabel *hint = [[UILabel alloc] init];
    hint.text = @"HUD 浮在状态栏上，App 进入后台后继续显示。修改后点保存即时生效。";
    hint.font = [UIFont systemFontOfSize:12];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.numberOfLines = 0;
    hint.textAlignment = NSTextAlignmentCenter;

    NSMutableArray *arranged = [NSMutableArray arrayWithObjects:
        title, [self row:@"启用 HUD" ctrl:self.swEnabled],
        [self row:@"位置" ctrl:self.segPos],
        [self row:self.lblFont ctrl:self.slFont],
        [self row:self.lblInterval ctrl:self.slInterval],
        [self label:@"文字颜色" size:15], self.colorStack,
        [self label:@"选择小组件（可多选）" size:15], nil];
    [arranged addObjectsFromArray:widgetRows];
    [arranged addObjectsFromArray:@[self.txtText, save, hint]];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:arranged];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];
}

- (UIView *)row:(UIView *)left ctrl:(UIView *)right {
    UIStackView *sv = [[UIStackView alloc] initWithArrangedSubviews:@[left, right]];
    sv.axis = UILayoutConstraintAxisHorizontal;
    sv.alignment = UIStackViewAlignmentCenter;
    sv.distribution = UIStackViewDistributionEqualSpacing;
    return sv;
}

- (UILabel *)label:(NSString *)t size:(CGFloat)s {
    UILabel *l = [[UILabel alloc] init];
    l.text = t; l.font = [UIFont boldSystemFontOfSize:s];
    return l;
}

- (void)fontChanged {
    self.lblFont.text = [NSString stringWithFormat:@"字体大小（%.0f）", self.slFont.value];
}
- (void)intervalChanged {
    self.lblInterval.text = [NSString stringWithFormat:@"刷新间隔（%.1fs）", self.slInterval.value];
}

- (void)colorTapped:(UIButton *)sender {
    for (UIView *v in self.colorStack.arrangedSubviews) {
        if ([v isKindOfClass:[UIButton class]]) ((UIButton *)v).layer.borderWidth = 0;
    }
    sender.layer.borderWidth = 3;
    for (NSString *hex in kColors) {
        if ([hex hash] == sender.tag) { self.selectedColor = hex; break; }
    }
}

- (void)onSave {
    NSMutableArray *selected = [NSMutableArray array];
    for (UISwitch *sw in self.widgetSwitches) {
        if (sw.on) [selected addObject:@(sw.tag)];
    }
    NSDictionary *cfg = @{
        @"enabled": @(self.swEnabled.on),
        @"widgets": selected,
        @"position": @(self.segPos.selectedSegmentIndex),
        @"fontSize": @(self.slFont.value),
        @"interval": @(self.slInterval.value),
        @"color": self.selectedColor,
        @"customText": self.txtText.text ?: @"",
    };
    WriteConfig(cfg);
    [[HUDManager shared] reloadConfig];

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"✅ 已保存"
        message:@"HUD 配置已应用" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

@interface HMAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation HMAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    HMVC *vc = [[HMVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    // 启动 HUD
    [[HUDManager shared] start];
    return YES;
}
- (void)applicationDidEnterBackground:(UIApplication *)application {
    // HUD 继续运行（静音音频保活）
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([HMAppDelegate class]));
    }
}

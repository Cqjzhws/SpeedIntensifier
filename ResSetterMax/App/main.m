// ResSetterMax — 分辨率设置器 v1.0.0 (ObjC UIKit, TrollStore)
// 优化增强 haoict ResolutionSetterSwift 1.1:
//   · ObjC 重写（585KB Swift → ~50KB ObjC）
//   · TSRootBinary resset 一体化（写 plist + respring）
//   · 预设分辨率管理 + 自定义 + 恢复 + 当前值显示
//   · canvas_height/canvas_width 机制（IOMobileGraphicsFamily plist）
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <spawn.h>

extern char **environ;

#define PLIST_PATH  @"/var/mobile/Library/Preferences/com.apple.iokit.IOMobileGraphicsFamily.plist"
#define BACKUP_PATH @"/var/tmp/com.ressettermax.backup.plist"

// ---- 预设分辨率 ----
@interface Preset : NSObject
@property (copy, nonatomic) NSString *name;
@property (assign, nonatomic) int height;
@property (assign, nonatomic) int width;
- (instancetype)initWithName:(NSString *)n height:(int)h width:(int)w;
@end
@implementation Preset
- (instancetype)initWithName:(NSString *)n height:(int)h width:(int)w {
    self = [super init]; if (self) { _name = n; _height = h; _width = w; } return self;
}
@end

@interface ResSetterVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (strong, nonatomic) UITableView *tableView;
@property (strong, nonatomic) NSArray<Preset *> *presets;
@property (strong, nonatomic) UITextField *hField;
@property (strong, nonatomic) UITextField *wField;
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ResSetterVC alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

@implementation ResSetterVC

- (void)loadView {
    [super loadView];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"Res Setter Max";

    self.presets = @[
        [[Preset alloc] initWithName:@"iPhone 14 Pro" height:1792 width:828],
        [[Preset alloc] initWithName:@"iPhone 14 Pro Max" height:1971 width:911],
        [[Preset alloc] initWithName:@"紧凑 (更大 UI)" height:1600 width:760],
        [[Preset alloc] initWithName:@"宽松 (更小 UI)" height:2200 width:1000],
    ];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
        case 0: return @"当前分辨率";
        case 1: return @"预设";
        case 2: return @"自定义";
        case 3: return @"操作";
        default: return @"";
    }
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case 0: return 1;
        case 1: return self.presets.count;
        case 2: return 1;
        case 3: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"c"];

    switch (ip.section) {
        case 0: { // 当前
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PLIST_PATH];
            NSInteger h = [d[@"canvas_height"] integerValue];
            NSInteger w = [d[@"canvas_width"] integerValue];
            if (h == 0 && w == 0) {
                c.textLabel.text = @"系统默认 (无自定义)";
                c.detailTextLabel.text = @"";
            } else {
                c.textLabel.text = [NSString stringWithFormat:@"%ld × %ld", (long)w, (long)h];
                c.detailTextLabel.text = @"canvas";
            }
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case 1: { // 预设
            Preset *p = self.presets[ip.row];
            c.textLabel.text = p.name;
            c.detailTextLabel.text = [NSString stringWithFormat:@"%d × %d", p.width, p.height];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        }
        case 2: { // 自定义
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            UIView *container = [[UIView alloc] initWithFrame:CGRectMake(15, 8, tv.bounds.size.width - 30, 60)];
            UILabel *hl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 80, 28)];
            hl.text = @"Height"; hl.font = [UIFont systemFontOfSize:14];
            self.hField = [[UITextField alloc] initWithFrame:CGRectMake(85, 0, 80, 28)];
            self.hField.borderStyle = UITextBorderStyleRoundedRect; self.hField.keyboardType = UIKeyboardTypeNumberPad;
            self.hField.placeholder = @"1792";
            UILabel *wl = [[UILabel alloc] initWithFrame:CGRectMake(180, 0, 80, 28)];
            wl.text = @"Width"; wl.font = [UIFont systemFontOfSize:14];
            self.wField = [[UITextField alloc] initWithFrame:CGRectMake(265, 0, 80, 28)];
            self.wField.borderStyle = UITextBorderStyleRoundedRect; self.wField.keyboardType = UIKeyboardTypeNumberPad;
            self.wField.placeholder = @"828";
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.frame = CGRectMake(360, 0, 60, 28);
            [btn setTitle:@"应用" forState:UIControlStateNormal];
            [btn addTarget:self action:@selector(applyCustom) forControlEvents:UIControlEventTouchUpInside];
            [container addSubview:hl]; [container addSubview:self.hField];
            [container addSubview:wl]; [container addSubview:self.wField];
            [container addSubview:btn];
            c.contentView.bounds = CGRectMake(0, 0, tv.bounds.size.width, 76);
            [c.contentView addSubview:container];
            break;
        }
        case 3: { // 操作
            switch (ip.row) {
                case 0: c.textLabel.text = @"恢复默认"; c.textLabel.textColor = [UIColor systemOrangeColor]; break;
                case 1: c.textLabel.text = @"Respring"; c.textLabel.textColor = [UIColor systemRedColor]; break;
            }
            c.textLabel.textAlignment = NSTextAlignmentCenter;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        }
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    switch (ip.section) {
        case 1: { // 预设
            Preset *p = self.presets[ip.row];
            [self runResset:@[ [NSString stringWithFormat:@"%d", p.height], [NSString stringWithFormat:@"%d", p.width] ]];
            break;
        }
        case 3: { // 操作
            if (ip.row == 0) [self runResset:@[@"restore"]];
            else [self runResset:@[]];
            break;
        }
    }
}

- (void)applyCustom {
    [self.hField resignFirstResponder];
    [self.wField resignFirstResponder];
    int h = [self.hField.text intValue];
    int w = [self.wField.text intValue];
    if (h < 100 || w < 100) {
        [self alert:@"请输入有效的 Height 和 Width (≥100)"];
        return;
    }
    [self runResset:@[ [NSString stringWithFormat:@"%d", h], [NSString stringWithFormat:@"%d", w] ]];
}

- (void)runResset:(NSArray<NSString *> *)args {
    NSString *ressetPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"resset"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:ressetPath]) {
        [self alert:@"resset 二进制未找到"];
        return;
    }
    NSMutableArray *argv = [NSMutableArray arrayWithObject:@"resset"];
    [argv addObjectsFromArray:args];
    char **cargv = (char **)malloc(sizeof(char *) * (argv.count + 1));
    for (NSUInteger i = 0; i < argv.count; i++) {
        cargv[i] = (char *)[argv[i] UTF8String];
    }
    cargv[argv.count] = NULL;
    pid_t pid = 0;
    int err = posix_spawn(&pid, ressetPath.fileSystemRepresentation, NULL, NULL, cargv, environ);
    free(cargv);
    if (err != 0) {
        [self alert:[NSString stringWithFormat:@"启动失败: %s", strerror(err)]];
        return;
    }
    // 弹窗提示即将 respring
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"应用成功"
                                                                message:@"即将重启 SpringBoard..."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:ac animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ac dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

- (void)alert:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.view endEditing:YES];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}

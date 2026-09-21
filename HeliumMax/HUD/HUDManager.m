//
//  HUDManager.m
//  Helium Max — HUD 窗口管理（浮在状态栏 + 定时刷新 + 后台保活）
//
#import "HUDManager.h"
#import <AVFoundation/AVFoundation.h>
#import <notify.h>

#define kPrefPath  @"/var/Managed Preferences/mobile/com.local.heliummax.plist"
#define kNotifyKey @"com.local.heliummax.reload"

@interface HUDWindow : UIWindow
@end
@implementation HUDWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_ignoresHitTest { return YES; }
- (BOOL)_isSecure { return YES; }
@end

@interface HUDManager ()
@property (strong, nonatomic) HUDWindow *hudWindow;
@property (strong, nonatomic) UILabel *label;
@property (strong, nonatomic) NSTimer *timer;
@property (strong, nonatomic) AVAudioPlayer *silentPlayer;
@property (assign, nonatomic) BOOL running;
@end

@implementation HUDManager

+ (instancetype)shared {
    static HUDManager *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[HUDManager alloc] init]; });
    return inst;
}

- (NSDictionary *)config {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    return d ?: @{};
}

- (void)start {
    if (self.running) return;
    self.running = YES;

    // 创建 HUD 窗口，浮在状态栏之上
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat statusH = [UIApplication sharedApplication].statusBarFrame.size.height;
    if (statusH <= 0) statusH = 54; // 刘海屏默认
    self.hudWindow = [[HUDWindow alloc] initWithFrame:CGRectMake(0, 0, sb.size.width, statusH)];
    self.hudWindow.windowLevel = UIWindowLevelStatusBar + 100;
    self.hudWindow.backgroundColor = [UIColor clearColor];
    self.hudWindow.rootViewController = [UIViewController new];
    self.hudWindow.hidden = NO;

    self.label = [[UILabel alloc] initWithFrame:self.hudWindow.bounds];
    self.label.textAlignment = NSTextAlignmentCenter;
    self.label.backgroundColor = [UIColor clearColor];
    [self.hudWindow addSubview:self.label];

    [self reloadConfig];

    // 后台保活：循环播放静音音频
    [self startSilentAudio];

    // 监听配置变化
    int token;
    notify_register_dispatch(kNotifyKey.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
        [self reloadConfig];
    });
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    [self.silentPlayer stop];
    self.silentPlayer = nil;
    self.hudWindow.hidden = YES;
    self.hudWindow = nil;
    self.running = NO;
}

- (void)reloadConfig {
    NSDictionary *cfg = [self config];
    BOOL enabled = [cfg[@"enabled"] boolValue];
    if (!enabled) {
        self.hudWindow.hidden = YES;
        [self.timer invalidate];
        self.timer = nil;
        return;
    }
    self.hudWindow.hidden = NO;

    // 位置
    NSInteger pos = [cfg[@"position"] integerValue]; // 0=左 1=中 2=右
    CGFloat y = 0;
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat statusH = self.hudWindow.frame.size.height;
    if (pos == 0)      self.label.textAlignment = NSTextAlignmentLeft;
    else if (pos == 2) self.label.textAlignment = NSTextAlignmentRight;
    else               self.label.textAlignment = NSTextAlignmentCenter;

    // 字体大小
    CGFloat fontSize = [cfg[@"fontSize"] doubleValue];
    if (fontSize <= 0) fontSize = 11;

    // 颜色
    UIColor *color = [UIColor whiteColor];
    NSString *hex = cfg[@"color"];
    if (hex.length == 7) {
        unsigned int rgb;
        NSScanner *sc = [NSScanner scannerWithString:[hex substringFromIndex:1]];
        [sc scanHexInt:&rgb];
        color = [UIColor colorWithRed:((rgb>>16)&0xFF)/255.0
                                green:((rgb>>8)&0xFF)/255.0
                                 blue:(rgb&0xFF)/255.0
                                alpha:1.0];
    }

    // 选中的 widget 列表
    NSArray *widgetIDs = cfg[@"widgets"];
    if (!widgetIDs.count) widgetIDs = @[@(HMWidgetTime), @(HMWidgetBatteryPct)];

    // 刷新率
    NSTimeInterval interval = [cfg[@"interval"] doubleValue];
    if (interval < 0.5) interval = 1.0;

    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:interval target:self
                                                  selector:@selector(tick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];

    // 立即刷新一次
    self.label.tag = (NSInteger)fontSize;
    objc_setAssociatedObject(self.label, "colorKey", color, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(self.label, "widgetsKey", widgetIDs, OBJC_ASSOCIATION_RETAIN);
    [self tick];
}

- (void)tick {
    UIColor *color = objc_getAssociatedObject(self.label, "colorKey");
    NSArray *widgetIDs = objc_getAssociatedObject(self.label, "widgetsKey");
    CGFloat fontSize = (CGFloat)self.label.tag;
    if (!color) color = [UIColor whiteColor];

    NSMutableAttributedString *full = [[NSMutableAttributedString alloc] init];
    for (NSNumber *n in widgetIDs) {
        HMWidgetID wid = (HMWidgetID)n.integerValue;
        NSAttributedString *s = [HMWidget stringForWidgetID:wid options:nil fontSize:fontSize textColor:color];
        if (s.length) {
            if (full.length) [full appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "]];
            [full appendAttributedString:s];
        }
    }
    self.label.attributedText = full;
}

#pragma mark - 后台保活（静音音频）
- (void)startSilentAudio {
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&err];
    [session setActive:YES error:&err];

    // 生成 1 秒静音 WAV
    NSMutableData *wav = [NSMutableData data];
    int sampleRate = 44100, channels = 1, bits = 16, bytesPerSec = sampleRate * channels * bits / 8;
    int dataSize = sampleRate * channels * bits / 8;
    [wav appendBytes:"RIFF" length:4];
    int riffSize = 36 + dataSize;
    [wav appendBytes:&riffSize length:4];
    [wav appendBytes:"WAVEfmt " length:8];
    int fmtSize = 16; short fmt = 1;
    [wav appendBytes:&fmtSize length:4]; [wav appendBytes:&fmt length:2];
    [wav appendBytes:&channels length:2]; [wav appendBytes:&sampleRate length:4];
    [wav appendBytes:&bytesPerSec length:4];
    short blockAlign = channels * bits / 8;
    [wav appendBytes:&blockAlign length:2]; [wav appendBytes:&bits length:2];
    [wav appendBytes:"data" length:4]; [wav appendBytes:&dataSize length:4];
    void *silence = calloc(dataSize, 1);
    [wav appendBytes:silence length:dataSize];
    free(silence);

    self.silentPlayer = [[AVAudioPlayer alloc] initWithData:wav error:&err];
    self.silentPlayer.numberOfLoops = -1;
    self.silentPlayer.volume = 0;
    [self.silentPlayer prepareToPlay];
    [self.silentPlayer play];
}

@end

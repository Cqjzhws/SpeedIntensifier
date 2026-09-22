// AwemeMax — 抖音(Aweme) 全屏 + 下载 二合一增强插件 v1.0.0
// 合并 AwemeFullScreen.dylib + AwemeDownloadMedia.dylib，纯 ObjC runtime swizzle
// (无 CydiaSubstrate 依赖，TrollStore / TrollFools 注入友好)。
// 针对最新版抖音增强兼容性：
//   · 多候选类名查找 awemeBaseViewController (objc_getClass + 名称列表)
//   · Ivar 直读 + KVC 兜底读取 awe_tabBar / awe_blurView
//   · AVURLAsset -[initWithURL:options:] URL 捕获层下载 (版本无关)
//   · Darwin 通知热重载配置
//   · 仅在 com.ss.iphone.aweme (及关联版本) 进程内激活
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <notify.h>

#define kPrefPath    @"/var/Managed Preferences/mobile/com.local.awememax.plist"
#define kNotifyName  @"com.local.awememax.settingschanged"
#define kAwemeBundle @"com.ss.iphone.aweme"

// ---------- 配置 ----------
static BOOL gEnabled     = YES;
static BOOL gFullScreen  = YES;
static BOOL gDownload    = YES;
static BOOL gMute        = NO;   // 下载后静音（去除音轨音量）
static BOOL gSaveOrigin  = NO;   // 尝试读取抖音 model originUrl 原视频

// URL 捕获
static NSURL *gLastURL = nil;
static NSLock *gURLLock = nil;
static BOOL gDownloading = NO;  // 防止并发下载
static NSLock *gDlLock   = nil;

// ---------- 配置热重载 ----------
static void AMX_reload(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) return;
    gEnabled    = d[@"Enabled"]    ? [d[@"Enabled"] boolValue]    : YES;
    gFullScreen = d[@"FullScreen"] ? [d[@"FullScreen"] boolValue] : YES;
    gDownload   = d[@"Download"]   ? [d[@"Download"] boolValue]   : YES;
    gMute       = d[@"Mute"]       ? [d[@"Mute"] boolValue]       : NO;
    gSaveOrigin = d[@"SaveOrigin"] ? [d[@"SaveOrigin"] boolValue] : NO;
}

static void AMX_notifyCb(CFNotificationCenterRef c, void *o, CFNotificationName n,
                         const void *obj, CFDictionaryRef info) { AMX_reload(); }

static BOOL AMX_isAweme(void) {
    static NSString *bid = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    });
    if ([bid isEqualToString:kAwemeBundle]) return YES;
    // 抖音极速版 / 火山版 / 关联版本
    if ([bid containsString:@"aweme"] || [bid hasPrefix:@"com.ss.iphone.aweme"]) return YES;
    return NO;
}

// ---------- swizzle 工具 ----------
static void AMX_swizzleInstance(Class c, SEL sel, IMP newImp, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

#pragma mark - 全屏模块

// 多候选类名：抖音各版本间 awemeBaseViewController 可能改名
static Class AMX_findBaseVCClass(void) {
    static Class cls = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *names[] = {
            "awemeBaseViewController",
            "AwemeBaseViewController",
            "AWEBaseViewController",
            "AWEBaseVideoViewController",
            "AwemeVideoViewController",
            "AWEHomeVideoController",
            "awemeBaseVideoViewController",
            "AwemeFeedVideoViewController",
            0
        };
        for (int i = 0; names[i]; i++) {
            Class c = objc_getClass(names[i]);
            if (c) { cls = c; break; }
        }
    });
    return cls;
}

// Ivar 直读 + KVC 兜底读取视图
static UIView *AMX_getIvarView(id obj, const char *iname, NSString *kname) {
    if (!obj) return nil;
    UIView *v = nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), iname);
    if (iv) {
        id raw = object_getIvar(obj, iv);
        if ([raw isKindOfClass:[UIView class]]) v = raw;
    }
    if (!v && kname) {
        @try {
            id raw = [obj valueForKey:kname];
            if ([raw isKindOfClass:[UIView class]]) v = raw;
        } @catch (NSException *e) { v = nil; }
    }
    return v;
}

static void (*o_AMX_viewDidLayoutSubviews)(id, SEL);
static void amx_viewDidLayoutSubviews(id self, SEL _cmd) {
    o_AMX_viewDidLayoutSubviews(self, _cmd);
    if (!gEnabled || !gFullScreen || !AMX_isAweme()) return;
    UIView *tb = AMX_getIvarView(self, "awe_tabBar", @"awe_tabBar");
    UIView *bv = AMX_getIvarView(self, "awe_blurView", @"awe_blurView");
    if (tb && !tb.isHidden) tb.hidden = YES;
    if (bv && !bv.isHidden) bv.hidden = YES;
    // 撑满屏幕
    @try {
        UIView *v = [self valueForKey:@"view"];
        if ([v isKindOfClass:[UIView class]]) {
            CGRect sf = [UIScreen mainScreen].bounds;
            if (!CGRectEqualToRect(v.frame, sf)) v.frame = sf;
        }
    } @catch (NSException *e) {}
}

static void (*o_AMX_setFrame)(id, SEL, CGRect);
static void amx_setFrame(id self, SEL _cmd, CGRect f) {
    if (gEnabled && gFullScreen && AMX_isAweme()) {
        f = [UIScreen mainScreen].bounds;
    }
    o_AMX_setFrame(self, _cmd, f);
}

static void AMX_installFullScreen(void) {
    Class c = AMX_findBaseVCClass();
    if (!c) {
        NSLog(@"[AwemeMax] awemeBaseViewController not found, fullscreen disabled");
        return;
    }
    AMX_swizzleInstance(c, @selector(viewDidLayoutSubviews),
                        (IMP)amx_viewDidLayoutSubviews, (IMP *)&o_AMX_viewDidLayoutSubviews);
    // setFrame: 仅当类实现该方法时 swizzle（某些版本 awemeBaseViewController 有自定义 setFrame:）
    AMX_swizzleInstance(c, @selector(setFrame:),
                        (IMP)amx_setFrame, (IMP *)&o_AMX_setFrame);
    NSLog(@"[AwemeMax] fullscreen installed on %s", class_getName(c));
}

#pragma mark - URL 捕获模块

// hook AVURLAsset -[initWithURL:options:] 捕获当前播放 URL (版本无关的公共 API)
static id (*o_AMX_AVURLAsset_initWithURL)(id, SEL, NSURL *, NSDictionary *);
static id amx_AVURLAsset_initWithURL(id self, SEL _cmd, NSURL *url, NSDictionary *opts) {
    if (url) {
        NSString *s = url.scheme;
        if ([s isEqualToString:@"http"] || [s isEqualToString:@"https"]) {
            NSString *ab = url.absoluteString ?: @"";
            // 抖音视频 URL 特征关键字过滤，排除图片等非视频资源
            if ([ab containsString:@"video"] || [ab containsString:@".mp4"] ||
                [ab containsString:@"aweme"] || [ab containsString:@"bytecdn"] ||
                [ab containsString:@"douyin"] || [ab containsString:@"byteimg"] ||
                [ab containsString:@"tos-cn"] || [ab hasSuffix:@".mp4"]) {
                @synchronized(gURLLock) {
                    gLastURL = [url copy];
                }
            }
        }
    }
    return o_AMX_AVURLAsset_initWithURL(self, _cmd, url, opts);
}

static void AMX_installURLCapture(void) {
    Class c = objc_getClass("AVURLAsset");
    if (!c) return;
    AMX_swizzleInstance(c, @selector(initWithURL:options:),
                        (IMP)amx_AVURLAsset_initWithURL, (IMP *)&o_AMX_AVURLAsset_initWithURL);
    NSLog(@"[AwemeMax] URL capture installed on AVURLAsset");
}

// 尝试从当前 VC 层级读取抖音 model 的 origin URL (版本相关，可选增强)
static NSURL *AMX_tryOriginURL(void) {
    if (!gSaveOrigin) return nil;
    UIWindow *kw = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { kw = w; break; }
    }
    if (!kw) return nil;
    UIViewController *vc = kw.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;

    static const char *viewIvars[] = { "aweImageView", "aweContentView",
                                        "awemeImageView", "aweVideoView", 0 };
    static const char *modelIvars[] = { "livePhotoModel", "awemeModel",
                                         "videoModel", "model", 0 };
    static const char *urlKeys[] = { "originUrl", "originURLList", "videoUrl",
                                      "playURL", "downloadURL", "downloadURLList",
                                      "urlList", "endWatermarkDownloadURL", 0 };

    for (int i = 0; viewIvars[i]; i++) {
        Ivar iv = class_getInstanceVariable(object_getClass(vc), viewIvars[i]);
        if (!iv) continue;
        id view = object_getIvar(vc, iv);
        if (![view isKindOfClass:[UIView class]]) continue;
        for (int j = 0; modelIvars[j]; j++) {
            Ivar miv = class_getInstanceVariable(object_getClass(view), modelIvars[j]);
            if (!miv) continue;
            id model = object_getIvar(view, miv);
            if (!model) continue;
            for (int k = 0; urlKeys[k]; k++) {
                @try {
                    id raw = [model valueForKey:@(urlKeys[k])];
                    if ([raw isKindOfClass:[NSURL class]]) return raw;
                    if ([raw isKindOfClass:[NSString class]] && [(NSString *)raw length])
                        return [NSURL URLWithString:raw];
                    if ([raw isKindOfClass:[NSArray class]] && [(NSArray *)raw count] > 0) {
                        id first = raw[0];
                        if ([first isKindOfClass:[NSURL class]]) return first;
                        if ([first isKindOfClass:[NSString class]])
                            return [NSURL URLWithString:first];
                    }
                } @catch (NSException *e) {}
            }
        }
    }
    return nil;
}

#pragma mark - HUD

@interface AMXHUD : NSObject
+ (void)show:(NSString *)s;
+ (void)showProgress:(double)p;
+ (void)showOK:(NSString *)s;
+ (void)showErr:(NSString *)s;
@end

@implementation AMXHUD

+ (UIWindow *)hudWindow {
    static UIWindow *w = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = UIWindowLevelAlert + 100;
        w.backgroundColor = [UIColor clearColor];
        w.userInteractionEnabled = NO;
        UILabel *l = [[UILabel alloc] init];
        l.tag = 9527;
        l.textColor = [UIColor whiteColor];
        l.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.78];
        l.textAlignment = NSTextAlignmentCenter;
        l.font = [UIFont systemFontOfSize:14];
        l.numberOfLines = 0;
        l.layer.cornerRadius = 12;
        l.clipsToBounds = YES;
        [w addSubview:l];
        w.hidden = YES;
    });
    return w;
}

+ (void)_show:(NSString *)s color:(UIColor *)color autoDismiss:(BOOL)ad {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = [self hudWindow];
        UILabel *l = [w viewWithTag:9527];
        l.text = s;
        if (color) l.textColor = color; else l.textColor = [UIColor whiteColor];
        CGSize sz = [s sizeWithAttributes:@{NSFontAttributeName: l.font}];
        CGFloat pad = 24;
        CGRect f = CGRectMake(0, 0, sz.width + pad * 2, sz.height + pad);
        f.origin.x = (w.bounds.size.width  - f.size.width)  / 2;
        f.origin.y = w.bounds.size.height - f.size.height - 80;
        l.frame = f;
        w.hidden = NO;
        l.alpha = 0;
        [UIView animateWithDuration:0.18 animations:^{ l.alpha = 1; }];
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_hide) object:nil];
        if (ad) [self performSelector:@selector(_hide) withObject:nil afterDelay:2.2];
    });
}

+ (void)_hide {
    UIWindow *w = [self hudWindow];
    UILabel *l = [w viewWithTag:9527];
    [UIView animateWithDuration:0.22 animations:^{ l.alpha = 0; }
                     completion:^(BOOL f){ w.hidden = YES; }];
}

+ (void)show:(NSString *)s { [self _show:s color:nil autoDismiss:NO]; }
+ (void)showProgress:(double)p {
    [self _show:[NSString stringWithFormat:@"下载中  %.0f%%", p * 100] color:nil autoDismiss:NO];
}
+ (void)showOK:(NSString *)s  { [self _show:s color:[UIColor systemGreenColor] autoDismiss:YES]; }
+ (void)showErr:(NSString *)s { [self _show:s color:[UIColor systemRedColor]   autoDismiss:YES]; }

@end

#pragma mark - 下载器

@interface AMXDownloader : NSObject <NSURLSessionDownloadDelegate>
- (void)startWithURL:(NSURL *)url mute:(BOOL)mute completion:(void(^)(BOOL))cb;
@end

@implementation AMXDownloader {
    NSURLSession *_session;
    void (^_cb)(BOOL);
    BOOL _mute;
}

- (void)startWithURL:(NSURL *)url mute:(BOOL)mute completion:(void(^)(BOOL))cb {
    _mute = mute;
    _cb   = cb;
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 60;
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    NSURLSessionDownloadTask *t = [_session downloadTaskWithURL:url];
    [AMXHUD show:@"开始下载..."];
    [t resume];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)task
didFinishDownloadingToURL:(NSURL *)loc {
    NSError *e = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"awmx_%@.mp4", [NSUUID UUID].UUIDString]];
    [fm removeItemAtPath:tmp error:nil];
    [fm moveItemAtURL:loc toURL:[NSURL fileURLWithPath:tmp] error:&e];
    if (e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [AMXHUD showErr:@"下载写入失败"];
            [self _done:NO];
        });
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_mute) [self _muteAndSave:tmp];
        else             [self _saveToAlbum:tmp];
    });
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)task
     didWriteData:(int64_t)b
 totalBytesWritten:(int64_t)wb
totalBytesExpectedToWrite:(int64_t)t {
    if (t > 0) {
        double p = (double)wb / (double)t;
        [AMXHUD showProgress:p];
    }
}

- (void)URLSession:(NSURLSession *)session
            task:(NSURLSessionTask *)task
 didCompleteWithError:(NSError *)err {
    if (err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [AMXHUD showErr:[NSString stringWithFormat:@"下载失败：%@",
                            err.localizedDescription ?: @"未知错误"]];
            [self _done:NO];
        });
    }
}

- (void)_muteAndSave:(NSString *)src {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:src]
                                            options:nil];
    AVAssetExportSession *ex = [AVAssetExportSession
        exportSessionWithAsset:asset
                       presetName:AVAssetExportPresetHighestQuality];
    if (!ex) { [self _saveToAlbum:src]; return; }
    // 构造静音 audioMix
    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    NSMutableArray *params = [NSMutableArray array];
    for (AVAssetTrack *t in [asset tracksWithMediaType:AVMediaTypeAudio]) {
        AVMutableAudioMixInputParameters *p =
            [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:t];
        [p setVolume:0 atTime:kCMTimeZero];
        [params addObject:p];
    }
    if (params.count) { mix.inputParameters = params; ex.audioMix = mix; }
    NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"awmx_muted_%@.mp4", [NSUUID UUID].UUIDString]];
    [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
    ex.outputFileType = AVFileTypeMPEG4;
    ex.outputURL = [NSURL fileURLWithPath:out];
    ex.shouldOptimizeForNetworkUse = YES;
    [AMXHUD show:@"静音转码中..."];
    [ex exportAsynchronouslyWithCompletionHandler:^{
        if (ex.status == AVAssetExportSessionStatusCompleted) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self _saveToAlbum:out]; });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ [self _saveToAlbum:src]; });
        }
    }];
}

- (void)_saveToAlbum:(NSString *)path {
    NSURL *furl = [NSURL fileURLWithPath:path];
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus st) {
        if (st != PHAuthorizationStatusAuthorized) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [AMXHUD showErr:@"无相册权限"];
                [self _done:NO];
            });
            return;
        }
        [AMXHUD show:@"保存到相册..."];
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetCreationRequest *r =
                [PHAssetCreationRequest creationRequestForAssetFromVideoAtFileURL:furl];
            r.creationDate = [NSDate date];
        } completionHandler:^(BOOL ok, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) [AMXHUD showOK:@"已保存到相册"];
                else    [AMXHUD showErr:[NSString stringWithFormat:@"保存失败：%@",
                                        err.localizedDescription ?: @"未知错误"]];
                [self _done:ok];
            });
        }];
    }];
}

- (void)_done:(BOOL)ok {
    @synchronized(gDlLock) { gDownloading = NO; }
    if (_cb) _cb(ok);
    _session = nil;
}

@end

#pragma mark - 长按手势

static UILongPressGestureRecognizer *gLongPress = nil;

static void amx_longPress(id self, SEL _cmd, UIGestureRecognizer *g) {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (!gEnabled || !gDownload || !AMX_isAweme()) return;
    @synchronized(gDlLock) {
        if (gDownloading) { [AMXHUD showErr:@"正在下载中，请稍后"]; return; }
        gDownloading = YES;
    }
    NSURL *url = AMX_tryOriginURL();
    if (!url) {
        @synchronized(gURLLock) { url = [gLastURL copy]; }
    }
    if (!url) {
        [AMXHUD showErr:@"未捕获到视频 URL"];
        @synchronized(gDlLock) { gDownloading = NO; }
        return;
    }
    AMXDownloader *d = [[AMXDownloader alloc] init];
    [d startWithURL:url mute:gMute completion:^(BOOL ok){}];
}

static void AMX_installLongPressOnWindow(UIWindow *win) {
    if (!win) return;
    // 单例 target（动态创建的 NSObject 子类，承载 -onLongPress:）
    static NSObject *target = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class c = objc_allocateClassPair([NSObject class], "AMXGTarget", 0);
        if (c) {
            class_addMethod(c, @selector(onLongPress:),
                            (IMP)amx_longPress, "v@:@");
            objc_registerClassPair(c);
            target = [[c alloc] init];
        } else {
            target = [[NSObject alloc] init];  // fallback（不应触发）
        }
    });
    if (gLongPress && [win.gestureRecognizers containsObject:gLongPress]) return;
    if (!gLongPress) {
        gLongPress = [[UILongPressGestureRecognizer alloc]
                       initWithTarget:target action:@selector(onLongPress:)];
        [gLongPress setMinimumPressDuration:0.8];
        [gLongPress setAllowableMovement:30];
    }
    [win addGestureRecognizer:gLongPress];
    NSLog(@"[AwemeMax] long-press installed on %@", NSStringFromClass([win class]));
}

static void AMX_installLongPress(void) {
    UIWindow *kw = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { kw = w; break; }
    }
    if (kw) AMX_installLongPressOnWindow(kw);
    // 监听后续 key window 切换
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIWindowDidBecomeKeyNotification object:nil
                     queue:nil usingBlock:^(NSNotification *n) {
        AMX_installLongPressOnWindow(n.object);
    }];
}

#pragma mark - 入口

static void __attribute__((constructor)) AMX_init(void) {
    if (!AMX_isAweme()) return;  // 仅抖音进程内激活
    gURLLock = [[NSLock alloc] init];
    gDlLock  = [[NSLock alloc] init];
    AMX_reload();
    // Darwin 通知热重载
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, AMX_notifyCb, (__bridge CFStringRef)kNotifyName, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    AMX_installFullScreen();
    AMX_installURLCapture();
    // 长按手势：延迟到 keyWindow 就绪
    dispatch_async(dispatch_get_main_queue(), ^{
        AMX_installLongPress();
    });
    NSLog(@"[AwemeMax v1.0.0] init OK (bundle %@)",
          [[NSBundle mainBundle] bundleIdentifier]);
}

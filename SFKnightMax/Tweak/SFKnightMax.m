// SFKnightMax — 顺丰同城骑士 升级弹窗屏蔽 v1.0.2
// 目标进程: com.sfic.knight (顺丰同城骑士, 仅该 App 激活)
//
// v1.0.2 方案彻底变更 (v1.0.0/v1.0.1 的 NSURLProtocol 网络拦截在该 App 启动期
//   会导致卡死, 已废弃):
//   完全不碰网络栈 —— 不注册 NSURLProtocol, 不 swizzle NSURLSession, 不转发请求。
//   改为在 UI 层 hook -[UIViewController presentViewController:animated:completion:],
//   当被呈现的是"升级弹窗"时直接拦掉 (不调原实现, 仅执行 completion)。
//
//   弹窗识别 (双重):
//     1. 类名启发: presented VC 类名含 update/upgrade
//     2. 文本特征: UIAlertController 的 title/message/按钮标题,
//        或自定义弹窗视图树内 UILabel/UIButton 含强特征词
//        (立即更新/立即升级/发现新版本/新版本发布/升级啦/强制更新...)
//
//   安全性: 全程 @try, 任何异常默认放行; 不命中特征绝不影响正常 present。
//   与动画类 dylib (SIOriginal/SpeedsterTS 也 hook present) 共存时是天然链式
//   调用, 拦截只终止本次 present, 无网络/线程/启动时序风险。
//
// 纯 ObjC runtime, 无 CydiaSubstrate, TrollFools 友好.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kTargetBundle = @"com.sfic.knight";

#pragma mark - 弹窗识别

// 强特征词: 命中任意一个即判定为升级弹窗 (均为升级弹窗专有语料)
static NSArray<NSString *> *SFKStrongWords(void) {
    static NSArray *w;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        w = @[
            @"立即更新", @"立即升级", @"马上更新", @"前去更新", @"去更新",
            @"发现新版本", @"检测到新版本", @"新版本发布", @"有新版本",
            @"版本更新", @"升级啦", @"更新啦", @"强制更新",
            @"请更新到最新版本", @"请升级", @"立即体验新版本"
        ];
    });
    return w;
}

static BOOL SFKTextHit(NSString *s) {
    if (!s || s.length < 2) return NO;
    for (NSString *w in SFKStrongWords()) {
        if ([s rangeOfString:w].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL SFKClassNameHit(NSString *name) {
    if (!name) return NO;
    NSString *n = name.lowercaseString;
    // update/upgrade 类名的 modal VC 基本就是升级弹窗
    return [n containsString:@"update"] || [n containsString:@"upgrade"];
}

#define SFK_MAX_DEPTH 6
#define SFK_MAX_VIEWS 300

static BOOL SFKScanView(UIView *v, int depth, int *count) {
    if (!v || depth > SFK_MAX_DEPTH || (*count)++ > SFK_MAX_VIEWS) return NO;

    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (SFKTextHit(l.text)) return YES;
        if (l.attributedText.length && SFKTextHit(l.attributedText.string)) return YES;
    } else if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        if (SFKTextHit(b.titleLabel.text)) return YES;
        NSAttributedString *as = [b attributedTitleForState:UIControlStateNormal];
        if (as.length && SFKTextHit(as.string)) return YES;
    }

    for (UIView *sub in v.subviews) {
        if (SFKScanView(sub, depth + 1, count)) return YES;
    }
    return NO;
}

static BOOL SFKIsUpdatePopup(UIViewController *vc) {
    if (!vc) return NO;

    // 1. 类名
    if (SFKClassNameHit(NSStringFromClass(vc.class))) return YES;

    // 2a. UIAlertController: 直接读 title/message/actions, 不触碰 view
    if ([vc isKindOfClass:[UIAlertController class]]) {
        UIAlertController *a = (UIAlertController *)vc;
        if (SFKTextHit(a.title) || SFKTextHit(a.message)) return YES;
        for (UIAlertAction *act in a.actions) {
            if (SFKTextHit(act.title)) return YES;
        }
        return NO;
    }

    // 2b. 自定义弹窗: 访问 view 触发 loadView/viewDidLoad 后扫描文本
    @try {
        UIView *root = vc.view;
        if (root) {
            int count = 0;
            if (SFKScanView(root, 0, &count)) return YES;
        }
        // 弹窗可能包在 UINavigationController/容器里, 补扫子 VC
        for (UIViewController *child in vc.childViewControllers) {
            @try {
                UIView *cv = child.view;
                if (cv) {
                    int c2 = 0;
                    if (SFKScanView(cv, 0, &c2)) return YES;
                }
            } @catch (__unused NSException *e) {}
        }
    } @catch (__unused NSException *e) {}

    return NO;
}

#pragma mark - hook present

typedef void (*SFKPresentIMP)(id, SEL, UIViewController *, BOOL, void (^)(void));
static SFKPresentIMP s_origPresent = NULL;

static void SFKPresent(id self, SEL _cmd,
                       UIViewController *vc, BOOL animated,
                       void (^completion)(void)) {
    BOOL hit = NO;
    @try { hit = SFKIsUpdatePopup(vc); }
    @catch (__unused NSException *e) { hit = NO; }

    if (hit) {
        NSLog(@"[SFKnightMax] 已拦截升级弹窗: %@", NSStringFromClass(vc.class));
        if (completion) completion();   // 不呈现, 但放行 completion 防调用方等待
        return;
    }

    if (s_origPresent) {
        s_origPresent(self, _cmd, vc, animated, completion);
    }
}

#pragma mark - 入口

__attribute__((constructor))
static void SFKnightMaxInit(void) {
    @autoreleasepool {
        @try {
            NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
            if (![bid isEqualToString:kTargetBundle]) return;

            Class cls = [UIViewController class];
            Method m = class_getInstanceMethod(cls,
                            @selector(presentViewController:animated:completion:));
            if (m) {
                s_origPresent = (SFKPresentIMP)method_setImplementation(m, (IMP)SFKPresent);
            }

            NSLog(@"[SFKnightMax] v1.0.2 已激活 (UI 层拦截升级弹窗, 不碰网络)");
        } @catch (NSException *e) {
            NSLog(@"[SFKnightMax] 初始化异常(已忽略): %@", e);
        }
    }
}

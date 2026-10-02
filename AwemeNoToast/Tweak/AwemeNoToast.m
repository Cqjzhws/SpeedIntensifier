// AwemeNoToast v1.0 — 只吞掉 AwemeFullScreen 插件自己弹出的那条提示文字
// ============================================================================
// 背景：用户提供的 AwemeFullScreen.dylib 里**不存在任何文字常量**
//   （ASCII / UTF-16 / 单字节异或 / 双字节异或 / 反转 / 加减 全部 0 命中），
//   提示文字是运行时拼出来的；而它唯一引用的画字入口
//   「showText:withCenterPoint:」同时是它的**全屏钩子入口** ——
//   把这个 selector 改名会连全屏一起废掉（已实测）。
//
// 所以本 dylib 换一个思路：**一个字节都不动原 dylib**，只在运行时把
// 「插件自己发起的 showText:withCenterPoint:」丢掉。
//
// 判定依据：取本 hook 的返回地址，dladdr 得到调用方镜像名；
//   含 "AwemeFullScreen" → 说明是插件自己弹的提示 → 直接 return，不绘制；
//   其它（抖音自己的字幕/提示）→ 原样调用原实现，完全不受影响。
//
// 顺序问题：两个 dylib 都 hook 同一方法时，谁最后装谁在最外层。
// 本 dylib 会在 1/3/6 秒各重扫一次，并保证自己始终处于**最外层**，
// 这样「调用方是插件」这个判断总是成立。
//
// 安全：出任何问题只要移除本 dylib 的注入即可复原，原 dylib 未改动。
// ============================================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>

#define ANT_MAX 32
static Class gCls[ANT_MAX];
static IMP   gOrg[ANT_MAX];
static int   gN = 0;
static int   gDropped = 0;

static IMP ant_origFor(id obj) {
    Class c = object_getClass(obj);
    while (c) {
        for (int i = 0; i < gN; i++) if (gCls[i] == c) return gOrg[i];
        c = class_getSuperclass(c);
    }
    return NULL;
}

static void ant_showText(id self, SEL _cmd, id text, CGPoint p) {
    // 必须在本函数内取返回地址，才能拿到真正的调用方
    void *ret = __builtin_extract_return_addr(__builtin_return_address(0));
    Dl_info info;
    if (dladdr(ret, &info) && info.dli_fname) {
        if (strstr(info.dli_fname, "AwemeFullScreen")) {
            gDropped++;
            if (gDropped <= 3) {
                NSLog(@"[AwemeNoToast] dropped toast from %s (total %d)",
                      info.dli_fname, gDropped);
            }
            return;                       // 插件自己弹的 → 丢弃，不画
        }
    }
    IMP o = ant_origFor(self);
    if (o) ((void (*)(id, SEL, id, CGPoint))o)(self, _cmd, text, p);
}

static void ant_sweep(void) {
    SEL sel = NSSelectorFromString(@"showText:withCenterPoint:");
    if (!sel) return;
    unsigned int n = 0;
    Class *all = objc_copyClassList(&n);
    if (!all) return;
    int newly = 0;
    for (unsigned int i = 0; i < n; i++) {
        Class c = all[i];
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        Method target = NULL;
        for (unsigned int j = 0; j < mc; j++) {
            if (method_getName(ms[j]) == sel) { target = ms[j]; break; }
        }
        if (ms) free(ms);
        if (!target) continue;                       // 只处理"自己实现"的类
        IMP cur = method_getImplementation(target);
        if (cur == (IMP)ant_showText) continue;      // 已经是最外层
        int slot = -1;
        for (int k = 0; k < gN; k++) if (gCls[k] == c) { slot = k; break; }
        if (slot < 0) {
            if (gN >= ANT_MAX) continue;
            slot = gN++;
            gCls[slot] = c;
            newly++;
        }
        gOrg[slot] = cur;                            // 保存当前实现（可能是插件自己的 hook）
        method_setImplementation(target, (IMP)ant_showText);
    }
    free(all);
    if (newly) NSLog(@"[AwemeNoToast] hooked %d new class(es), total %d", newly, gN);
}

__attribute__((constructor))
static void ant_init(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *exe = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"];
        if (![bid hasPrefix:@"com.ss.iphone"] && ![exe isEqualToString:@"Aweme"]) return;
        NSLog(@"[AwemeNoToast] v1.0 loaded in %@", bid);
        dispatch_async(dispatch_get_main_queue(), ^{
            ant_sweep();
            for (int i = 1; i <= 6; i++) {
                int64_t d = (int64_t)(i * 1.0 * NSEC_PER_SEC);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, d), dispatch_get_main_queue(), ^{
                    ant_sweep();
                });
            }
        });
    }
}

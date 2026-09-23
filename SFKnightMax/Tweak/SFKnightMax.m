// SFKnightMax — 顺丰同城骑士 升级弹窗屏蔽 v1.0.0
// 目标进程: com.sfic.knight (顺丰同城骑士, 仅该 App 激活)
// 原理:
//   App 启动时 POST https://goic.sf-express.com/vrms/api/getappupdateinfo
//   服务端"有更新"时 data 为对象 (含 version/is_force/full_url...), "无更新"时 data = []
//   本 dylib 在网络层拦截该 URL 的响应, 把 data 改写为空数组 [] ——
//   与服务端真实"无更新"响应语义一致, App 不弹窗 (含 is_force=1 强更弹窗).
//
// 双保险 Hook (覆盖所有 NSURLSession 用法):
//   A. NSURLProtocol 子类  —— 覆盖 delegate 模式 (AFNetworking 老路径)
//   B. swizzle dataTaskWithRequest:completionHandler: —— 覆盖 block 模式
//   转发请求使用独立 ephemeral session + 递归标记, TLS 系统层完成 (绕过 App 证书锁定).
//
// 纯 ObjC runtime, 无 CydiaSubstrate, TrollFools 友好.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *const kURLMarker   = @"getappupdateinfo";
static NSString *const kHandledKey  = @"SFKnightMaxHandled";
static NSString *const kTargetBundle = @"com.sfic.knight";

#pragma mark - 响应改写核心

// 将信封 JSON 的 data 字段改写为空数组 (服务端"无更新"形态)
// 非 JSON / data 已为空时原样返回, 保证幂等
static NSData *SFKPatchData(NSData *data) {
    if (!data || data.length < 2) return data;
    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![json isKindOfClass:[NSDictionary class]]) return data;

    NSMutableDictionary *root = [json mutableCopy];
    id d = root[@"data"];
    // data 为字典(有更新信息) → 改成空数组; data 为 []/null/不存在 → 不动
    if ([d isKindOfClass:[NSDictionary class]]) {
        NSString *oldVersion = d[@"version"];
        NSInteger isForce = [d[@"is_force"] integerValue];
        NSLog(@"[SFKnightMax] 拦截升级信息: version=%@ is_force=%ld → 已屏蔽",
              oldVersion, (long)isForce);
        root[@"data"] = @[];
        NSData *out = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
        return out ?: data;
    }
    return data;
}

static BOOL SFKIsTargetURL(NSURL *url) {
    if (!url) return NO;
    NSString *s = url.absoluteString.lowercaseString;
    return [s containsString:kURLMarker];
}

#pragma mark - Layer A: NSURLProtocol

@interface SFKnightURLProtocol : NSURLProtocol
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation SFKnightURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!SFKIsTargetURL(request.URL)) return NO;
    // 防止转发请求递归
    if ([NSURLProtocol propertyForKey:kHandledKey inRequest:request]) return NO;
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *forward = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:forward];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    // 显式置空 (实际递归仍靠 kHandledKey 标记防护)
    cfg.protocolClasses = @[];
    self.session = [NSURLSession sessionWithConfiguration:cfg
                                                 delegate:nil
                                            delegateQueue:nil];

    __weak typeof(self) weakSelf = self;
    self.task = [self.session dataTaskWithRequest:forward
                                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error) {
            [self.client URLProtocol:self didFailWithError:error];
            return;
        }
        NSData *patched = SFKPatchData(data);

        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
            NSMutableDictionary *headers = [http.allHeaderFields mutableCopy] ?: [NSMutableDictionary dictionary];
            // 原 body 已被系统解压, 移除压缩头并修正长度
            [headers removeObjectForKey:@"Content-Encoding"];
            headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)patched.length];
            headers[@"Content-Type"] = @"application/json;charset=UTF-8";
            NSHTTPURLResponse *newResp =
                [[NSHTTPURLResponse alloc] initWithURL:resp.URL
                                             statusCode:http.statusCode
                                            HTTPVersion:@"HTTP/1.1"
                                           headerFields:headers];
            [self.client URLProtocol:self didReceiveResponse:newResp
                  cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        } else {
            [self.client URLProtocol:self didReceiveResponse:resp
                  cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        }
        [self.client URLProtocol:self didLoadData:patched];
        [self.client URLProtocolDidFinishLoading:self];
    }];
    [self.task resume];
}

- (void)stopLoading {
    [self.task cancel];
    self.task = nil;
    [self.session invalidateAndCancel];
    self.session = nil;
}

@end

#pragma mark - Layer B: NSURLSession block 模式 swizzle (双保险)

static IMP s_origDataTaskRequest = NULL;
static IMP s_origDataTaskURL = NULL;

static NSURLSessionDataTask *SFKDataTaskWithRequest(id self, SEL _cmd,
                                                    NSURLRequest *request,
                                                    void (^handler)(NSData *, NSURLResponse *, NSError *)) {
    BOOL hit = SFKIsTargetURL(request.URL)
               && handler
               && ![NSURLProtocol propertyForKey:kHandledKey inRequest:request];
    if (hit) {
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *resp, NSError *error) {
                @try { data = SFKPatchData(data); } @catch (__unused NSException *e) {}
                handler(data, resp, error);
            };
        return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, id))s_origDataTaskRequest)
                (self, _cmd, request, wrapped);
    }
    return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, id))s_origDataTaskRequest)
            (self, _cmd, request, handler);
}

static NSURLSessionDataTask *SFKDataTaskWithURL(id self, SEL _cmd,
                                                NSURL *url,
                                                void (^handler)(NSData *, NSURLResponse *, NSError *)) {
    BOOL hit = SFKIsTargetURL(url) && handler;
    if (hit) {
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *resp, NSError *error) {
                @try { data = SFKPatchData(data); } @catch (__unused NSException *e) {}
                handler(data, resp, error);
            };
        return ((NSURLSessionDataTask *(*)(id, SEL, NSURL *, id))s_origDataTaskURL)
                (self, _cmd, url, wrapped);
    }
    return ((NSURLSessionDataTask *(*)(id, SEL, NSURL *, id))s_origDataTaskURL)
            (self, _cmd, url, handler);
}

static void SFKSwizzle(Class cls, SEL sel, IMP newImp, IMP *origImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *origImp = method_setImplementation(m, newImp);
}

#pragma mark - 入口

__attribute__((constructor))
static void SFKnightMaxInit(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        if (![bid isEqualToString:kTargetBundle]) return;

        [NSURLProtocol registerClass:[SFKnightURLProtocol class]];

        Class sessionCls = [NSURLSession class];
        SFKSwizzle(sessionCls,
                   @selector(dataTaskWithRequest:completionHandler:),
                   (IMP)SFKDataTaskWithRequest, &s_origDataTaskRequest);
        SFKSwizzle(sessionCls,
                   @selector(dataTaskWithURL:completionHandler:),
                   (IMP)SFKDataTaskWithURL, &s_origDataTaskURL);

        NSLog(@"[SFKnightMax] 已激活 (屏蔽顺丰同城骑士升级弹窗)");
    }
}

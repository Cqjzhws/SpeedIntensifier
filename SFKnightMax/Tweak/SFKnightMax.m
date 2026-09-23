// SFKnightMax — 顺丰同城骑士 升级弹窗屏蔽 v1.0.1
// 目标进程: com.sfic.knight (顺丰同城骑士, 仅该 App 激活)
//
// v1.0.1 说明:
//   - 保留 v1.0.0 已验证有效的 NSURLProtocol 层 (关键! 顺丰骑士走 AFNetworking,
//     AF 的 completionHandler 内部实际是 delegate 模式, block swizzle 拦不到,
//     只有 NSURLProtocol 能拦)
//   - 安装期全部 @try 防御, 任何 hook 失败都不影响 App 启动
//   - 转发回调显式串行化, 避免与其它注入 dylib (动画类) 共存时的时序问题
//
// 原理: App 启动 POST getappupdateinfo, 服务端"有更新"时 data 为对象,
//   "无更新"时 data = []。本 dylib 把 data 字典改写为 [] —— 与服务端真实
//   "无更新"响应语义一致, 普通弹窗 + is_force=1 强更弹窗都不出现。
//
// 纯 ObjC runtime, 无 CydiaSubstrate, TrollFools 友好.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *const kURLMarker    = @"getappupdateinfo";
static NSString *const kHandledKey   = @"SFKnightMaxHandled";
static NSString *const kTargetBundle = @"com.sfic.knight";

#pragma mark - 响应改写核心

static NSData *SFKPatchData(NSData *data) {
    if (!data || data.length < 2) return data;
    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![json isKindOfClass:[NSDictionary class]]) return data;

    NSMutableDictionary *root = [json mutableCopy];
    id d = root[@"data"];
    if ([d isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[SFKnightMax] 拦截升级信息: version=%@ is_force=%ld → 已屏蔽",
              d[@"version"], (long)[d[@"is_force"] integerValue]);
        root[@"data"] = @[];
        NSData *out = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
        return out ?: data;
    }
    return data;
}

static BOOL SFKIsTargetURL(NSURL *url) {
    if (!url) return NO;
    return [url.absoluteString.lowercaseString containsString:kURLMarker];
}

#pragma mark - Layer A: NSURLProtocol (核心, AFNetworking 必需)

@interface SFKnightURLProtocol : NSURLProtocol
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation SFKnightURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    @try {
        if (!SFKIsTargetURL(request.URL)) return NO;
        if ([NSURLProtocol propertyForKey:kHandledKey inRequest:request]) return NO;
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *forward = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:forward];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    // 转发 session 不注册任何自定义 protocol, 走系统默认 HTTP/HTTPS 处理器
    cfg.protocolClasses = nil;

    // 专用串行队列, 保证 client 回调顺序与网络层一致
    NSOperationQueue *q = [[NSOperationQueue alloc] init];
    q.maxConcurrentOperationCount = 1;
    q.qualityOfService = NSQualityOfServiceUserInitiated;

    self.session = [NSURLSession sessionWithConfiguration:cfg
                                                 delegate:nil
                                            delegateQueue:q];
    __weak typeof(self) weakSelf = self;
    self.task = [self.session dataTaskWithRequest:forward
                                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        @try {
            if (error) {
                [strongSelf.client URLProtocol:strongSelf didFailWithError:error];
                return;
            }
            NSData *patched = SFKPatchData(data);
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
                NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
                NSMutableDictionary *headers = [http.allHeaderFields mutableCopy]
                    ?: [NSMutableDictionary dictionary];
                [headers removeObjectForKey:@"Content-Encoding"];
                [headers removeObjectForKey:@"Content-Length"];
                headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu",
                                              (unsigned long)patched.length];
                headers[@"Content-Type"] = @"application/json;charset=UTF-8";
                NSHTTPURLResponse *newResp =
                    [[NSHTTPURLResponse alloc] initWithURL:resp.URL
                                                statusCode:http.statusCode
                                               HTTPVersion:@"HTTP/1.1"
                                              headerFields:headers];
                [strongSelf.client URLProtocol:strongSelf
                            didReceiveResponse:newResp
                            cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            } else {
                [strongSelf.client URLProtocol:strongSelf
                            didReceiveResponse:resp
                            cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            }
            [strongSelf.client URLProtocol:strongSelf didLoadData:patched];
            [strongSelf.client URLProtocolDidFinishLoading:strongSelf];
        } @catch (__unused NSException *e) {
            // 回调链异常时退回原始数据, 保证 App 不卡死
            @try {
                if (error) {
                    [strongSelf.client URLProtocol:strongSelf didFailWithError:error];
                } else {
                    [strongSelf.client URLProtocol:strongSelf didLoadData:data ?: [NSData data]];
                    [strongSelf.client URLProtocolDidFinishLoading:strongSelf];
                }
            } @catch (__unused NSException *e2) {}
        }
    }];
    [self.task resume];
}

- (void)stopLoading {
    @try {
        [self.task cancel];
        [self.session invalidateAndCancel];
    } @catch (__unused NSException *e) {}
    self.task = nil;
    self.session = nil;
}

@end

#pragma mark - Layer B: block 模式兜底 (不走 AF 的少数直连场景)

typedef NSURLSessionDataTask *(*SFKDataTaskReqIMP)(id, SEL, NSURLRequest *, id);
typedef NSURLSessionDataTask *(*SFKDataTaskURLIMP)(id, SEL, NSURL *, id);
typedef NSURLSessionUploadTask *(*SFKUploadDataIMP)(id, SEL, NSURLRequest *, NSData *, id);

static SFKDataTaskReqIMP s_origDataTaskRequest = NULL;
static SFKDataTaskURLIMP s_origDataTaskURL = NULL;
static SFKUploadDataIMP  s_origUploadData = NULL;

static void (^SFKWrapHandler(void (^handler)(NSData *, NSURLResponse *, NSError *)))
    (NSData *, NSURLResponse *, NSError *) {
    return ^(NSData *data, NSURLResponse *resp, NSError *error) {
        @try { data = SFKPatchData(data); } @catch (__unused NSException *e) {}
        handler(data, resp, error);
    };
}

static NSURLSessionDataTask *SFKDataTaskWithRequest(id self, SEL _cmd,
                                                    NSURLRequest *request,
                                                    void (^handler)(NSData *, NSURLResponse *, NSError *)) {
    if (!s_origDataTaskRequest) return nil;
    if (handler && SFKIsTargetURL(request.URL)) {
        return s_origDataTaskRequest(self, _cmd, request, SFKWrapHandler(handler));
    }
    return s_origDataTaskRequest(self, _cmd, request, handler);
}

static NSURLSessionDataTask *SFKDataTaskWithURL(id self, SEL _cmd,
                                                NSURL *url,
                                                void (^handler)(NSData *, NSURLResponse *, NSError *)) {
    if (!s_origDataTaskURL) return nil;
    if (handler && SFKIsTargetURL(url)) {
        return s_origDataTaskURL(self, _cmd, url, SFKWrapHandler(handler));
    }
    return s_origDataTaskURL(self, _cmd, url, handler);
}

static NSURLSessionUploadTask *SFKUploadTaskWithData(id self, SEL _cmd,
                                                     NSURLRequest *request,
                                                     NSData *bodyData,
                                                     void (^handler)(NSData *, NSURLResponse *, NSError *)) {
    if (!s_origUploadData) return nil;
    if (handler && SFKIsTargetURL(request.URL)) {
        return s_origUploadData(self, _cmd, request, bodyData, SFKWrapHandler(handler));
    }
    return s_origUploadData(self, _cmd, request, bodyData, handler);
}

static void SFKSwizzle(Class cls, SEL sel, IMP newImp, void **origImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        *origImp = (void *)method_setImplementation(m, newImp);
    }
}

#pragma mark - 入口

__attribute__((constructor))
static void SFKnightMaxInit(void) {
    @autoreleasepool {
        @try {
            NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
            if (![bid isEqualToString:kTargetBundle]) return;

            [NSURLProtocol registerClass:[SFKnightURLProtocol class]];

            Class cls = [NSURLSession class];
            SFKSwizzle(cls, @selector(dataTaskWithRequest:completionHandler:),
                       (IMP)SFKDataTaskWithRequest, (void **)&s_origDataTaskRequest);
            SFKSwizzle(cls, @selector(dataTaskWithURL:completionHandler:),
                       (IMP)SFKDataTaskWithURL, (void **)&s_origDataTaskURL);
            SFKSwizzle(cls, @selector(uploadTaskWithRequest:fromData:completionHandler:),
                       (IMP)SFKUploadTaskWithData, (void **)&s_origUploadData);

            NSLog(@"[SFKnightMax] v1.0.1 已激活 (屏蔽升级弹窗)");
        } @catch (NSException *e) {
            NSLog(@"[SFKnightMax] 初始化异常(已忽略): %@", e);
        }
    }
}

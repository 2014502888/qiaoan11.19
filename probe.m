// Joolink 探针 v2 —— 按 v1.32（JoolinkSDReplay）的成熟骨架重写
//
// 与 v1 的差别（v1 注入后闪退的原因）：
//   1) v1 在 constructor 里 hook 了 NSFileManager 的 fileExistsAtPath: —— dyld 加载
//      框架时高频调用，hook 内又调 Foundation，初始化中途重入 → 崩。本版**完全不碰系统类**。
//   2) v1 日志走 ObjC 文件 API 且带路径判断，有重入/死锁风险。本版日志用纯 C stdio。
//   3) v1 类未加载时无兜底。本版沿用 v1.32：constructor 轻量检查 + 后台轮询 30 次 × 0.5s。
//
// 编译：
//   xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
//     -dynamiclib -fobjc-arc -fblocks \
//     -framework Foundation -framework UIKit probe.m -o JoolinkProbe.dylib

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <stdio.h>
#import <sys/stat.h>

#pragma mark - 属性访问（不依赖 Flutter 头文件）

@interface NSObject (JPProps)
- (NSString *)name;
- (NSString *)method;
- (id)arguments;
@end

typedef void (^JPHandler)(id call, id result);
typedef void (^JPResult)(id result);

#pragma mark - 日志（纯 C stdio，禁 ObjC 文件 API）

static FILE *gLogFile = NULL;
static pthread_mutex_t gLogMutex = PTHREAD_MUTEX_INITIALIZER;
static char gLogPath[512] = {0};

static void JPSetupLogPath(void) {
    if (gLogPath[0]) return;
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        NSString *p = [home stringByAppendingPathComponent:@"Documents/jl_probe.log"];
        snprintf(gLogPath, sizeof(gLogPath), "%s", p.UTF8String ?: "/tmp/jl_probe.log");
    }
}

static NSString *JPTxt(id obj) {
    if (!obj) return @"nil";
    NSString *s = nil;
    @try {
        s = [obj isKindOfClass:[NSString class]] ? (NSString *)obj : [obj description];
    } @catch (__unused NSException *e) {
        s = @"<desc失败>";
    }
    if (s.length > 3000) {
        s = [[s substringToIndex:3000] stringByAppendingString:@"…(截断)"];
    }
    return s ?: @"nil";
}

static void JLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = nil;
    @try {
        msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    } @catch (__unused NSException *e) {
        msg = @"<格式化失败>";
    }
    va_end(ap);

    static NSDateFormatter *df = nil;
    if (!df) {
        @try {
            df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"HH:mm:ss.SSS";
        } @catch (__unused NSException *e) {}
    }
    NSString *line = nil;
    @try {
        line = [NSString stringWithFormat:@"[%@] %@\n",
                df ? [df stringFromDate:[NSDate date]] : @"?", msg];
    } @catch (__unused NSException *e) {
        line = [msg stringByAppendingString:@"\n"];
    }
    if (!line) return;

    pthread_mutex_lock(&gLogMutex);
    @try {
        JPSetupLogPath();
        if (!gLogFile) {
            gLogFile = fopen(gLogPath, "a");
        }
        if (gLogFile) {
            struct stat st;
            if (stat(gLogPath, &st) == 0 && st.st_size > 20 * 1024 * 1024) {
                fclose(gLogFile);
                gLogFile = fopen(gLogPath, "w");   // 超 20MB 截断重写
            }
            const char *u = line.UTF8String;
            if (u) {
                fwrite(u, 1, strlen(u), gLogFile);
                fflush(gLogFile);
            }
        }
    } @catch (__unused NSException *e) {}
    pthread_mutex_unlock(&gLogMutex);
}

#pragma mark - 幂等安装（同 v1.32 的 JASetImp）

static void JPSetImp(Class cls, SEL sel, IMP newImp, IMP *saved) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;          // 已装，防重复注入
    if (saved && !*saved) *saved = cur; // 记录原始实现
    method_setImplementation(m, newImp);
}

#pragma mark - Hook 实现

static IMP g_orig_setHandler = NULL;
static IMP g_orig_invoke = NULL;
static IMP g_orig_response = NULL;

// Dart → 原生：包一层 result 拿返回值
static void jp_setHandler(id self, SEL _cmd, JPHandler handler) {
    if (!handler) {
        ((void (*)(id, SEL, JPHandler))g_orig_setHandler)(self, _cmd, handler);
        return;
    }
    NSString *chName = @"?";
    @try { chName = [[self name] copy] ?: @"?"; } @catch (__unused NSException *e) {}
    JPHandler orig = handler;

    JPHandler wrapped = ^(id call, id result) {
        NSString *m = @"?";
        id args = nil;
        @try { m = [call method] ?: @"?"; args = [call arguments]; } @catch (__unused NSException *e) {}
        JLog(@"CH-IN  %@ :: %@  args=%@", chName, m, JPTxt(args));

        JPResult rb = (JPResult)result;
        JPResult wrappedResult = ^(id r) {
            JLog(@"CH-OUT %@ :: %@  ret=%@", chName, m, JPTxt(r));
            if (rb) rb(r);
        };
        @try {
            orig(call, wrappedResult);
        } @catch (NSException *e) {
            JLog(@"CH-ERR %@ :: %@  %@", chName, m, e.reason);
        }
    };
    ((void (*)(id, SEL, JPHandler))g_orig_setHandler)(self, _cmd, wrapped);
}

// 原生 → Dart
static void jp_invoke(id self, SEL _cmd, NSString *method, id arguments) {
    @try {
        JLog(@"CH→Dart %@ :: %@  args=%@", [self name], method, JPTxt(arguments));
    } @catch (__unused NSException *e) {}
    ((void (*)(id, SEL, NSString *, id))g_orig_invoke)(self, _cmd, method, arguments);
}

// 原生网络（AFNetworking）
static id jp_response(id self, SEL _cmd, NSURLResponse *response, NSData *data, NSError **error) {
    id obj = ((id (*)(id, SEL, NSURLResponse *, NSData *, NSError **))g_orig_response)(self, _cmd, response, data, error);
    @try {
        JLog(@"NET %@  bytes=%lu", response.URL.absoluteString ?: @"?", (unsigned long)data.length);
    } @catch (__unused NSException *e) {}
    return obj;
}

#pragma mark - 安装 + 轮询（沿用 v1.32 的兜底策略）

static BOOL g_hookedChan = NO;
static BOOL g_hookedNet = NO;

static void JPHook(void) {
    if (!g_hookedChan) {
        Class c = NSClassFromString(@"FlutterMethodChannel");
        if (c) {
            JPSetImp(c, NSSelectorFromString(@"setMethodCallHandler:"), (IMP)jp_setHandler, &g_orig_setHandler);
            JPSetImp(c, NSSelectorFromString(@"invokeMethod:arguments:"), (IMP)jp_invoke, &g_orig_invoke);
            g_hookedChan = YES;
        }
    }
    if (!g_hookedNet) {
        Class c2 = NSClassFromString(@"AFHTTPResponseSerializer");
        if (c2) {
            JPSetImp(c2, NSSelectorFromString(@"responseObjectForResponse:data:error:"),
                     (IMP)jp_response, &g_orig_response);
            g_hookedNet = YES;
        }
    }
    if (g_hookedChan && g_hookedNet) {
        JLog(@"=== hooks ready | chan=%d net=%d ===", g_hookedChan, g_hookedNet);
    }
}

__attribute__((constructor))
static void JPInit(void) {
    @try {
        JPSetupLogPath();
        JLog(@"=== JoolinkProbe v2 loaded | log=%s ===", gLogPath);

        // 先同步试一次（v1.32 做法：类已在则立即装，不依赖主队列时机）
        JPHook();

        // 类晚加载兜底：0.5s × 30
        if (!g_hookedChan) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                int tries = 0;
                while (tries < 30 && !g_hookedChan) {
                    [NSThread sleepForTimeInterval:0.5];
                    tries++;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @try { JPHook(); } @catch (__unused NSException *e) {}
                    });
                }
                JLog(@"=== poll finished | chan=%d net=%d tries=%d ===", g_hookedChan, g_hookedNet, tries);
            });
        }
    } @catch (NSException *e) {
        // constructor 内异常绝不上抛，避免拖垮启动
    }
}

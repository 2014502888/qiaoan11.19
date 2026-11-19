// Joolink 探针 v1（dylib 版，无 Theos 依赖）
//
// 编译：
//   xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
//     -dynamiclib -fobjc-arc -fblocks \
//     -framework Foundation -framework UIKit probe.m -o JoolinkProbe.dylib
//
// 只读观测，不改任何业务逻辑：
//   CH-IN / CH-OUT  Flutter 通道调用与返回
//   CH→Dart         原生回调 Dart
//   NET             原生网络请求
//   JB              越狱路径查询

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

#pragma mark - 属性访问声明（避免依赖 Flutter 头文件）

@interface NSObject (JPFlutterProps)
- (NSString *)name;
- (NSString *)method;
- (id)arguments;
@end

typedef void (^JPHandler)(id call, id result);
typedef void (^JPResult)(id result);

#pragma mark - 日志

static NSString *gLogPath = nil;
static NSLock *gLogLock = nil;
static os_log_t gOSLog = NULL;

static NSString *JPTxt(id obj) {
    if (!obj) return @"nil";
    NSString *s = [obj isKindOfClass:[NSString class]] ? (NSString *)obj : [obj description];
    if (s.length > 3000) {
        s = [[s substringToIndex:3000] stringByAppendingString:@"…(截断)"];
    }
    return s;
}

static void JPLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];

    [gLogLock lock];
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:gLogPath]) {
            [fm createFileAtPath:gLogPath contents:nil attributes:nil];
        }
        NSDictionary *attr = [fm attributesOfItemAtPath:gLogPath error:nil];
        if ([attr fileSize] > 20 * 1024 * 1024) {
            [fm removeItemAtPath:gLogPath error:nil];
            [fm createFileAtPath:gLogPath contents:nil attributes:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        fh = fh;
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (__unused NSException *e) {
    }
    [gLogLock unlock];

    if (gOSLog) os_log(gOSLog, "%{public}s", line.UTF8String);
}

#pragma mark - Hook 实现

static void *orig_setHandler = NULL;
static void *orig_invoke = NULL;
static void *orig_response = NULL;
static void *orig_fileExists = NULL;

// Flutter 通道：拦截 Dart → 原生 的方法调用，并包一层 result 拿到返回值
static void jp_setHandler(id self, SEL _cmd, JPHandler handler) {
    if (!handler) {
        ((void (*)(id, SEL, JPHandler))orig_setHandler)(self, _cmd, handler);
        return;
    }
    NSString *chName = [[self name] copy] ?: @"(unknown)";
    JPHandler orig = handler;

    JPHandler wrapped = ^(id call, id result) {
        NSString *m = [call method] ?: @"(nil)";
        JPLog(@"CH-IN  %@ :: %@  args=%@", chName, m, JPTxt([call arguments]));

        JPResult rb = (JPResult)result;
        JPResult wrappedResult = ^(id r) {
            JPLog(@"CH-OUT %@ :: %@  ret=%@", chName, m, JPTxt(r));
            if (rb) rb(r);
        };
        orig(call, wrappedResult);
    };
    ((void (*)(id, SEL, JPHandler))orig_setHandler)(self, _cmd, wrapped);
}

// Flutter 通道：原生 → Dart 的调用
static void jp_invoke(id self, SEL _cmd, NSString *method, id arguments) {
    JPLog(@"CH→Dart %@ :: %@  args=%@", [self name], method, JPTxt(arguments));
    ((void (*)(id, SEL, NSString *, id))orig_invoke)(self, _cmd, method, arguments);
}

// 原生网络：AFNetworking 响应
static id jp_response(id self, SEL _cmd, NSURLResponse *response, NSData *data, NSError **error) {
    id obj = ((id (*)(id, SEL, NSURLResponse *, NSData *, NSError **))orig_response)(self, _cmd, response, data, error);
    @try {
        JPLog(@"NET %@  bytes=%lu", response.URL.absoluteString ?: @"?", (unsigned long)data.length);
    } @catch (__unused NSException *e) {}
    return obj;
}

// 越狱路径查询
static BOOL JPIsJBPath(NSString *p) {
    static NSArray<NSString *> *prefixes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[@"/var/jb", @"/Applications/Cydia", @"/Applications/Sileo", @"/Applications/Zebra",
                     @"/Library/MobileSubstrate", @"/usr/lib/libsubstrate", @"/usr/lib/libsubstitute",
                     @"/usr/sbin/sshd", @"/usr/bin/ssh", @"/private/var/lib/apt", @"/private/var/lib/cydia",
                     @"/etc/apt", @"/bin/bash", @"/usr/lib/frida"];
    });
    for (NSString *x in prefixes) {
        if ([p hasPrefix:x]) return YES;
    }
    return NO;
}

static BOOL jp_fileExists(id self, SEL _cmd, NSString *path) {
    BOOL r = ((BOOL (*)(id, SEL, NSString *))orig_fileExists)(self, _cmd, path);
    if (path.length && JPIsJBPath(path)) {
        JPLog(@"JB  %@ -> %d", path, r);
    }
    return r;
}

#pragma mark - 安装

static BOOL JPInstall(const char *clsName, const char *selName, IMP newImp, void **origOut) {
    Class cls = objc_getClass(clsName);
    if (!cls) return NO;
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    *origOut = (void *)method_getImplementation(m);
    method_setImplementation(m, newImp);
    return YES;
}

__attribute__((constructor)) static void JPInit(void) {
    gLogLock = [[NSLock alloc] init];
    gLogPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jl_probe.log"];
    gOSLog = os_log_create("com.jl.probe", "log");

    BOOL okHandler  = JPInstall("FlutterMethodChannel", "setMethodCallHandler:", (IMP)jp_setHandler, &orig_setHandler);
    BOOL okInvoke   = JPInstall("FlutterMethodChannel", "invokeMethod:arguments:", (IMP)jp_invoke, &orig_invoke);
    BOOL okNet      = JPInstall("AFHTTPResponseSerializer", "responseObjectForResponse:data:error:", (IMP)jp_response, &orig_response);
    BOOL okJB       = JPInstall("NSFileManager", "fileExistsAtPath:", (IMP)jp_fileExists, &orig_fileExists);

    JPLog(@"=== JoolinkProbe(dylib) loaded | CH-handler=%d CH-invoke=%d NET=%d JB=%d | log=%@ ===",
          okHandler, okInvoke, okNet, okJB, gLogPath);
}

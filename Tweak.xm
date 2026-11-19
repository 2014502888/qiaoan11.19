// Joolink 探针 v1
// 目的：定位「跳转后直接显示当前时间无录像」——看那台设备到底走了哪条链路、接口返回了什么。
// 只读观测，不改任何业务逻辑。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

// ============ Flutter 类型（前向声明，不依赖 Flutter 头文件）============
@interface FlutterMethodChannel : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@end

@interface FlutterMethodCall : NSObject
@property (nonatomic, readonly, copy) NSString *method;
@property (nonatomic, readonly, copy) id arguments;
@end

typedef void (^FlutterMethodCallHandler)(FlutterMethodCall *call, id result);
typedef void (^JPResultBlock)(id result);

// ============ 日志 ============
static NSString *gLogPath = nil;
static NSLock *gLock = nil;
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

    [gLock lock];
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
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (__unused NSException *e) {
    }
    [gLock unlock];

    if (gOSLog) os_log(gOSLog, "%{public}s", line.UTF8String);
}

// ============ 1. Flutter 通道：入参与返回全记录 ============
%hook FlutterMethodChannel

- (void)setMethodCallHandler:(FlutterMethodCallHandler)handler {
    if (!handler) {
        %orig;
        return;
    }
    NSString *chName = [self.name copy] ?: @"(unknown)";
    FlutterMethodCallHandler orig = handler;

    FlutterMethodCallHandler wrapped = ^(FlutterMethodCall *call, id result) {
        NSString *m = call.method ?: @"(nil)";
        JPLog(@"CH-IN  %@ :: %@  args=%@", chName, m, JPTxt(call.arguments));

        JPResultBlock rb = (JPResultBlock)result;
        JPResultBlock wrappedResult = ^(id r) {
            JPLog(@"CH-OUT %@ :: %@  ret=%@", chName, m, JPTxt(r));
            if (rb) rb(r);
        };
        orig(call, wrappedResult);
    };
    %orig(wrapped);
}

- (void)invokeMethod:(NSString *)method arguments:(id)arguments {
    JPLog(@"CH→Dart %@ :: %@  args=%@", self.name, method, JPTxt(arguments));
    %orig;
}

%end

// ============ 2. 原生网络（AFNetworking，只看 URL 与字节数）============
%hook AFHTTPResponseSerializer

- (id)responseObjectForResponse:(NSURLResponse *)response data:(NSData *)data error:(NSError **)error {
    id obj = %orig;
    @try {
        JPLog(@"NET %@  bytes=%lu", response.URL.absoluteString ?: @"?", (unsigned long)data.length);
    } @catch (__unused NSException *e) {}
    return obj;
}

%end

// ============ 3. 越狱路径查询（看广告 SDK 到底查了什么、结果如何）============
static BOOL JPIsJBPath(NSString *p) {
    static NSArray<NSString *> *pre = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pre = @[@"/var/jb", @"/Applications/Cydia", @"/Applications/Sileo", @"/Applications/Zebra",
                @"/Library/MobileSubstrate", @"/usr/lib/libsubstrate", @"/usr/lib/libsubstitute",
                @"/usr/sbin/sshd", @"/usr/bin/ssh", @"/private/var/lib/apt", @"/private/var/lib/cydia",
                @"/etc/apt", @"/bin/bash", @"/usr/lib/frida"];
    });
    for (NSString *x in pre) {
        if ([p hasPrefix:x]) return YES;
    }
    return NO;
}

%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    BOOL r = %orig;
    if (path.length && JPIsJBPath(path)) {
        JPLog(@"JB  %@ -> %d", path, r);
    }
    return r;
}

%end

// ============ 初始化 ============
%ctor {
    gLock = [[NSLock alloc] init];
    gLogPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jl_probe.log"];
    gOSLog = os_log_create("com.jl.probe", "log");
    JPLog(@"=== JoolinkProbe loaded | log=%@ ===", gLogPath);
}

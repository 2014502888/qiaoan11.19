// JoolinkSDReplay v1.50 —— 乔安智联 4.4.79 报警消息 → 直达本地 SD 回放并定位
//
// v1.50（当前，已实测 5 个监控全部正常）：
//   定位链路最终形态 = 点火 + 纯 seek。
//   ① startSDPlayWithSelectTimeStamp: 只负责把官方带进 SD 模式（它会重建流、
//      先落「最新录像」位置，这个位置不可控，所以不指望它定位）。
//   ② 确认 viewModel.isEnterSDPlay=1 后，调 VC 的 seekTo:duration:（相对秒）做
//      **纯 seek**。纯 seek 只移动播放位置、不重建视频流，所以不花屏、可安全重试。
//   ③ 每次 seek 后 1.5s 读 timeLineView.currentSec（跟随真实播放位置）验证是否
//      到位，未到位最多重试 3 次；到位后才用 changeCurrentTimeStamp: 拨显示指针。
//
// 关键教训（前面十几轮踩过的坑，别再回头）：
//   · currentTimeStamp 是「实时/设备当前时间」，不是播放位置，不能判成败。
//   · 唯一可靠的播放位置是 timeLineView.currentSec。
//   · changeCurrentTimeStamp: 只拨显示指针，不动播放 → 会出现「指针对、画面错」。
//   · startSDPlayWithSelectTimeStamp: 每调一次重建一次流 → 多次调用必花屏。
//
// v1.50 起保留的 4.4.79 适配（下面三条仍然有效）：
//   ① 不再硬造 VC，走官方 setupData 才会建 viewModel / 拉当日事件列表。
//   ② 去掉进入后 3.0s 的 stopSDPlay（停流会让 isEnterSDPlay 停在 NO）。
//   ③ 定位前轮询当日事件数组，非空才动手。

// 诊断开关：1 = 打印全部 ivar/属性/方法 dump（日志会涨到几百 KB），0 = 只打关键链路
#define JA_DIAG 0

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <stdio.h>
#import <string.h>
#import <sys/stat.h>

// ---------- 日志（纯 C，不经任何被 hook 的 ObjC 方法） ----------

static FILE *gLogFile = NULL;
static pthread_mutex_t gLogMutex = PTHREAD_MUTEX_INITIALIZER;
static char gLogPath[512] = {0};

static void JASetupLogPath(void) {
    if (gLogPath[0]) return;
    @autoreleasepool {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jl_sd.log"];
        snprintf(gLogPath, sizeof(gLogPath), "%s", p.UTF8String ?: "/tmp/jl_sd.log");
    }
}

static void JALog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = nil;
    @try { msg = [[NSString alloc] initWithFormat:fmt arguments:ap]; }
    @catch (__unused NSException *e) { msg = @"<fmt err>"; }
    va_end(ap);
    if (!msg) return;

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
    } @catch (__unused NSException *e) { line = [msg stringByAppendingString:@"\n"]; }
    if (!line) return;

    pthread_mutex_lock(&gLogMutex);
    @try {
        JASetupLogPath();
        if (!gLogFile) gLogFile = fopen(gLogPath, "a");
        if (gLogFile) {
            struct stat st;
            if (stat(gLogPath, &st) == 0 && st.st_size > 20 * 1024 * 1024) {
                fclose(gLogFile);
                gLogFile = fopen(gLogPath, "w");
            }
            const char *u = line.UTF8String;
            if (u) { fwrite(u, 1, strlen(u), gLogFile); fflush(gLogFile); }
        }
    } @catch (__unused NSException *e) {}
    pthread_mutex_unlock(&gLogMutex);
}

// ---------- KVC 工具 ----------

static id JAVal(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (NSException *e) { return nil; }
}

static void JASet(id obj, NSString *key, id val) {
    if (!obj || !val) return;
    @try { [obj setValue:val forKey:key]; }
    @catch (NSException *e) {}
}

static UIViewController *JATopVC(void) {
    UIViewController *vc = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:UINavigationController.class]) {
        vc = ((UINavigationController *)vc).topViewController;
    }
    return vc;
}

// ---------- camera 获取 ----------

static id JAGroupManagerShared(void) {
    Class cls = NSClassFromString(@"JAGroupManager");
    if (!cls) return nil;
    NSArray *names = @[@"shared", @"sharedInstance", @"shareManager",
                       @"defaultManager", @"getInstance", @"sharedManager",
                       @"defaultInstance", @"shareInstance", @"manager"];
    for (NSString *sn in names) {
        SEL s = NSSelectorFromString(sn);
        if (class_respondsToSelector(cls, s)) {
            id obj = ((id(*)(id, SEL))objc_msgSend)((id)cls, s);
            if (obj) return obj;
        }
    }
    return nil;
}

static NSString *JANormId(id v) {
    if (!v) return nil;
    if ([v isKindOfClass:NSNumber.class]) return [v stringValue];
    if ([v isKindOfClass:NSString.class]) {
        return [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return [v description];
}

// eid 取不到时依次试 devId / deviceId / uid（4.4.79 报警模型字段可能改名）
static NSString *JAWarnDeviceId(id warn) {
    NSArray *keys = @[@"eid", @"devId", @"deviceId", @"uid", @"device_id"];
    for (NSString *k in keys) {
        NSString *v = JANormId(JAVal(warn, k));
        if (v.length) return v;
    }
    return nil;
}

static id JAFindCameraFromGroupManager(id warn, NSString **src) {
    id gm = JAGroupManagerShared();
    if (!gm) return nil;

    NSString *eid = JAWarnDeviceId(warn);

    if (eid) {
        id cam = nil;
        @try {
            cam = [gm performSelector:NSSelectorFromString(@"getMyCameraWithUid:")
                           withObject:eid];
        } @catch (NSException *e) {}
        if (cam) {
            *src = [NSString stringWithFormat:@"JAGroupManager.getMyCameraWithUid(%@)", eid];
            return cam;
        }
    }

    id all = nil;
    @try { all = [gm performSelector:NSSelectorFromString(@"getAllMyCamera")]; }
    @catch (NSException *e) {}
    if ([all isKindOfClass:NSArray.class]) {
        for (id cam in (NSArray *)all) {
            NSString *uid = JANormId(JAVal(cam, @"uid"));
            if (eid && uid && [uid isEqualToString:eid]) {
                *src = [NSString stringWithFormat:@"getAllMyCamera uid==%@", eid];
                return cam;
            }
        }
    }
    return nil;
}

static id JAFindCamera(UIViewController *detailVC, id warn, NSString **src) {
    id cam = JAVal(detailVC, @"myCamera");
    if (cam) { *src = @"detailVC.myCamera"; return cam; }

    // 4.4.79 新增：camera 可能挂在 viewModel 上
    id vm = JAVal(detailVC, @"viewModel");
    if (vm) {
        cam = JAVal(vm, @"myCamera");
        if (cam) { *src = @"detailVC.viewModel.myCamera"; return cam; }
    }

    cam = JAFindCameraFromGroupManager(warn, src);
    if (cam) return cam;

    Class lmCls = NSClassFromString(@"JALiveManager");
    if (lmCls) {
        id lm = JAVal(lmCls, @"sharedInstance");
        if (lm) {
            cam = JAVal(lm, @"myCamera");
            if (cam) { *src = @"JALiveManager.sharedInstance.myCamera"; return cam; }
        }
    }

    UINavigationController *nav = detailVC.navigationController;
    for (UIViewController *v in nav.viewControllers) {
        id c = JAVal(v, @"myCamera");
        if (c) {
            *src = [NSString stringWithFormat:@"navStack.%@.myCamera", NSStringFromClass(v.class)];
            return c;
        }
    }
    return nil;
}

// ---------- 时间戳 ----------

// 时间戳合理区间：2020-01-01 ~ 2035-01-01
// 4.4.79 的 event_file_url / eventTimeUTC 可能夹带设备固件时间（如 2012 年），
// 不加校验会直接定位到十几年前 → 必然判"无录像" → 回实时。
#define JA_SEC_MIN 1577836800LL
#define JA_SEC_MAX 2051222400LL

static BOOL JASecValid(long long v) { return v >= JA_SEC_MIN && v < JA_SEC_MAX; }

static NSNumber *JABuildTimestamp(id warn) {
    JALog(@"TS 候选 url=%@ | utc=%@ | date=%@ | time=%@",
          JAVal(warn, @"event_file_url"),
          JAVal(warn, @"eventTimeUTC"),
          JAVal(warn, @"event_date"),
          JAVal(warn, @"event_time"));

    // ① event_file_url 文件名内嵌 10 位秒
    id url = JAVal(warn, @"event_file_url");
    if ([url isKindOfClass:NSString.class]) {
        NSString *u = url;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"-(\\d{10})\\."
                                                                            options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:u options:0 range:NSMakeRange(0, u.length)];
        if (m && m.numberOfRanges > 1) {
            long long v = [[u substringWithRange:[m rangeAtIndex:1]] longLongValue];
            if (JASecValid(v)) {
                JALog(@"TS 采用① url 秒=%lld", v);
                return @(v);
            }
            JALog(@"TS 拒绝① url 秒=%lld（超出 2020~2035）", v);
        }
    }

    // ② eventTimeUTC（4.4.79 可能变成非秒格式，必须校验）
    id t = JAVal(warn, @"eventTimeUTC");
    if (t) {
        long long v = 0;
        if ([t isKindOfClass:NSNumber.class]) v = [t longLongValue];
        else if ([t isKindOfClass:NSString.class]) v = (long long)[t doubleValue];
        if (JASecValid(v)) {
            JALog(@"TS 采用② eventTimeUTC=%lld", v);
            return @(v);
        }
        JALog(@"TS 拒绝② eventTimeUTC=%lld（原始值=%@）", v, t);
    }

    // ③ event_date + event_time 拼本地秒
    NSString *d = JAVal(warn, @"event_date");
    NSString *tm = JAVal(warn, @"event_time");
    if (d.length && tm.length) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        fmt.timeZone = [NSTimeZone localTimeZone];
        NSDate *date = [fmt dateFromString:[NSString stringWithFormat:@"%@ %@", d, tm]];
        if (date) {
            long long v = (long long)[date timeIntervalSince1970];
            if (JASecValid(v)) {
                JALog(@"TS 采用③ %@ %@ → %lld", d, tm, v);
                return @(v);
            }
            JALog(@"TS 拒绝③ %@ %@ → %lld", d, tm, v);
        } else {
            JALog(@"TS ③ 日期解析失败 d=%@ t=%@", d, tm);
        }
    }

    JALog(@"TS 全部来源无效，无法定位");
    return nil;
}

// 报警日 0 点（东八区）：sec - ((sec + 28800) % 86400)
static long long JADayStartSec(NSNumber *ts) {
    if (!ts) return 0;
    long long v = ts.longLongValue;
    if (v >= 1000000000LL && v < 10000000000LL) return v - ((v + 28800LL) % 86400LL);
    return 0;
}

// ---------- 全局状态 ----------

static void JASetImp(Class cls, SEL sel, IMP newImp, IMP *saved);
static void ja_rtc_viewDidLoad(id self, SEL _cmd);
static void ja_rtc_viewDidAppear(id self, SEL _cmd);
static void ja_rtc_viewDidDisappear(id self, SEL _cmd);
static void ja_rtc_reloadTimeLine(id self, SEL _cmd, long long day, id arr, long long type);

static id g_activeSDPlayer = nil;
static BOOL g_rtcHooked = NO;
static IMP g_orig_rtc_vdl = NULL;
static IMP g_orig_rtc_vda = NULL;
static IMP g_orig_rtc_vdd = NULL;
static IMP g_orig_rtc_reload = NULL;
static BOOL g_eventsReady = NO;   // 官方 reload 回调已给出目标日数据
static long long g_rtcTargetSec = 0;
static unsigned long long g_rtcVdaGen = 0;
static BOOL g_daySwitched = NO;   // viewDidLoad 阶段已经切过日，viewDidAppear 不再重复
static BOOL g_located = NO;   // 已发过定位（保留给旧的判断用）
static int  g_locateCount = 0; // 本次进入已发出的定位次数（最多 2 次）
static double g_t0 = 0;       // 本次 push 的时刻，用于算耗时

#define JANow() [[NSDate date] timeIntervalSinceReferenceDate]
#define JAElapsed() (g_t0 > 0 ? (JANow() - g_t0) : 0)

// ---------- 创建官方 SD 回放实例（v1.50 核心改动 ①） ----------

// 优先用官方构造方法，让 setupData 正常跑起来（viewModel + 当日事件列表）
static id JACreateSDPlayer(Class cls, id cam, NSString **how) {
    NSArray *inits = @[@"initWithCamera:", @"initWithMyCamera:", @"initWithDevice:"];
    for (NSString *n in inits) {
        SEL s = NSSelectorFromString(n);
        if (![cls instancesRespondToSelector:s]) continue;
        @try {
            id vc = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], s, cam);
            if (vc) {
                *how = [NSString stringWithFormat:@"official %@", n];
                return vc;
            }
        } @catch (NSException *e) {
            JALog(@"v1.50 init %@ 异常: %@", n, e.reason);
        }
    }

    // 退路：alloc + init，再显式调用官方 setup
    id vc = [[cls alloc] init];
    if (!vc) return nil;
    *how = @"alloc+init";

    NSArray *setups = @[@"setupData", @"setup", @"setupWithCamera:"];
    for (NSString *n in setups) {
        SEL s = NSSelectorFromString(n);
        if (![vc respondsToSelector:s]) continue;
        @try {
            if ([n hasSuffix:@":"]) {
                ((void (*)(id, SEL, id))objc_msgSend)(vc, s, cam);
            } else {
                ((void (*)(id, SEL))objc_msgSend)(vc, s);
            }
            *how = [NSString stringWithFormat:@"alloc+init+%@", n];
            break;
        } @catch (NSException *e) {
            JALog(@"v1.50 setup %@ 异常: %@", n, e.reason);
        }
    }
    return vc;
}

// ---------- 事件就绪判断（v1.50 核心改动 ③） ----------

static id JAEventArray(id vc) {
    NSArray *direct = @[@"sdRecordFileArr", @"sdRecordList", @"sdRecordArr", @"sdRecords", @"recordList"];
    for (NSString *k in direct) {
        id arr = JAVal(vc, k);
        if (arr) return arr;
    }
    NSArray *vmKeys = @[@"viewModel", @"sdPlayViewModel", @"playViewModel", @"vm", @"sdViewModel"];
    for (NSString *vk in vmKeys) {
        id vm = JAVal(vc, vk);
        if (!vm) continue;
        for (NSString *k in direct) {
            id arr = JAVal(vm, k);
            if (arr) return arr;
        }
    }
    return nil;
}

// 返回：-1 无法判断（属性都不存在）  0 空  1 有数据
static int JAEventState(id vc) {
    id arr = JAEventArray(vc);
    if (!arr) return -1;
    if ([arr isKindOfClass:NSArray.class]) return [(NSArray *)arr count] > 0 ? 1 : 0;
    if ([arr respondsToSelector:@selector(count)]) {
        NSUInteger n = ((NSUInteger (*)(id, SEL))objc_msgSend)(arr, @selector(count));
        return n > 0 ? 1 : 0;
    }
    return -1;
}

// ---------- 定位 ----------

static void JADumpRecordFiles(id vc, NSString *tag);
static NSString *JAKVC(id obj, NSString *key);

static void JASwitchDay(id vc, long long sec) {
    long long dayStart = JADayStartSec(@(sec));
    if (dayStart < 1000000000LL) dayStart = sec - ((sec + 28800LL) % 86400LL);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd";
    NSString *ds = [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:sec]];

    SEL sw = NSSelectorFromString(@"switchToSDDay:dateString:");
    if ([vc respondsToSelector:sw]) {
        @try { ((void (*)(id, SEL, long long, id))objc_msgSend)(vc, sw, dayStart, ds); }
        @catch (NSException *e) { JALog(@"v1.50 switchToSDDay 异常: %@", e.reason); }
        JALog(@"切日 switchToSDDay → day=%lld date=%@", dayStart, ds);
    } else {
        JALog(@"v1.50 无 switchToSDDay:dateString: —— 4.4.79 可能改名");
    }

    // 关键：switchToSDDay 只改「选中日」这个状态，不会重新拉当天的事件列表。
    // 不重拉 → 时间轴没有报警色条（缺色带），seek 到了也是空画面。
    // 官方 viewDidLoad 已按今日拉过一次，这里必须显式请求报警那一天的事件。
    SEL lr = NSSelectorFromString(@"loadRecordListWithSelectiontDay:");
    if ([vc respondsToSelector:lr]) {
        Method lm = class_getInstanceMethod(object_getClass(vc), lr);
        JALog(@"loadRecordList 类型编码=%s", lm ? method_getTypeEncoding(lm) : "?");
        @try { ((void (*)(id, SEL, long long))objc_msgSend)(vc, lr, dayStart); }
        @catch (NSException *e) { JALog(@"loadRecordList 异常: %@", e.reason); }
        JALog(@"重拉当天事件 loadRecordListWithSelectiontDay: %lld", dayStart);
    } else {
        JALog(@"无 loadRecordListWithSelectiontDay:，尝试 loadRecordListWithType:");
        SEL lt = NSSelectorFromString(@"loadRecordListWithType:");
        if ([vc respondsToSelector:lt]) {
            Method lm2 = class_getInstanceMethod(object_getClass(vc), lt);
            JALog(@"loadRecordListWithType 类型编码=%s", lm2 ? method_getTypeEncoding(lm2) : "?");
            @try { ((void (*)(id, SEL, long long))objc_msgSend)(vc, lt, 0); }
            @catch (NSException *e) { JALog(@"loadRecordListWithType 异常: %@", e.reason); }
            JALog(@"重拉事件 loadRecordListWithType: 0");
        }
    }

    // 备用入口：viewModel 上的 sdSelectiontDayWithTimeInterval:（名字带 TimeInterval）
    id vmj = nil;
    @try { vmj = [vc valueForKey:@"viewModel"]; } @catch (__unused NSException *e) {}
    SEL sd = NSSelectorFromString(@"sdSelectiontDayWithTimeInterval:");
    if (vmj && [vmj respondsToSelector:sd]) {
        Method sm = class_getInstanceMethod(object_getClass(vmj), sd);
        JALog(@"sdSelectiontDayWithTimeInterval 类型编码=%s", sm ? method_getTypeEncoding(sm) : "?");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (vc != g_activeSDPlayer) return;
            id vm2 = nil;
            @try { vm2 = [vc valueForKey:@"viewModel"]; } @catch (__unused NSException *e) {}
            if (!vm2) return;
            // 这个接口返回 id（类型编码 @24@0:8q16），返回值很可能是「该日的时间轴数据/
            // 修正后的时间戳」，之前我们只调用、把返回值丢了。
            id ret = nil;
            @try { ret = ((id (*)(id, SEL, long long))objc_msgSend)(vm2, sd, dayStart); }
            @catch (NSException *e) { JALog(@"sdSelectiontDay 异常: %@", e.reason); }
            if ([ret isKindOfClass:NSArray.class]) {
                NSArray *a = (NSArray *)ret;
                JALog(@"sdSelectiontDay 返回 NSArray count=%lu 首元素=%@",
                      (unsigned long)a.count, a.count ? NSStringFromClass([a[0] class]) : @"-");
            } else if ([ret isKindOfClass:NSNumber.class]) {
                JALog(@"sdSelectiontDay 返回 NSNumber=%@", ret);
            } else {
                JALog(@"sdSelectiontDay 返回 %@ = %@", ret ? NSStringFromClass([ret class]) : @"nil", ret);
            }
            JALog(@"备用 sdSelectiontDayWithTimeInterval: %lld", dayStart);
        });
    } else {
        JALog(@"viewModel 无 sdSelectiontDayWithTimeInterval:");
    }

    // 切日后 2s 打一次加载状态，看官方到底有没有进入重载流程
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (vc != g_activeSDPlayer) return;
        JADumpRecordFiles(vc, @"切日后2s");
        JALog(@"切日后2s 缓存列表=%@ 重载列表=%@ 选中日=%@",
              JAKVC(vc, @"isLoadCacheEventList"),
              JAKVC(vc, @"isReLoadNormalEventList"),
              JAKVC(vc, @"currentSelectedSDDay"));
    });

    @try { [vc setValue:@(dayStart) forKeyPath:@"myCamera.sdSelectiontDay"]; }
    @catch (__unused NSException *e) {}
}

static NSString *JAKVC(id obj, NSString *key) {
    if (!obj) return @"-";
    @try {
        id v = [obj valueForKey:key];
        if (!v) return @"nil";
        if ([v isKindOfClass:NSNumber.class]) return [NSString stringWithFormat:@"%@", v];
        if ([obj isKindOfClass:NSArray.class]) return [NSString stringWithFormat:@"%lu项", (unsigned long)[(NSArray *)v count]];
        return [v description];
    } @catch (NSException *e) { return @"-"; }
}

// 把播放器/时间轴的真实状态打出来，用来区分「指示器到位」和「播放流到位」
// 播放流真实位置：vc.currentTimeStamp 是官方播放器的当前秒（日志实测可用），
// 和时间轴指示器不同 —— 指示器是我们自己拨的，不能用来判断定位是否生效。
// 唯一的成功信号是 viewModel.isEnterSDPlay 从 0 变 1。
// 注意：currentTimeStamp 是「实时/设备当前时间」，不是播放位置，不能拿来判成败。

// 把 VC 的全部 ivar / 属性名打出来（只打名字和类型，不打值），
// 用来找到真实的「事件数组 / 播放状态 / 流上下文」字段名，不再靠猜属性。
#if JA_DIAG
static void JADumpFields(id vc) {
    if (!vc) return;
    Class cls = object_getClass(vc);

    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList(cls, &n);
    NSMutableString *s = [NSMutableString stringWithFormat:@"IVAR(%u): ", n];
    for (unsigned int i = 0; i < n; i++) {
        const char *nm = ivar_getName(ivars[i]);
        const char *tp = ivar_getTypeEncoding(ivars[i]);
        if (nm) [s appendFormat:@"%s:%s ", nm, tp ? tp : "?"];
    }
    if (ivars) free(ivars);
    JALog(@"%@", s);

    unsigned int pn = 0;
    objc_property_t *props = class_copyPropertyList(cls, &pn);
    NSMutableString *p = [NSMutableString stringWithFormat:@"PROP(%u): ", pn];
    for (unsigned int i = 0; i < pn; i++) {
        const char *nm = property_getName(props[i]);
        if (nm) [p appendFormat:@"%s ", nm];
    }
    if (props) free(props);
    JALog(@"%@", p);

    unsigned int mn = 0;
    Method *ms = class_copyMethodList(cls, &mn);
    NSMutableString *m = [NSMutableString stringWithFormat:@"METH(%u): ", mn];
    for (unsigned int i = 0; i < mn && i < 200; i++) {
        SEL sel = method_getName(ms[i]);
        if (sel) [m appendFormat:@"%@ ", NSStringFromSelector(sel)];
    }
    if (ms) free(ms);
    JALog(@"%@", m);
}
#endif  // JA_DIAG

// 注意：sdRecordFileArr 实际装的是 MYEventModel（报警事件列表），不是录像片段表
static void JADumpRecordFiles(id vc, NSString *tag) {
    NSArray *arr = nil;
    @try { arr = [vc valueForKey:@"sdRecordFileArr"]; } @catch (__unused NSException *e) {}
    if (!arr) { JALog(@"[事件列表] %@ sdRecordFileArr=nil", tag); return; }
    if (![arr isKindOfClass:NSArray.class]) {
        JALog(@"[事件列表] %@ sdRecordFileArr 类型=%@", tag, NSStringFromClass([arr class]));
        return;
    }
    NSArray *a = (NSArray *)arr;
    JALog(@"[事件列表] %@ 总数=%lu 首元素=%@", tag, (unsigned long)a.count,
          a.count ? NSStringFromClass([a[0] class]) : @"-");
}

static void JADumpState(id vc, NSString *tag) {
    if (!vc) return;
    id cam = nil;
    @try { cam = [vc valueForKey:@"myCamera"]; } @catch (__unused NSException *e) {}
    JALog(@"状态[%@] 选中日=%@ 无录像=%@ 卡状态=%@ 正在seek=%@ 暂停中=%@ 设备时间=%@ 原位置=%@ 缓存列表=%@ 重载列表=%@",
          tag,
          JAKVC(vc, @"currentSelectedSDDay"),
          JAKVC(vc, @"currentSelectedDayNoRecord"),
          JAKVC(vc, @"sdCardState"),
          JAKVC(vc, @"isSeeking"),
          JAKVC(vc, @"isPausingSDPlay"),
          JAKVC(vc, @"deviceSystemTimeStamp"),
          JAKVC(vc, @"beforeSeekTimestamp"),
          JAKVC(vc, @"isLoadCacheEventList"),
          JAKVC(vc, @"isReLoadNormalEventList"));

    JALog(@"状态[%@] curTS=%@ curSec=%@", tag,
          JAKVC(vc, @"currentTimeStamp"), JAKVC([vc valueForKey:@"timeLineView"], @"currentSec"));

    id vm = nil;
    @try { vm = [vc valueForKey:@"viewModel"]; } @catch (__unused NSException *e) {}
    if (!vm) { JALog(@"状态[%@] viewModel=nil", tag); return; }
    JALog(@"状态[%@] vm 进入SD=%@ 播放中=%@ 会话连接=%@ seek中=%@ 暂停=%@ 播放控制=%@ 最后TS=%@ vmCurTS=%@",
          tag,
          JAKVC(vm, @"isEnterSDPlay"),
          JAKVC(vm, @"isPlaying"),
          JAKVC(vm, @"isSessionConnected"),
          JAKVC(vm, @"isSeekingPlay"),
          JAKVC(vm, @"isPause"),
          JAKVC(vm, @"sdplayControl"),
          JAKVC(vm, @"timestampLast"),
          JAKVC(vm, @"currentTimeStamp"));
}

// 前向声明（JADoLocate 内部要用，必须先声明）
static BOOL JASDReady(id vc);
static void JASeekExact(id vc, long long sec, int attempt);
static void JATimeLineSync(id vc, long long sec);
static long long JATimeLineSec(id vc);

static void JADoLocate(id vc, long long sec, int state) {
    (void)state;
    if (vc != g_activeSDPlayer) return;
    if (g_locateCount >= 2) return;

    // 注意：不能用 timeLineView 的指示器判断是否已到位 —— 那个指示器是我们在
    // 1.5s 后自己拨的，永远显示「到位」，但播放流可能压根没 seek 过去。
    // 官方在 isEnterSDPlay 未就绪时会静默吞掉定位，所以只能无条件重试。
    g_locateCount++;
    g_located = YES;

    JADumpState(vc, @"定位前");

    SEL s = NSSelectorFromString(@"startSDPlayWithSelectTimeStamp:");
    if ([vc respondsToSelector:s]) {
        @try { ((void (*)(id, SEL, long long))objc_msgSend)(vc, s, sec); }
        @catch (NSException *e) { JALog(@"v1.50 定位异常: %@", e.reason); }
        JALog(@"第 %d 次定位 (+%.3fs)", g_locateCount, JAElapsed());
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (vc == g_activeSDPlayer) JADumpState(vc, @"定位后1s");
        });
    } else {
        JALog(@"v1.50 无 startSDPlayWithSelectTimeStamp: —— 4.4.79 可能改名");
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (vc != g_activeSDPlayer) return;
        // 时间轴指示器拨到报警秒（相对秒）
        long long dayStart = JADayStartSec(@(sec));
        if (dayStart < 1000000000LL) dayStart = sec - ((sec + 28800LL) % 86400LL);
        long long rel = sec - dayStart;
        if (rel < 0) rel = 0;
        if (rel > 86399) rel = 86399;

        id tl = nil;
        @try { tl = [vc valueForKey:@"timeLineView"]; } @catch (__unused NSException *e) {}
        SEL c = NSSelectorFromString(@"changeCurrentTimeStamp:");
        if (tl && [tl respondsToSelector:c]) {
            @try { ((void (*)(id, SEL, long long))objc_msgSend)(tl, c, rel); }
            @catch (__unused NSException *e) {}
            JALog(@"时间轴同步完成 (+%.3fs)", JAElapsed());
        }
    });

    // 关键：currentTimeStamp 是「实时/设备当前时间」，不是播放位置，不能用来判成败。
    // 唯一的成功信号是 viewModel 的 isEnterSDPlay 从 0 变 1 —— 说明这一次调用
    // 真的把官方带进了 SD 模式并完成了定位。
    // 若 1.5s 后仍是 0，说明这次只完成了「点火」、定位被吞，才补发第 2 次。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (vc != g_activeSDPlayer) return;
        if (JASDReady(vc)) {
            JALog(@"进入SD=1，定位已生效 (%d 次)", g_locateCount);
            // startSDPlayWithSelectTimeStamp: 会重建流并先落「最新录像」，
            // 再调 viewModel 的 seek 精确跳目标 —— 这是纯 seek，不重建流、不花屏。
            JASeekExact(vc, sec, 1);
            return;
        }
        if (g_locateCount >= 2) {
            JALog(@"仍是进入SD=0，2 次已用完");
            return;
        }
        JALog(@"进入SD 仍为 0，第 1 次被吞，补发 (%d 次)", g_locateCount);
        JADoLocate(vc, sec, 2);
    });
}

// viewModel 级精确 seek：seekSDPlayWithSelectTimeStamp: / sdSelectiontDayWithTimeInterval:
// 只移动播放位置，不重建视频流，所以不会出现「花屏/看不清」。
// 时间轴指示器当前停在的相对秒（跟随真实播放位置，不是我们拨的显示值）
static long long JATimeLineSec(id vc) {
    id tl = nil;
    @try { tl = [vc valueForKey:@"timeLineView"]; } @catch (__unused NSException *e) {}
    if (!tl) return -1;
    id v = nil;
    @try { v = [tl valueForKey:@"currentSec"]; } @catch (__unused NSException *e) {}
    if (!v) return -1;
    return [v longLongValue];
}

// 把时间轴指示器拨到目标秒（只影响显示指针）
static void JATimeLineSync(id vc, long long sec) {
    if (vc != g_activeSDPlayer) return;
    long long dayStart = sec - ((sec + 28800LL) % 86400LL);
    long long rel = sec - dayStart;
    if (rel < 0) rel = 0;
    if (rel > 86399) rel = 86399;
    id tl = nil;
    @try { tl = [vc valueForKey:@"timeLineView"]; } @catch (__unused NSException *e) {}
    SEL c = NSSelectorFromString(@"changeCurrentTimeStamp:");
    if (tl && [tl respondsToSelector:c]) {
        @try { ((void (*)(id, SEL, long long))objc_msgSend)(tl, c, rel); }
        @catch (__unused NSException *e) {}
        JALog(@"时间轴指针拨到 rel=%lld (+%.3fs)", rel, JAElapsed());
    }
}

// 纯 seek：只移动播放位置、不重建视频流，所以可以安全重试（不会花屏）。
// 先试 VC 的 seekTo:duration:（播放器级、最直接），再试 viewModel 的 seek。
// 每次 seek 后 1.5s 读 timeLineView.currentSec 判断是否真的到位。
static void JASeekExact(id vc, long long sec, int attempt) {
    if (vc != g_activeSDPlayer) return;

    long long dayStart = sec - ((sec + 28800LL) % 86400LL);
    long long rel = sec - dayStart;
    if (rel < 0) rel = 0;
    if (rel > 86399) rel = 86399;

    SEL st = NSSelectorFromString(@"seekTo:duration:");
    if ([vc respondsToSelector:st]) {
        JALog(@"seekTo:duration: rel=%lld (第 %d 次)", rel, attempt);
        @try { ((void (*)(id, SEL, long long, double))objc_msgSend)(vc, st, rel, 0.0); }
        @catch (NSException *e) { JALog(@"seekTo 异常: %@", e.reason); }
    } else {
        id vm = nil;
        @try { vm = [vc valueForKey:@"viewModel"]; } @catch (__unused NSException *e) {}
        SEL s = NSSelectorFromString(@"seekSDPlayWithSelectTimeStamp:");
        if (vm && [vm respondsToSelector:s]) {
            JALog(@"viewModel seek → 秒=%lld (第 %d 次)", sec, attempt);
            @try { ((void (*)(id, SEL, long long))objc_msgSend)(vm, s, sec); }
            @catch (NSException *e) { JALog(@"viewModel seek 异常: %@", e.reason); }
        } else {
            JALog(@"seek: 两个接口都不可用");
            return;
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (vc != g_activeSDPlayer) return;
        long long cur = JATimeLineSec(vc);
        long long diff = cur - rel;
        if (diff < 0) diff = -diff;

        if (cur >= 0 && diff <= 90) {
            JALog(@"seek 到位 curSec=%lld 目标=%lld (第 %d 次)", cur, rel, attempt);
            JATimeLineSync(vc, sec);
            return;
        }
        if (attempt >= 3) {
            JALog(@"seek 3 次仍不到位 curSec=%lld 目标=%lld", cur, rel);
            JATimeLineSync(vc, sec);
            return;
        }
        JALog(@"seek 未到位 curSec=%lld 目标=%lld，重试 (第 %d 次)", cur, rel, attempt);
        JASeekExact(vc, sec, attempt + 1);
    });
}

// viewModel 的 isEnterSDPlay —— 官方是否真的进入了 SD 播放模式
static BOOL JASDReady(id vc) {
    id vm = nil;
    @try { vm = [vc valueForKey:@"viewModel"]; } @catch (__unused NSException *e) {}
    if (!vm) return NO;
    id v = nil;
    @try { v = [vm valueForKey:@"isEnterSDPlay"]; } @catch (__unused NSException *e) {}
    return v ? [v boolValue] : NO;
}

// 等官方进入 SD 模式再定位。太早发会被吞，发太多次会把流反复重建、画面灰。
static void JAPollReady(id vc, long long sec, int attempt) {
    if (vc != g_activeSDPlayer || g_located) return;

    if (JASDReady(vc) || attempt >= 5) {
        JALog(@"SD 就绪等待=%d 次，发定位", attempt);
        JADoLocate(vc, sec, 1);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        JAPollReady(vc, sec, attempt + 1);
    });
}

// 轮询事件就绪：就绪即定位，最多 20 次 × 0.3s = 6s
static void JAPollEvents(id vc, long long sec, int attempt) {
    if (vc != g_activeSDPlayer || g_located) return;

    int state = JAEventState(vc);
    if (state == 1 || g_eventsReady) {
        JALog(@"事件就绪(%d 次轮询) → 定位", attempt);
        JADumpRecordFiles(vc, @"就绪时");
#if JA_DIAG
        id vm = nil;
        @try { vm = [vc valueForKey:@"viewModel"]; } @catch (__unused NSException *e) {}
        if (vm) {
            JADumpFields(vm);
            id evm = nil;
            @try { evm = [vc valueForKey:@"currentEvent"]; } @catch (__unused NSException *e) {}
            if (evm) JADumpFields(evm);
        }
#endif
        JAPollReady(vc, sec, 0);
        return;
    }
    if (attempt >= 20) {
        // 冷启动首次进入时时间轴可能还没初始化(curSec=0)，说明官方根本没进 SD 模式，
        // 这时定位必然无效、只会播实时。多等一轮（最多 12s），别白白发定位。
        long long tlSec = 0;
        id tl = nil;
        @try { tl = [vc valueForKey:@"timeLineView"]; } @catch (__unused NSException *e) {}
        @try {
            id v = [tl valueForKey:@"currentSec"];
            if (v) tlSec = [v longLongValue];
        } @catch (__unused NSException *e) {}

        if (tlSec <= 0 && attempt < 40) {
            if (attempt == 20) JALog(@"时间轴未初始化(curSec=0)，继续等到 12s");
        } else {
            JALog(@"事件等待超时(%d 次) → 保底定位", attempt);
            JADoLocate(vc, sec, 0);
            return;
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        JAPollEvents(vc, sec, attempt + 1);
    });
}

// ---------- 打开 SD 回放 ----------

static void JATryOpenSDReplay(UIViewController *detailVC, id warn, id cam) {
    Class cls = NSClassFromString(@"JANewRtcSDPlayViewController");
    if (!cls) {
        JALog(@"v1.50 JANewRtcSDPlayViewController 不存在");
        return;
    }
    if (!g_rtcHooked) {
        JASetImp(cls, @selector(viewDidAppear:), (IMP)ja_rtc_viewDidAppear, &g_orig_rtc_vda);
        JASetImp(cls, @selector(viewDidDisappear:), (IMP)ja_rtc_viewDidDisappear, &g_orig_rtc_vdd);
        g_rtcHooked = YES;
    }

    NSString *how = @"?";
    id vc = JACreateSDPlayer(cls, cam, &how);
    if (!vc) { JALog(@"v1.50 创建 VC 失败"); return; }

    g_t0 = JANow();
    g_located = NO;
    g_locateCount = 0;
    g_eventsReady = NO;
    g_daySwitched = NO;
    g_rtcVdaGen = 0;
#if JA_DIAG
    JADumpFields(vc);
#endif
    JALog(@"=== 进入回放 设备uid=%@ name=%@ | 创建方式=%@ ===",
          JAVal(cam, @"uid") ?: @"?",
          JAVal(cam, @"name") ?: @"?",
          how);

    // camera / 事件 / 时间戳（官方式构造可能已设置，这里补齐，失败不影响）
    @try { [vc setValue:cam forKey:@"myCamera"]; } @catch (__unused NSException *e) {}
    if (warn) {
        // 4.4.79 字段可能改名，打印完整描述便于核对真实字段
        @try {
            NSString *desc = [warn description];
            if (desc.length > 1500) desc = [[desc substringToIndex:1500] stringByAppendingString:@"…"];
            JALog(@"warn=%@", desc);
        } @catch (__unused NSException *e) {}

        JASet(vc, @"currentEvent", warn);
        NSNumber *ts = JABuildTimestamp(warn);
        if (ts) JASet(vc, @"currentTimeStamp", ts);
        long long tv = ts ? ts.longLongValue : 0;
        if (tv >= 1000000000LL && tv < 10000000000LL) g_rtcTargetSec = tv;
        long long dayStart = JADayStartSec(ts);
        if (dayStart > 0 && cam) JASet(cam, @"sdSelectiontDay", @(dayStart));
    }

    UINavigationController *nav = detailVC.navigationController;
    if (!nav) nav = JATopVC().navigationController;
    g_located = NO;                  // 每次进入重置
    g_rtcVdaGen = 0;
    if (nav) {
        g_activeSDPlayer = vc;
        [nav pushViewController:vc animated:YES];    } else {
        [UIApplication.sharedApplication.keyWindow.rootViewController
            presentViewController:vc animated:YES completion:nil];
    }
    JALog(@"v1.50 push 完成, 目标秒=%lld", g_rtcTargetSec);
}

// ---------- hooks ----------

static IMP g_orig_clickCloudRecordAction = NULL;
static IMP g_orig_handleJumpToOpenCloud = NULL;

// v1.34：界面加载阶段就切日 —— 官方 viewDidLoad 会把 sdSelectiontDay 覆盖成「今日」，
// 这里立刻改回报警日，让 setupData 直接按报警日拉事件，页面出现时数据已经对，
// 不再先播一段实时再跳（v1.32 靠 stopSDPlay 强停会打坏 isEnterSDPlay，不能用）
static void ja_rtc_viewDidLoad(id self, SEL _cmd) {
    if (g_orig_rtc_vdl) ((void (*)(id, SEL))g_orig_rtc_vdl)(self, _cmd);
    if (self != g_activeSDPlayer) return;
    long long sec = g_rtcTargetSec;
    if (sec < 1000000000LL) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self != g_activeSDPlayer || g_located) return;
        JALog(@"viewDidLoad 阶段切日 → 秒=%lld (+%.3fs)", sec, JAElapsed());
        g_daySwitched = YES;
        JASwitchDay(self, sec);
        // 切日 + 重拉事件后，数组里可能还残留「今日」的旧数据，
        // 立刻轮询会误判就绪、拿旧事件去定位。等 1.5s 让官方清空再重填。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self != g_activeSDPlayer || g_located) return;
            JAPollEvents(self, sec, 0);
        });
    });
}

static void ja_rtc_viewDidAppear(id self, SEL _cmd) {
    if (g_orig_rtc_vda) ((void (*)(id, SEL))g_orig_rtc_vda)(self, _cmd);
    if (self != g_activeSDPlayer || g_located) return;
    long long sec = g_rtcTargetSec;
    if (sec < 1000000000LL) return;

    unsigned long long myGen = ++g_rtcVdaGen;

    // 兜底：viewDidLoad 阶段没赶上（hook 晚装/官方走了别的路径）时再补一次
    // 已经切过日就不重复 —— 二次切日会让官方把已加载的事件清掉重拉，反而更慢
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self != g_activeSDPlayer || g_located || myGen != g_rtcVdaGen) return;
        if (g_daySwitched) return;
        JALog(@"viewDidAppear 兜底切日 → 秒=%lld (+%.3fs)", sec, JAElapsed());
        g_daySwitched = YES;
        JASwitchDay(self, sec);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self != g_activeSDPlayer || g_located) return;
            JAPollEvents(self, sec, 0);
        });
    });
}

static void ja_rtc_viewDidDisappear(id self, SEL _cmd) {
    if (g_orig_rtc_vdd) ((void (*)(id, SEL))g_orig_rtc_vdd)(self, _cmd);
    if (self != g_activeSDPlayer) return;
    g_activeSDPlayer = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SEL st = NSSelectorFromString(@"stopSDPlay");
        if ([self respondsToSelector:st]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(self, st); }
            @catch (__unused NSException *e) {}
        }
    });
}

// 官方时间轴重载完成回调：timePaintingArray 就是该日的录像片段数组。
// 这是「数据真的到了」的唯一可靠信号，比猜属性名靠谱。
static void ja_rtc_reloadTimeLine(id self, SEL _cmd, long long day, id arr, long long type) {
    if (g_orig_rtc_reload) {
        ((void (*)(id, SEL, long long, id, long long))g_orig_rtc_reload)(self, _cmd, day, arr, type);
    }
    if (self != g_activeSDPlayer) return;

    NSUInteger n = 0;
    if ([arr isKindOfClass:NSArray.class]) {
        n = [(NSArray *)arr count];
    } else if ([arr respondsToSelector:@selector(count)]) {
        n = ((NSUInteger (*)(id, SEL))objc_msgSend)(arr, @selector(count));
    }

    long long targetDay = JADayStartSec(@(g_rtcTargetSec));
    JALog(@"事件重载 day=%lld count=%lu type=%lld | 目标日=%lld (+%.3fs)",
          day, (unsigned long)n, type, targetDay, JAElapsed());

    if (targetDay > 0 && day != targetDay) {
        JALog(@"  不是目标日，忽略");
        return;
    }
    if (n == 0) {
        JALog(@"  目标日录像片段为 0 —— 官方数据确实是空的");
        return;
    }

    g_eventsReady = YES;
    if (g_locateCount < 3) {
        JALog(@"  数据到位 → 定位");
        JADoLocate(self, g_rtcTargetSec, 1);
    }
}

static void *g_lastDetailVC = NULL;
static NSTimeInterval g_lastPushTime = 0;

static BOOL JADebounce(UIViewController *detailVC) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if ((__bridge void *)detailVC == g_lastDetailVC && (now - g_lastPushTime) < 2.0) return YES;
    return NO;
}

static void ja_clickCloudRecordAction(id self, SEL _cmd, id sender) {
    if (JADebounce(self)) return;
    NSString *src = nil;
    id warn = JAVal(self, @"warnInfoEntityModelEx");
    id cam = JAFindCamera(self, warn, &src);
    if (cam) {
        JALog(@"v1.50 camera 来源=%@", src ?: @"?");
        JATryOpenSDReplay(self, warn, cam);
        g_lastDetailVC = (__bridge void *)self;
        g_lastPushTime = [NSDate timeIntervalSinceReferenceDate];
        return;
    }
    JALog(@"v1.50 首次未取到 camera，1.2s 重试");

    __weak id weakSelf = self;
    __weak id weakSender = sender;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strongSelf = weakSelf;
        if (!strongSelf) return;
        if (JADebounce(strongSelf)) return;
        id warn2 = JAVal(strongSelf, @"warnInfoEntityModelEx");
        NSString *src2 = nil;
        id cam2 = JAFindCamera(strongSelf, warn2, &src2);
        if (cam2) {
            JALog(@"v1.50 重试取到 camera 来源=%@", src2 ?: @"?");
            JATryOpenSDReplay(strongSelf, warn2, cam2);
            g_lastDetailVC = (__bridge void *)strongSelf;
            g_lastPushTime = [NSDate timeIntervalSinceReferenceDate];
        } else {
            // v1.50：仍找不到 camera 也不再回落官方（官方会弹云存储）
            JALog(@"v1.50 两次都未取到 camera，放弃跳转（不弹云存储）");
        }
    });
}

// v1.32 起该方法就不拦截，只转发 —— 它不是「查看录像」主链，拦了会误伤云存储按钮
static void ja_handleJumpToOpenCloud(id self, SEL _cmd) {
    @try { JALog(@"v1.50 handleJumpToOpenCloud 转发官方"); } @catch (__unused NSException *e) {}
    if (g_orig_handleJumpToOpenCloud) {
        ((void (*)(id, SEL))g_orig_handleJumpToOpenCloud)(self, _cmd);
    }
}

static void ja_handleJumpToOpenCloudWithMyCamera(id self, SEL _cmd, id cam) {
    JALog(@"v1.50 拦截 handleJumpToOpenCloudWithMyCamera");
    id warn = JAVal(self, @"warnInfoEntityModelEx");
    JATryOpenSDReplay(self, warn, cam);
}

// ---------- 安装 ----------

static void JASetImp(Class cls, SEL sel, IMP newImp, IMP *saved) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;
    if (saved && !*saved) *saved = cur;
    method_setImplementation(m, newImp);
}

static BOOL JAHooked = NO;

static void JAHook(void) {
    if (!JAHooked) {
        Class detailCls = NSClassFromString(@"JANewsWarnInfoDetailVC");
        if (detailCls) {
            JASetImp(detailCls, NSSelectorFromString(@"clickCloudRecordAction:"),
                     (IMP)ja_clickCloudRecordAction, &g_orig_clickCloudRecordAction);
            JASetImp(detailCls, NSSelectorFromString(@"handleJumpToOpenCloud"),
                     (IMP)ja_handleJumpToOpenCloud, &g_orig_handleJumpToOpenCloud);
            JASetImp(detailCls, NSSelectorFromString(@"handleJumpToOpenCloudWithMyCamera:"),
                     (IMP)ja_handleJumpToOpenCloudWithMyCamera, NULL);
            JAHooked = YES;
            JALog(@"v1.50 详情页 hooks 已装");
        }
    }
    if (!g_rtcHooked) {
        Class rtcCls = NSClassFromString(@"JANewRtcSDPlayViewController");
        if (rtcCls) {
            JASetImp(rtcCls, @selector(viewDidLoad), (IMP)ja_rtc_viewDidLoad, &g_orig_rtc_vdl);
            JASetImp(rtcCls, @selector(viewDidAppear:), (IMP)ja_rtc_viewDidAppear, &g_orig_rtc_vda);
            JASetImp(rtcCls, @selector(viewDidDisappear:), (IMP)ja_rtc_viewDidDisappear, &g_orig_rtc_vdd);

            SEL rsel = NSSelectorFromString(@"reloadTimeLineWithsdSelectiontDay:timePaintingArray:reloadType:");
            Method rm = class_getInstanceMethod(rtcCls, rsel);
            if (rm) {
                JALog(@"reloadTimeLine 存在, 类型编码=%s", method_getTypeEncoding(rm));
                JASetImp(rtcCls, rsel, (IMP)ja_rtc_reloadTimeLine, &g_orig_rtc_reload);
            } else {
                JALog(@"reloadTimeLine 不在 JANewRtcSDPlayViewController 上");
            }
            g_rtcHooked = YES;
            JALog(@"v1.50 SD 播放器 hooks 已装");
        }
    }
}

__attribute__((constructor))
static void JASDReplayInit(void) {
    @try {
        JASetupLogPath();
        JALog(@"=== JoolinkSDReplay v1.50 loaded (4.4.79) ===");
        if (NSClassFromString(@"JANewsWarnInfoDetailVC")
            && NSClassFromString(@"JANewRtcSDPlayViewController")) {
            JAHook();
            return;
        }
        __block int tries = 0;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            while (tries < 30 && !(JAHooked && g_rtcHooked)) {
                [NSThread sleepForTimeInterval:0.5];
                tries++;
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try { JAHook(); } @catch (__unused NSException *e) {}
                });
            }
            JALog(@"=== v1.50 轮询结束 tries=%d detail=%d rtc=%d ===", tries, JAHooked, g_rtcHooked);
        });
    } @catch (__unused NSException *e) {}
}

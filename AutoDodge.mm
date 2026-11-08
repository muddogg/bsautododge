// AutoDodge.mm
// Language: Objective-C++ | ARM64 | iOS 15.5+
// Target: com.supercell.laser (Brawl Stars v70.757)

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <cmath>
#include <cstring>

// ═══════════════════════════════════════════════
// OFFSET BLOCK — fill from v70.757 community dump
// ═══════════════════════════════════════════════
namespace off {
    uintptr_t g_world        = 0x0; // FILL
    uintptr_t g_local_player = 0x0; // FILL
    uintptr_t lp_pos_x       = 0x30;
    uintptr_t lp_pos_y       = 0x34;
    uintptr_t svc_alive      = 0x08;
    uintptr_t svc_owner_team = 0x20;
    uintptr_t svc_pos_x      = 0x28;
    uintptr_t svc_pos_y      = 0x2C;
    uintptr_t svc_vel_x      = 0x10;
    uintptr_t svc_vel_y      = 0x14;
}

static BOOL           s_enabled    = NO;
static uintptr_t      s_slide      = 0;
static NSTimeInterval s_last_dodge = 0;
static id             s_stick      = nil;
static IMP            s_orig_tick  = nil;

static constexpr float kRadius   = 300.f;
static constexpr float kCooldown = 0.08f;
static constexpr int   kMaxScan  = 64;

// ───────────────────────────────────────────────
// MENU
// ───────────────────────────────────────────────
@interface ADWindow : UIWindow
- (void)build;
@end
@implementation ADWindow
- (void)build {
    self.windowLevel = UIWindowLevelAlert + 100;
    self.backgroundColor = UIColor.clearColor;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(20,100,200,112)];
    panel.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.93];
    panel.layer.cornerRadius = 14;
    panel.layer.borderWidth  = 1;
    panel.layer.borderColor  = [UIColor colorWithRed:0.24 green:0.80 blue:1.0 alpha:0.55].CGColor;
    panel.clipsToBounds = YES;
    [self addSubview:panel];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0,0,200,36)];
    bar.backgroundColor = [UIColor colorWithRed:0.08 green:0.28 blue:0.48 alpha:1];
    [panel addSubview:bar];

    UILabel *ttl = [[UILabel alloc] initWithFrame:bar.bounds];
    ttl.text          = @"⚡ AutoDodge";
    ttl.textColor     = UIColor.whiteColor;
    ttl.font          = [UIFont boldSystemFontOfSize:14];
    ttl.textAlignment = NSTextAlignmentCenter;
    [bar addSubview:ttl];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(14,48,110,28)];
    lbl.text      = @"Auto Dodge";
    lbl.textColor = UIColor.whiteColor;
    lbl.font      = [UIFont systemFontOfSize:13];
    [panel addSubview:lbl];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(134,46,0,0)];
    sw.transform  = CGAffineTransformMakeScale(0.80, 0.80);
    sw.on         = NO;
    sw.onTintColor = [UIColor colorWithRed:0.24 green:0.80 blue:1.0 alpha:1.0];
    [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:sw];

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(14,80,172,22)];
    status.text      = @"● OFF";
    status.tag       = 999;
    status.textColor = [UIColor colorWithWhite:0.45 alpha:1];
    status.font      = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    [panel addSubview:status];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(dragged:)];
    [panel addGestureRecognizer:pan];
    panel.tag = 1;

    [self makeKeyAndVisible];
}
- (void)toggled:(UISwitch *)sw {
    s_enabled = sw.isOn;
    UIView  *panel  = [self viewWithTag:1];
    UILabel *status = (UILabel *)[panel viewWithTag:999];
    if (s_enabled) {
        status.text      = @"● ON";
        status.textColor = [UIColor colorWithRed:0.18 green:0.90 blue:0.42 alpha:1];
    } else {
        status.text      = @"● OFF";
        status.textColor = [UIColor colorWithWhite:0.45 alpha:1];
    }
}
- (void)dragged:(UIPanGestureRecognizer *)g {
    UIView *panel = [self viewWithTag:1];
    CGPoint d = [g translationInView:self];
    CGRect  f = panel.frame;
    CGSize  sc = UIScreen.mainScreen.bounds.size;
    f.origin.x = MAX(0, MIN(f.origin.x + d.x, sc.width  - f.size.width));
    f.origin.y = MAX(0, MIN(f.origin.y + d.y, sc.height - f.size.height));
    panel.frame = f;
    [g setTranslation:CGPointZero inView:self];
}
@end

// ───────────────────────────────────────────────
// DODGE LOGIC
// ───────────────────────────────────────────────
struct Vec2 { float x, y; };

template<typename T>
static bool sr(uintptr_t a, T &o) {
    if (a < 0x100000000ULL) return false;
    vm_size_t n = 0;
    return vm_read_overwrite(mach_task_self(),
        (vm_address_t)a, sizeof(T), (vm_address_t)&o, &n)
        == KERN_SUCCESS && n == sizeof(T);
}

static uintptr_t slide(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm,"/laser") && !strstr(nm,"laserx"))
            return (uintptr_t)_dyld_get_image_vmaddr_slide(i);
    }
    return 0;
}

static id find_stick(void) {
    if (s_stick) return s_stick;
    NSMutableArray *q = [NSMutableArray array];
    for (UIWindow *w in UIApplication.sharedApplication.windows) [q addObject:w];
    while (q.count) {
        UIView *v = q.firstObject; [q removeObjectAtIndex:0];
        NSString *cn = NSStringFromClass(v.class);
        if (([cn containsString:@"VirtuaStick"] ||
             [cn containsString:@"Joystick"]   ||
             [cn containsString:@"MoveStick"])  &&
            [v respondsToSelector:@selector(setDirection:)]) {
            s_stick = v; return v;
        }
        for (UIView *s in v.subviews) [q addObject:s];
    }
    return nil;
}

static Vec2 dodge(void) {
    if (!s_enabled || !off::g_world || !off::g_local_player) return {0,0};
    uintptr_t lp=0;
    if (!sr(s_slide+off::g_local_player,lp)||!lp) return {0,0};
    float lx=0,ly=0;
    if (!sr(lp+off::lp_pos_x,lx)||!sr(lp+off::lp_pos_y,ly)) return {0,0};
    uintptr_t w=0;
    if (!sr(s_slide+off::g_world,w)||!w) return {0,0};
    uintptr_t arr=0; uint32_t cnt=0;
    if (!sr(w+0x08,arr)||!sr(w+0x10,cnt)||!arr||!cnt) return {0,0};
    Vec2 sum={0,0}; int hits=0;
    uint32_t lim=cnt<(uint32_t)kMaxScan?cnt:(uint32_t)kMaxScan;
    for (uint32_t i=0;i<lim;i++) {
        uintptr_t c=0;
        if (!sr(arr+i*sizeof(uintptr_t),c)||!c) continue;
        uint8_t alive=0,team=0;
        if (!sr(c+off::svc_alive,alive)||!alive) continue;
        if (!sr(c+off::svc_owner_team,team)||!team) continue;
        float px=0,py=0;
        if (!sr(c+off::svc_pos_x,px)||!sr(c+off::svc_pos_y,py)) continue;
        float dx=lx-px,dy=ly-py,dist=sqrtf(dx*dx+dy*dy);
        if (dist>kRadius||dist<0.001f) continue;
        float wt=1.f/(dist+1.f);
        sum.x+=(dx/dist)*wt; sum.y+=(dy/dist)*wt; hits++;
    }
    if (!hits) return {0,0};
    float mag=sqrtf(sum.x*sum.x+sum.y*sum.y);
    if (mag<0.001f) return {0,0};
    return {sum.x/mag,sum.y/mag};
}

// ───────────────────────────────────────────────
// TICK HOOK
// ───────────────────────────────────────────────
static void hooked_tick(id self, SEL _cmd, CADisplayLink *link) {
    if (s_orig_tick) ((void(*)(id,SEL,CADisplayLink*))s_orig_tick)(self,_cmd,link);
    if (!s_enabled) return;
    NSTimeInterval now=link.timestamp;
    if (now-s_last_dodge<kCooldown) return;
    id stick=find_stick();
    if (!stick) return;
    Vec2 d=dodge();
    if (!d.x&&!d.y) return;
    s_last_dodge=now;
    CGPoint dir=CGPointMake(d.x,d.y);
    [stick performSelector:@selector(setDirection:)
               withObject:[NSValue valueWithCGPoint:dir]];
}

// ───────────────────────────────────────────────
// INIT
// ───────────────────────────────────────────────
static ADWindow *s_win=nil;

__attribute__((constructor))
static void ad_init(void) {
    s_slide=slide();
    NSLog(@"[AutoDodge] loaded slide=0x%lx",s_slide);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),
                   dispatch_get_main_queue(),^{
        s_win=[[ADWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        [s_win build];
        Class tgt=NSClassFromString(@"GameViewController")
                 ?:NSClassFromString(@"UnityAppController");
        SEL sel=NSSelectorFromString(@"displayLinkCallback:");
        if (!tgt||![tgt instancesRespondToSelector:sel]) {
            tgt=[CADisplayLink class]; sel=@selector(fire);
        }
        Method m=class_getInstanceMethod(tgt,sel);
        if (m) {
            s_orig_tick=method_getImplementation(m);
            method_setImplementation(m,(IMP)hooked_tick);
            NSLog(@"[AutoDodge] hooked %@",NSStringFromSelector(sel));
        }
    });
}

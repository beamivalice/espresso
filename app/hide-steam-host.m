//  Injected into Wine (x86_64). Steam's host steam.exe creates a Cocoa app
//  with no visible window; steamwebhelper owns the Library UI. Wine's Mac
//  driver then calls transformProcessToForeground, so Cmd+Tab shows two
//  "Wine" tiles. Keep the host at LSUIElement/accessory.

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <string.h>

static BOOL should_demote(void) {
    static int cached = -1;
    if (cached >= 0) return cached;
    BOOL web = NO, steam = NO;
    for (NSString *a in [NSProcessInfo processInfo].arguments) {
        NSString *l = a.lowercaseString;
        if ([l containsString:@"steamwebhelper"]) web = YES;
        if ([l containsString:@"steam.exe"]) steam = YES;
    }
    cached = (steam && !web) ? 1 : 0;
    return cached;
}

#pragma mark - NSApplication setActivationPolicy:

typedef NSApplicationActivationPolicy (*SetPolFn)(id, SEL, NSApplicationActivationPolicy);
static SetPolFn orig_setPol;

static NSApplicationActivationPolicy hook_setPol(id self, SEL sel, NSApplicationActivationPolicy pol) {
    if (should_demote() && pol == NSApplicationActivationPolicyRegular)
        pol = NSApplicationActivationPolicyAccessory;
    return orig_setPol(self, sel, pol);
}

static void hook_set_activation_policy(void) {
    static BOOL done;
    if (done) return;
    Method m = class_getInstanceMethod([NSApplication class], @selector(setActivationPolicy:));
    if (!m) return;
    orig_setPol = (SetPolFn)method_getImplementation(m);
    method_setImplementation(m, (IMP)hook_setPol);
    done = YES;
}

#pragma mark - WineApplicationController transformProcessToForeground:

typedef void (*XformFn)(id, SEL, BOOL);
static XformFn orig_xform;

static void hook_xform(id self, SEL sel, BOOL activate) {
    if (should_demote()) return;
    orig_xform(self, sel, activate);
}

static void hook_wine_transform(void) {
    static BOOL done;
    if (done) return;
    Class cls = NSClassFromString(@"WineApplicationController");
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(transformProcessToForeground:));
    if (!m) return;
    orig_xform = (XformFn)method_getImplementation(m);
    method_setImplementation(m, (IMP)hook_xform);
    done = YES;
}

static void on_image(const struct mach_header *mh, intptr_t vmaddr_slide) {
    (void)mh;
    (void)vmaddr_slide;
    if (!should_demote()) return;
    hook_wine_transform();
}

__attribute__((constructor))
static void init(void) {
    if (!should_demote()) return;
    hook_set_activation_policy();
    hook_wine_transform();
    _dyld_register_func_for_add_image(on_image);
    dispatch_async(dispatch_get_main_queue(), ^{
        hook_wine_transform();
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    });
}

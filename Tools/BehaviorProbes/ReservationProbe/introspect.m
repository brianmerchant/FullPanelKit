// Copyright (c) 2026 Brian Merchant. Licensed under the MIT License (see LICENSE).
//
// Read-only: reports whether this macOS has the private AppKit selectors FullPanelKit's
// menu-bar reservation hook needs, with their type encodings. Creates no windows.
//   clang -fobjc-arc -framework AppKit introspect.m -o introspect && ./introspect
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
static void dump(NSString *name, NSArray<NSString *> *needles) {
    Class c = NSClassFromString(name);
    printf("== %s %s super=%s\n", name.UTF8String, c ? "present" : "MISSING",
           c ? class_getName(class_getSuperclass(c)) : "-");
    if (!c) return;
    unsigned n = 0; Method *m = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n; i++) {
        NSString *sel = NSStringFromSelector(method_getName(m[i]));
        BOOL hit = needles.count == 0;
        for (NSString *k in needles) if ([sel.lowercaseString containsString:k]) hit = YES;
        if (hit) printf("  -%s  %s\n", sel.UTF8String, method_getTypeEncoding(m[i]));
    }
    free(m);
    unsigned pn = 0; Ivar *iv = class_copyIvarList(c, &pn);
    for (unsigned i = 0; i < pn; i++) {
        NSString *iname = @(ivar_getName(iv[i]));
        if ([iname.lowercaseString containsString:@"window"]) printf("  ivar %s %s\n", ivar_getName(iv[i]), ivar_getTypeEncoding(iv[i]));
    }
    free(iv);
}
int main(void) { @autoreleasepool {
    NSArray *k = @[@"reserve", @"menubar", @"window", @"tile", @"frame", @"safearea", @"notch", @"auxiliary"];
    dump(@"_NSFullScreenContentController", k);
    dump(@"_NSFullScreenMenuBarCompanionController", @[@"reveal", @"window", @"content"]);
    // Who else implements the reservation selector? (other classes could be asked too)
    SEL r = NSSelectorFromString(@"reservesSpaceForMenuBarInFullScreen");
    int count = objc_getClassList(NULL, 0); __unsafe_unretained Class *all = (__unsafe_unretained Class *)malloc(sizeof(Class) * count); count = objc_getClassList(all, count);
    for (int i = 0; i < count; i++) { unsigned n=0; Method *ms = class_copyMethodList(all[i], &n);
        for (unsigned j=0;j<n;j++) if (method_getName(ms[j]) == r) printf("implementer: %s %s\n", class_getName(all[i]), method_getTypeEncoding(ms[j]));
        free(ms); }
    free(all);
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    printf("macOS %ld.%ld.%ld\n", v.majorVersion, v.minorVersion, v.patchVersion);
}}

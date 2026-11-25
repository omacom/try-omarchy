// Loaded into the app under test: once the trigger file appears, asks the app
// to update, as the Update button does; accepts what the app then asks; and
// logs what its windows say. UI automation would need a macOS permission that
// CI and a person's Mac should not have to grant.

#import <AppKit/AppKit.h>

static void collect(NSView *view, NSMutableArray<NSString *> *texts) {
    if ([view isKindOfClass:NSTextField.class]) {
        NSString *text = ((NSTextField *)view).stringValue;
        if (text.length > 0) [texts addObject:text];
    } else if ([view isKindOfClass:NSButton.class] && ((NSButton *)view).title.length > 0) {
        [texts addObject:[NSString stringWithFormat:@"[%@]", ((NSButton *)view).title]];
    }
    for (NSView *child in view.subviews) collect(child, texts);
}

__attribute__((constructor)) static void start(void) {
    NSString *trigger = NSProcessInfo.processInfo.environment[@"UPDATE_TEST_TRIGGER"];
    static NSString *previous;
    static NSString *answered;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *_) {
        NSMutableArray<NSString *> *texts = [NSMutableArray array];
        for (NSWindow *window in NSApp.windows)
            if (window.visible) collect(window.contentView, texts);
        NSString *current = [texts componentsJoinedByString:@" | "];
        if (![current isEqualToString:previous]) fprintf(stderr, "[update-test] %s\n", current.UTF8String);
        previous = current;

        if ([NSFileManager.defaultManager fileExistsAtPath:trigger]) {
            [NSFileManager.defaultManager removeItemAtPath:trigger error:nil];
            fprintf(stderr, "[update-test] choosing the update\n");
            // An open sheet, such as What's New, must not keep the app from quitting.
            for (NSWindow *window in NSApp.windows) {
                if (!window.visible || window.attachedSheet != nil || window.sheetParent != nil) continue;
                [window beginSheet:[[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO] completionHandler:nil];
                break;
            }
            // The app may answer with a modal alert, which would hold this timer.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
                [NSApp sendAction:NSSelectorFromString(@"installAppUpdate:") to:NSApp.delegate from:nil];
            });
        } else if (NSApp.modalWindow != nil && ![current isEqualToString:answered]) {
            answered = current;
            fprintf(stderr, "[update-test] choosing the alert's first button\n");
            [NSApp stopModalWithCode:NSAlertFirstButtonReturn];
        }
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

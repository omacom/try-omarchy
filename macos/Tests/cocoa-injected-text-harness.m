#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#include <assert.h>
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define KEY_LEFTSHIFT 256
#define KEY_RIGHTSHIFT 257
static bool held[512];
static int events[1024][2], count;
static void *kbd;
static int64_t injectedTextSource;
static uint32_t queue_count, queue_limit = 1024;
static unsigned int delays;
/* QUEUE */
static void qemu_input_event_send_key_delay(unsigned int ms) { assert(ms == 10);delays++; }
static TISInputSourceRef layoutSource;
static TISInputSourceRef testInput(void) { return (TISInputSourceRef)CFRetain(layoutSource); }
#define TISCopyCurrentKeyboardLayoutInputSource testInput
static int cocoa_keycode_to_linux(int key) { return key; }
static bool qkbd_state_key_get(void *unused,int key) { return held[key]; }
static void qkbd_state_key_event(void *unused,int key,bool down) {
    if (!down && !held[key]) return;
    held[key]=down; assert(count<1024);events[count][0]=key;events[count++][1]=down;
}
/* HELPERS */
@interface Probe : NSObject
- (bool)handleInjectedText:(NSEvent *)event;
@end
@implementation Probe
/* METHOD */
@end
static NSEvent *event(NSString *text, bool down, int key, CGEventFlags flags, int pid) {
    CGEventRef cg=CGEventCreateKeyboardEvent(NULL,key,down);
    CGEventSetFlags(cg,flags);CGEventSetIntegerValueField(cg,kCGEventSourceUnixProcessID,pid);
    UniChar chars[256];[text getCharacters:chars range:NSMakeRange(0,text.length)];
    CGEventKeyboardSetUnicodeString(cg,text.length,chars);
    NSEvent *result=[NSEvent eventWithCGEvent:cg];CFRelease(cg);return result;
}
static void reset(void) { memset(held,0,sizeof(held));count=0;injectedTextSource=0;queue_count=0;delays=0; }
static void layout(NSString *name) {
    if(layoutSource)CFRelease(layoutSource);
    NSDictionary *filter=@{(__bridge NSString *)kTISPropertyInputSourceID:name};
    CFArrayRef list=TISCreateInputSourceList((__bridge CFDictionaryRef)filter,true);
    assert(list && CFArrayGetCount(list)>0);
    layoutSource=(TISInputSourceRef)CFRetain(CFArrayGetValueAtIndex(list,0));CFRelease(list);
}
int main(void) { @autoreleasepool {
    assert(qemu_input_event_queue_has_room(1024));
    assert(!qemu_input_event_queue_has_room(1025));
    queue_count=1025;assert(!qemu_input_event_queue_has_room(0));queue_count=0;
    layout(@"com.apple.keylayout.US");Probe *p=[Probe new];
    reset();assert([p handleInjectedText:event(@"1234",true,0,0,42)]);
    int digits[]={kVK_ANSI_1,kVK_ANSI_2,kVK_ANSI_3,kVK_ANSI_4};
    assert(count==8);for(int i=0;i<4;i++){assert(events[2*i][0]==digits[i] && events[2*i][1]==1);assert(events[2*i+1][0]==digits[i] && events[2*i+1][1]==0);}
    assert([p handleInjectedText:event(@"a",false,0,0,42)]);assert(count==8);
    assert(delays==4);
    reset();assert([p handleInjectedText:event(@"12345678901234567890",true,0,0,42)]);
    assert(count==40 && delays==20);
    reset();queue_count=1024;assert([p handleInjectedText:event(@"1234",true,0,0,42)]);
    assert(count==0 && delays==0);
    reset();assert(![p handleInjectedText:event(@"a",true,0,0,0)]);
    assert(![p handleInjectedText:event(@"a",true,0,0,42)]);
    reset();assert([p handleInjectedText:event(@"A",true,0,kCGEventFlagMaskShift,42)]);
    assert(count==4 && events[0][0]==KEY_LEFTSHIFT && events[0][1]==1);
    assert(events[1][0]==kVK_ANSI_A && events[1][1]==1);
    assert(events[2][0]==kVK_ANSI_A && events[2][1]==0);
    assert(events[3][0]==KEY_LEFTSHIFT && events[3][1]==0);
    assert([p handleInjectedText:event(@"a",false,0,kCGEventFlagMaskShift,42)]);
    reset();held[KEY_LEFTSHIFT]=true;
    assert(![p handleInjectedText:event(@"A",true,0,kCGEventFlagMaskShift,42)]);
    reset();assert(![p handleInjectedText:event(@"a",true,0,kCGEventFlagMaskCommand,42)]);
    assert(![p handleInjectedText:event(@"\001",true,0,kCGEventFlagMaskControl,42)]);
    assert(![p handleInjectedText:event(@"å",true,0,kCGEventFlagMaskAlternate,42)]);
    assert([p handleInjectedText:event(@"1234",true,0,kCGEventFlagMaskCommand,42)]);
    assert(count==0);assert([p handleInjectedText:event(@"a",false,0,kCGEventFlagMaskCommand,42)]);
    reset();assert([p handleInjectedText:event(@"1234",true,0,kCGEventFlagMaskControl,42)]);
    assert(count==0);
    reset();assert([p handleInjectedText:event(@"1234",true,0,kCGEventFlagMaskAlternate,42)]);
    assert(count==0);
    assert(![p handleInjectedText:event(@"1",true,kVK_ANSI_1,0,42)]);assert(count==0);
    reset();assert([p handleInjectedText:event(@"Hello!",true,0,0,42)]);
    assert(count>12);for(int i=0;i<512;i++)assert(!held[i]);
    reset();held[KEY_RIGHTSHIFT]=true;
    assert([p handleInjectedText:event(@"12Ab!",true,0,kCGEventFlagMaskShift,42)]);
    assert(held[KEY_RIGHTSHIFT] && !held[KEY_LEFTSHIFT]);for(int i=0;i<256;i++)assert(!held[i]);
    reset();assert([p handleInjectedText:event(@"a1",true,0,kCGEventFlagMaskAlphaShift,42)]);
    assert(events[0][0]==KEY_LEFTSHIFT && events[0][1]==1);
    reset();assert([p handleInjectedText:event(@"12中文",true,0,0,42)]);assert(count==0);
    assert([p handleInjectedText:event(@"a",false,0,0,42)]);assert(count==0);
    reset();held[kVK_ANSI_1]=true;
    assert([p handleInjectedText:event(@"1234",true,0,0,42)]);assert(count==0 && held[kVK_ANSI_1]);
    reset();assert([p handleInjectedText:event(@"1234",true,0,0,42)]);
    assert(![p handleInjectedText:event(@"a",false,0,0,43)]);
    assert(![p handleInjectedText:event(@"a",true,0,0,42)]);
    assert(![p handleInjectedText:event(@"a",false,0,0,42)]);
    layout(@"com.apple.keylayout.French");reset();
    assert(![p handleInjectedText:event(@"q",true,0,0,42)]);assert(count==0);
    assert([p handleInjectedText:event(@"1234",true,0,0,42)]);
    assert(events[0][0]==KEY_LEFTSHIFT && events[0][1]==1);
    for(int i=0;i<512;i++)assert(!held[i]);
    layout(@"com.apple.keylayout.USInternational-PC");reset();
    assert([p handleInjectedText:event(@"abc'd",true,0,0,42)]);assert(count==0);
    assert([p handleInjectedText:event(@"'",false,0,0,42)]);assert(count==0);
    CFRelease(layoutSource);puts("injected text: batches, physical keys, shortcuts, layouts, caps/shift, held keys, Unicode and trailing releases passed");
}}

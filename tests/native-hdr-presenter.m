// Integration test: GPU readback is restricted to this test harness.
#include "ui/cocoa-hdr.m"
#include <assert.h>
#include <objc/runtime.h>

static id<MTLTexture> captured_output;
static IMP original_next_drawable;
static id capture_drawable(id layer, SEL selector) {
    id<CAMetalDrawable> drawable = ((id (*)(id, SEL))original_next_drawable)(layer, selector);
    [captured_output release];
    captured_output = [drawable.texture retain];
    return drawable;
}


static float pq(float nits) {
    double v = pow(nits / 10000.0, 2610.0 / 16384.0);
    return pow((3424.0/4096.0 + (2413.0/128.0)*v) /
               (1 + (2392.0/128.0)*v), 2523.0/32.0);
}

static void close_to(const char *label, float actual, float expected) {
    printf("%s actual=%.6f expected=%.6f\n", label, actual, expected);
    assert(fabsf(actual-expected) < fmaxf(0.006f, fabsf(expected)*0.009f));
}

static void frame(QemuHDRPresenter *p, QemuHDRMetadata metadata, bool hdr) {
    enum { W=256, H=128 };
    assert(cocoa_hdr_begin(p,W,H));
    glViewport(0,0,W,H);
    glEnable(GL_SCISSOR_TEST);
    float values[4][4]={{1,1,1,1},{0.5,0.5,0.5,1},{1,0,0,1},{0,1,0,1}};
    if(hdr) {
        values[0][0]=values[0][1]=values[0][2]=pq(100);
        values[1][0]=values[1][1]=values[1][2]=pq(1000);
        values[2][0]=pq(1000);values[3][1]=pq(1000);
    }
    for(int i=0;i<4;i++) {
        glScissor((i%2)*W/2,(i/2)*H/2,W/2,H/2);
        glClearColor(values[i][0],values[i][1],values[i][2],1);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    glDisable(GL_SCISSOR_TEST);
    assert(glGetError()==GL_NO_ERROR);
    assert(cocoa_hdr_present(p,&metadata));
    // The test waits for the production submission queue, then reads its actual drawable.
    dispatch_sync(p->submit_queue, ^{});
    id<MTLTexture> output=[captured_output retain];
    assert(output);
    id<MTLBuffer> result=[p->device newBufferWithLength:W*H*8 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command=[p->queue commandBuffer];
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    [blit copyFromTexture:output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
              sourceSize:MTLSizeMake(W,H,1) toBuffer:result destinationOffset:0
           destinationBytesPerRow:W*8 destinationBytesPerImage:W*H*8];
    [blit endEncoding];[command commit];[command waitUntilCompleted];
    assert(command.status==MTLCommandBufferStatusCompleted);
    __fp16 *pixels=result.contents;
    float expectedSDR[4][3]={{1,1,1},{0.214041,0.214041,0.214041},
        {0.627404,0.0690973,0.0163914},{0.329283,0.919540,0.0880133}};
    float expectedHDR[4][3]={{1,1,1},{10,10,10},{10,0,0},{0,10,0}};
    for(int i=0;i<4;i++) {
        // Bottom GL quadrants must appear at the bottom of the Metal drawable.
        int x=(i%2)*W/2+W/4, y=H-1-((i/2)*H/2+H/4);
        for(int c=0;c<3;c++) {
            char label[80];snprintf(label,sizeof(label),"%s quadrant=%d channel=%d",hdr?"HDR":"SDR",i,c);
            close_to(label,(float)pixels[(y*W+x)*4+c],hdr?expectedHDR[i][c]:expectedSDR[i][c]);
        }
    }
    [result release];[output release];
}

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(50,50,256,128)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.title=@"HDR pipeline verification";
    window.contentView.wantsLayer=YES;
    [window orderFront:nil];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.05,false);
    PFNEGLGETPLATFORMDISPLAYEXTPROC getDisplay=(void*)eglGetProcAddress("eglGetPlatformDisplayEXT");
    EGLint da[]={0x3203,0x3489,EGL_NONE};
    EGLDisplay d=getDisplay(0x3202,EGL_DEFAULT_DISPLAY,da);
    assert(eglInitialize(d,NULL,NULL));assert(eglBindAPI(EGL_OPENGL_ES_API));
    EGLint ca[]={EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT,EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_NONE};
    EGLConfig config;EGLint count;assert(eglChooseConfig(d,ca,&config,1,&count)&&count);
    EGLint ctxa[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
    EGLContext ctx=eglCreateContext(d,config,EGL_NO_CONTEXT,ctxa);assert(ctx!=EGL_NO_CONTEXT);
    QemuHDRPresenter *presenter=cocoa_hdr_create(window.contentView.layer,d,config,ctx);assert(presenter);
    Method next=class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
    original_next_drawable=method_setImplementation(next, (IMP)capture_drawable);
    presenter->layer.framebufferOnly=NO; // Test readback only. Production stays framebuffer-only.
    QemuHDRMetadata sdr={0};
    QemuHDRMetadata hdr={.colorspace=9,.eotf=2,.max_luminance=1000,.max_cll=1000,.max_fall=400};
    frame(presenter,sdr,false);frame(presenter,hdr,true);frame(presenter,sdr,false);
    assert(presenter->presented==3 && presenter->skipped==0);
    // Simulate a stalled WindowServer acquisition. Three queued frames fill the
    // bounded pool; another refresh must return without waiting on submission.
    dispatch_semaphore_t entered=dispatch_semaphore_create(0);
    dispatch_semaphore_t unblock=dispatch_semaphore_create(0);
    dispatch_async(presenter->submit_queue, ^{
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(unblock, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC));
    });
    dispatch_semaphore_wait(entered, DISPATCH_TIME_FOREVER);
    for(int i=0;i<3;i++) {
        assert(cocoa_hdr_begin(presenter,256,128));
        glClearColor(0,0,0,1);glClear(GL_COLOR_BUFFER_BIT);
        assert(cocoa_hdr_present(presenter,&sdr));
    }
    assert(!cocoa_hdr_begin(presenter,256,128));
    assert(presenter->skipped==1);
    dispatch_semaphore_signal(unblock);
    dispatch_sync(presenter->submit_queue, ^{});
    id<MTLCommandBuffer> drain=[presenter->queue commandBuffer];
    [drain commit];[drain waitUntilCompleted];
    dispatch_release(entered);dispatch_release(unblock);
    puts("PASS: SDR/PQ/SDR, 100/1000-nit values, primaries, orientation, GPU handoff, nonblocking bounded submission");
    [window orderOut:nil];
    return 0;
} }

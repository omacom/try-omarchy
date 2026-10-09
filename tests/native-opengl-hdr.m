#define GL_SILENCE_DEPRECATION
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGL/gl3.h>
#include <stdbool.h>
#include <stdio.h>
#include <math.h>
#include "cocoa-gl-hdr.h"

static CocoaGLHDRShader shader;
static CGLContextObj shared_context;
static GLuint shared_texture;
static bool layer_finished;
static bool layer_passed;

static void require(bool condition, const char *message)
{
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

static float pq_encode(float nits)
{
    double v = pow(nits / 10000.0, 2610.0 / 16384.0);
    return pow((3424.0/4096.0 + 2413.0/128.0*v)/(1 + 2392.0/128.0*v),2523.0/32.0);
}

static void check_pixel(float expected, const char *name)
{
    float rgba[4];
    glReadPixels(0,0,1,1,GL_RGBA,GL_FLOAT,rgba);
    require(glGetError() == GL_NO_ERROR, "GPU pixel readback");
    printf("%s: %.6f %.6f %.6f (expected %.6f)\n",name,rgba[0],rgba[1],rgba[2],expected);
    for (int i=0;i<3;i++) require(fabs(rgba[i]-expected)<fmax(0.002,expected*0.006),name);
}

static void benchmark_final_pass(void)
{
    GLuint input, output, fbo, vao, query;
    glGenTextures(1,&input);glBindTexture(GL_TEXTURE_2D,input);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGB10_A2,3456,2160,0,GL_RGBA,GL_UNSIGNED_INT_2_10_10_10_REV,NULL);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,input,0);
    glClearColor(pq_encode(1000),pq_encode(1000),pq_encode(1000),1);glClear(GL_COLOR_BUFFER_BIT);
    glGenTextures(1,&output);glBindTexture(GL_TEXTURE_2D,output);
    glGenVertexArrays(1,&vao);glGenQueries(1,&query);
    GLuint fragment=cocoa_hdr_compile(GL_FRAGMENT_SHADER,
        "#version 150\n in vec2 uv;out vec4 color;uniform sampler2D source;void main(){color=texture(source,uv);}");
    GLuint vertex=cocoa_hdr_compile(GL_VERTEX_SHADER,cocoa_hdr_vertex);
    GLuint copy=glCreateProgram();glAttachShader(copy,vertex);glAttachShader(copy,fragment);glLinkProgram(copy);
    GLint linked=0;glGetProgramiv(copy,GL_LINK_STATUS,&linked);require(linked,"baseline copy shader");
    glDeleteShader(vertex);glDeleteShader(fragment);
    for(int mode=0;mode<2;mode++) {
        glBindTexture(GL_TEXTURE_2D,output);
        glTexImage2D(GL_TEXTURE_2D,0,mode?GL_RGBA16F:GL_RGBA8,3456,2160,0,GL_RGBA,GL_FLOAT,NULL);
        glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,output,0);
        require(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE,"benchmark target");
        glViewport(0,0,3456,2160);
        double durations[60];
        for(int frame=0;frame<65;frame++) {
            glBeginQuery(GL_TIME_ELAPSED,query);
            if(mode) cocoa_hdr_shader_draw(&shader,vao,input,true,true,true,105);
            else {
                glUseProgram(copy);glUniform1i(glGetUniformLocation(copy,"source"),0);
                glUniform1i(glGetUniformLocation(copy,"flip"),1);
                glBindVertexArray(vao);glBindTexture(GL_TEXTURE_2D,input);glDrawArrays(GL_TRIANGLES,0,3);
            }
            glEndQuery(GL_TIME_ELAPSED);
            GLuint64 nanoseconds=0;glGetQueryObjectui64v(query,GL_QUERY_RESULT,&nanoseconds);
            if(frame>=5) durations[frame-5]=nanoseconds/1e6;
        }
        double total=0,max=0;
        for(int i=0;i<60;i++){total+=durations[i];if(durations[i]>max)max=durations[i];}
        printf("3456x2160 final-pass GPU time (%s): mean %.3f ms, max %.3f ms; 120-Hz frame budget 8.333 ms\n",mode?"PQ + FP16 HDR":"copy + 8-bit SDR",total/60,max);
    }
    require(glGetError()==GL_NO_ERROR,"benchmark GL commands");
    glDeleteQueries(1,&query);glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&input);glDeleteTextures(1,&output);glDeleteVertexArrays(1,&vao);glDeleteProgram(copy);
}

@interface HDRProbeLayer : CAOpenGLLayer
@end
@implementation HDRProbeLayer
- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)format
{
    CGLContextObj context=NULL;
    require(CGLCreateContext(format,shared_context,&context)==kCGLNoError,"CGL context shares VirGL-style texture/program objects");
    return context;
}
- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask
{
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAAccelerated, kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAColorFloat, kCGLPFAColorSize,64,0};
    CGLPixelFormatObj format=NULL; GLint count=0;
    require(CGLChoosePixelFormat(attributes,&format,&count)==kCGLNoError && format,"layer float pixel format");
    return format;
}
- (void)drawInCGLContext:(CGLContextObj)context pixelFormat:(CGLPixelFormatObj)format
          forLayerTime:(CFTimeInterval)time displayTime:(const CVTimeStamp *)stamp
{
    CGLSetCurrentContext(context);
    GLint red=0,green=0,blue=0,type=0;
    glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,GL_BACK_LEFT,
                                           GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE,&red);
    glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,GL_BACK_LEFT,
                                           GL_FRAMEBUFFER_ATTACHMENT_GREEN_SIZE,&green);
    glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,GL_BACK_LEFT,
                                           GL_FRAMEBUFFER_ATTACHMENT_BLUE_SIZE,&blue);
    glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,GL_BACK_LEFT,
                                           GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE,&type);
    GLenum error=glGetError();
    if (error==GL_INVALID_OPERATION || error==GL_INVALID_ENUM) {
        while(glGetError()!=GL_NO_ERROR) {}
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,
                                               GL_FRAMEBUFFER_ATTACHMENT_RED_SIZE,&red);
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,
                                               GL_FRAMEBUFFER_ATTACHMENT_GREEN_SIZE,&green);
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,
                                               GL_FRAMEBUFFER_ATTACHMENT_BLUE_SIZE,&blue);
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,
                                               GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE,&type);
    }
    printf("Cocoa layer backing: RGB %d/%d/%d bits, component type 0x%x, GL error 0x%x\n",red,green,blue,type,glGetError());
    GLuint vao;
    glGenVertexArrays(1,&vao);
    cocoa_hdr_shader_draw(&shader,vao,shared_texture,true,true,true,105);
    glDeleteVertexArrays(1,&vao);
    float pixel[4]; glReadPixels(0,0,1,1,GL_RGBA,GL_FLOAT,pixel);
    printf("Cocoa layer shared-texture PQ readback: %.4f %.4f %.4f; EDR enabled: %d\n",pixel[0],pixel[1],pixel[2],self.wantsExtendedDynamicRangeContent);
    layer_passed=red>=16 && green>=16 && blue>=16 && type==GL_FLOAT && fabs(pixel[0]-1000.0f/105)<0.06f;
    layer_finished=true;
    [super drawInCGLContext:context pixelFormat:format forLayerTime:time displayTime:stamp];
}
@end

int main(void)
{
    @autoreleasepool {
        NSOpenGLPixelFormatAttribute attributes[]={
            NSOpenGLPFAAccelerated,NSOpenGLPFAOpenGLProfile,NSOpenGLProfileVersion3_2Core,
            NSOpenGLPFAColorFloat,NSOpenGLPFAColorSize,64,0};
        NSOpenGLPixelFormat *format=[[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
        require(format!=nil,"accelerated floating-point OpenGL format available");
        NSOpenGLContext *context=[[NSOpenGLContext alloc] initWithFormat:format shareContext:nil];
        [context makeCurrentContext];
        printf("Renderer: %s; GL: %s\n",glGetString(GL_RENDERER),glGetString(GL_VERSION));
        require(cocoa_hdr_shader_init(&shader),"actual HDR shader compiles and links");
        GLuint vao,input,output,fbo;
        glGenVertexArrays(1,&vao);
        glGenTextures(1,&input); glBindTexture(GL_TEXTURE_2D,input);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
        glGenTextures(1,&output); glBindTexture(GL_TEXTURE_2D,output);
        glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA16F,2,2,0,GL_RGBA,GL_FLOAT,NULL);
        glGenFramebuffers(1,&fbo); glBindFramebuffer(GL_FRAMEBUFFER,fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,output,0);
        require(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE,"float render target");
        glViewport(0,0,2,2);
        const float nits[]={105,1000,4000};
        for(int i=0;i<3;i++) {
            float encoded=pq_encode(nits[i]); float pixel[]={encoded,encoded,encoded,1};
            glBindTexture(GL_TEXTURE_2D,input);
            glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA32F,1,1,0,GL_RGBA,GL_FLOAT,pixel);
            cocoa_hdr_shader_draw(&shader,vao,input,true,true,true,105);
            check_pixel(nits[i]/105,"PQ to linear EDR");
        }
        float white[]={1,1,1,1};
        glBindTexture(GL_TEXTURE_2D,input); glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA32F,1,1,0,GL_RGBA,GL_FLOAT,white);
        cocoa_hdr_shader_draw(&shader,vao,input,true,false,false,105); check_pixel(1,"SDR white after HDR");
        float gray[]={0.5,0.5,0.5,1};
        glBindTexture(GL_TEXTURE_2D,input); glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA32F,1,1,0,GL_RGBA,GL_FLOAT,gray);
        cocoa_hdr_shader_draw(&shader,vao,input,true,false,false,105); check_pixel(0.214041,"SDR gamma");
        float red[]={1,0,0,1};
        glBindTexture(GL_TEXTURE_2D,input); glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA32F,1,1,0,GL_RGBA,GL_FLOAT,red);
        cocoa_hdr_shader_draw(&shader,vao,input,true,false,false,105);
        float converted[4];glReadPixels(0,0,1,1,GL_RGBA,GL_FLOAT,converted);
        require(fabs(converted[0]-0.627403896)<0.002 && fabs(converted[1]-0.069097289)<0.002 && fabs(converted[2]-0.016391439)<0.002,"sRGB red converts to BT.2020 with correct matrix orientation");
        float pattern[]={0,0,0,1, 0,0,0,1, 1,1,1,1, 1,1,1,1};
        glBindTexture(GL_TEXTURE_2D,input);glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA32F,2,2,0,GL_RGBA,GL_FLOAT,pattern);
        cocoa_hdr_shader_draw(&shader,vao,input,true,false,false,105);check_pixel(0,"bottom-up texture orientation");
        cocoa_hdr_shader_draw(&shader,vao,input,false,false,false,105);check_pixel(1,"top-down texture orientation");
        float pq=pq_encode(1000);float bright[]={pq,pq,pq,1};
        glBindTexture(GL_TEXTURE_2D,input);glTexImage2D(GL_TEXTURE_2D,0,GL_RGB10_A2,1,1,0,GL_RGBA,GL_FLOAT,bright);
        cocoa_hdr_shader_draw(&shader,vao,input,true,true,true,105);check_pixel(1000.0f/105,"10-bit PQ input");
        shared_context=context.CGLContextObj;shared_texture=input;
        glFlush();
        glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&output);glDeleteVertexArrays(1,&vao);
        [NSApplication sharedApplication];
        NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,320,200)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.title=@"Try Omarchy OpenGL HDR probe";
        HDRProbeLayer *layer=[HDRProbeLayer layer];
        layer.asynchronous=NO; layer.wantsExtendedDynamicRangeContent=YES;
        CGColorSpaceRef colorspace=CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearITUR_2020);
        layer.colorspace=colorspace;CGColorSpaceRelease(colorspace);
        window.contentView.wantsLayer=YES;window.contentView.layer=layer;
        [window orderFront:nil];[layer setNeedsDisplay];
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
        while(!layer_finished && deadline.timeIntervalSinceNow>0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        require(layer_finished && layer_passed,"real Cocoa layer preserves extended float output");
        printf("Screen EDR headroom: current %.3f, potential %.3f\n",window.screen.maximumExtendedDynamicRangeColorComponentValue,window.screen.maximumPotentialExtendedDynamicRangeColorComponentValue);
        NSDate *headroomDeadline=[NSDate dateWithTimeIntervalSinceNow:1];
        while(headroomDeadline.timeIntervalSinceNow>0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        printf("Settled screen EDR headroom: %.3f\n",window.screen.maximumExtendedDynamicRangeColorComponentValue);
        [window orderOut:nil];
        [context makeCurrentContext];glDeleteTextures(1,&input);
        benchmark_final_pass();
        puts("Native OpenGL HDR GPU and Cocoa layer checks passed");
    }
}

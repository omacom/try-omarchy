/* Run inside the real guest; see docs/runtime-validation.md. This checks the
 * accelerated GLES3/MSAA path without needing an unlocked host desktop. */
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s (EGL %x GL %x)\n", __LINE__, #x, eglGetError(), glGetError()); exit(1); } } while (0)
int main(void) {
    EGLDisplay display = eglGetPlatformDisplay(0x31DD, EGL_DEFAULT_DISPLAY, NULL);
    CHECK(display != EGL_NO_DISPLAY);
    CHECK(eglInitialize(display, NULL, NULL));
    CHECK(eglBindAPI(EGL_OPENGL_ES_API));
    EGLint attrs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, 0x40,
        EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
    EGLConfig config; EGLint count;
    CHECK(eglChooseConfig(display,attrs,&config,1,&count) && count==1);
    EGLint surface_attrs[]={EGL_WIDTH,8,EGL_HEIGHT,8,EGL_NONE};
    EGLSurface surface=eglCreatePbufferSurface(display,config,surface_attrs);
    EGLint context_attrs[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
    EGLContext context=eglCreateContext(display,config,EGL_NO_CONTEXT,context_attrs);
    CHECK(context!=EGL_NO_CONTEXT && surface!=EGL_NO_SURFACE);
    CHECK(eglMakeCurrent(display,surface,surface,context));
    const char *renderer=(const char *)glGetString(GL_RENDERER);
    printf("renderer: %s\nversion: %s\n",renderer,glGetString(GL_VERSION));
    CHECK(strstr(renderer,"virgl")!=NULL);
    GLint samples=0; glGetIntegerv(GL_MAX_SAMPLES,&samples);
    printf("max samples: %d\n",samples); CHECK(samples>=4);
    GLuint framebuffers[2], renderbuffers[2];
    glGenFramebuffers(2,framebuffers); glGenRenderbuffers(2,renderbuffers);
    for(int i=0;i<2;i++) {
        glBindRenderbuffer(GL_RENDERBUFFER,renderbuffers[i]);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER,i?0:4,GL_RGBA8,8,8);
        glBindFramebuffer(GL_FRAMEBUFFER,framebuffers[i]);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_RENDERBUFFER,renderbuffers[i]);
        CHECK(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE);
    }
    glBindFramebuffer(GL_FRAMEBUFFER,framebuffers[0]);
    glClearColor(.2f,.4f,.6f,1.f); glClear(GL_COLOR_BUFFER_BIT);
    glBindFramebuffer(GL_READ_FRAMEBUFFER,framebuffers[0]);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,framebuffers[1]);
    glBlitFramebuffer(0,0,8,8,0,0,8,8,GL_COLOR_BUFFER_BIT,GL_NEAREST);
    glBindFramebuffer(GL_FRAMEBUFFER,framebuffers[1]);
    unsigned char pixel[4]={0}; glReadPixels(0,0,1,1,GL_RGBA,GL_UNSIGNED_BYTE,pixel);
    CHECK(glGetError()==GL_NO_ERROR);
    printf("resolved RGBA: %d %d %d %d\n",pixel[0],pixel[1],pixel[2],pixel[3]);
    CHECK(pixel[0]==51 && pixel[1]==102 && pixel[2]==153 && pixel[3]==255);
    eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
    eglDestroyContext(display,context); eglDestroySurface(display,surface); eglTerminate(display);
    puts("PASS: hardware VirGL GLES3 and 4x multisample color resolve");
    return 0;
}

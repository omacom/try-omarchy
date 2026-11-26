/* Check the capability bits a native Apple GL host gives the guest's Mesa, without a GL context. */
#include "vrend/vrend_renderer.c"

/* Mesa 26.3's VIRGL_CAP_V2_QUERY_FORMAT_MODIFIER: the host answers GBM format and layout queries. */
#define MESA_QUERY_FORMAT_MODIFIER (1u << 19)

static const GLubyte *GLAPIENTRY get_string(GLenum name)
{
   switch (name) {
   case GL_VENDOR: return (const GLubyte *)"Apple";
   case GL_RENDERER: return (const GLubyte *)"Apple M4 Max";
   case GL_VERSION: return (const GLubyte *)"4.1 Metal - 90.5";
   case GL_SHADING_LANGUAGE_VERSION: return (const GLubyte *)"4.10";
   default: return (const GLubyte *)"";
   }
}
static void GLAPIENTRY get_integer(UNUSED GLenum name, GLint *value) { *value = 0; }
static void GLAPIENTRY get_float(GLenum name, GLfloat *value)
{
   value[0] = 0;
   if (name == GL_ALIASED_POINT_SIZE_RANGE || name == GL_ALIASED_LINE_WIDTH_RANGE ||
       name == GL_SMOOTH_POINT_SIZE_RANGE || name == GL_SMOOTH_LINE_WIDTH_RANGE)
      value[1] = 0;
}
static GLenum GLAPIENTRY get_error(void) { return GL_NO_ERROR; }
static void GLAPIENTRY gen_names(GLsizei count, GLuint *names)
{
   for (GLsizei i = 0; i < count; i++)
      names[i] = i + 1;
}
static void GLAPIENTRY bind_name(UNUSED GLenum target, UNUSED GLuint name) {}
static void GLAPIENTRY delete_names(UNUSED GLsizei count, UNUSED const GLuint *names) {}
static GLenum GLAPIENTRY framebuffer_status(UNUSED GLenum target) { return GL_FRAMEBUFFER_UNSUPPORTED; }
static void GLAPIENTRY tex_image_2d(UNUSED GLenum target, UNUSED GLint level, UNUSED GLint internal_format,
                                    UNUSED GLsizei width, UNUSED GLsizei height, UNUSED GLint border,
                                    UNUSED GLenum format, UNUSED GLenum type, UNUSED const void *pixels) {}
static void GLAPIENTRY tex_multisample(UNUSED GLenum target, UNUSED GLsizei samples, UNUSED GLenum internal_format,
                                       UNUSED GLsizei width, UNUSED GLsizei height, UNUSED GLboolean fixed) {}
static void GLAPIENTRY renderbuffer_multisample(UNUSED GLenum target, UNUSED GLsizei samples,
                                                UNUSED GLenum internal_format, UNUSED GLsizei width,
                                                UNUSED GLsizei height) {}
static void GLAPIENTRY framebuffer_texture(UNUSED GLenum target, UNUSED GLenum attachment, UNUSED GLenum textarget,
                                           UNUSED GLuint texture, UNUSED GLint level) {}
static void GLAPIENTRY framebuffer_renderbuffer(UNUSED GLenum target, UNUSED GLenum attachment,
                                                UNUSED GLenum renderbuffertarget, UNUSED GLuint renderbuffer) {}
static void GLAPIENTRY get_multisample(UNUSED GLenum name, UNUSED GLuint index, GLfloat *value) { value[0] = value[1] = 0; }

int main(void)
{
   epoxy_glGetString = get_string;
   epoxy_glGetIntegerv = get_integer;
   epoxy_glGetFloatv = get_float;
   epoxy_glGetError = get_error;
   epoxy_glGenTextures = gen_names;
   epoxy_glGenFramebuffers = gen_names;
   epoxy_glGenRenderbuffers = gen_names;
   epoxy_glBindTexture = bind_name;
   epoxy_glBindFramebuffer = bind_name;
   epoxy_glBindRenderbuffer = bind_name;
   epoxy_glDeleteTextures = delete_names;
   epoxy_glDeleteFramebuffers = delete_names;
   epoxy_glDeleteRenderbuffers = delete_names;
   epoxy_glCheckFramebufferStatus = framebuffer_status;
   epoxy_glTexImage2D = tex_image_2d;
   epoxy_glTexImage2DMultisample = tex_multisample;
   epoxy_glTexStorage2DMultisample = tex_multisample;
   epoxy_glRenderbufferStorageMultisample = renderbuffer_multisample;
   epoxy_glFramebufferTexture2D = framebuffer_texture;
   epoxy_glFramebufferRenderbuffer = framebuffer_renderbuffer;
   epoxy_glGetMultisamplefv = get_multisample;

   union virgl_caps caps;
   vrend_state.use_core_profile = true;
   vrend_renderer_fill_caps(VIRTGPU_DRM_CAPSET_VIRGL2, VREND_CAPSET_VIRGL2_MAX_VERSION, &caps);
   if (caps.v2.capability_bits_v2 & MESA_QUERY_FORMAT_MODIFIER) {
      fprintf(stderr, "FAIL: a core profile host claims GBM format and layout queries it cannot answer\n");
      return 1;
   }
   puts("PASS: a core profile host leaves Mesa's GBM format and layout queries off");
   return 0;
}

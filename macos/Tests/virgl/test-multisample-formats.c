/* Exercise the actual VirGL format probe with controlled GL entry points.
 * No window or graphics context is required by the build regression. */
#define epoxy_is_desktop_gl test_is_desktop_gl
#include "vrend/vrend_formats.c"

static bool desktop;
static unsigned mutable_calls, storage_calls;
static GLenum allocation_error;
bool test_is_desktop_gl(void) { return desktop; }
static void GLAPIENTRY generate(GLsizei n, GLuint *ids) { while (n--) ids[n] = n + 1; }
static void GLAPIENTRY bind_texture(GLenum target, GLuint id) { (void)target; (void)id; }
static void GLAPIENTRY delete_textures(GLsizei n, const GLuint *ids) { (void)n; (void)ids; }
static GLenum GLAPIENTRY get_error(void) { return allocation_error; }
static void GLAPIENTRY mutable_texture(GLenum target, GLsizei samples, GLenum format,
                                      GLsizei width, GLsizei height, GLboolean fixed)
{
   (void)target; (void)samples; (void)format; (void)width; (void)height; (void)fixed;
   mutable_calls++;
}
static void GLAPIENTRY storage_texture(GLenum target, GLsizei samples, GLenum format,
                                      GLsizei width, GLsizei height, GLboolean fixed)
{
   (void)target; (void)samples; (void)format; (void)width; (void)height; (void)fixed;
   storage_calls++;
}

static bool check_case(const char *name, bool is_desktop, bool ms_storage,
                       bool ordinary_storage, GLenum error,
                       unsigned mutable_expected, unsigned storage_expected, bool supported)
{
   struct vrend_format_table table[VIRGL_FORMAT_MAX_EXTENDED] = {0};
   const unsigned index = VIRGL_FORMAT_R8G8B8A8_UNORM;
   table[index].internalformat = GL_RGBA8;
   table[index].flags = ordinary_storage ? VIRGL_TEXTURE_CAN_TEXTURE_STORAGE : 0;
   desktop = is_desktop;
   allocation_error = error;
   mutable_calls = storage_calls = 0;
   vrend_check_texture_multisample(table, ms_storage);
   if (mutable_calls != mutable_expected || storage_calls != storage_expected ||
       !!(table[index].flags & VIRGL_TEXTURE_CAN_MULTISAMPLE) != supported) {
      fprintf(stderr, "FAIL: %s (mutable=%u storage=%u flags=%x)\n",
              name, mutable_calls, storage_calls, table[index].flags);
      return false;
   }
   printf("PASS: %s\n", name);
   return true;
}

int main(void)
{
   epoxy_glGenTextures = generate;
   epoxy_glBindTexture = bind_texture;
   epoxy_glDeleteTextures = delete_textures;
   epoxy_glGetError = get_error;
   epoxy_glTexImage2DMultisample = mutable_texture;
   epoxy_glTexStorage2DMultisample = storage_texture;
   bool passed = true;
   passed &= check_case("desktop GL uses mutable MSAA with ordinary immutable storage",
                        true, false, true, GL_NO_ERROR, 1, 0, true);
   passed &= check_case("desktop GL uses mutable MSAA without immutable storage",
                        true, false, false, GL_NO_ERROR, 1, 0, true);
   passed &= check_case("desktop GL uses available immutable MSAA",
                        true, true, true, GL_NO_ERROR, 0, 1, true);
   passed &= check_case("GLES does not call unavailable mutable MSAA",
                        false, false, true, GL_NO_ERROR, 0, 0, false);
   passed &= check_case("GLES uses available immutable MSAA",
                        false, true, true, GL_NO_ERROR, 0, 1, true);
   passed &= check_case("failed mutable allocation is not advertised",
                        true, false, true, GL_INVALID_OPERATION, 1, 0, false);
   passed &= check_case("failed immutable allocation is not advertised",
                        true, true, true, GL_INVALID_OPERATION, 0, 1, false);
   return passed ? 0 : 1;
}

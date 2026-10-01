/* Exercise the renderer's vendor and shader-input policies, without a GL context. */
#include "vrend/vrend_renderer.c"

static const char *vendor;
static const GLubyte *GLAPIENTRY get_vendor(GLenum name)
{
   return name == GL_VENDOR ? (const GLubyte *)vendor : NULL;
}
static bool check_vendor(const char *name, bool expected)
{
   vendor = name;
   if (use_integer() != expected) {
      fprintf(stderr, "FAIL: integer attribute policy for %s\n", name ? name : "NULL");
      return false;
   }
   return true;
}
static bool check_alpha(bool gles, GLenum target, bool expected)
{
   struct vrend_context ctx = {0};
   struct vrend_sub_context sub = {.parent = &ctx};
   struct vrend_shader_selector fragment = {.type = PIPE_SHADER_FRAGMENT};
   struct vrend_shader_key key = {0};
   struct vrend_resource texture = {.target = target};
   struct vrend_sampler_view view = {.format = VIRGL_FORMAT_A8_UNORM, .texture = &texture};
   ctx.sub = &sub;
   ctx.shader_cfg.use_gles = gles;
   sub.views[PIPE_SHADER_FRAGMENT].max_num_views = 1;
   sub.views[PIPE_SHADER_FRAGMENT].views[0] = &view;
   vrend_state.use_gles = gles;
   vrend_state.use_core_profile = true;
   vrend_fill_shader_key(&sub, &fragment, &key);
   bool lowered = vrend_shader_sampler_views_mask_get(key.sampler_views_lower_swizzle_mask, 0);
   if (lowered != expected) {
      fprintf(stderr, "FAIL: alpha shader conversion (GLES=%d target=%x)\n", gles, target);
      return false;
   }
   return true;
}
int main(void)
{
   epoxy_glGetString = get_vendor;
   unsetenv("VIRGL_USE_INTEGER");
   bool passed = check_vendor("Apple", true) && check_vendor("Google Inc. (Apple)", true) &&
                 check_vendor("ARM", true) && check_vendor("NVIDIA Corporation", false) &&
                 check_vendor(NULL, false);
   setenv("VIRGL_USE_INTEGER", "1", 1);
   passed &= check_vendor("NVIDIA Corporation", true);
   unsetenv("VIRGL_USE_INTEGER");
   if (passed) puts("PASS: native Apple and ANGLE select integer attributes automatically");
   passed &= check_alpha(false, GL_TEXTURE_2D, false);
   passed &= check_alpha(false, GL_TEXTURE_BUFFER, true);
   passed &= check_alpha(true, GL_TEXTURE_2D, false);
   passed &= check_alpha(true, GL_TEXTURE_BUFFER, true);
   if (passed) puts("PASS: native alpha samplers avoid duplicate shader swizzles; buffers retain lowering");
   return passed ? 0 : 1;
}

#version 300 es
// Omarchy's 4000 K manual night light, applied after scene composition.
// Virtio GPU has no DRM CTM property, so hyprsunset's hardware path is a no-op.
precision highp float;
in vec2 v_texcoord;
uniform sampler2D tex;
out vec4 fragColor;

void main() {
    vec4 color = texture(tex, v_texcoord);
    fragColor = vec4(color.rgb * vec3(1.0, 0.807, 0.651), color.a);
}

// polychrome.glsl — Palo Latro "Viral" edition shimmer (P4 shine). CLEAN-ROOM: our own diagonal rainbow
// flow + saturation boost, not Balatro's polychrome.fs. A slow rainbow band drifts across the portrait.
extern number time;     // wall-clock seconds (G.TIMERS.BACKGROUND)
extern number phase;    // per-card offset

vec3 hue_shift(vec3 c, float a) {
    const vec3 k = vec3(0.57735);
    float ca = cos(a), sa = sin(a);
    return c * ca + cross(k, c) * sa + k * dot(k, c) * (1.0 - ca);
}

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 px = Texel(tex, tc);
    if (px.a < 0.01) return px * color;
    float t = time * 0.5 + phase;
    float band = tc.x * 2.0 + tc.y + t;                 // diagonal rainbow flow
    vec3 col = hue_shift(px.rgb, sin(band) * 1.5);
    float l = dot(col, vec3(0.299, 0.587, 0.114));      // boost saturation a touch
    col = mix(vec3(l), col, 1.25);
    return vec4(col, px.a) * color;
}

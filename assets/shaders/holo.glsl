// holo.glsl — Palo Latro "Battle-Tested" edition shimmer. CLEAN-ROOM: our own turbulence+grid
// field, not Balatro's holo.fs. A shifting hue wash + faint diagonal grid sparkle over the portrait.
extern number time;     // wall-clock seconds (G.TIMERS.BACKGROUND)
extern number phase;    // per-card offset

// hue rotation about the grey axis (Rodrigues rotation — standard, our own use)
vec3 hue_shift(vec3 c, float a) {
    const vec3 k = vec3(0.57735);
    float ca = cos(a), sa = sin(a);
    return c * ca + cross(k, c) * sa + k * dot(k, c) * (1.0 - ca);
}

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 px = Texel(tex, tc);
    if (px.a < 0.01) return px * color;
    float t = time * 0.6 + phase;
    float turb = sin(tc.x * 12.0 + t) * sin(tc.y * 12.0 - t * 0.8);   // turbulence
    float grid = sin((tc.x + tc.y) * 40.0 + t * 3.0) * 0.5 + 0.5;     // fine diagonal grid
    float m = (turb * 0.5 + 0.5) * grid;
    vec3 col = hue_shift(px.rgb, m * 1.2 - 0.6);                      // shifting hue
    col += vec3(0.30, 0.25, 0.10) * pow(m, 3.0) * 0.5;               // warm grid sparkle
    return vec4(col, px.a) * color;
}

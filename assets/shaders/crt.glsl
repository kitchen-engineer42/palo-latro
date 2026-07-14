// crt.glsl — Palo Latro gentle CRT post-fx (P4 shine, optional/toggle). CLEAN-ROOM: our own pass, not
// Balatro's CRT.fs. Deliberately NO geometric warp/bulge — only colour overlays (scanlines + a touch of
// chromatic aberration + vignette). Keeping pixels in place means the mouse→virtual mapping stays exact.
// Applied once when blitting the full-scene canvas to the screen.
extern number time;       // wall-clock seconds (unused-warp-free; reserved for subtle flicker)
extern vec2  resolution;  // canvas/window size in px

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    float off = 1.2 / resolution.x;                 // sub-pixel chromatic aberration
    float r = Texel(tex, tc - vec2(off, 0.0)).r;
    float g = Texel(tex, tc).g;
    float b = Texel(tex, tc + vec2(off, 0.0)).b;
    vec3 col = vec3(r, g, b);

    float scan = 0.93 + 0.07 * sin(tc.y * resolution.y * 3.14159);   // soft scanlines
    col *= scan;

    vec2 v = tc - 0.5;                              // gentle vignette
    col *= 1.0 - 0.45 * dot(v, v);

    col *= 1.0 + 0.01 * sin(time * 6.2831);         // barely-there flicker (uses time so the uniform stays live)
    return vec4(col, 1.0) * color;
}

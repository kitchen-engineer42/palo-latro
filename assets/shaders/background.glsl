// background.glsl — Palo Latro animated backdrop.
// CLEAN-ROOM: our OWN swirl field — NOT a copy of Balatro's background.fs. A slow painterly
// vortex that lerps between three muted market tints, drawn as one fullscreen quad in WINDOW space
// (before the virtual scale transform) so it fills the whole window including the letterbox surround.
extern number time;        // wall-clock seconds (G.TIMERS.BACKGROUND)
extern number spin;        // extra swirl during big moments (0 normally)
extern vec2  resolution;   // window size in px
extern number contrast;
extern vec3  tint1;        // dark base
extern vec3  tint2;        // mid
extern vec3  tint3;        // highlight

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec2 uv = (sc - 0.5 * resolution) / resolution.y;   // aspect-correct, origin at centre
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float t = time * 0.06;
    float swirl = a + r * 2.2 - t - spin * r * 3.0;     // angle tightening toward the edges

    // a few flowing octaves in swirl+radius space → a soft moving band field
    float f = 0.0;
    f += sin(swirl * 2.0 + t * 1.3) * 0.50;
    f += sin(r * 6.0 - t * 0.9 + swirl) * 0.30;
    f += sin((uv.x + uv.y) * 3.0 + t * 0.7) * 0.20;
    f = clamp((f * 0.5) * contrast + 0.5, 0.0, 1.0);    // → [0,1], contrast around the midpoint

    vec3 col = mix(tint1, tint2, smoothstep(0.0, 0.6, f));
    col = mix(col, tint3, smoothstep(0.55, 1.0, f));
    col *= 1.0 - 0.35 * smoothstep(0.6, 1.4, r);        // soft corner vignette
    return vec4(col, 1.0) * color;
}

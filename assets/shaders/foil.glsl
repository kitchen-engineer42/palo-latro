// foil.glsl — Palo Latro "Open-Source" edition shimmer. CLEAN-ROOM: our own dual-sweep field,
// not Balatro's foil.fs. Cool metallic streaks that sweep across the founder portrait over time; each card
// offset by `phase` so a row doesn't shimmer in lockstep. Drawn THROUGH the card art image.
extern number time;     // wall-clock seconds (G.TIMERS.BACKGROUND)
extern number phase;    // per-card offset (id + hover) so cards animate independently

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 px = Texel(tex, tc);
    if (px.a < 0.01) return px * color;                 // leave transparent pixels alone
    float t = time * 0.8 + phase;
    float h1 = sin((tc.x + tc.y) * 9.0  + t * 2.0);     // two diagonal sweeps, different angle + frequency
    float h2 = sin((tc.x - tc.y) * 14.0 - t * 1.3);
    float shine = (h1 * 0.5 + 0.5) * (h2 * 0.5 + 0.5);
    shine = pow(shine, 2.0);                             // tighten into streaks
    vec3 col = px.rgb + vec3(0.55, 0.75, 1.0) * shine * 0.35;   // cool foil highlight
    return vec4(col, px.a) * color;
}

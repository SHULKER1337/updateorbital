// Orbital Laser's post pass (capability `render`): one full-screen pass over the
// world, drawn after any shader pack. Everything is anchored in the world by
// rebuilding each pixel's position from the depth buffer and the camera
// matrices, or by tracing the view ray against shapes placed in the world
// (planes, cylinders, a volume). Nothing is painted flat on the screen except
// the lens: bloom, a streak, the flash.
//
// The mod hands it sixteen numbers each frame, `frame.mod_params`:
//   [0] target x, y, z (the point hit), strike clock in seconds
//   [1] hit block centre x, z, the wings' facing (radians: towards the player, the mothership points away), laser
//   [2] seed, intensity, capture mode (0 off, 3 video capture), hit block y
//   [3] the mothership's approach (0 towards the player, 1 from behind them, 2 from their left, 3 from their right,
//       4 from overhead), and how it arrives (0 snap, 1 unfold, 2 warp); unused by the others
//
// Lasers:
//   0 Plasma   a raging plasma beam, forked lightning, a churning fireball, a smoke plume
//   1 Godly    the clouds part, a calm pillar of light comes down, halo rings and wings stand
//              in the sky, six pillars of light land round a golden sigil, a dome of light
//   2 Black hole  a singularity over the target bends the light round it; an accretion disk, a jet
//              out of both poles, the land dragged in, and it evaporates in a flash (`singularity`)
//   3 Meteor storm  meteors pound the land round the target, then one the size of a hill lands on it: a
//              fireball, a shockwave, ejecta across the sky and a sky gone brown with dust (`meteor_storm`)
//   4 Mothership  a slab of dark metal a kilometre long drops out of hyperspace over the target and stops dead, its
//              shadow on the land; its emitters' green beams meet under it, and one beam comes down and sweeps away,
//              cutting a molten trench; then it is gone (`mothership`)
//   5 Downfall  its own pass (shaders/downfall.wgsl, after everything here up to fs_main): the mothership brought down
//              by a meteor, its black hole engine rupturing (`downfall`). [3].z there is how far downrange its stern
//              comes to rest. Kept out of this pass so its size costs the other lasers nothing.

fn target_x() -> f32 { return frame.mod_params[0].x; }
fn target_y() -> f32 { return frame.mod_params[0].y; }
fn target_z() -> f32 { return frame.mod_params[0].z; }
fn anchor_x() -> f32 { return frame.mod_params[1].x; }
fn anchor_z() -> f32 { return frame.mod_params[1].y; }
fn wing_a() -> f32 { return frame.mod_params[1].z; }
fn laser() -> f32 { return frame.mod_params[1].w; }
fn seed_v() -> f32 { return frame.mod_params[2].x; }
fn intensity_v() -> f32 { return max(frame.mod_params[2].y, 0.05); }
fn capture() -> f32 { return frame.mod_params[2].z; }
fn block_y() -> f32 { return frame.mod_params[2].w; }
fn approach() -> i32 { return i32(frame.mod_params[3].x + 0.5); }
// The ship lasers' own light, in the colour picked for them (frame.mod_params[3].w: 0 green, the Mothership's own, 1 red,
// 2 amber, 3 blue, 4 violet, 5 white): their green lights taken through a matrix (each column what that channel turns
// into). Green leaves them exactly as they are.
fn ship_tint(c: vec3<f32>) -> vec3<f32> {
    let i = i32(frame.mod_params[3].w + 0.5);
    if (i <= 0) {
        return c;
    }
    var m = mat3x3<f32>(0.25, 0.25, 0.25, 0.62, 0.65, 0.68, 0.1, 0.1, 0.1);
    switch i {
        case 1: { m = mat3x3<f32>(0.2, 0.35, 0.0, 1.0, 0.1, 0.03, 0.0, 0.0, 0.2); }
        case 2: { m = mat3x3<f32>(0.2, 0.3, 0.0, 1.0, 0.55, 0.05, 0.0, 0.0, 0.15); }
        case 3: { m = mat3x3<f32>(0.1, 0.1, 0.2, 0.12, 0.45, 1.0, 0.0, 0.1, 0.3); }
        case 4: { m = mat3x3<f32>(0.2, 0.2, 0.1, 0.7, 0.12, 1.0, 0.0, 0.0, 0.3); }
        default: {}
    }
    return m * c;
}
fn arrival_style() -> i32 { return i32(frame.mod_params[3].y + 0.5); }

const TAU: f32 = 6.2831853;
const T_FIRE: f32 = 4.0;
const PILLAR_R: f32 = 40.0;       // keep in step with strike.py: GODLY_PILLAR_R, GODLY_PILLAR_A0
const PILLAR_A0: f32 = 0.5235988;
const SIGIL_R1: f32 = 31.0;       // the inner etched ring (godly bowl_r + 3)

fn hash21(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(127.1, 311.7))) * 43758.5453);
}

fn hash31(p: vec3<f32>) -> f32 {
    return fract(sin(dot(p, vec3<f32>(127.1, 311.7, 74.7))) * 43758.5453);
}

fn vnoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash21(i);
    let b = hash21(i + vec2<f32>(1.0, 0.0));
    let c = hash21(i + vec2<f32>(0.0, 1.0));
    let d = hash21(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn fbm(p: vec2<f32>) -> f32 {
    let o = vec2<f32>(17.3, 9.1);
    let q1 = p * 2.03 + o;
    let q2 = q1 * 2.03 + o;
    let q3 = q2 * 2.03 + o;
    let q4 = q3 * 2.03 + o;
    return 0.5 * vnoise(p) + 0.25 * vnoise(q1) + 0.125 * vnoise(q2) + 0.0625 * vnoise(q3) + 0.03125 * vnoise(q4);
}

fn vnoise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mix(hash31(i), hash31(i + vec3<f32>(1.0, 0.0, 0.0)), u.x);
    let b = mix(hash31(i + vec3<f32>(0.0, 1.0, 0.0)), hash31(i + vec3<f32>(1.0, 1.0, 0.0)), u.x);
    let c = mix(hash31(i + vec3<f32>(0.0, 0.0, 1.0)), hash31(i + vec3<f32>(1.0, 0.0, 1.0)), u.x);
    let d = mix(hash31(i + vec3<f32>(0.0, 1.0, 1.0)), hash31(i + vec3<f32>(1.0, 1.0, 1.0)), u.x);
    return mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
}

fn fbm3(p: vec3<f32>) -> f32 {
    let q = p * 2.07 + vec3<f32>(5.1, 1.3, 7.7);
    let r = q * 2.11 + vec3<f32>(2.9, 8.3, 4.1);
    return 0.55 * vnoise3(p) + 0.3 * vnoise3(q) + 0.15 * vnoise3(r);
}

// Cheaper noise for the heavy passes (the black hole, the meteor storm): an integer hash (PCG) instead of sin.
fn pcg(x: u32) -> u32 {
    let s = x * 747796405u + 2891336453u;
    let w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
fn fh21(p: vec2<f32>) -> f32 {
    let q = bitcast<vec2<u32>>(vec2<i32>(floor(p)));
    return f32(pcg(q.x ^ pcg(q.y))) * (1.0 / 4294967295.0);
}
fn fh31(p: vec3<f32>) -> f32 {
    let q = bitcast<vec3<u32>>(vec3<i32>(floor(p)));
    return f32(pcg(q.x ^ pcg(q.y ^ pcg(q.z)))) * (1.0 / 4294967295.0);
}
fn fvnoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(fh21(i), fh21(i + vec2<f32>(1.0, 0.0)), u.x), mix(fh21(i + vec2<f32>(0.0, 1.0)), fh21(i + vec2<f32>(1.0, 1.0)), u.x), u.y);
}
fn ffbm(p: vec2<f32>) -> f32 {
    return 0.55 * fvnoise(p) + 0.3 * fvnoise(p * 2.03 + vec2<f32>(17.3, 9.1)) + 0.15 * fvnoise(p * 4.1 + vec2<f32>(3.1, 5.7));
}
fn fvnoise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = mix(fh31(i), fh31(i + vec3<f32>(1.0, 0.0, 0.0)), u.x);
    let b = mix(fh31(i + vec3<f32>(0.0, 1.0, 0.0)), fh31(i + vec3<f32>(1.0, 1.0, 0.0)), u.x);
    let c = mix(fh31(i + vec3<f32>(0.0, 0.0, 1.0)), fh31(i + vec3<f32>(1.0, 0.0, 1.0)), u.x);
    let d = mix(fh31(i + vec3<f32>(0.0, 1.0, 1.0)), fh31(i + vec3<f32>(1.0, 1.0, 1.0)), u.x);
    return mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
}
fn ffbm3(p: vec3<f32>) -> f32 {
    return 0.62 * fvnoise3(p) + 0.38 * fvnoise3(p * 2.07 + vec3<f32>(5.1, 1.3, 7.7));
}

fn lava_ramp(x: f32) -> vec3<f32> {
    let h = saturate(x);
    var c = mix(vec3<f32>(0.02, 0.0, 0.0), vec3<f32>(0.7, 0.05, 0.0), smoothstep(0.0, 0.3, h));
    c = mix(c, vec3<f32>(1.0, 0.38, 0.02), smoothstep(0.25, 0.55, h));
    c = mix(c, vec3<f32>(1.0, 0.85, 0.35), smoothstep(0.5, 0.8, h));
    c = mix(c, vec3<f32>(1.0, 1.0, 1.0), smoothstep(0.8, 1.0, h));
    return c;
}

fn gold_ramp(x: f32) -> vec3<f32> {
    let h = saturate(x);
    var c = mix(vec3<f32>(0.12, 0.05, 0.0), vec3<f32>(0.85, 0.45, 0.05), smoothstep(0.0, 0.3, h));
    c = mix(c, vec3<f32>(1.0, 0.82, 0.3), smoothstep(0.25, 0.6, h));
    c = mix(c, vec3<f32>(1.0, 0.98, 0.9), smoothstep(0.6, 1.0, h));
    return c;
}

// The plasma fireball's colour by temperature: smoke, a violet-blue body, cyan, then white.
fn plasma_ramp(x: f32) -> vec3<f32> {
    let h = saturate(x);
    var c = mix(vec3<f32>(0.0), vec3<f32>(0.35, 0.08, 0.6), smoothstep(0.05, 0.3, h));
    c = mix(c, vec3<f32>(0.3, 0.6, 2.2), smoothstep(0.25, 0.55, h));
    c = mix(c, vec3<f32>(1.2, 2.0, 3.0), smoothstep(0.5, 0.8, h));
    c = mix(c, vec3<f32>(4.0, 4.0, 4.2), smoothstep(0.8, 1.0, h));
    return c;
}

// 1 when `theme` is i, else 0 (the option arrives as a float).
fn th_is(i: f32) -> f32 {
    return 1.0 - step(0.5, abs(laser() - i));
}

fn pick2(a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    return a * th_is(0.0) + b * th_is(1.0);
}

fn aces(x: vec3<f32>) -> vec3<f32> {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

fn target_pos() -> vec3<f32> {
    var v = vec3<f32>(0.0);
    v.x = target_x();
    v.y = target_y();
    v.z = target_z();
    return v;
}

fn anchor_xz() -> vec2<f32> {
    var v = vec2<f32>(0.0);
    v.x = anchor_x();
    v.y = anchor_z();
    return v;
}

fn wing_dirs() -> vec4<f32> {
    // xy: the wings' facing (towards the shooter), zw: the span direction, both in the xz plane
    let a = wing_a();
    let c = cos(a);
    let s = sin(a);
    return vec4<f32>(c, s, -s, c);
}

// The strike's clock (it starts at 0 when the designator fires): the mod gives its whole ticks, and the frame's partial
// tick (frame.time.w, the one the camera is drawn at) carries it on between them, so what it moves stays in step with a
// moving camera (the mod's own count of the time since its tick ran ahead of or behind the camera's by up to a frame:
// what flies jittered against the camera as it moved).
fn now() -> f32 {
    return frame.mod_params[0].w + frame.time.w * 0.05;
}

// What frame.camera_position's f32 rounding leaves out of where the camera is (the fork's api-10 prelude): for a
// difference from it taken first, then less this, exact far from the world's origin.
fn camera_rest() -> vec3<f32> {
    return frame.camera_rest.xyz;
}

fn phase_time() -> f32 {
    return now();
}

// Screen uv of a camera-relative world point; z < 0 when behind the camera.
fn project_rel(p: vec3<f32>) -> vec3<f32> {
    let clip = frame.projection * (frame.view * vec4<f32>(p, 1.0));
    let ndc = clip.xy / max(abs(clip.w), 1e-4);
    return vec3<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5, select(-1.0, 1.0, clip.w > 0.0));
}

fn bolt_disp(len: f32, u: f32, seed: f32, tq: f32) -> f32 {
    let amp = len * 0.2;
    let n1 = (vnoise(vec2<f32>(u * 4.0 + seed, tq)) - 0.5) * 2.0;
    let n2 = (vnoise(vec2<f32>(u * 13.0 + seed * 3.1, tq * 1.7)) - 0.5) * 2.0;
    let n3 = (vnoise(vec2<f32>(u * 41.0 + seed * 5.3, tq * 2.3)) - 0.5) * 2.0;
    return (n1 * amp + n2 * amp * 0.38 + n3 * amp * 0.12) * smoothstep(0.0, 0.1, u);
}

// x: hot core, y: soft glow, z: position along the bolt (0 at its root)
fn bolt_line(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>, seed: f32, tq: f32, wid: f32) -> vec3<f32> {
    let ab = b - a;
    let len = max(length(ab), 1.0e-4);
    let dir = ab / len;
    let nrm = vec2<f32>(-dir.y, dir.x);
    let ap = p - a;
    let u = clamp(dot(ap, dir) / len, 0.0, 1.0);
    let off = dot(ap, nrm) - bolt_disp(len, u, seed, tq);
    let along = dot(ap, dir) - u * len;
    let d = length(vec2<f32>(off, along));
    let w = wid * (1.0 - 0.75 * u);
    let core = exp(-pow(d / w, 2.0));
    let g = 1.0 / (1.0 + pow(d / (w * 3.0), 2.0));
    return vec3<f32>(core, g * g, u);
}

// Soft capsule between two points of a plane (world units): x = hot core, y = glow. Thinner towards the far end.
fn seg_soft(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>, w: f32) -> vec2<f32> {
    let ab = b - a;
    let l2 = max(dot(ab, ab), 1.0e-8);
    let u = clamp(dot(p - a, ab) / l2, 0.0, 1.0);
    let d = length(p - (a + ab * u));
    let ww = w * (1.0 - 0.65 * u);
    return vec2<f32>(exp(-pow(d / ww, 2.0)), 1.0 / (1.0 + pow(d / (ww * 4.0), 2.0)));
}

// Distance-based edge of one equilateral triangle (circumradius R) at polar (r, ang); its edges face ang = 0, 120, 240 degrees.
fn tri_line(r: f32, ang: f32, R: f32, w: f32) -> f32 {
    let sector = TAU / 3.0;
    let a = ang - floor(ang / sector + 0.5) * sector;
    let d = r * cos(a) - R * 0.5;
    return exp(-pow(d / w, 2.0)) * (1.0 - smoothstep(R * 0.98, R * 1.04, r));
}

// Distance from the view ray to a vertical axis at xz `c` (camera-relative): x = ray distance at closest approach,
// y = distance from the axis there, z = height of that point. x < 0 when the axis is behind.
fn axis_hit(c: vec2<f32>, v2: vec2<f32>, vv: f32, cam_y: f32, rdy: f32) -> vec3<f32> {
    var t = length(c);
    var d = length(c);
    if (vv > 1.0e-5) {
        t = dot(c, v2) / vv;
        d = length(c - v2 * t);
    }
    return vec3<f32>(t, d, cam_y + rdy * t);
}

// ---- laser 2: the black hole ----------------------------------------------------------------
// A singularity hangs over the target. Light is bent round it by marching each view ray that passes near it through
// the hole's gravity (the photon orbit equation, r'' = -1.5 h^2 r / |r|^5, in horizon radii): rays that fall in are
// black, rays that cross the disk pick up its light, and the rest resample the scene (or the starry sky) in the
// direction they leave in. Its jet is a vertical column like the other lasers' beams.

const HOLE_H: f32 = 28.0;         // keep in step with strike.rs: HOLE_H, BH_END
const BH_END: f32 = 10.0;
const BH_RS: f32 = 3.6;           // the horizon's radius, in blocks
const DISK_IN: f32 = 2.6;         // the accretion disk, in horizon radii
const DISK_OUT: f32 = 9.0;
const LENS_R: f32 = 12.0;         // how far out light is bent, in horizon radii

// A dark sky of stars and violet haze, looking along `d`.
fn bh_sky(d: vec3<f32>, seed: f32) -> vec3<f32> {
    let q = d * 140.0;
    let f = fract(q) - 0.5;
    let h = fh31(floor(q) + vec3<f32>(seed));
    let star = step(0.975, h) * exp(-dot(f, f) * 40.0) * (0.5 + 4.0 * fract(h * 37.0));
    let tint = mix(vec3<f32>(0.7, 0.8, 1.25), vec3<f32>(1.25, 0.9, 0.7), fract(h * 91.0));
    let neb = ffbm3(d * 2.6 + vec3<f32>(seed * 0.01));
    let neb2 = ffbm3(d * 6.0 - vec3<f32>(2.0, 0.0, 1.0));
    let haze = vec3<f32>(0.10, 0.02, 0.17) * smoothstep(0.4, 0.85, neb) + vec3<f32>(0.02, 0.04, 0.13) * smoothstep(0.5, 0.9, neb2);
    return tint * star + haze;
}

// The disk's colour by temperature: dull red at the rim, orange, white, then blue-white at the inner edge.
fn disk_ramp(x: f32) -> vec3<f32> {
    let h = saturate(x);
    var c = mix(vec3<f32>(0.0), vec3<f32>(0.7, 0.07, 0.02), smoothstep(0.0, 0.25, h));
    c = mix(c, vec3<f32>(2.4, 0.75, 0.12), smoothstep(0.2, 0.5, h));
    c = mix(c, vec3<f32>(3.4, 2.5, 1.35), smoothstep(0.45, 0.75, h));
    c = mix(c, vec3<f32>(3.2, 3.6, 5.0), smoothstep(0.75, 1.0, h));
    return c;
}

// The scene at `uvs`, dimmed, its sky turned to the black hole's starry dark (seen along `dir`).
fn bh_scene(uvs: vec2<f32>, dir: vec3<f32>, seed: f32, sky_env: f32, dim: f32) -> vec3<f32> {
    let c = srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, uvs, 0.0).rgb) * dim;
    if (is_sky(depth_at(uvs))) {
        return mix(c, bh_sky(dir, seed), sky_env * 0.94);
    }
    return c;
}

// ---- the black hole's debris: blocks torn out of the ground, spiralling in, eaten or flung ----
// strike.rs tears the same blocks out of the ground at the same moments (debris_*): keep the formulas in step.
const DEBRIS: i32 = 160;

fn debris_angle(fi: f32, seed: f32) -> f32 { return fract(fi * 0.381966 + seed * 0.1137) * TAU; }
fn debris_r0(fi: f32, seed: f32) -> f32 { return 35.0 + 15.0 * fract(fi * 0.618034 + seed * 0.1234); }
fn debris_t(fi: f32) -> f32 { return 0.4 + 6.0 * fi / f32(DEBRIS) + 0.3 * fract(fi * 0.7548777); }
fn debris_big(fi: f32, seed: f32) -> bool { return fract(fi * 0.2763932 + seed * 0.0517) > 0.78; }

fn rot_axis(v: vec3<f32>, a: vec3<f32>, ang: f32) -> vec3<f32> {
    let c = cos(ang);
    let s = sin(ang);
    return v * c + cross(a, v) * s + a * dot(a, v) * (1.0 - c);
}

// ---- falling into a black hole (the Black Hole's and the Downfall's debris, and the Downfall's wreck) ----
// How far out a piece is `u` (0 to 1) of the way through its fall from `r0`: from rest, slowly at first, then faster and
// faster, through the horizon and into the middle by u = 1 (r0 (1 - u²)^(2/3), close to a free fall's).
fn bh_fall(r0: f32, u: f32) -> f32 {
    return r0 * pow(max(1.0 - u * u, 0.0), 0.6667);
}
// How many times as long a piece `l0` long is drawn out at `u` through its fall from `r0` (its near end at `r`, bh_fall):
// its far end falls the same way from further out, so later (`lag` times as long: the free fall's time goes as r^1.5),
// and the gap between them grows faster and faster as they near the hole; at most 6 times.
fn bh_tide(r0: f32, l0: f32, r: f32, u: f32, lag: f32) -> f32 {
    return clamp((bh_fall(r0 + l0, u / lag) - r) / l0, 1.0, 6.0);
}
// No less than bh_tide, without its pow (the far end's fall to first order): for culling.
fn bh_tide_max(r0: f32, l0: f32, r: f32, u: f32, lag: f32) -> f32 {
    let rt = (r0 + l0) / r0 * r * (1.0 + 1.3333 * u * u * (1.0 - 1.0 / lag) / max(1.0 - u * u, 1.0e-4));
    return select(clamp((rt - r) / l0, 1.0, 6.0), 6.0, u > 0.97);
}
// The light from something `r` from the hole: redder and dimmer nearer the horizon (climbing out of the hole's pull),
// none from the horizon in.
fn bh_redshift(r: f32, rs: f32) -> vec3<f32> {
    let z = sqrt(saturate(1.0 - rs / max(r, 1.0e-3)));
    return vec3<f32>(pow(z, 0.7), pow(z, 1.6), pow(z, 2.6));
}
// A ray from the camera (`rd`) against a piece falling in: a box of half-size `hs`, turned `ang` about `ax`, drawn out
// `k` times along `u` (out from the hole) and thinned across about its middle `c` (camera-relative); none of it from the
// horizon (`rs` round `H`) in. How far (x, -1: missed), and where on it in its own space (yzw, the box -1 to 1).
fn bh_chunk(c: vec3<f32>, rd: vec3<f32>, u: vec3<f32>, k: f32, hs: f32, ax: vec3<f32>, ang: f32, H: vec3<f32>, rs: f32) -> vec4<f32> {
    let sk = sqrt(k);
    let ro = -c;
    let ro_s = (ro - u * dot(u, ro)) * sk + u * dot(u, ro) / k;
    let rd_s = (rd - u * dot(u, rd)) * sk + u * dot(u, rd) / k;
    let ro_l = rot_axis(ro_s, ax, -ang) / hs;
    let rd_l = rot_axis(rd_s, ax, -ang) / hs;
    let inv = 1.0 / select(rd_l, vec3<f32>(1.0e-6), abs(rd_l) < vec3<f32>(1.0e-6));
    let ta = (vec3<f32>(-1.0) - ro_l) * inv;
    let tb = (vec3<f32>(1.0) - ro_l) * inv;
    let tlo = min(ta, tb);
    let thi = max(ta, tb);
    let tn = max(max(tlo.x, tlo.y), tlo.z);
    let tf = min(min(thi.x, thi.y), thi.z);
    // (where the ray meets it inside the horizon, what is behind is in the hole's shadow)
    if (tf < tn || tn < 0.0 || length(rd * tn - H) < rs) {
        return vec4<f32>(-1.0);
    }
    return vec4<f32>(tn, ro_l + rd_l * tn);
}
// The world normal of the face of a bh_chunk box at `lp` (its own space).
fn bh_chunk_n(lp: vec3<f32>, u: vec3<f32>, k: f32, ax: vec3<f32>, ang: f32) -> vec3<f32> {
    let al = abs(lp);
    var nl = vec3<f32>(0.0, sign(lp.y), 0.0);
    if (al.x >= al.y && al.x >= al.z) {
        nl = vec3<f32>(sign(lp.x), 0.0, 0.0);
    } else if (al.z >= al.y) {
        nl = vec3<f32>(0.0, 0.0, sign(lp.z));
    }
    // (the stretch is symmetric, so normals go back through it as it is)
    let ns = rot_axis(nl, ax, ang);
    return normalize((ns - u * dot(u, ns)) * sqrt(k) + u * dot(u, ns) / k);
}

// One piece of debris: where its near end is (camera-relative), its radial direction from the hole, how stretched it
// is (or below 0: drawn out by the tides, worked out by bh_tide from `tide` (r0, l0, u, lag) and `r` only once the ray is
// known to pass near it), how hot, how present (0: not there).
struct Piece {
    c: vec3<f32>,
    u: vec3<f32>,
    k: f32,
    glow: f32,
    alive: f32,
    tide: vec4<f32>,
    r: f32,
}

fn debris_piece(i: i32, ft: f32, seed: f32, cam: vec3<f32>, tgt: vec3<f32>, H: vec3<f32>, n: vec3<f32>, rs: f32) -> Piece {
    var pc: Piece;
    pc.alive = 0.0;
    pc.k = 1.0;
    pc.glow = 0.0;
    pc.u = vec3<f32>(0.0, 1.0, 0.0);
    pc.c = vec3<f32>(0.0);
    let fi = f32(i);
    let t_rip = debris_t(fi);
    let s = min(ft, BH_END) - t_rip;
    if (s <= 0.0) {
        return pc;
    }
    let a0 = debris_angle(fi, seed);
    let R0 = debris_r0(fi, seed);
    let big = debris_big(fi, seed);
    let h1 = fh21(vec2<f32>(fi, seed + 5.0));
    let h2 = fh21(vec2<f32>(fi, seed + 9.0));
    let T_in = 2.6 + 1.4 * h2;
    let flung = h1 < 0.28;
    let u_f = 0.5 + 0.2 * h2;
    let ub = s / T_in;
    let l0 = select(1.0, 2.0, big);
    let lag = (R0 + l0) / R0 * sqrt((R0 + l0) / R0);
    let u = min(ub, select(lag, u_f, flung));
    // the disk's plane, with world x and z laid onto it so the orbit starts where the block was torn out
    let E1 = normalize(vec3<f32>(1.0, 0.0, 0.0) - n * n.x);
    let E2 = normalize(vec3<f32>(0.0, 0.0, 1.0) - n * n.z - E1 * dot(vec3<f32>(0.0, 0.0, 1.0), E1));
    let rsn = max(rs, 0.6);
    // its near end falls from rest, faster and faster, through the horizon to the middle; its far end, a block or two
    // further out, falls in a little after it (the free fall's time goes as r^1.5): so the tides draw it out along the
    // way in, more and more as it nears the hole
    let r = bh_fall(R0, u);
    let th = a0 - (3.0 + 3.0 * h1) * u * u;                    // the same way round as the disk turns
    let lift = smoothstep(0.0, 0.45, u);
    // torn out of the ground where strike.rs removes it (block-aligned), then up into the disk's plane
    let src = floor(tgt.xz + vec2<f32>(cos(a0), sin(a0)) * R0) + select(vec2<f32>(0.5), vec2<f32>(0.0), big);
    let gy = block_y() + select(0.5, 0.0, big);           // the hit block's layer, which the blast levels the ground to
    let ground = vec3<f32>(src.x, gy, src.y) - cam;
    let ground_r = vec3<f32>(tgt.x - cam.x, gy - cam.y, tgt.z - cam.z) + vec3<f32>(cos(th), 0.0, sin(th)) * r;
    let gp = mix(ground, ground_r, smoothstep(0.0, 0.15, u));
    let dp = H + (E1 * cos(th) + E2 * sin(th)) * r;
    var c = mix(gp, dp, lift) + vec3<f32>(0.0, sin(lift * 3.14159) * 7.0, 0.0);
    var alive = smoothstep(0.0, 0.05, s);
    var stretch = select(1.0, -bh_tide_max(R0, l0, r, u, lag), !flung || ub < u_f);
    if (flung && ub > u_f) {
        // slingshot round the hole and away
        let dt = (ub - u_f) * T_in;
        let tdir = E1 * sin(th) - E2 * cos(th);
        c = c + (tdir * 65.0 + n * 16.0) * dt;
        alive = alive * (1.0 - smoothstep(2.5, 4.0, dt));
        stretch = 1.0;
    } else if (!flung) {
        // eaten: gone once its far end too is through the horizon
        alive = alive * (1.0 - step(lag, ub));
    }
    if (ft > BH_END) {
        // what was still circling when it evaporated is thrown outwards
        let ef = ft - BH_END;
        c = c + normalize(c - H) * ef * 70.0;
        alive = alive * (1.0 - smoothstep(1.0, 2.5, ef));
        stretch = 1.0;
    }
    pc.u = normalize(c - H + vec3<f32>(1.0e-4));
    pc.c = c;
    pc.k = stretch;
    pc.tide = vec4<f32>(R0, l0, u, lag);
    pc.r = r;
    pc.glow = select(smoothstep(rsn * 4.0, rsn * 1.2, r), 0.0, flung && ub > u_f) * f32(ft <= BH_END);
    pc.alive = alive;
    return pc;
}

// A block's face colour (sRGB) at face pixel `px`: grass, dirt, stone, deepslate, log or leaves.
fn debris_tex(kind: i32, px: vec2<f32>, top: bool, side_y: f32, seed: f32) -> vec3<f32> {
    let nz = fh21(px + vec2<f32>(seed * 3.1, f32(kind) * 17.0));
    let nz2 = fh21(px * 1.7 + vec2<f32>(5.0, seed));
    switch kind {
        case 0: {
            if (top || side_y > 0.8) {
                return vec3<f32>(0.33, 0.55, 0.2) * (0.75 + 0.45 * nz);
            }
            return vec3<f32>(0.52, 0.36, 0.24) * (0.75 + 0.45 * nz);
        }
        case 1: { return vec3<f32>(0.52, 0.36, 0.24) * (0.75 + 0.45 * nz); }
        case 2: { return vec3<f32>(0.5, 0.5, 0.5) * (0.78 + 0.35 * nz) * (0.9 + 0.1 * nz2); }
        case 3: { return vec3<f32>(0.27, 0.27, 0.3) * (0.75 + 0.4 * nz); }
        case 4: {
            if (top) {
                let ring = fract(length(px - vec2<f32>(7.5)) * 0.35);
                return mix(vec3<f32>(0.68, 0.55, 0.34), vec3<f32>(0.5, 0.38, 0.22), step(0.5, ring)) * (0.9 + 0.2 * nz);
            }
            return vec3<f32>(0.4, 0.31, 0.19) * (0.7 + 0.5 * hash21(vec2<f32>(px.x, seed))) * (0.9 + 0.2 * nz);
        }
        default: {
            return vec3<f32>(0.2, 0.42, 0.13) * (0.5 + 0.8 * nz) * (0.6 + 0.4 * step(0.25, nz2));
        }
    }
}

// What a view ray brings back past a black hole at `H` (camera-relative) of horizon radius `rs_l`: it is marched through
// the hole's gravity (the photon orbit equation, in horizon radii), picking up the disk's light (`acc`, seen through
// `trans` of it) where it crosses the disk's plane (normal `n`, `e1` `e2` in it), and either falls in (`captured`), ends
// on the scene (`hit`), or leaves along `v` from `p` (camera-relative) and resamples the scene that way (`bent`; `w`
// how much the bending counts). `on`: whether the ray came near enough to be bent at all.
struct BhLens {
    on: bool,
    captured: bool,
    hit: bool,
    bent: vec3<f32>,
    trans: f32,
    acc: vec3<f32>,
    rmin: f32,
    p: vec3<f32>,
    v: vec3<f32>,
    w: f32,
}
fn bh_lens(H: vec3<f32>, rs_l: f32, rd: vec3<f32>, uv2: vec2<f32>, scene_len: f32, sky: bool, n: vec3<f32>, e1: vec3<f32>,
           e2: vec3<f32>, disk_env: f32, hot: f32, seed: f32, time: f32, sky_env: f32, dim: f32) -> BhLens {
    var L: BhLens;
    L.on = false;
    L.captured = false;
    L.hit = false;
    L.bent = vec3<f32>(0.0);
    L.trans = 1.0;
    L.acc = vec3<f32>(0.0);
    L.rmin = 1.0e9;
    L.p = vec3<f32>(0.0);
    L.v = rd;
    L.w = 0.0;
    let infl = LENS_R * rs_l;
    let tc = dot(H, rd);
    let b = length(H - rd * tc);
    let t0 = max(tc - infl, 0.0);
    if (b < infl && tc + infl > 0.0 && scene_len > t0) {
        L.on = true;
        var pp = (rd * t0 - H) / rs_l;                     // the ray, relative to the hole, in horizon radii
        var v = rd;
        var travel = t0;
        let hv = cross(pp, v);
        let h2 = dot(hv, hv);
        var trans = 1.0;
        var acc = vec3<f32>(0.0);
        var captured = false;
        var hit = false;
        var rmin = 1.0e9;
        for (var i = 0; i < 96; i = i + 1) {
            let r = length(pp);
            rmin = min(rmin, r);
            if (r < 1.0) {
                captured = true;
                break;
            }
            if (r > LENS_R + 0.5 && dot(pp, v) > 0.0) {
                break;
            }
            let dt = clamp((r - 0.9) * 0.16, 0.03, 1.5);
            let prev = pp;
            let r2 = r * r;
            v = normalize(v - 1.5 * h2 * pp / (r2 * r2 * r) * dt);
            pp = pp + v * dt;
            travel = travel + dt * rs_l;
            if (!sky && travel > scene_len) {
                hit = true;
                break;
            }
            // crossing the disk's plane: its light, seen through whatever bending got the ray here
            let s0 = dot(prev, n);
            let s1 = dot(pp, n);
            if (disk_env > 0.001 && s0 * s1 < 0.0) {
                let x = mix(prev, pp, s0 / (s0 - s1));
                let dr = length(x);
                if (dr > DISK_IN * 0.9 && dr < DISK_OUT) {
                    let dx = vec2<f32>(dot(x, e1), dot(x, e2));
                    // inner rings turn faster than outer ones (Kepler), so the gas shears into streaks
                    let rot = -time * 5.5 / pow(dr, 1.5);
                    let q = vec2<f32>(dx.x * cos(rot) - dx.y * sin(rot), dx.x * sin(rot) + dx.y * cos(rot));
                    let nz = fbm(q * 0.9 + vec2<f32>(seed, 3.0));
                    let bands = 0.55 + 0.45 * sin(dr * 7.0 + nz * 7.0);
                    let dens = saturate(bands * (0.35 + 1.1 * nz));
                    let edge = smoothstep(DISK_IN * 0.9, DISK_IN * 1.15, dr) * (1.0 - smoothstep(DISK_OUT * 0.55, DISK_OUT, dr));
                    // the side turning towards you is brighter and bluer (relativistic beaming)
                    let tdir = normalize(cross(n, x));
                    let beta = 0.62 * sqrt(DISK_IN / dr);
                    let g = sqrt(1.0 - beta * beta) / (1.0 - beta * dot(tdir, -v));
                    let temp = pow(DISK_IN / dr, 0.85) * (0.7 + 0.4 * nz) * g * 0.95 * hot;
                    let a_d = saturate(dens * edge * 1.1) * disk_env;
                    acc = acc + trans * a_d * disk_ramp(temp) * min(g * g * g, 4.0) * 1.6;
                    trans = trans * (1.0 - a_d * 0.92);
                }
            }
            if (trans < 0.02) {
                break;
            }
        }
        // how much the bending counts: all of it near the hole, none at the edge, so it meets the unbent world
        let w = 1.0 - smoothstep(LENS_R * 0.35, LENS_R * 0.95, rmin);
        var bent = vec3<f32>(0.0);
        if (!captured) {
            let dir_b = normalize(mix(rd, v, w));
            var far = H + pp * rs_l + v * 4000.0;
            if (hit) {
                far = H + pp * rs_l;
            }
            let pr = project_rel(far);
            let uvb = mix(uv2, pr.xy, w);
            let on = pr.z > 0.0 && all(uvb > vec2<f32>(0.001)) && all(uvb < vec2<f32>(0.999));
            if (on || w < 0.01) {
                bent = bh_scene(clamp(uvb, vec2<f32>(0.001), vec2<f32>(0.999)), dir_b, seed, sky_env, dim);
            } else if (dir_b.y > -0.03) {
                bent = bh_sky(dir_b, seed) * sky_env + vec3<f32>(0.03, 0.025, 0.04) * (1.0 - sky_env);
            } else {
                bent = vec3<f32>(0.02, 0.016, 0.022) * dim;
            }
        }
        L.captured = captured;
        L.hit = hit;
        L.bent = bent;
        L.trans = trans;
        L.acc = acc;
        L.rmin = rmin;
        L.p = H + pp * rs_l;
        L.v = v;
        L.w = w;
    }
    return L;
}


// Gradient noise (smooth, without the square grid value noise shows), from a cheap integer hash, for the meteor
// storm's fire and smoke. Each octave is turned so their grids never line up.
fn pcg3d(v0: vec3<u32>) -> vec3<u32> {
    var v = v0 * 1664525u + 1013904223u;
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    v = v ^ (v >> vec3<u32>(16u));
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    return v;
}
fn grad3(i: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(pcg3d(bitcast<vec3<u32>>(vec3<i32>(i)))) * (2.0 / 4294967295.0) - 1.0;
}
fn gnoise3(p: vec3<f32>) -> f32 {
    let i = floor(p);
    let f = p - i;
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let n000 = dot(grad3(i), f);
    let n100 = dot(grad3(i + vec3<f32>(1.0, 0.0, 0.0)), f - vec3<f32>(1.0, 0.0, 0.0));
    let n010 = dot(grad3(i + vec3<f32>(0.0, 1.0, 0.0)), f - vec3<f32>(0.0, 1.0, 0.0));
    let n110 = dot(grad3(i + vec3<f32>(1.0, 1.0, 0.0)), f - vec3<f32>(1.0, 1.0, 0.0));
    let n001 = dot(grad3(i + vec3<f32>(0.0, 0.0, 1.0)), f - vec3<f32>(0.0, 0.0, 1.0));
    let n101 = dot(grad3(i + vec3<f32>(1.0, 0.0, 1.0)), f - vec3<f32>(1.0, 0.0, 1.0));
    let n011 = dot(grad3(i + vec3<f32>(0.0, 1.0, 1.0)), f - vec3<f32>(0.0, 1.0, 1.0));
    let n111 = dot(grad3(i + vec3<f32>(1.0, 1.0, 1.0)), f - vec3<f32>(1.0, 1.0, 1.0));
    let x0 = mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y);
    let x1 = mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y);
    return mix(x0, x1, u.z) * 0.75 + 0.5;
}
fn gfbm3(p: vec3<f32>, octaves: i32) -> f32 {
    let m = mat3x3<f32>(0.00, 0.80, 0.60, -0.80, 0.36, -0.48, -0.60, -0.48, 0.64);
    var q = p;
    var a = 0.5;
    var s = 0.0;
    var w = 0.0;
    for (var o = 0; o < octaves; o = o + 1) {
        s = s + a * gnoise3(q);
        w = w + a;
        q = m * q * 2.03 + vec3<f32>(1.7, 9.2, 5.3);
        a = a * 0.5;
    }
    return s / w;
}
fn grad2(i: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(pcg3d(bitcast<vec3<u32>>(vec3<i32>(vec2<i32>(i), 7))).xy) * (2.0 / 4294967295.0) - 1.0;
}
fn gnoise2(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = p - i;
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let a = dot(grad2(i), f);
    let b = dot(grad2(i + vec2<f32>(1.0, 0.0)), f - vec2<f32>(1.0, 0.0));
    let c = dot(grad2(i + vec2<f32>(0.0, 1.0)), f - vec2<f32>(0.0, 1.0));
    let d = dot(grad2(i + vec2<f32>(1.0, 1.0)), f - vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 0.9 + 0.5;
}
fn gfbm2(p: vec2<f32>) -> f32 {
    let m = mat2x2<f32>(0.8, 0.6, -0.6, 0.8);
    let q1 = m * p * 2.03 + vec2<f32>(1.7, 9.2);
    let q2 = m * q1 * 2.01 + vec2<f32>(5.3, 2.8);
    return (0.5 * gnoise2(p) + 0.25 * gnoise2(q1) + 0.125 * gnoise2(q2)) / 0.875;
}
// A dither that changes from pixel to pixel without clumping, to hide the steps of a march.
fn ign(px: vec2<f32>) -> f32 {
    return fract(52.9829189 * fract(dot(px, vec2<f32>(0.06711056, 0.00583715))));
}

// ---- laser 3: the meteor storm ------------------------------------------------------------------
// Seventy-two meteors come in from one direction and land over the land round the target, then one the size of a
// hill comes down on the target itself. Each meteor is a glowing head and a trail on its path, hidden by the terrain
// in front of it (so it disappears into the ground where it really hits), a fireball and a ring on the ground where it
// lands. strike.rs digs the craters at the same places and moments (met_*): keep the formulas in step.

const MET_N: i32 = 72;             // keep in step with strike.rs: MET_N, MET_SPAN, BIG_T
const MET_SPAN: f32 = 120.0;
const BIG_T: f32 = 13.5;           // the big one lands this long after the fire, on the target
const BIG_R: f32 = 16.0;           // its radius, in blocks
const MET_V: f32 = 150.0;          // how fast the small ones are going when they land, blocks a second
const MET_A: f32 = 45.0;           // how hard the air slows them (they come in four times faster)
const MET_ENTRY: f32 = 5.0;        // seconds from the top of their path to the ground
const BIG_V: f32 = 260.0;
const MET_END: f32 = 34.0;         // when everything has faded (the strike runs 38 s)

// A meteor's own random numbers (`k` picks which): an integer hash, so strike.rs gets exactly the same ones.
fn mh(i: u32, seed: u32, k: u32) -> f32 { return f32(pcg(i ^ pcg(seed ^ pcg(k)))) * (1.0 / 4294967296.0); }
// Where a meteor lands (x, z off the target) and when (seconds after the fire). A third of them come down together,
// the fragments of one that broke up, close to one another and within a second or so of each other; the rest
// anywhere, at any time.
fn met_where(fi: f32, seed: f32) -> vec3<f32> {
    let i = u32(fi);
    let s = u32(seed);
    if (mh(i, s, 5u) < 0.33) {
        let c = 100u + min(u32(mh(i, s, 6u) * 6.0), 5u);
        let ca = mh(c, s, 1u) * TAU;
        let cr = 24.0 + (MET_SPAN - 30.0) * sqrt(mh(c, s, 2u));
        let oa = mh(i, s, 7u) * TAU;
        let orr = 3.0 + 11.0 * mh(i, s, 8u);
        let pos = vec2<f32>(cos(ca), sin(ca)) * cr + vec2<f32>(cos(oa), sin(oa)) * orr;
        return vec3<f32>(pos, 3.0 + 8.5 * mh(c, s, 3u) + 1.4 * mh(i, s, 9u));
    }
    let a = mh(i, s, 1u) * TAU;
    let r = 14.0 + (MET_SPAN - 14.0) * sqrt(mh(i, s, 2u));
    return vec3<f32>(cos(a) * r, sin(a) * r, 2.5 + 9.5 * mh(i, s, 3u));
}
fn met_t(fi: f32, seed: f32) -> f32 { return met_where(fi, seed).z; }
// How far up its path a meteor is `tau` seconds before it lands, and when (seconds before landing) it passed `l`.
fn met_path(tau: f32) -> f32 { return MET_V * tau + MET_A * tau * tau; }
fn met_when(l: f32) -> f32 { return (sqrt(MET_V * MET_V + 4.0 * MET_A * l) - MET_V) / (2.0 * MET_A); }
fn met_off(fi: f32, seed: f32) -> vec2<f32> { return met_where(fi, seed).xy; }
fn met_class(fi: f32, seed: f32) -> i32 {
    let h = mh(u32(fi), u32(seed), 4u);
    return select(select(2, 1, h < 0.87), 0, h < 0.6);
}
// Where a meteor comes from (pointing back up its path): all from one part of the sky, a little scattered.
fn met_dir(fi: f32, seed: f32, elev: f32, spread: f32) -> vec3<f32> {
    let phi = fract(seed * 0.0911) * TAU + (fh21(vec2<f32>(fi, 31.0)) - 0.5) * 0.45 * spread;
    let e = elev + (fh21(vec2<f32>(fi, 37.0)) - 0.5) * 0.3 * spread;
    return vec3<f32>(cos(e) * cos(phi), sin(e), cos(e) * sin(phi));
}

// The closest approach of the view ray (from the eye, along `rd`) to the segment ab (camera-relative):
// x = the distance between them, y = how far along the ray, z = where along ab (0 at a).
fn ray_seg(rd: vec3<f32>, a: vec3<f32>, b: vec3<f32>) -> vec3<f32> {
    let ab = b - a;
    let l2 = max(dot(ab, ab), 1.0e-6);
    let rab = dot(rd, ab);
    let den = l2 - rab * rab;
    var s = clamp(select(0.0, (rab * dot(rd, a) - dot(a, ab)) / den, den > 1.0e-6), 0.0, 1.0);
    let t = max(dot(rd, a + ab * s), 0.0);
    s = clamp(dot(rd * t - a, ab) / l2, 0.0, 1.0);
    return vec3<f32>(length(rd * t - (a + ab * s)), t, s);
}


// ---- laser 4: the mothership --------------------------------------------------------------------------------------
// A ship a kilometre long, a slab of dark metal with a blunted, tapering bow, drops out of hyperspace over the target:
// it bursts out of a point and unfolds to its full size as it rushes in along its heading from far off (the approach
// the player picked), and stops dead high overhead in about a quarter of a second, smeared by real motion blur. It
// leaves the way it points, stretching out as it goes. It is never marched: each view ray is met analytically with the hull's three stepped
// tiers (flat floors at fixed heights, each bounded by a rectangular outline in the ship's own plan, with the walls
// between them found by bisecting the outline), and the plating, seams and lights are worked out only where the ray
// lands. Its shadow is the same outline seen along the sun. strike.rs cuts the trench where the beam is on the ground
// (ms_sweep): keep the formulas in step.

const MS_H: f32 = 420.0;           // its belly over the target; keep in step with strike.rs: MS_*, TRENCH_L
const MS_ARRIVE: f32 = 3.0;        // it drops out of hyperspace
const MS_SNAP: f32 = 0.167;        // the snap: stopped this long after, four film frames
const MS_IN: f32 = 0.28;           // the unfold: stopped, at its full size, this long after
const MS_WARP: f32 = 0.45;         // the warp: out of its streak this long after
const MS_BEAM: f32 = 8.0;          // the beam leaves the ship
const MS_HIT: f32 = 8.2;           // and lands on the target
const MS_SWEEP0: f32 = 10.0;       // it sweeps away from the player
const MS_SWEEP1: f32 = 19.0;
const MS_CUT: f32 = 20.0;          // the beam cuts off
const MS_LEAVE: f32 = 23.0;        // it goes
const MS_OUT: f32 = 0.3;           // and is gone this long after
const MS_END: f32 = 32.0;          // the trench has cooled (the strike runs 34 s)
const MS_FAR: f32 = 24000.0;       // how far off along its heading it comes from, and goes to
const MS_COAST: f32 = 14.0;        // what it coasts on after the stop, dying away long before the beam fires
const MS_SHUTTER: f32 = 0.0417;    // the motion blur's shutter: a film frame, 1/24 s (the snap's is half of it, 180°)
const TRENCH_L: f32 = 100.0;
const MS_HL: f32 = 560.0;          // its half-length and half-width, and how far its stern's corners are cut off
const MS_HW: f32 = 250.0;
const MS_CHAMFER: f32 = 50.0;
const MS_TAPER: f32 = 220.0;       // its bow tapers over this length, to a blunt tip this wide either side
const MS_TIP: f32 = 70.0;
const MS_EM_X: f32 = 70.0;         // the eye (where the beam comes from), along the hull from its middle towards the bow
const MS_EYE_R: f32 = 46.0;
const MS_EYE_UP: f32 = 18.0;       // how far the eye is set up into the belly
const MS_FOCUS: f32 = 70.0;        // the emitters' beams meet this far under the belly
const MS_TIER_B: f32 = 28.0;       // the tiers' floors, over the belly (the keel's): middle, outer, and its top
const MS_TIER_C: f32 = 56.0;
const MS_TOP: f32 = 150.0;
const MS_HANGAR: vec4<f32> = vec4<f32>(-290.0, 0.0, 90.0, 100.0);   // the hangar bay: middle (x, z), half-length, half-width
const MS_HANGAR_UP: f32 = 115.0;   // its ceiling, over the belly
const CLOUD_Y: f32 = 192.0;        // the vanilla cloud layer

// How far along the trench the beam is at `t`, 0 to 1, and when it is `u` of the way (strike.rs's ms_sweep, ms_when).
fn ms_sweep(t: f32) -> f32 {
    let s = saturate((t - MS_SWEEP0) / (MS_SWEEP1 - MS_SWEEP0));
    return s * s * (3.0 - 2.0 * s);
}
fn ms_when(u: f32) -> f32 {
    return MS_SWEEP0 + (MS_SWEEP1 - MS_SWEEP0) * (0.5 - sin(asin(1.0 - 2.0 * saturate(u)) / 3.0));
}
// The way the beam sweeps: from the target away from the player (strike.rs's ms_axis). The ship points the other way.
fn ms_axis() -> vec2<f32> {
    let a = wing_a();
    return -vec2<f32>(cos(a), sin(a));
}

// Where the ship is: where its middle stops (xz), its heading and across it, its belly's height, how far along its
// heading it is from there, and how it is scaled along (sx, round `px`), across (sz) and up (sy, from its belly).
struct MsFrame {
    c: vec2<f32>,
    ax: vec2<f32>,
    sd: vec2<f32>,
    y0: f32,
    shift: f32,
    sx: f32,
    sz: f32,
    sy: f32,
    px: f32,
}

// How long after it drops in it has stopped, for each way of arriving (0 snap, 1 unfold, 2 warp).
fn ms_stop(style: i32) -> f32 {
    return select(select(MS_WARP, MS_IN, style == 1), MS_SNAP, style == 0);
}

// The ship at `t`, coming in on approach `mode` (4: dropping from overhead, the rest along its heading) in `style`:
//   0 snap: solid from the first frame, a hard rigid slide in from far off, slowing so hard it is all but there after
//     a frame or two, then the last few blocks coasted to a standstill;
//   1 unfold: it bursts out of a point, unfolding to its full size as it rushes in;
//   2 warp: it is there at once, but smeared out kilometres back along its path, and pulls in out of the streak.
// On the way out it accelerates away the way it points (straight up from overhead), its bow leading and its stern
// lagging, so it stretches out as it goes.
fn ms_frame(base: MsFrame, t: f32, mode: i32, style: i32) -> MsFrame {
    var f = base;
    let up = mode == 4;
    let td = t - MS_LEAVE;
    if (td > 0.0) {
        let u = td / MS_OUT;
        let lead = MS_FAR * u * u * u;
        let lag = MS_FAR * pow(u, 4.5);
        if (up) {
            f.y0 = f.y0 + lag;
            f.sy = 1.0 + (lead - lag) / MS_TOP;
        } else {
            f.shift = lag;
            f.px = -MS_HL;
            f.sx = 1.0 + (lead - lag) / (2.0 * MS_HL);
        }
        return f;
    }
    let ta = max(t - MS_ARRIVE, 0.0);
    var far = MS_COAST * exp(-ta / 1.3);
    if (style == 2) {
        // smeared out behind its bow (above its belly, from overhead), narrower the more it is stretched
        let s = 1.0 + 70.0 * exp(-ta * 13.0);
        if (up) {
            f.sy = s;
        } else {
            f.sx = s;
            f.px = MS_HL;
            f.sz = 1.0 / (1.0 + (s - 1.0) * 0.3);
        }
    } else if (style == 1) {
        let u = saturate(ta / MS_IN);
        far = far + MS_FAR * pow(1.0 - u, 4.0);
        let s = max(1.0 - pow(1.0 - u, 2.2), 0.002);
        f.sx = s;
        f.sz = s;
        f.sy = s;
    } else {
        far = far + MS_FAR * pow(1.0 - saturate(ta / MS_SNAP), 5.0);
    }
    if (up) {
        f.y0 = f.y0 + far;
    } else {
        f.shift = -far;
    }
    return f;
}
fn ms_here(t: f32) -> bool {
    return t >= MS_ARRIVE && t < MS_LEAVE + MS_OUT;
}

// A world xz into the ship's plan: x along it (the bow at +560, the stern at -560), y across, in blocks; and back.
fn ms_local(f: MsFrame, p: vec2<f32>) -> vec2<f32> {
    let r = p - f.c;
    return vec2<f32>((dot(r, f.ax) - f.shift - f.px) / f.sx + f.px, dot(r, f.sd) / f.sz);
}
fn ms_world(f: MsFrame, q: vec2<f32>) -> vec2<f32> {
    return f.c + f.ax * (f.shift + f.px + (q.x - f.px) * f.sx) + f.sd * (q.y * f.sz);
}

// The sponsons stepping out of its sides: how far out at `x`.
fn ms_sponson(x: f32) -> f32 {
    return 32.0 * (step(abs(x + 150.0), 70.0) + step(abs(x - 130.0), 70.0));
}
// The hull's half-width at `x` along it: the full width (and the sponsons), narrowing over the bow to its blunt tip.
fn ms_half_w(x: f32) -> f32 {
    return min(MS_HW + ms_sponson(x), MS_HW - (MS_HW - MS_TIP) * (x - (MS_HL - MS_TAPER)) / MS_TAPER);
}

// The hull's outline, a long slab with sponsons stepping out of its sides, its stern's corners cut off and its bow
// tapering to a blunt tip, eroded by `inset` blocks: below 0 inside, roughly the distance to its edge.
fn ms_outline(q: vec2<f32>, inset: f32) -> f32 {
    let a = abs(q);
    var d = max(a.x - MS_HL + inset, a.y - MS_HW - ms_sponson(q.x) + inset);
    d = max(d, (a.x + a.y - (MS_HL + MS_HW - MS_CHAMFER) + inset * 1.4142) * 0.7071);
    let slope = (MS_HW - MS_TIP) / MS_TAPER;
    return max(d, (a.y + slope * (q.x - (MS_HL - MS_TAPER)) - MS_HW) / sqrt(1.0 + slope * slope) + inset);
}
// The hangar bay's outline (below 0 inside).
fn ms_hangar(q: vec2<f32>) -> f32 {
    return max(abs(q.x - MS_HANGAR.x) - MS_HANGAR.z, abs(q.y - MS_HANGAR.y) - MS_HANGAR.w);
}

// Tier `k`'s outline (each inside the next, so a ray from below meets them in order):
//   0 the keel: a ridge down the middle the whole length, widening at the stern into the engine block, broken by the
//     hangar bay;
//   1 the middle deck: two long trenches let into it either side of the keel, recessed bays in its long sides, the
//     hangar's mouth;
//   2 the outer hull, its long sides stepped in and out in long blocks.
fn ms_tier(q: vec2<f32>, k: i32) -> f32 {
    if (k == 0) {
        let ridge = max(abs(q.y) - 70.0, ms_outline(q, 30.0));
        let engines = max(max(abs(q.y) - 170.0, q.x + 430.0), ms_outline(q, 42.0));
        return max(min(ridge, engines), -ms_hangar(q));
    }
    if (k == 1) {
        var d = ms_outline(q, 40.0);
        let cell = floor(q.x / 140.0);
        let bay = max(abs(q.x - (cell + 0.5) * 140.0) - 36.0, MS_HW - 74.0 - abs(q.y));
        d = max(d, select(-1.0e9, -bay, fh21(vec2<f32>(cell, sign(q.y) * 3.0 + 11.0)) > 0.35));
        let trench = max(abs(abs(q.y) - 119.0) - 7.0, abs(q.x + 60.0) - 360.0);
        return max(max(d, -trench), -ms_hangar(q));
    }
    let step_in = step(0.5, fh21(vec2<f32>(floor(q.x / 100.0), sign(q.y) + 3.0))) * step(abs(q.x), MS_HL - 60.0);
    return ms_outline(q, 0.0) + 8.0 * step_in;
}
fn ms_eye(q: vec2<f32>) -> f32 {
    return length(q - vec2<f32>(MS_EM_X, 0.0)) - MS_EYE_R;
}
fn ms_tier_h(k: i32) -> f32 {
    return select(select(MS_TOP, MS_TIER_C, k == 2), select(MS_TIER_B, 0.0, k == 0), k < 2);
}

// Where a view ray meets the hull: how far, where in its plan, how high over the belly, and what it hit: 0, 1, 2 a
// tier's floor, 3 a tier's wall, 4 the eye's ceiling, 5 the eye's wall, 6 the hangar's ceiling, 7 its wall; -1 nothing.
struct MsHit {
    t: f32,
    q: vec2<f32>,
    h: f32,
    kind: i32,
}

// Up a recess from its mouth at `t_lo`: its ceiling (`up` over the belly), or its wall on the way (found by bisecting
// `which`'s outline: 0 the eye, 1 the hangar).
fn ms_recess(f: MsFrame, cam: vec3<f32>, rd: vec3<f32>, t_lo: f32, up: f32, which: i32) -> MsHit {
    var hit: MsHit;
    let t_c = (f.y0 + up * f.sy - cam.y) / rd.y;
    let q_c = ms_local(f, cam.xz + rd.xz * t_c);
    if (select(ms_hangar(q_c), ms_eye(q_c), which == 0) < 0.0) {
        hit.t = t_c;
        hit.q = q_c;
        hit.h = up;
        hit.kind = select(6, 4, which == 0);
        return hit;
    }
    var a = t_lo;
    var b = t_c;
    for (var i = 0; i < 5; i = i + 1) {
        let m = 0.5 * (a + b);
        let qm = ms_local(f, cam.xz + rd.xz * m);
        if (select(ms_hangar(qm), ms_eye(qm), which == 0) < 0.0) {
            a = m;
        } else {
            b = m;
        }
    }
    hit.t = b;
    hit.q = ms_local(f, cam.xz + rd.xz * b);
    hit.h = (cam.y + rd.y * b - f.y0) / f.sy;
    hit.kind = select(7, 5, which == 0);
    return hit;
}

// Met from underneath only: the footprints grow tier by tier going up, so the first thing the ray meets is a floor it
// is inside at the floor's height, or the wall it crosses before the next floor, or one of the two recesses (the eye
// in the keel, the hangar in the middle deck). A dozen outline tests at most.
fn ms_trace(f: MsFrame, cam: vec3<f32>, rd: vec3<f32>) -> MsHit {
    var hit: MsHit;
    hit.t = 1.0e9;
    hit.q = vec2<f32>(0.0);
    hit.h = 0.0;
    hit.kind = -1;
    if (rd.y < 1.0e-3 || cam.y > f.y0) {
        return hit;
    }
    // quick reject: the ray passes the hull's whole height clear of it
    let pa = cam.xz + rd.xz * ((f.y0 - cam.y) / rd.y);
    let pb = cam.xz + rd.xz * ((f.y0 + MS_TOP * f.sy - cam.y) / rd.y);
    let ab = pb - pa;
    let mid = ms_world(f, vec2<f32>(0.0));
    let u = saturate(dot(mid - pa, ab) / max(dot(ab, ab), 1.0e-4));
    if (length(pa + ab * u - mid) > 640.0 * max(f.sx, f.sz)) {
        return hit;
    }
    for (var k = 0; k < 3; k = k + 1) {
        let t_lo = (f.y0 + ms_tier_h(k) * f.sy - cam.y) / rd.y;
        let t_hi = (f.y0 + ms_tier_h(k + 1) * f.sy - cam.y) / rd.y;
        let q_lo = ms_local(f, cam.xz + rd.xz * t_lo);
        if (k == 1 && ms_hangar(q_lo) < 0.0 && ms_outline(q_lo, 40.0) < 0.0) {
            return ms_recess(f, cam, rd, t_lo, MS_HANGAR_UP, 1);
        }
        if (ms_tier(q_lo, k) < 0.0) {
            if (k == 0 && ms_eye(q_lo) < 0.0) {
                return ms_recess(f, cam, rd, t_lo, MS_EYE_UP, 0);
            }
            hit.t = t_lo;
            hit.q = q_lo;
            hit.h = ms_tier_h(k);
            hit.kind = k;
            return hit;
        }
        let q_hi = ms_local(f, cam.xz + rd.xz * t_hi);
        if (ms_tier(q_hi, k) < 0.0) {
            var a = t_lo;
            var b = t_hi;
            for (var i = 0; i < 5; i = i + 1) {
                let m = 0.5 * (a + b);
                if (ms_tier(ms_local(f, cam.xz + rd.xz * m), k) < 0.0) {
                    b = m;
                } else {
                    a = m;
                }
            }
            hit.t = b;
            hit.q = ms_local(f, cam.xz + rd.xz * b);
            hit.h = (cam.y + rd.y * b - f.y0) / f.sy;
            hit.kind = 3;
            return hit;
        }
    }
    return hit;
}

// The plating at `q` (blocks) seen with a footprint of `fp` blocks a pixel: x = how much of the pixel a seam between
// plates covers (thin seams fade out into an average far off rather than shimmer), y = the plate's own random number,
// zw = the plate's size.
fn ms_plates(q: vec2<f32>, fp: f32) -> vec4<f32> {
    let h0 = fh21(floor(q / 48.0) + vec2<f32>(17.0, 3.0));
    let size = vec2<f32>(select(48.0, 24.0, h0 > 0.45), select(48.0, 24.0, h0 > 0.75));
    let c = floor(q / size);
    let fr = q - c * size;
    let e = min(min(fr.x, size.x - fr.x), min(fr.y, size.y - fr.y));
    let w = 0.45;
    let seam = (1.0 - smoothstep(w * 0.5, w + fp, e)) * min(1.0, 2.0 * w / max(fp, 1.0e-3));
    return vec4<f32>(seam, fh21(c * vec2<f32>(1.0, 1.7) + size * 0.37), size);
}

// A thin glowing line at distance `d` (blocks) from it, `w` wide, kept about a pixel wide (and dimmed to match) far off.
fn ms_line(d: f32, w: f32, fp: f32) -> f32 {
    let ww = max(w, fp);
    return exp(-pow(d / ww, 2.0)) * (w / ww);
}

// What the metal mirrors, looking along `r`: the land below (darker straight down, where the ship's own shadow lies),
// the bright haze at the horizon, the sun's glare off the land and the haze under it, and the sky. The sky's colour
// is taken mostly grey, so the metal reads as metal, not as blue.
fn ms_env(r: vec3<f32>, haze: vec3<f32>, sun: vec3<f32>, day: f32) -> vec3<f32> {
    let grey = mix(haze, vec3<f32>(luminance(haze)), 0.65);
    let ground = vec3<f32>(0.16, 0.17, 0.13) * (0.08 + 0.92 * day) * mix(0.35, 1.0, smoothstep(-0.75, -0.3, r.y));
    let e = mix(ground, grey * 1.1, smoothstep(-0.28, 0.0, r.y));
    let glare = vec3<f32>(1.0, 0.88, 0.7) * pow(max(dot(r, normalize(vec3<f32>(sun.x, -abs(sun.y), sun.z))), 0.0), 24.0) * 1.1 * day;
    return mix(e, grey * 0.9, smoothstep(0.0, 0.5, r.y)) + glare;
}

// The hull's colour where the ray hit it: dark metal mirroring the land and the sky (Fresnel: brighter the more
// glancing the look), each plate a little differently tilted, toned and rough, grimed along its seams; green seams,
// windows and lights. `lit` how lit up its seams are, `core` the gathering light under the eye, `beam` the beam,
// `focus` where they meet (camera-relative), `boost` how much its lights flare (while it is a blur), `wake` seconds
// since it stopped (its seams and windows come on in a cascade a beat after; its running lights are on all along),
// `eng` how bright its engines are.
fn ms_hull(h: MsHit, f: MsFrame, rd: vec3<f32>, time: f32, lit: f32, chase_on: f32, core: f32, beam: f32, focus: vec3<f32>,
           haze: vec3<f32>, day: f32, sun: vec3<f32>, boost: f32, wake: f32, eng: f32) -> vec3<f32> {
    let q = h.q;
    let pix = 2.0 / (frame.projection[1][1] * frame.resolution.y);
    let wall = h.kind == 3 || h.kind == 5 || h.kind == 7;
    let fp = h.t * pix / select(max(rd.y, 0.12), 0.6, wall);
    let X = rd * h.t;
    let green = vec3<f32>(0.12, 1.5, 0.3);
    // the cascade: from the stern to the bow in a quarter of a second, each light at its own moment in it
    let on_at = 0.35 + 0.25 * (q.x + MS_HL) / (2.0 * MS_HL) + 0.06 * fh21(floor(q / 23.0) + vec2<f32>(77.0, 1.0));
    let on = smoothstep(on_at, on_at + 0.05, wake);
    // a wave of light running along the seams towards the bow while it charges
    let chase = pow(0.5 + 0.5 * sin(q.x * 0.025 - time * 7.0), 6.0) * chase_on;
    let glow = (0.25 + 0.9 * lit + 1.6 * chase) * boost * on;
    var tone = 1.0;                       // how bright the metal is (plates, grime, recesses)
    var rough = 0.35;
    var nl = vec3<f32>(0.0, -1.0, 0.0);   // the surface's normal in the ship's frame (x along, y up, z across)
    var emit = vec3<f32>(0.0);
    if (h.kind <= 2) {
        // the decks: plates, their seams, fine machinery between, some plates set back into the hull
        let pl = ms_plates(q, fp);
        // each plate its own tilt and roughness
        let hv = vec3<f32>(pcg3d(bitcast<vec3<u32>>(vec3<i32>(vec2<i32>(floor(q / pl.zw)), 9)))) * (1.0 / 4294967295.0);
        nl = normalize(vec3<f32>((hv.x - 0.5) * 0.45, -1.0, (hv.y - 0.5) * 0.45));
        rough = 0.15 + 0.6 * hv.z;
        tone = (0.55 + 0.7 * pl.y) * mix(1.0, 0.25, pl.x) * select(select(1.1, 1.0, h.kind == 1), 0.85, h.kind == 0);
        // whole sections of it a shade lighter or darker, weathered
        tone = tone * (0.65 + 0.7 * gnoise2(q * 0.006 + vec2<f32>(3.1, 7.7)));
        let g = fh21(floor(q / 6.0) + vec2<f32>(pl.y * 91.0, 5.0));
        tone = tone * mix(1.0, 0.65 + 0.7 * g * g, saturate(2.0 - fp / 3.0));
        // grime: dark streaks trailing back from the seams, along the way it flies
        let seam_d = 12.0 - abs(fract(q.y / 24.0) - 0.5) * 24.0;
        let streak = smoothstep(0.45, 0.75, gnoise2(vec2<f32>(q.x * 0.015, q.y * 0.45)));
        tone = tone * (1.0 - 0.45 * exp(-seam_d / 2.5) * streak * saturate(2.0 - fp / 2.0));
        if (pl.y > 0.82) {
            // a plate set 4 blocks up: past its edge you see the side of the recess, inside it a darker grid
            let rdl = vec2<f32>(dot(rd.xz, f.ax), dot(rd.xz, f.sd));
            let qd = q + rdl * (4.0 / max(rd.y, 0.2));
            if (any(floor(qd / pl.zw) != floor(q / pl.zw))) {
                tone = tone * 0.3;
            } else {
                let gd = abs(fract(qd / 3.0) - 0.5) * 3.0;
                tone = tone * mix(0.45, 0.7, saturate(min(gd.x, gd.y) / max(fp, 0.4)));
                rough = 0.8;
            }
        } else if (pl.y > 0.6 && pl.y < 0.7) {
            // conduits running along the hull
            tone = tone * mix(1.0, 0.75 + 0.5 * smoothstep(0.15, 0.35, abs(fract(q.y / 2.5) - 0.5)), saturate(1.5 - fp));
        } else if (pl.y < 0.12) {
            // a row of intakes: dark slots across the plate
            let slot = step(abs(fract(q.x / 4.0) - 0.5), 0.3) * step(abs(fract(q.y / pl.w) - 0.5), 0.3);
            tone = tone * mix(1.0, 1.0 - 0.85 * slot, saturate(2.0 - fp / 1.5));
        }
        if (h.kind == 1 && abs(q.y) > 70.0) {
            // armour: the plating stepping up from the keel in overlapping layers, each lip catching the light and
            // throwing a shadow on the layer above it
            let lz = (abs(q.y) - 70.0) / 34.0;
            let fl = fract(lz);
            tone = tone * (0.85 + 0.3 * fh21(vec2<f32>(floor(lz), 61.0)));
            tone = tone * (1.0 - 0.5 * exp(-fl * 34.0 / 2.5)) + 0.9 * exp(-(1.0 - fl) * 34.0 / max(1.0, fp));
        }
        if (h.kind == 2) {
            // fields of radiator fins hanging across the hull: you see the side of each that faces you
            let fc = floor(q / vec2<f32>(80.0, 60.0));
            if (fh21(fc + vec2<f32>(13.0, 29.0)) > 0.62 && abs(q.x) < MS_HL - 120.0) {
                let rdl = dot(rd.xz, f.ax);
                let fin = smoothstep(0.3, 0.7, fract(q.x / 3.0 + 0.2 * sign(rdl)));
                tone = tone * mix(0.8, 0.45 + 0.7 * fin, saturate(1.6 - fp / 1.5));
                rough = 0.5;
            }
        }
        if (q.x > MS_HL - MS_TAPER - 30.0 && h.kind > 0) {
            // sensor arrays on the bow: domes, each mirroring the sky round it, a light blinking on some
            let sc = floor(q / 16.0);
            let sh = fh21(sc + vec2<f32>(5.0, 83.0));
            let dv = q - (sc + 0.5) * 16.0;
            let dd = length(dv);
            if (sh > 0.45 && dd < 5.0) {
                nl = normalize(vec3<f32>(dv.x / 5.0, -sqrt(max(1.0 - dd * dd / 25.0, 0.05)), dv.y / 5.0));
                tone = 1.3;
                rough = 0.1;
                emit = emit + vec3<f32>(0.4, 2.6, 0.5) * ms_line(dd, 0.6, fp) * step(0.75, sh) * step(0.6, fract(time * 0.7 + sh * 9.0));
            } else if (sh > 0.3 && dd < 6.0) {
                tone = tone * (0.4 + 0.6 * smoothstep(0.5, 1.0, abs(fract(dd / 2.0) - 0.5) * 2.0));
            }
        }
        if (h.h >= MS_TOP) {
            // (the roof, seen from above: the downfall's ship as it rolls)
            nl.y = -nl.y;
        }
        // the decks' edges bevelled, catching the light from round the side
        let edge = -ms_tier(q, h.kind);
        let bevel = (1.0 - smoothstep(0.0, 2.5 + fp, edge)) * select(1.0, 0.0, h.kind == 0 && ms_eye(q) < 2.0);
        tone = tone + 1.2 * bevel;
        rough = mix(rough, 0.1, bevel);
        // glowing seams: along the foot of the deck above, down both sides of the keel, ribs across
        var s = ms_line(abs(fract(q.x / 120.0 + 0.5) - 0.5) * 120.0, 0.5, fp) * 0.35 * step(0.4, fh21(vec2<f32>(floor(q.x / 120.0 + 0.5), floor(q.y / 70.0) + 40.0)));
        if (h.kind == 0) {
            s = s + ms_line(abs(abs(q.y) - 20.0), 0.5, fp) * 0.6;
        } else {
            s = s + ms_line(ms_tier(q, h.kind - 1) - 1.4, 0.6, fp) * 1.3;
        }
        emit = emit + green * s * glow;
        if (h.kind > 0) {
            // windows: rows of tiny lights in districts, lit and dark, like a city seen at night from far above
            let row = floor(q.y / 6.0);
            let district = fh21(vec2<f32>(row, floor(q.x / 90.0)) + vec2<f32>(3.0, 17.0));
            let wx = floor(q.x / 2.0);
            let wh = fh21(vec2<f32>(wx, row) + vec2<f32>(41.0, 5.0));
            if (district > 0.64 && wh > 0.72) {
                let d = length(q - vec2<f32>(wx * 2.0 + 1.0, row * 6.0 + 3.0));
                let flick = 0.6 + 0.4 * step(0.2, fract(wh * 13.0 + floor(time * 0.5) * 0.37));
                emit = emit + vec3<f32>(0.55, 1.5, 0.6) * ms_line(d, 0.45, fp) * flick * boost * on * 0.6;
            }
        }
        if (h.kind == 2) {
            // running lights down both long sides: deep green to port, bright to starboard, a white strobe; on all along
            let cx = floor(q.x / 40.0);
            let lx = cx * 40.0 + 20.0;
            let d = length(q - vec2<f32>(lx, sign(q.y) * (ms_half_w(lx) - 14.0)));
            let blink = step(0.82, fract(time * 0.9 - cx * 0.11));
            let rc = select(vec3<f32>(0.4, 2.6, 0.5), vec3<f32>(0.08, 1.1, 0.18), q.y > 0.0);
            emit = emit + mix(rc, vec3<f32>(3.5, 4.0, 3.5), blink) * ms_line(d, 1.3, fp) * (0.6 + 1.4 * blink) * boost;
        }
    } else if (h.kind == 4) {
        // the eye's ceiling: six emitters round the aperture the beam comes from
        let e = q - vec2<f32>(MS_EM_X, 0.0);
        let re = length(e);
        let ae = atan2(e.y, e.x);
        let sa = TAU / 6.0;
        let ke = floor(ae / sa + 0.5);
        let de = length(e - vec2<f32>(cos(ke * sa), sin(ke * sa)) * 30.0);
        let ribs = smoothstep(0.2, 0.6, abs(fract(ae / sa * 4.0) - 0.5) * 2.0);
        tone = 0.45 + 0.4 * ribs;
        rough = 0.5;
        let hot = mix(vec3<f32>(0.15, 1.8, 0.35), vec3<f32>(3.5, 5.0, 3.6), core);
        emit = emit + hot * ((1.0 - smoothstep(5.0, 5.0 + fp, de)) * (0.3 * on + 7.0 * core + 6.0 * beam) + exp(-de / 6.0) * (0.2 * on + 2.5 * core));
        emit = emit + vec3<f32>(4.5, 6.0, 4.5) * (1.0 - smoothstep(9.0, 9.0 + fp, re)) * (0.2 * on + 10.0 * core + 10.0 * beam);
        emit = emit + green * (ms_line(re - 18.0, 0.6, fp) + ms_line(re - 42.0, 0.8, fp)) * glow;
    } else if (h.kind == 6) {
        // the hangar's ceiling: a lit interior, rows of light strips, the dark shapes of craft docked under them
        let hq = q - MS_HANGAR.xy;
        let strip = ms_line(abs(fract(hq.y / 16.0 + 0.5) - 0.5) * 16.0, 1.2, fp);
        let docked = max(abs(fract(hq.x / 30.0) - 0.5) * 30.0 - 9.0, abs(fract(hq.y / 16.0) - 0.5) * 16.0 - 4.0);
        tone = 0.35 * (0.8 + 0.4 * fh21(floor(hq / 30.0)));
        rough = 0.7;
        let inner = vec3<f32>(0.8, 1.6, 0.9) * (0.25 + 1.2 * strip) * on;
        emit = emit + inner * select(1.0, 0.1, docked < 0.0);
    } else {
        // walls: their normal from the outline, decks every 5 blocks, rows of lit windows along them, ribs every 30;
        // the engines' bells on the walls facing aft
        var n2 = vec2<f32>(0.0);
        if (h.kind == 3) {
            let k = select(0, select(1, 2, h.h > MS_TIER_C), h.h > MS_TIER_B);
            n2 = vec2<f32>(ms_tier(q + vec2<f32>(1.0, 0.0), k) - ms_tier(q - vec2<f32>(1.0, 0.0), k),
                           ms_tier(q + vec2<f32>(0.0, 1.0), k) - ms_tier(q - vec2<f32>(0.0, 1.0), k));
        } else if (h.kind == 5) {
            n2 = vec2<f32>(MS_EM_X, 0.0) - q;
        } else {
            let hq = q - MS_HANGAR.xy;
            n2 = select(vec2<f32>(0.0, -sign(hq.y)), vec2<f32>(-sign(hq.x), 0.0), abs(hq.x) - MS_HANGAR.z > abs(hq.y) - MS_HANGAR.w);
        }
        n2 = n2 / max(length(n2), 1.0e-4);
        nl = vec3<f32>(n2.x, 0.0, n2.y);
        let u = select(dot(q, vec2<f32>(-n2.y, n2.x)), atan2(q.y, q.x - MS_EM_X) * MS_EYE_R, h.kind == 5);
        let deck = abs(fract(h.h / 5.0) - 0.5) * 5.0;
        let deck_l = mix(mix(0.45, 1.0, saturate((deck - 0.3) / max(fp * 0.5, 0.2))), 0.93, smoothstep(0.7, 2.2, fp));
        tone = 0.8 * deck_l * (0.75 + 0.4 * fh21(vec2<f32>(floor(u / 30.0), 9.0)));
        rough = 0.3 + 0.4 * fh21(vec2<f32>(floor(u / 30.0), 19.0));
        let wc = vec2<f32>(floor(u / 3.5), floor(h.h / 5.0));
        let wh = fh21(wc + vec2<f32>(3.0, 51.0));
        let win = step(select(0.88, 0.55, h.kind == 7), wh) * step(1.2, deck) * step(abs(fract(u / 3.5) - 0.5), 0.3);
        emit = emit + vec3<f32>(0.45, 1.5, 0.5) * win * saturate(1.6 - fp / 2.5) * boost * on * select(1.0, 2.0, h.kind == 7);
        emit = emit + green * ms_line(MS_TOP - h.h, 0.8, fp) * glow * select(0.0, 1.0, h.kind == 3);
        if (h.kind == 3 && n2.x > 0.8 && q.x > MS_HL - 4.0) {
            // the bow's blunt end: heavy ribs up it, a prow light along its middle
            let rib = abs(fract(q.y / 14.0) - 0.5) * 14.0;
            tone = tone * mix(1.0, 0.5 + 0.6 * smoothstep(1.0, 3.0, rib), saturate(2.0 - fp / 2.0));
            emit = emit + green * ms_line(abs(h.h - 75.0), 1.2, fp) * (0.4 + glow) * 1.5;
        }
        if (h.kind == 3 && n2.x < -0.8) {
            // the engines: big bells across the stern above, a row of smaller ones in the engine block below
            let big = h.h > MS_TIER_C;
            let pitch = select(50.0, 90.0, big);
            let r = select(14.0, 34.0, big);
            let zc = (floor(q.y / pitch) + 0.5) * pitch;
            let vc = select(14.0, 103.0, big);
            let d = length(vec2<f32>(q.y - zc, h.h - vc));
            if (abs(zc) < select(160.0, 200.0, big) && d < r * 1.3) {
                tone = tone * mix(1.0, 0.25, step(d, r));
                let bell = ms_line(d - r, 1.5, fp) * 1.5 + (1.0 - smoothstep(r * 0.2, r, d)) * 1.2;
                emit = emit + mix(vec3<f32>(0.2, 1.8, 0.4), vec3<f32>(3.0, 5.0, 3.2), saturate(eng - 1.0)) * bell * eng;
            }
        }
    }
    // the metal: it mirrors the land and the sky, sharply where a plate is smooth, blurred where it is rough, more
    // and more the more glancing the look; in sunlight its walls catch a hot glint of the sun
    let n = normalize(vec3<f32>(f.ax.x, 0.0, f.ax.y) * nl.x + vec3<f32>(0.0, nl.y, 0.0) + vec3<f32>(f.sd.x, 0.0, f.sd.y) * nl.z);
    let r = reflect(rd, n);
    let cosv = max(dot(-rd, n), 0.0);
    let fres = 0.45 + 0.55 * pow(1.0 - cosv, 5.0);
    let env = mix(ms_env(r, haze, sun, day), (mix(haze, vec3<f32>(luminance(haze)), 0.65) * 0.6 + vec3<f32>(0.08, 0.085, 0.07) * day) * 0.6, rough * 0.8);
    let sun_c = vec3<f32>(1.0, 0.92, 0.8) * 2.5 * day * step(0.0, sun.y);
    let glint = sun_c * pow(max(dot(r, sun), 0.0), mix(300.0, 20.0, rough)) * (1.0 - rough) * max(dot(n, sun), 0.0) * 4.0;
    let metal = vec3<f32>(0.42, 0.43, 0.44) * tone;
    var c = metal * (env * fres + glint) + metal * 0.04 * (haze + vec3<f32>(0.1) * day) * max(dot(n, sun), 0.0);
    // and the green light gathering under the eye, and the beam's
    let lf = X - focus;
    c = c + metal * ship_tint(vec3<f32>(0.4, 2.0, 0.6)) * (core * 0.8 + beam * 1.6) * 4000.0 / (dot(lf, lf) + 2500.0) * 0.3;
    // the air between: a light veil of the sky's blue, and its lights dimmed, which is what makes it look so far away
    let hz = 1.0 - exp(-h.t / 3000.0);
    return mix(c, haze * 0.6, hz * 0.35) + ship_tint(emit) * exp(-h.t / 3000.0);
}

// The air reacting to the mothership as it comes (the clouds stirring before it), as it stops (a pressure ripple
// running out through the cloud layer, `tr` seconds after) and just after (a shimmer of heat round its edges): seen only
// as the world bending, so it comes back as the offset of the picture at `uv`.
fn ms_air(uv: vec2<f32>, cam: vec3<f32>, p0: vec3<f32>, sky0: bool, stir: f32, tr: f32, wake: f32, base: MsFrame, f: MsFrame,
          time: f32, seed: f32, k: f32) -> vec2<f32> {
    var off = vec2<f32>(0.0);
    if (stir > 0.001 && !sky0 && abs(p0.y - CLOUD_Y - 2.0) < 6.0) {
        // before it comes the clouds start to stir, as if the air is being pushed aside
        let sw = vec2<f32>(gnoise2(p0.xz * 0.012 + vec2<f32>(time * 0.35, seed)), gnoise2(p0.xz * 0.012 + vec2<f32>(7.0, time * 0.3))) - 0.5;
        off = off + sw * 0.014 * stir * stir * k;
    }
    // the air reacting to it: a pressure ripple running out through the cloud layer and the air below it as it stops
    // (and again as it goes), seen only as the world bending, and a shimmer of heat round its edges for a second
    let rd0 = normalize(world_offset(uv, 0.5));
    if (tr > 0.0 && tr < 6.0 && abs(rd0.y) > 1.0e-3) {
        let t_cl = (CLOUD_Y - cam.y) / rd0.y;
        if (t_cl > 0.0 && (sky0 || t_cl < length(p0 - cam) + 40.0)) {
            let rr = length(cam.xz + rd0.xz * t_cl - base.c);
            let ripple = exp(-pow((rr - tr * 650.0) / (40.0 + tr * 15.0), 2.0)) * exp(-tr * 0.8);
            let pr = project_rel(vec3<f32>(base.c.x, CLOUD_Y, base.c.y) - cam);
            let rdir = uv - pr.xy;
            off = off + rdir / max(length(rdir), 1.0e-4) * ripple * 0.012 * pr.z * k;
        }
    }
    if (wake > 0.0 && wake < 1.2 && rd0.y > 1.0e-3 && cam.y < base.y0) {
        let qe = ms_local(f, cam.xz + rd0.xz * ((base.y0 + 20.0 - cam.y) / rd0.y));
        let m = exp(-pow(ms_tier(qe, 2) / 18.0, 2.0)) * (1.0 - wake / 1.2);
        if (m > 0.01) {
            let hw = vec2<f32>(gnoise2(uv * vec2<f32>(120.0, 60.0) + vec2<f32>(0.0, time * 6.0)), gnoise2(uv * vec2<f32>(120.0, 60.0) + vec2<f32>(17.0, time * 5.0))) - 0.5;
            off = off + hw * 0.006 * m * k;
        }
    }
    return off;
}

// The mothership's arrival in light: the point it unfolds out of, the warp streak it pulls out of, its exhaust
// streaming out behind it while it moves fast.
fn ms_arrival_fx(f: MsFrame, base: MsFrame, cam: vec3<f32>, rd: vec3<f32>, sky: bool, scene_len: f32, ta: f32, mode: i32, style: i32,
                 blurring: bool, present: bool, k: f32) -> vec3<f32> {
    var add = vec3<f32>(0.0);
    // the unfold: the point it bursts out of, a tiny bright star far off where it is coming from, swelling into it
    if (style == 1 && ta >= 0.0 && ta < MS_IN) {
        let pc = vec3<f32>(ms_world(f, vec2<f32>(0.0)).x, f.y0 + 40.0 * f.sy, ms_world(f, vec2<f32>(0.0)).y) - cam;
        let tp = dot(pc, rd);
        if (tp > 0.0 && (sky || tp < scene_len)) {
            let ang = length(pc - rd * tp) / tp;
            let born = pow(1.0 - f.sx, 1.5);
            add = add + (vec3<f32>(4.0, 6.0, 4.0) * exp(-pow(ang / 0.0025, 2.0)) + vec3<f32>(0.4, 1.6, 0.5) * exp(-ang / 0.012) * 0.5) * born * k;
        }
    }
    if (style == 2 && ta > -0.3 && ta < 0.06) {
        // the warp: the streak it comes in on, racing in along its path from far off and snapping into it
        let up = mode == 4;
        let head = MS_HL - 30000.0 * pow(saturate(-ta / 0.3), 2.0);
        let a2 = ms_world(base, vec2<f32>(select(head, 0.0, up), 0.0));
        let b2 = ms_world(base, vec2<f32>(select(head - 30000.0, 0.0, up), 0.0));
        let ya = base.y0 + select(30.0, MS_TOP - head + MS_HL, up);
        let q = ray_seg(rd, vec3<f32>(a2.x, ya, a2.y) - cam, vec3<f32>(b2.x, ya + select(0.0, 30000.0, up), b2.y) - cam);
        let w = max(3.0, q.y * 0.0015);
        let vis = select(1.0, 0.0, !sky && q.y > scene_len);
        add = add + vec3<f32>(1.2, 2.6, 1.5) * exp(-pow(q.x / w, 2.0)) * (3.0 / w) * 2.0 * smoothstep(-0.3, -0.1, ta) * (1.0 - smoothstep(0.0, 0.06, ta)) * vis * k;
    }
    if (blurring && present) {
        // its engines' exhaust streaming out behind it while it moves
        for (var j = 0; j < 5; j = j + 1) {
            let zc = (f32(j) - 2.0) * 90.0;
            let e0 = ms_world(f, vec2<f32>(-MS_HL, zc));
            let e1 = ms_world(f, vec2<f32>(-MS_HL - 260.0, zc));
            let q = ray_seg(rd, vec3<f32>(e0.x, f.y0 + 103.0 * f.sy, e0.y) - cam, vec3<f32>(e1.x, f.y0 + 103.0 * f.sy, e1.y) - cam);
            let w = max(16.0 + 30.0 * q.z, q.y * 0.0015);
            let vis = select(1.0, 0.0, !sky && q.y > scene_len);
            add = add + vec3<f32>(0.4, 2.2, 0.6) * exp(-pow(q.x / w, 2.0)) * (16.0 / w) * (1.0 - q.z) * 0.8 * vis * k;
        }
    }
    return ship_tint(add);
}

// The mothership's charge: its emitters' beams converging under the eye on `focus` (camera-relative), and the blinding
// point of light gathering there. `ship_t`: how far off the hull is along the view (the beams pass behind it).
fn ms_charge_fx(f: MsFrame, cam: vec3<f32>, rdb: vec3<f32>, focus: vec3<f32>, sky: bool, scene_len: f32, ship_t: f32, conv_env: f32,
                core_env: f32, present: bool, time: f32, k: f32) -> vec3<f32> {
    var add = vec3<f32>(0.0);
    // ---- the charge: the emitters' beams converging under the eye, a blinding point of light gathering there ----
    if (conv_env > 0.001 && present) {
        let rad = 30.0;
        for (var i = 0; i < 6; i = i + 1) {
            let a = f32(i) * TAU / 6.0;
            let ew = ms_world(f, vec2<f32>(MS_EM_X + cos(a) * rad, sin(a) * rad));
            let e3 = vec3<f32>(ew.x, f.y0 + MS_EYE_UP, ew.y) - cam;
            let q = ray_seg(rdb, e3, focus);
            let w = max(1.2 + 0.8 * core_env, q.y * 0.0012);
            let vis = select(1.0, 0.0, (!sky && q.y > scene_len) || q.y > ship_t + 1.0);
            let flick = 0.8 + 0.2 * sin(time * 40.0 + f32(i) * 2.1);
            add = add + (vec3<f32>(2.6, 4.8, 2.6) * exp(-pow(q.x / (w * 0.5), 2.0)) + vec3<f32>(0.15, 1.4, 0.3) * exp(-pow(q.x / (w * 2.5), 2.0)))
                * (1.2 / w) * conv_env * flick * vis * k;
        }
    }
    if (core_env > 0.001) {
        let tc = dot(focus, rdb);
        if (tc > 0.0) {
            let dc = length(focus - rdb * tc);
            let R = (1.0 + 3.5 * core_env) * (1.0 + 0.08 * sin(time * 33.0));
            let vis = select(1.0, 0.2, (!sky && tc > scene_len) || tc > ship_t + 2.0);
            add = add + (vec3<f32>(5.0, 6.0, 5.0) * exp(-pow(dc / R, 2.0)) + vec3<f32>(0.6, 2.6, 0.8) * exp(-dc / R) * 0.9 + vec3<f32>(0.12, 0.7, 0.2) * exp(-dc / (R * 5.0)) * 0.4) * core_env * vis * k;
        }
    }
    return ship_tint(add);
}


// Orbital Laser's post pass for the Crystal Bloom (laser 7). Like the Planet Killer's, the mod builds it from
// shaders/strike.wgsl up to its fs_main (the helpers: the noise, ray_seg, rot_axis, project_rel, mh) less the other lasers'
// own functions, followed by this file, and sets it for a crystal bloom strike only. Validate with tools/check-shader.sh.

// ---- laser 7: the crystal bloom ---------------------------------------------------------------------------------
// The land round the target wakes: a deep hum, light seeping up through cracks spreading out over it, the ground heaving
// where the first crystals are coming. They punch up out of it one after another, each breaking the ground in a burst of
// earth and rock, catching, straining, then surging up; the heart comes last, in the middle. Then the bloom: a wave of
// spires running out over the land in clusters, splayed, each growing from a shard to a tower, the tallest hundreds of
// blocks. They are solid crystal: faceted, lit from inside, catching the sky, throwing coloured light on the land and the
// clouds. They resonate: light runs up them all together, faster and faster, the air shimmers round them, shards break
// off and orbit them; a breath; and they detonate: a flash of colour, the spires bursting into a storm of shards and
// glitter, a prismatic shock running out. What is left is real blocks: the geode crater, the stumps, the shards strewn
// over the land. strike.rs places the same spires (cb_spire), breaks them at the same heights (cb_break), throws the same
// shards (cb_frag) and digs the crater when this pass opens it (cb_dig_t): keep the CB_* and cb_* in step.

const CB_N: i32 = 46;              // the spires: 0..4 the first shards, 5 the heart, then ten clusters of four
const CB_LEADS: i32 = 6;
const CB_FIELD: f32 = 150.0;       // how far out they stand
const CB_SINK: f32 = 40.0;         // how far under the target's ground each runs down
const CB_STUMP: f32 = 0.5;         // its stump as wide as this of it (its heart: the rest of it shatters)
const CB_PUNCH0: f32 = 3.5;        // the first shard breaks the ground, the next CB_PUNCH_DT after, the heart last
const CB_PUNCH_DT: f32 = 0.62;
const CB_BULGE: f32 = 0.7;         // the ground over each heaves for this long before it breaks
const CB_STRUGGLE: f32 = 0.9;      // it struggles there, then surges up over CB_SURGE
const CB_SURGE: f32 = 1.5;
const CB_BLOOM0: f32 = 7.6;        // the bloom sets out from the middle, reaching CB_FIELD CB_BLOOM_V later
const CB_BLOOM_V: f32 = 4.6;
const CB_RES: f32 = 14.0;          // they resonate from here,
const CB_ORBIT: f32 = 15.6;        // shards breaking off and orbiting them from here,
const CB_DET: f32 = 22.0;          // and detonate
const CB_END: f32 = 31.0;          // the burst's light gone
const CB_LATE: f32 = 59.0;         // the well's light and the motes over the crater gone (the strike runs 60 s)
const CB_G: f32 = 22.0;            // how hard they fall
const CB_ORBITERS: i32 = 32;
const CB_BOWL: f32 = 88.0;         // the crater (strike.rs's cb_depth): CB_BOWL round, CB_BOWL_D deep, a well CB_WELL round
const CB_BOWL_D: f32 = 28.0;
const CB_WELL: f32 = 10.0;
const CB_DIG_V: f32 = 70.0;        // dug from the middle out at this many blocks a second (cb_dig_t)
const CB_CRACKS: i32 = 9;          // fissures running out from the crater to CB_CRACK_R, opening as the shock reaches them
const CB_CRACK_R: f32 = 205.0;
const CB_SHOCK_V: f32 = 170.0;

// ---- where everything is -------------------------------------------------------------------------------------------
// The spires and their pieces are worked out once, by the mod, as the strike starts (strike/crystal.rs's cb_table: where
// each stands, its shape, its break, its pieces' cuts, throws and spins), and given to the pass with render.set-data:
// the same for every pixel, read here rather than hashed again for each. The words under CB_TAB are the pieces'
// landings (cb_drop). Keep these offsets in step with cb_table's.
const CB_TAB: u32 = 1024u;
const CB_ORB: u32 = 1056u;         // CB_TAB + 32: the orbiting shards' random numbers, three each
const CB_SPB: u32 = 1152u;         // CB_TAB + 128: the spires, CB_SPW words each
const CB_SPW: u32 = 96u;
const CB_PCB: u32 = 5568u;         // CB_SPB + CB_N * CB_SPW: the pieces, CB_PCW words each
const CB_PCW: u32 = 32u;
fn cb_u(i: u32) -> u32 {
    return select(0u, mod_data[min(i, arrayLength(&mod_data) - 1u)], i < arrayLength(&mod_data));
}
fn cb_w(i: u32) -> f32 {
    return bitcast<f32>(cb_u(i));
}
fn cb_w2(i: u32) -> vec2<f32> {
    return vec2<f32>(cb_w(i), cb_w(i + 1u));
}
fn cb_w3(i: u32) -> vec3<f32> {
    return vec3<f32>(cb_w(i), cb_w(i + 1u), cb_w(i + 2u));
}
fn cb_w4(i: u32) -> vec4<f32> {
    return vec4<f32>(cb_w(i), cb_w(i + 1u), cb_w(i + 2u), cb_w(i + 3u));
}
fn cb_sp(i: i32) -> u32 {
    return CB_SPB + u32(i) * CB_SPW;
}
// Spire i: x, z its foot off the target, y when it sets off (breaks the ground), w how tall it grows.
fn cb_place(i: i32, seed: f32) -> vec4<f32> {
    return cb_w4(cb_sp(i));
}
// Spire i's shape: x its radius (the apothem of its hexagon at its foot), y how far it leans off upright (radians),
// z which way (radians round from +x), w how far it is turned about its own axis.
fn cb_form(i: i32, seed: f32, p: vec4<f32>) -> vec4<f32> {
    return cb_w4(cb_sp(i) + 4u);
}
// Where spire i breaks as they burst: x the height up its axis (0: it shatters whole), z, w the break's tilt across it.
fn cb_break(i: i32, seed: f32, ph: f32) -> vec4<f32> {
    return cb_w4(cb_sp(i) + 8u);
}
// Its colour round the wheel.
fn cb_hue_of(i: i32) -> f32 {
    return cb_w(cb_sp(i) + 12u);
}
// Its axis (from its lean).
fn cb_axis(f: vec4<f32>) -> vec3<f32> {
    return vec3<f32>(sin(f.y) * cos(f.z), cos(f.y), sin(f.y) * sin(f.z));
}
// Its frame: e1 and e2 across its axis, turned by f.w.
fn cb_frame(a: vec3<f32>, rot: f32) -> mat2x3<f32> {
    let u = normalize(cross(a, vec3<f32>(0.0, 0.0, 1.0)));
    let w = cross(u, a);
    let c = cos(rot);
    let s = sin(rot);
    return mat2x3<f32>(u * c + w * s, -u * s + w * c);
}
// Its tip's apex, off its axis a little (x, z in its frame, of its radius at the top).
fn cb_apex(i: i32, seed: f32) -> vec2<f32> {
    return cb_w2(cb_sp(i) + 14u);
}
// How far a spire `s` seconds after it set off has grown (x, of its height) and how hard it shudders (y, blocks). The
// first shards break the ground, catch, strain and give twice, gathering, then surge up out of it, a little past their
// height, and settle; the bloom's grow in two or three pushes, each easing off, the last slowest.
fn cb_ease(x: f32) -> f32 {
    let y = 1.0 - saturate(x);
    return 1.0 - y * y * y;
}
fn cb_jolt(s: f32, at: f32, k: f32) -> f32 {
    return select(0.0, exp(-(s - at) * k), s > at);
}
fn cb_grow(i: i32, s: f32, ph: f32) -> vec2<f32> {
    if (s <= 0.0) {
        return vec2<f32>(0.0);
    }
    if (i < CB_LEADS) {
        var g = 0.0;
        if (s < 0.1) {
            g = 0.06 * cb_ease(s / 0.1);
        } else if (s < 0.34) {
            g = mix(0.06, 0.068, (s - 0.1) / 0.24);
        } else if (s < 0.42) {
            g = mix(0.068, 0.1, cb_ease((s - 0.34) / 0.08));
        } else if (s < 0.66) {
            g = mix(0.1, 0.108, (s - 0.42) / 0.24);
        } else if (s < 0.74) {
            g = mix(0.108, 0.14, cb_ease((s - 0.66) / 0.08));
        } else if (s < CB_STRUGGLE) {
            g = 0.14 - 0.006 * smoothstep(0.74, CB_STRUGGLE, s);
        } else {
            let x = (s - CB_STRUGGLE) / CB_SURGE;
            if (x < 1.0) {
                g = mix(0.134, 1.03, 1.0 - pow(1.0 - x, 2.6));
            } else {
                let y = saturate((x - 1.0) * 1.5);
                g = mix(1.03, 1.0, y * y * (3.0 - 2.0 * y));
            }
        }
        let strain = smoothstep(0.75, CB_STRUGGLE, s) * f32(s < CB_STRUGGLE);
        let sh = 0.25 * f32(s < CB_STRUGGLE) + 1.6 * cb_jolt(s, 0.0, 9.0) + 1.2 * cb_jolt(s, 0.34, 10.0)
            + 1.3 * cb_jolt(s, 0.66, 10.0) + 1.4 * strain + 2.4 * cb_jolt(s, CB_STRUGGLE, 3.0);
        return vec2<f32>(g, sh);
    }
    // the bloom: three pushes, the first sharp (it breaks the ground), each easing off
    let d = 1.3 + 2.2 * saturate(ph / 260.0);
    let x = s / d;
    let g = 0.3 * cb_ease(x / 0.12) + 0.4 * cb_ease((x - 0.18) / 0.3) + 0.3 * cb_ease((x - 0.55) / 0.45);
    let sh = 0.5 * cb_jolt(s, 0.0, 8.0) + 0.3 * cb_jolt(s, 0.18 * d, 9.0) + 0.2 * cb_jolt(s, 0.55 * d, 9.0);
    return vec2<f32>(g, sh * (0.5 + ph / 120.0));
}
// When the crater `r` out has been dug (strike.rs's cb_dig_t, a chunk column at a time from the middle out), and how
// far the land at `rel2` has really been opened by `time`: after the chunk round it has been dug (strike.rs may put one
// off by up to CB_SLACK), its edge wandering.
fn cb_dig_t(r: f32) -> f32 {
    return CB_DET + 0.1 + r / CB_DIG_V;
}
fn cb_open(rel2: vec2<f32>, r: f32, time: f32) -> f32 {
    let n = gnoise2(rel2 * 0.05) - 0.5;
    return smoothstep(0.0, 0.25, time - cb_dig_t(r + 20.0 + 6.0 * n));
}
// When the fissures open `r` out (strike.rs's cb_crack_t): as the shock reaches them, not before the land over them
// has been cleared.
fn cb_crack_t(r: f32) -> f32 {
    let shock = CB_DET + 0.2 + r / CB_SHOCK_V;
    return max(shock, cb_dig_t(r + 20.0) + 0.05);
}
// Fissure i: x its heading out from the target, y how far out it runs.
fn cb_crack(i: i32, seed: f32) -> vec2<f32> {
    return cb_w2(CB_TAB + 1u + u32(i) * 2u);
}

// ---- the crystal: a hexagonal prism drawing in a little up its length, under a six-faced tip, its foot run down into
// the ground; after the burst its stump, cut across at the break. Convex: every view ray meets it in one stretch, found
// exactly, plane by plane, with the face it enters by (its facets are real faces).
struct Crystal {
    B: vec3<f32>,      // its foot on the ground (camera-relative)
    a: vec3<f32>,      // its axis
    e1: vec3<f32>,
    e2: vec3<f32>,
    R: f32,            // its radius at its foot (the hexagon's apothem) and at the top of its sides
    Rt: f32,
    Hb: f32,           // where its sides end and its tip begins, up its axis, and how tall the tip is
    tip: f32,
    apex: vec2<f32>,
    cut: vec4<f32>,    // its break: inside where y + x * cut.y + z * cut.z <= cut.x (cut.w 1 when there is one)
    hue: f32,
    skew: f32,         // how uneven its faces are
    g: f32,            // how far grown
    s: f32,            // since it set off
}
const CB_DIRS = array<vec2<f32>, 6>(vec2<f32>(1.0, 0.0), vec2<f32>(0.5, 0.8660254), vec2<f32>(-0.5, 0.8660254),
    vec2<f32>(-1.0, 0.0), vec2<f32>(-0.5, -0.8660254), vec2<f32>(0.5, -0.8660254));
// Plane k of a crystal (in its frame): xyz its outward normal (not normalised), w: inside where dot(n, p) <= w.
fn cb_plane(c: Crystal, k: i32) -> vec4<f32> {
    if (k < 6) {
        let cs = CB_DIRS[k];
        let tp = (c.R - c.Rt) / max(c.Hb + CB_SINK, 1.0);
        // (its faces not all as wide: each side stands a little in or out)
        let sk = 1.0 + c.skew * (fract(c.hue * 91.7 + f32(k) * 0.618) - 0.5);
        return vec4<f32>(cs.x, tp, cs.y, (c.R - tp * CB_SINK) * sk);
    }
    if (k < 12) {
        let cs = CB_DIRS[k - 6];
        let m = (c.Rt - dot(cs, c.apex) * c.Rt) / max(c.tip, 0.5);
        return vec4<f32>(cs.x, m, cs.y, c.Rt + m * c.Hb);
    }
    if (k == 12) {
        return vec4<f32>(0.0, -1.0, 0.0, CB_SINK);
    }
    return vec4<f32>(c.cut.y, 1.0, c.cut.z, select(1.0e7, c.cut.x, c.cut.w > 0.5));
}
// The view ray (o, d in the crystal's frame) through it: x where it goes in (under 0: it misses), y where it comes out,
// z the face it goes in by.
fn cb_hit(c: Crystal, o: vec3<f32>, d: vec3<f32>) -> vec3<f32> {
    var t0 = -1.0e9;
    var t1 = 1.0e9;
    var kin = 0;
    for (var k = 0; k < 14; k = k + 1) {
        let pl = cb_plane(c, k);
        let dn = dot(pl.xyz, d);
        let num = pl.w - dot(pl.xyz, o);
        if (abs(dn) < 1.0e-7) {
            if (num < 0.0) {
                return vec3<f32>(-1.0, -1.0, 0.0);
            }
            continue;
        }
        let t = num / dn;
        if (dn < 0.0) {
            if (t > t0) {
                t0 = t;
                kin = k;
            }
        } else {
            t1 = min(t1, t);
        }
    }
    if (t0 > t1 || t1 < 0.0) {
        return vec3<f32>(-1.0, -1.0, 0.0);
    }
    return vec3<f32>(t0, t1, f32(kin));
}
// From inside it at q along d: how far to where it comes out (x) and the face it comes out by (y).
fn cb_exit(c: Crystal, q: vec3<f32>, d: vec3<f32>) -> vec2<f32> {
    var t1 = 1.0e9;
    var kout = 0;
    for (var k = 0; k < 14; k = k + 1) {
        let pl = cb_plane(c, k);
        let dn = dot(pl.xyz, d);
        if (dn > 1.0e-7) {
            let t = (pl.w - dot(pl.xyz, q)) / dn;
            if (t < t1) {
                t1 = t;
                kout = k;
            }
        }
    }
    return vec2<f32>(max(t1, 0.0), f32(kout));
}
// Spire i at `time` (cam the eye, tgt the target): its pose, how far it has grown, and its break once it has burst.
fn cb_crystal(i: i32, seed: f32, time: f32, crel: vec3<f32>) -> Crystal {
    var c: Crystal;
    let p = cb_place(i, seed);
    let f = cb_form(i, seed, p);
    let gr = cb_grow(i, time - p.z, p.w);
    let fi = f32(i);
    c.s = time - p.z;
    c.g = gr.x;
    // (it shudders as it struggles and as each push takes it)
    let sh = vec3<f32>(sin(time * 41.0 + fi * 1.3) + 0.5 * sin(time * 73.0 + fi), 0.0, sin(time * 37.0 + fi * 2.1) + 0.5 * sin(time * 67.0 + fi * 0.7)) * gr.y * 0.35;
    c.B = crel + vec3<f32>(p.x, 0.0, p.y) + sh;
    // (the first shards lean a little more while they struggle, and straighten as they surge up)
    var lean = f.y;
    if (i < CB_LEADS) {
        lean = f.y * (1.0 + 0.6 * (1.0 - smoothstep(CB_STRUGGLE, CB_STRUGGLE + 0.8, c.s))) + 0.003 * gr.y;
    }
    c.a = cb_axis(vec4<f32>(f.x, lean, f.z, f.w));
    let fr = cb_frame(c.a, f.w);
    c.e1 = fr[0];
    c.e2 = fr[1];
    let H = p.w * gr.x;
    let w = 0.38 + 0.62 * saturate(gr.x * 1.15);
    c.R = f.x * w;
    c.Rt = c.R * 0.8;
    c.tip = min(c.Rt * (1.3 + 1.5 * cb_w(cb_sp(i) + 13u)), H + CB_SINK * 0.5);
    c.skew = 0.35;
    c.Hb = H - c.tip;
    c.apex = cb_apex(i, seed);
    c.cut = vec4<f32>(0.0);
    c.hue = cb_hue_of(i);
    return c;
}
// A point (camera-relative) or a direction in a crystal's frame, and back.
fn cb_to(c: Crystal, x: vec3<f32>) -> vec3<f32> {
    return vec3<f32>(dot(x, c.e1), dot(x, c.a), dot(x, c.e2));
}
fn cb_from(c: Crystal, v: vec3<f32>) -> vec3<f32> {
    return c.e1 * v.x + c.a * v.y + c.e2 * v.z;
}

// ---- colour ---------------------------------------------------------------------------------------------------------
// The crystals' colours round the wheel: violet, magenta, rose, ice, cyan, deep blue.
fn cb_hue(x: f32) -> vec3<f32> {
    var pal = array<vec3<f32>, 6>(
        vec3<f32>(0.58, 0.32, 1.0), vec3<f32>(0.92, 0.32, 0.92), vec3<f32>(1.0, 0.5, 0.75),
        vec3<f32>(0.8, 0.86, 1.0), vec3<f32>(0.3, 0.8, 1.0), vec3<f32>(0.32, 0.38, 1.0));
    let h = fract(x) * 6.0;
    let i = i32(floor(h));
    let f = smoothstep(0.0, 1.0, h - floor(h));
    return mix(pal[i], pal[(i + 1) % 6], f);
}
// A spectrum, for the prismatic light: red through violet as x runs 0 to 1.
fn cb_spectrum(x: f32) -> vec3<f32> {
    let h = saturate(x);
    return saturate(vec3<f32>(1.5 - abs(h - 0.15) * 4.5, 1.5 - abs(h - 0.45) * 4.5, 1.5 - abs(h - 0.78) * 4.5)) + vec3<f32>(0.5, 0.0, 0.5) * smoothstep(0.85, 1.0, h);
}
// A beam of light split by a prism, `lat` across it (-1 to 1): its colours fanned out, the crystal's own in the middle.
fn cb_prism(lat: f32, own: vec3<f32>) -> vec3<f32> {
    let sp = cb_spectrum(0.5 + 0.5 * clamp(lat, -1.2, 1.2)) * vec3<f32>(1.0, 0.7, 1.0);
    return mix(own * 1.2, sp, smoothstep(0.1, 0.6, abs(lat)));
}
// What a facet of crystal catches of the world in direction v: the sky (darkened as the strike darkens it), the sun, a
// bright horizon, the land under it dark.
fn cb_env(v: vec3<f32>, sky_c: vec3<f32>, sun: vec3<f32>, day: f32, dark: f32, glow: vec3<f32>) -> vec3<f32> {
    let up = v.y;
    let zen = mix(vec3<f32>(0.01, 0.012, 0.03), sky_c * 0.8, day) * (1.0 - 0.6 * dark);
    let hor = mix(vec3<f32>(0.03, 0.035, 0.07), sky_c * 1.25 + vec3<f32>(0.15), day) * (1.0 - 0.5 * dark);
    var e = mix(hor, zen, smoothstep(0.0, 0.6, up));
    let ground = vec3<f32>(0.05, 0.05, 0.045) * (0.2 + 0.8 * day) * (1.0 - 0.5 * dark) + glow * 0.5;
    e = mix(e, ground, smoothstep(0.02, -0.12, up));
    let sd = max(dot(v, sun), 0.0);
    e = e + vec3<f32>(6.0, 5.6, 5.0) * pow(sd, 900.0) * day + vec3<f32>(0.6, 0.55, 0.5) * pow(sd, 18.0) * day * 0.4;
    return e;
}
fn cb_occ(t: f32, scene_len: f32, sky: bool, cloud: bool) -> f32 {
    return select(select(0.0, 0.5, cloud), 1.0, sky || t < scene_len);
}

// ---- small shards: an octahedron stretched along one axis, turned by `ax`, `ang`; how far along the view ray it is met
// (x, under 0 a miss) and the face's normal (yzw). C camera-relative, `sz` its half-size across, `ln` along.
fn cb_shard(rd: vec3<f32>, C: vec3<f32>, sz: f32, ln: f32, ax: vec3<f32>, ang: f32, tmax: f32) -> vec4<f32> {
    let tc = dot(C, rd);
    let bound = max(sz, ln) * 1.05;
    let dc2 = dot(C, C) - tc * tc;
    if (tc < 0.0 || dc2 > bound * bound || tc - bound > tmax) {
        return vec4<f32>(-1.0);
    }
    let o = rot_axis(-C, ax, -ang);
    let d = rot_axis(rd, ax, -ang);
    var t0 = -1.0e9;
    var t1 = 1.0e9;
    var nin = vec3<f32>(0.0, 1.0, 0.0);
    for (var k = 0; k < 8; k = k + 1) {
        let n = vec3<f32>(select(-1.0, 1.0, (k & 1) == 0) / sz, select(-1.0, 1.0, (k & 2) == 0) / ln, select(-1.0, 1.0, (k & 4) == 0) / sz);
        let dn = dot(n, d);
        let num = 1.0 - dot(n, o);
        if (abs(dn) < 1.0e-8) {
            continue;
        }
        let t = num / dn;
        if (dn < 0.0) {
            if (t > t0) {
                t0 = t;
                nin = n;
            }
        } else {
            t1 = min(t1, t);
        }
    }
    if (t0 > t1 || t0 < 0.0 || t0 > tmax) {
        return vec4<f32>(-1.0);
    }
    return vec4<f32>(t0, normalize(rot_axis(nin, ax, ang)));
}
// The hashes for the spires' chunks and the rest (strike.rs's cb_h3).
fn cb_h3(f: i32, k: u32, seed: f32) -> vec3<f32> {
    return vec3<f32>(pcg3d(vec3<u32>(u32(f), k, u32(seed)))) * (1.0 / 4294967295.0);
}

// ---- the break: each spire fractures into chunks as they burst --------------------------------------------------
// Each spire (above its break, or from the ground if it shatters whole) is cut across its length at CB_NSEG uneven
// heights by planes tilted every which way, so its pieces are slabs and wedges, long splinters and short fragments;
// the wider ones split again down their length. Each piece keeps the spire's own faces (it is the spire, clipped by
// its cuts) and is thrown out from where it was, tumbling as its size allows, and comes down where strike.rs builds it
// in blocks (cb_chunk there): keep the two in step.
fn cb_nseg(R: f32, span: f32) -> i32 {
    return clamp(i32(span / (10.0 + R * 1.1)), 2, 6);
}
// How high up its axis cut k of spire i is (0 its foot, nseg its top).
fn cb_cut_h(i: i32, k: i32, nseg: i32, h0: f32, span: f32, seed: f32) -> f32 {
    var tot = 0.0;
    var at = 0.0;
    for (var j = 0; j < 6; j = j + 1) {
        if (j >= nseg) {
            break;
        }
        let w = 0.45 + cb_h3(i * 16 + j, 501u, seed).x;
        if (j < k) {
            at = at + w;
        }
        tot = tot + w;
    }
    return h0 + span * at / tot;
}
// Cut k as a plane in the spire's frame: inside (below it) where dot(xyz, q) <= w.
fn cb_cut_plane(i: i32, k: i32, nseg: i32, h0: f32, span: f32, R: f32, seed: f32) -> vec4<f32> {
    return cb_cut_at(i, k, nseg, cb_cut_h(i, k, nseg, h0, span, seed), span, R, seed);
}
fn cb_cut_at(i: i32, k: i32, nseg: i32, h: f32, span: f32, R: f32, seed: f32) -> vec4<f32> {
    let t = (cb_h3(i * 16 + k, 502u, seed).xy - 0.5) * min(1.1, 0.4 * span / f32(nseg) / R);
    return vec4<f32>(t.x, 1.0, t.y, h);
}
// The crater's depth r out, as a chunk falling in it meets it (strike.rs's cb_bowl_dep).
fn cb_bowl_dep(r: f32) -> f32 {
    let u = saturate(r / CB_BOWL);
    return select(0.0, CB_BOWL_D * pow(1.0 - u * u, 0.75), r < CB_BOWL);
}
struct CbChunk {
    C0: vec3<f32>,     // its middle as it breaks off (off the target)
    v: vec3<f32>,      // how fast it is thrown
    spin: vec4<f32>,   // the axis it tumbles about, and how fast
    lo: vec4<f32>,     // its cuts in the spire's frame: inside where dot(xyz, q) <= w
    hi: vec4<f32>,
    sp: vec4<f32>,
    tl: f32,           // when it comes down (after the burst), and when it is built in blocks there
    tp: f32,
    L: f32,            // how long and how wide it is
    wid: f32,
    A: vec3<f32>,      // its spire's axis
    dy: f32,           // how much higher than the target it comes down: the ground under it as it lies (cb_drop)
}
// How much higher than the target piece f (i * 16 + k * 2 + half) comes down: the mod rests each on the ground as it
// really lies there and gives the pass how far up that is (render.set-data, word f), long before the burst; 0 (the land
// at the target's height, the crater's floor in it) for any it has not given.
fn cb_drop(f: i32) -> f32 {
    let i = u32(f);
    if (i >= arrayLength(&mod_data)) {
        return 0.0;
    }
    let v = bitcast<f32>(mod_data[i]);
    return select(0.0, clamp(v, -60.0, 60.0), abs(v) <= 60.0);
}
// Piece (k, half) of spire i (its foot F off the target, its frame a, e1, e2, radius R, height H; its break brk).
fn cb_chunk(i: i32, k: i32, half: i32, seed: f32, F: vec3<f32>, a: vec3<f32>, e1: vec3<f32>, e2: vec3<f32>, R: f32, nseg: i32, ylo: f32, yhi: f32) -> CbChunk {
    var o: CbChunk;
    let split = R > 11.0 && k < nseg - 1;
    var ym = (ylo + yhi) * 0.5;
    if (k == nseg - 1) {
        ym = ylo + (yhi - ylo) * 0.4;
    }
    var cx = vec2<f32>(0.0);
    o.sp = vec4<f32>(0.0, 0.0, 0.0, 1.0e7);
    o.wid = R;
    if (split) {
        let hs = cb_h3(i * 16 + k, 503u, seed);
        let ph = hs.x * TAU;
        let n = vec2<f32>(cos(ph), sin(ph));
        let w = (hs.y - 0.5) * R * 0.5;
        o.sp = select(vec4<f32>(n.x, 0.0, n.y, w), vec4<f32>(-n.x, 0.0, -n.y, -w), half == 1);
        cx = n * (w + select(-1.0, 1.0, half == 1) * R * 0.45);
        o.wid = R * 0.6;
    }
    o.L = yhi - ylo;
    o.A = a;
    o.C0 = F + e1 * cx.x + a * ym + e2 * cx.y;
    let f = i * 16 + k * 2 + half;
    let hm = cb_h3(f, 504u, seed);
    let hsn = cb_h3(f, 505u, seed);
    let out = normalize(vec2<f32>(o.C0.x + 0.01, o.C0.z));
    let az = (hm.y - 0.5) * 0.9;
    let o2 = vec2<f32>(out.x * cos(az) - out.y * sin(az), out.x * sin(az) + out.y * cos(az));
    let vy = 6.0 + 17.0 * hm.z;
    let mass = 1.4 - 0.5 * saturate(o.wid * o.L / 600.0);
    let y0 = max(o.C0.y, 0.0);
    let tl0 = (vy + sqrt(vy * vy + 2.0 * CB_G * y0)) / CB_G;
    let vh = min((11.0 + 26.0 * hm.x + y0 * 0.08) * mass, max(225.0 - length(o.C0.xz), 10.0) / tl0);
    let r1 = length(o.C0.xz + o2 * vh * tl0);
    o.tl = (vy + sqrt(vy * vy + 2.0 * CB_G * (y0 + cb_bowl_dep(r1)))) / CB_G;
    let rl = length(o.C0.xz + o2 * vh * o.tl);
    o.tp = max(select(o.tl, max(o.tl, cb_dig_t(rl + 20.0) + 0.15 - CB_DET), rl < 150.0), o.tl + 0.16);
    o.v = vec3<f32>(o2.x * vh, vy, o2.y * vh);
    o.dy = cb_drop(f);
    let rate = (0.8 + 2.6 * hsn.x) * 14.0 / (14.0 + o.L * 0.35 + o.wid * 0.25) * select(-1.0, 1.0, hsn.y > 0.5);
    o.spin = vec4<f32>(normalize(hsn - 0.5 + vec3<f32>(0.0, 0.01, 0.0)), rate);
    return o;
}
// Its cuts across, below and above (its first below at the spire's break, if it leaves a stump).
fn cb_chunk_cuts(o: ptr<function, CbChunk>, i: i32, k: i32, nseg: i32, ylo: f32, yhi: f32, span: f32, R: f32, brk: vec4<f32>, seed: f32) {
    if (k == 0 && brk.x > 0.5) {
        (*o).lo = vec4<f32>(-brk.z, -1.0, -brk.w, -brk.x);
    } else {
        (*o).lo = -cb_cut_at(i, k, nseg, ylo, span, R, seed);
    }
    (*o).hi = select(cb_cut_at(i, k + 1, nseg, yhi, span, R, seed), vec4<f32>(0.0, 1.0, 0.0, 1.0e7), k == nseg - 1);
}
// Where a piece is `dt` after the burst (off the target) and how far it has turned: flying, then come down and driven
// in along its path (deeper the bigger it is), lying there until it is built (strike.rs's CbChunk::rest: keep in step).
const CB_WEDGE: f32 = 0.5;
const CB_WEDGE_K: f32 = 0.003;
const CB_WEDGE_MAX: f32 = 0.4;
const CB_IMPACT: f32 = 0.15;
// How long a piece takes to fade once its blocks are in (the mod's param 14, [3].z: the latest landed piece's blocks
// in, by strike time), leaving them.
const CB_FADE: f32 = 0.25;
fn cb_chunk_at(o: CbChunk, dt: f32) -> vec4<f32> {
    let tf = min(dt, o.tl);
    // (thrown that much higher, so it comes down there at tl all the same: CbChunk::rest_at)
    var P = o.C0 + o.v * tf - vec3<f32>(0.0, 0.5 * CB_G * tf * tf - o.dy * tf / o.tl, 0.0);
    if (dt > o.tl) {
        let vl = normalize(o.v + vec3<f32>(0.0, o.dy / o.tl - CB_G * o.tl, 0.0));
        // (the bigger the deeper, but never so deep that a good part of it is not left standing out, however it lies)
        let ay = rot_axis(o.A, o.spin.xyz, o.spin.w * o.tl).y;
        let hv = 0.25 * (o.L * abs(ay) + 2.0 * o.wid * sqrt(max(1.0 - ay * ay, 0.0)));
        let wd = min(CB_WEDGE + CB_WEDGE_K * (o.L + o.wid) * (o.L + o.wid), CB_WEDGE_MAX * hv / max(abs(vl.y), 0.3));
        // (stopped hard: fast as it hits, slowing to nothing at its rest, never past it)
        let u = 1.0 - saturate((dt - o.tl) / CB_IMPACT);
        P = P + vl * wd * (1.0 - u * u * u);
    }
    return vec4<f32>(P, o.spin.w * tf);
}
// How big it is by then: shrinking as it falls, smoothly, to half by the time it comes down (strike.rs's CB_LAND_SCALE).
fn cb_chunk_scale(o: CbChunk, dt: f32) -> f32 {
    let u = saturate(dt / o.tl);
    return 1.0 - 0.5 * u * u * (3.0 - 2.0 * u);
}
// Piece n of the table (pb its first word, vt its throw and when it comes down): where it is `dt` after the burst (off
// the target) and how far it has turned, as cb_chunk_at; how big it is by then, as cb_chunk_scale; its planes (0..12
// its spire's faces as it stood, 13..15 its cuts), and the view ray through them, as cb_hit3.
fn cb_piece_at(pb: u32, vt: vec4<f32>, dt: f32) -> vec4<f32> {
    let tl = vt.w;
    let v = vt.xyz;
    let dy = cb_drop(i32(cb_u(pb + 3u)));
    let rate = cb_w(pb + 11u);
    let tf = min(dt, tl);
    var P = cb_w3(pb) + v * tf - vec3<f32>(0.0, 0.5 * CB_G * tf * tf - dy * tf / tl, 0.0);
    if (dt > tl) {
        let vl = normalize(v + vec3<f32>(0.0, dy / tl - CB_G * tl, 0.0));
        let wd = min(cb_w(pb + 29u), CB_WEDGE_MAX * cb_w(pb + 28u) / max(abs(vl.y), 0.3));
        let u = 1.0 - saturate((dt - tl) / CB_IMPACT);
        P = P + vl * wd * (1.0 - u * u * u);
    }
    return vec4<f32>(P, rate * tf);
}
fn cb_piece_scale(tl: f32, dt: f32) -> f32 {
    let u = saturate(dt / tl);
    return 1.0 - 0.5 * u * u * (3.0 - 2.0 * u);
}
fn cb_piece_plane(sb: u32, pb: u32, k: i32) -> vec4<f32> {
    return select(cb_w4(sb + 40u + u32(k) * 4u), cb_w4(pb + 12u + u32(k - 13) * 4u), k >= 13);
}
fn cb_hit_t(sb: u32, o: vec3<f32>, d: vec3<f32>, pb: u32) -> vec3<f32> {
    var t0 = -1.0e9;
    var t1 = 1.0e9;
    var kin = 0;
    for (var k = 0; k < 16; k = k + 1) {
        let pl = select(cb_w4(sb + 40u + u32(k) * 4u), cb_w4(pb + 12u + u32(k - 13) * 4u), k >= 13);
        let dn = dot(pl.xyz, d);
        let num = pl.w - dot(pl.xyz, o);
        if (abs(dn) < 1.0e-7) {
            if (num < 0.0) {
                return vec3<f32>(-1.0, -1.0, 0.0);
            }
            continue;
        }
        let t = num / dn;
        if (dn < 0.0) {
            if (t > t0) {
                t0 = t;
                kin = k;
            }
        } else {
            t1 = min(t1, t);
        }
    }
    if (t0 > t1 || t1 < 0.0) {
        return vec3<f32>(-1.0, -1.0, 0.0);
    }
    return vec3<f32>(t0, t1, f32(kin));
}
// The view ray through a crystal's own faces (but its cut) and three more planes: x in, y out, z the face it goes in
// by (13 and on: a broken face).
fn cb_hit3(c: Crystal, o: vec3<f32>, d: vec3<f32>, x0: vec4<f32>, x1: vec4<f32>, x2: vec4<f32>) -> vec3<f32> {
    var t0 = -1.0e9;
    var t1 = 1.0e9;
    var kin = 0;
    for (var k = 0; k < 16; k = k + 1) {
        var pl: vec4<f32>;
        if (k < 13) {
            pl = cb_plane(c, k);
        } else if (k == 13) {
            pl = x0;
        } else if (k == 14) {
            pl = x1;
        } else {
            pl = x2;
        }
        let dn = dot(pl.xyz, d);
        let num = pl.w - dot(pl.xyz, o);
        if (abs(dn) < 1.0e-7) {
            if (num < 0.0) {
                return vec3<f32>(-1.0, -1.0, 0.0);
            }
            continue;
        }
        let t = num / dn;
        if (dn < 0.0) {
            if (t > t0) {
                t0 = t;
                kin = k;
            }
        } else {
            t1 = min(t1, t);
        }
    }
    if (t0 > t1 || t1 < 0.0) {
        return vec3<f32>(-1.0, -1.0, 0.0);
    }
    return vec3<f32>(t0, t1, f32(kin));
}

// ---- the ground heaving over a shard about to break it: the land itself forced up and broken into plates ----------
// (q off the shard's foot across the land; R how far round it heaves, H how high at the middle, g how far gone, 0..1;
// id the shard.) The land round it is cut into plates (a Voronoi of them, finer towards the middle), each lifted with
// the swell under its middle and tilted out from it, the cracks between them opening as it goes: x the height there,
// y how far into its plate (from the nearest crack), z its plate's hash, w how wide the cracks are.
fn cb_heave(q: vec2<f32>, R: f32, H: f32, g: f32, id: i32) -> vec4<f32> {
    let cell = R * 0.3;
    let u = q / cell;
    let iu = floor(u);
    var d1 = 1.0e9;
    var d2 = 1.0e9;
    var c1 = vec2<f32>(0.0);
    var hz = vec3<f32>(0.0);
    for (var j = 0; j < 9; j = j + 1) {
        let o = iu + vec2<f32>(f32(j % 3 - 1), f32(j / 3 - 1));
        let hh = vec3<f32>(pcg3d(vec3<u32>(vec3<i32>(i32(o.x) + 4096, i32(o.y) + 4096, id + 77)))) * (1.0 / 4294967295.0);
        let c = o + 0.15 + 0.7 * hh.xy;
        let dd = length(u - c);
        if (dd < d1) {
            d2 = d1;
            d1 = dd;
            c1 = c;
            hz = hh;
        } else {
            d2 = min(d2, dd);
        }
    }
    let edge = (d2 - d1) * 0.5 * cell;
    let cw = c1 * cell;
    let rc = length(cw) / R;
    let dome = saturate(1.0 - rc * rc);
    let swell = dome * dome;
    // (the plate tilted up towards the middle, out over the land, and a little its own way)
    let outd = cw / max(length(cw), 0.5);
    let slope = H / R * (1.6 * sqrt(dome) + 0.3) * g;
    let tilt = -outd * slope + (hz.xz - 0.5) * 0.35 * H / R * g;
    var h = H * swell * (0.8 + 0.4 * hz.z) * g + dot(q - cw, tilt);
    // (and outside the plates' reach, the land only swelling a little, down to nothing)
    let rq = length(q) / R;
    let outer = saturate(1.0 - rq * rq);
    h = select(H * 0.12 * outer * outer * g, max(h, 0.0), rc < 0.92);
    let w = (0.12 + cell * 0.09 * g * dome) * f32(rc < 0.92);
    // (its edge broken off steep, a little crumbled: a slab, not a cushion)
    h = h * smoothstep(w * 0.5, w * 0.5 + 0.5 + 0.25 * hz.y, edge);
    return vec4<f32>(h, edge, hz.z, w);
}

// ---- dust: what each crystal throws up as it breaks the ground and comes up out of it -----------------------------
// Round each of the first shards, the heart and each of the bloom's clusters (a "source": its foot, when it broke
// through, how big its dust is): a burst of earth as it breaks the ground (again as it surges, and at each push), a
// billowing column climbing with it (cb_rise), a surge rolling out over the land (cb_surge); the bloom's wall of dust
// running out ahead of its spires; and the haze all of it leaves, drifting and thinning. Each part is marched in a few
// steps over where the view ray crosses it, up to whatever is nearer (the land, a spire), and the parts are put
// together whatever their order (a weighted blend: they are all dust).
const CB_RISE_END: f32 = 6.0;       // a source's column gone this long after it surged (the haze carries on)
const CB_SURGE_END: f32 = 6.0;      // its surge gone (the bloom's soon, taken up into its wall)
const CB_SURGE_BLOOM: f32 = 3.0;
struct CbDL {
    crel: vec3<f32>,
    Ld: vec3<f32>,
    sky_l: vec3<f32>,
    sun_l: vec3<f32>,
    time: f32,
    seed: f32,
    glow_k: f32,
}
// A burst of earth `a` seconds after it was thrown, r out and y up from the foot, S the dust's size: a fountain from
// the foot, flaring as it climbs, its head falling back and spreading.
fn cb_burst(r: f32, y: f32, a: f32, S: f32) -> f32 {
    if (a <= 0.0 || a > 4.5) {
        return 0.0;
    }
    let rb = S * (0.45 + 1.5 * cb_ease(a / 1.2));
    let hb = S * (0.3 + 1.9 * cb_ease(a / 0.8)) * (1.0 - 0.45 * smoothstep(0.7, 3.5, a));
    let rf = rb * (0.5 + 0.5 * saturate(y / max(hb, 1.0)));
    let f = saturate(1.0 - length(vec2<f32>(r / rf, (y - clamp(y, 0.0, hb)) / (rb * 0.7))));
    return f * f * (3.0 - 2.0 * f) * smoothstep(0.0, 0.06, a) * exp(-a / 1.2) * 2.2;
}
// What a source throws up at p (off its foot): x how much dust, y how much of that is earth. s seconds since it broke
// the ground, S its dust's size, R its radius, Hc how high its column has climbed; dp 0 for the first shards and the
// heart (a bulge before they break, a surge after they struggle), else the time each of the bloom's pushes takes.
fn cb_rise(p: vec3<f32>, s: f32, S: f32, R: f32, Hc: f32, dp: f32) -> vec2<f32> {
    // (its column settled into the haze by the time it is CB_RISE_END old)
    let lead = dp == 0.0;
    let r = length(p.xz);
    let y = max(p.y, 0.0);
    var dirt = cb_burst(r, y, s, S);
    if (lead) {
        dirt = dirt + 1.3 * cb_burst(r, y, s - CB_STRUGGLE, S * 1.2);
    } else {
        dirt = dirt + 0.6 * cb_burst(r, y, s - 0.18 * dp, S * 0.8) + 0.45 * cb_burst(r, y, s - 0.55 * dp, S * 0.7);
    }
    var d = 0.0;
    // (before it breaks: dust seeping up round its foot as the ground heaves)
    if (lead && s < 0.3) {
        let sb = smoothstep(-CB_BULGE, 0.05, s);
        d = sb * sb * smoothstep(R + S * 0.9, R * 0.5, r) * smoothstep(S * 0.6, 0.0, y) * 0.9;
    }
    let sc = select(s, s - CB_STRUGGLE, lead);
    if (sc > -0.2) {
        let up = smoothstep(-0.2, 0.5, sc) * exp(-max(sc - 1.0, 0.0) / 4.5) * (1.0 - smoothstep(CB_RISE_END - 2.0, CB_RISE_END, sc));
        let rc = R * 1.02 + S * (0.3 + 0.55 * cb_ease(sc / 4.0)) + y * 0.16;
        let body = smoothstep(rc, R * 0.85, r) * smoothstep(Hc, Hc * 0.3, y);
        let hh = Hc * 0.82;
        let fh = saturate(1.0 - length(vec2<f32>(r / (rc * 1.35), (y - hh) / (rc * 0.9))));
        d = d + max(body, fh * fh * (3.0 - 2.0 * fh)) * up * 1.4;
    }
    return vec2<f32>(d + dirt, dirt);
}
// (it is gone `end` seconds after it set out). How far out it has rolled (sc seconds since it set out: x its middle, y how wide, z how high).
fn cb_surge_at(sc: f32, S: f32, R: f32) -> vec3<f32> {
    let e = cb_ease(sc / 3.6);
    return vec3<f32>(R + S * (0.3 + 3.4 * e), S * (0.4 + 0.7 * e), S * (0.45 + 0.6 * cb_ease(sc / 3.0)));
}
fn cb_surge(p: vec3<f32>, sc: f32, S: f32, R: f32, end: f32) -> f32 {
    let g = cb_surge_at(sc, S, R);
    let r = length(p.xz);
    let ring = exp(-pow((r - g.x) / g.y, 2.0)) + 0.2 * smoothstep(g.x, R, r);
    return ring * smoothstep(g.z, g.z * 0.05, max(p.y, 0.0)) * smoothstep(-0.2, 0.3, sc) * exp(-max(sc, 0.0) / 3.4) * (1.0 - smoothstep(end * 0.6, end, sc)) * 1.6;
}
// A cheap smooth noise (about 0..1, no lattice to show) for the dust's billows, marched many times a pixel: waves
// bent by waves, at two scales and turned to each other.
fn cb_wn3(p: vec3<f32>) -> f32 {
    let a = sin(p.x + 1.1 * sin(p.z * 0.73 + 1.3)) * sin(p.y * 1.13 + 1.2 * sin(p.x * 0.81)) * sin(p.z * 0.91 + sin(p.y * 0.62 + 2.0));
    let q = mat3x3<f32>(0.00, 0.80, 0.60, -0.80, 0.36, -0.48, -0.60, -0.48, 0.64) * p * 2.1 + vec3<f32>(1.7, 9.2, 5.3);
    let b = sin(q.x + 1.1 * sin(q.z * 0.77 + 0.4)) * sin(q.y * 1.07 + 1.1 * sin(q.x * 0.69 + 2.2)) * sin(q.z * 0.95 + sin(q.y * 0.58 + 0.7));
    return saturate(0.5 + 0.62 * a + 0.3 * b);
}
// The dust at qt (off the target) given how much of it the shapes put there (env, earth of it, its light from the
// crystals glw): its billows crisp-edged, two scales, rising and drifting, each shading itself where the light reaching
// it has come through more of it; lit by the sky and sun from above, the crystals from inside and below. x, y, z the
// light it sends back, w how dense.
fn cb_dshade(env: f32, dirt: f32, glw: vec3<f32>, qt: vec3<f32>, L: CbDL) -> vec4<f32> {
    if (env < 0.12) {
        return vec4<f32>(0.0);
    }
    let np = qt * (1.0 / 13.0) + vec3<f32>(L.seed * 0.37 - L.time * 0.12, -L.time * 0.32, L.time * 0.06);
    let n1 = cb_wn3(np);
    let n = n1 * 0.68 + cb_wn3(np * 2.3 + vec3<f32>(11.0, 3.0, 7.0)) * 0.32;
    let er = saturate((env - (1.0 - n) * 1.5) * 2.4);
    let dens = er * er * (3.0 - 2.0 * er) * (0.55 + 0.45 * min(env, 2.0));
    if (dens < 0.003) {
        return vec4<f32>(0.0);
    }
    let ns1 = cb_wn3(np + L.Ld * 0.35);
    let lit = saturate(0.5 + (n1 - ns1) * 3.5);
    let occ = 0.5 + 0.5 * exp(-env * 0.45);
    let tops = 0.7 + 0.3 * saturate(qt.y / 60.0);
    let alb = mix(vec3<f32>(0.62, 0.55, 0.47), vec3<f32>(0.36, 0.29, 0.22), saturate(dirt / env));
    let li = alb * (L.sky_l * (0.3 + 0.7 * lit) * occ * tops + L.sun_l * lit * lit * occ)
        + glw / env * (0.55 + 0.45 * (1.0 - lit)) * L.glow_k;
    return vec4<f32>(li, dens);
}
// Where the view ray (from the eye) is inside an upright cylinder, R round C (camera-relative), from y0 to y1 over it:
// x in, y out (y <= x: it misses).
fn cb_cyl(rd: vec3<f32>, C: vec3<f32>, R: f32, y0: f32, y1: f32) -> vec2<f32> {
    let a = max(dot(rd.xz, rd.xz), 1.0e-8);
    let b = -dot(rd.xz, C.xz);
    let c = dot(C.xz, C.xz) - R * R;
    let disc = b * b - a * c;
    if (disc <= 0.0) {
        return vec2<f32>(1.0, 0.0);
    }
    var t0 = (-b - sqrt(disc)) / a;
    var t1 = (-b + sqrt(disc)) / a;
    if (abs(rd.y) > 1.0e-5) {
        let ya = (C.y + y0) / rd.y;
        let yb = (C.y + y1) / rd.y;
        t0 = max(t0, min(ya, yb));
        t1 = min(t1, max(ya, yb));
    } else if (C.y + y0 > 0.0 || C.y + y1 < 0.0) {
        return vec2<f32>(1.0, 0.0);
    }
    return vec2<f32>(max(t0, 0.0), t1);
}
// One part of the dust marched over t0..t1 of the view ray: kind 0 a source's burst and column, 1 its surge (F its
// foot, v its s, S, R, Hc; dp as cb_rise's; gc its light), 2 the bloom's wall (F the target, v how far out it has run,
// how wide, how high, how thick). x, y, z the light it sends back, w how much of what is behind it shows through.
fn cb_dseg(rd: vec3<f32>, t0: f32, t1: f32, kind: i32, N: i32, F: vec3<f32>, v: vec4<f32>, dp: f32, gc: vec3<f32>, L: CbDL, jit: f32) -> vec4<f32> {
    let stp = (t1 - t0) / f32(N);
    var T = 1.0;
    var acc = vec3<f32>(0.0);
    for (var k = 0; k < N; k = k + 1) {
        let x = rd * (t0 + (f32(k) + jit) * stp);
        let p = x - F;
        let qt = x - L.crel;
        var env = 0.0;
        var dirt = 0.0;
        var glw = vec3<f32>(0.0);
        if (kind == 2) {
            let rr = length(qt.xz);
            let ang = atan2(qt.z, qt.x);
            let hw = v.z * (0.7 + 0.3 * sin(ang * 5.0 + L.seed) * sin(ang * 3.0 - 1.3 + L.seed * 0.7));
            env = exp(-pow((rr - v.x) / v.y, 2.0)) * smoothstep(hw, hw * 0.1, qt.y) * v.w;
            glw = cb_hue(ang / TAU + rr * 0.002 + L.time * 0.02) * env * 0.25 * exp(-max(qt.y, 0.0) / 15.0);
        } else {
            if (kind == 0) {
                let e = cb_rise(p, v.x, v.y, v.z, v.w, dp);
                env = e.x;
                dirt = e.y;
            } else {
                env = cb_surge(p, select(v.x, v.x - CB_STRUGGLE, dp == 0.0), v.y, v.z, select(CB_SURGE_END, CB_SURGE_BLOOM, dp > 0.0));
            }
            // (its light on the dust round it: from inside it and from below, the dust taking its colour)
            let rr = length(p.xz);
            glw = gc * (env - 0.7 * dirt) * exp(-max(rr - v.z, 0.0) / (v.y * 1.1)) * (0.35 + 0.65 * exp(-max(p.y, 0.0) / (v.y * 2.0)));
        }
        let sm = cb_dshade(env, dirt, glw, qt, L);
        if (sm.w > 0.0) {
            let al = 1.0 - exp(-sm.w * 0.11 * stp);
            acc = acc + T * al * sm.xyz;
            T = T * (1.0 - al);
            if (T < 0.02) {
                break;
            }
        }
    }
    return vec4<f32>(acc, T);
}

fn crystal_bloom(in: StageIn) -> vec4<f32> {
    let uv = in.uv;
    let aspect = frame.resolution.x / frame.resolution.y;
    let time = now();
    let cam = frame.camera_position.xyz;
    let tgt = target_pos();
    let crel = tgt - cam;
    let k = intensity_v();
    let seed = seed_v();
    let px_a = frame.view_params.w / frame.resolution.y;      // (the angle a pixel spans)

    // ---- timeline -------------------------------------------------------------
    let wake = smoothstep(0.2, 3.0, time);
    let dt = time - CB_DET;
    let det = dt > 0.0;
    // the light going down as the land wakes, a little; back once it is over
    let dark = smoothstep(0.0, 3.0, time) * (0.8 + 0.15 * smoothstep(CB_RES, CB_DET, time)) * (1.0 - smoothstep(CB_DET + 3.0, CB_END, time));
    // the resonance: building from CB_RES, the pulses running up them faster and faster, a breath just before it bursts
    let res = smoothstep(CB_RES, CB_DET - 0.4, time) * f32(!det);
    let breath = smoothstep(CB_DET - 0.32, CB_DET - 0.12, time) * f32(!det);
    let pulse_f = 0.5 + 6.5 * res * res;
    let pulse_ph = time * 0.5 + 6.5 * max(time - CB_RES, 0.0) * res * res * 0.6;
    // the colours turning: slowly as they grow, faster as they resonate, all to white as they burst
    let hue_t = time * 0.02 + res * res * (time - CB_RES) * 0.08;
    let flash = select(0.0, exp(-dt * 6.0) * 1.2 + exp(-dt * 25.0) * 1.8, det);
    let after = 1.0 - smoothstep(CB_END - 3.0, CB_END, time);
    let sun = frame.sun.xyz;
    let day = saturate(sun.y * 2.5 + 0.35);
    let sky_c = srgb_to_linear(frame.sky_color.rgb);
    let pT = project_rel(crel);
    let heart = crel + vec3<f32>(0.0, 150.0, 0.0);
    let pH = project_rel(heart);

    // ---- what bends the light: the air shimmering round the spires as they resonate, the shock running out ------
    let d0 = depth_at(uv);
    let sky0 = is_sky(d0);
    let rd0 = normalize(world_offset(uv, 0.5));
    let p0 = cam + world_offset(uv, select(d0, 0.5, sky0));
    var off = vec2<f32>(0.0);
    if (res > 0.01) {
        var sh = 0.0;
        for (var i = 0; i < CB_LEADS; i = i + 1) {
            let pl = cb_place(i, seed);
            let fm = cb_form(i, seed, pl);
            let A = crel + vec3<f32>(pl.x, 0.0, pl.y);
            let q = ray_seg(rd0, A, A + cb_axis(fm) * pl.w);
            sh = sh + exp(-max(q.x - fm.x, 0.0) / (fm.x * 1.5)) * select(1.0, 0.0, !sky0 && q.y > length(p0 - cam) + 20.0);
        }
        let hw = vec2<f32>(gnoise2(uv * vec2<f32>(70.0, 30.0) + vec2<f32>(0.0, -time * 3.0)), gnoise2(uv * vec2<f32>(70.0, 30.0) + vec2<f32>(31.0, -time * 2.6))) - 0.5;
        off = off + hw * 0.007 * saturate(sh) * res * (0.5 + 0.5 * sin(time * pulse_f * 6.0)) * k;
    }
    if (det && dt < 4.0 && pT.z > 0.0) {
        let rs = CB_SHOCK_V * dt;
        if (!sky0) {
            let r0 = length(p0.xz - tgt.xz);
            off = off + normalize(uv - pT.xy + vec2<f32>(1.0e-5)) * exp(-pow((r0 - rs) / 8.0, 2.0)) * exp(-dt * 0.7) * 0.02 * k;
        }
        // (and through the air: a shell round the heart)
        let tcs = dot(heart, rd0);
        let dcs = length(rd0 * max(tcs, 0.0) - heart);
        let Rs = 40.0 + 260.0 * (1.0 - exp(-dt * 1.4));
        off = off + normalize(uv - pH.xy + vec2<f32>(1.0e-5)) * exp(-pow((dcs - Rs) / 10.0, 2.0)) * exp(-dt * 1.2) * 0.012 * f32(tcs > 0.0) * k;
    }
    let uv2 = clamp(uv + off, vec2<f32>(0.002), vec2<f32>(0.998));

    // ---- the scene ------------------------------------------------------------
    let d = depth_at(uv2);
    var sky = is_sky(d);
    var solid = false;
    let rel = world_offset(uv2, select(d, 0.5, sky));
    var scene_len = select(1.0e9, length(rel), !sky);
    let rd = normalize(world_offset(uv2, 0.5));
    let P = cam + rel;
    var cloud = !sky && abs(P.y - CLOUD_Y - 2.0) < 6.0;
    let ca = (flash * 0.02 + res * res * 0.004) * k;
    let ca_dir = (uv2 - vec2<f32>(0.5)) * ca;
    var col = srgb_to_linear(vec3<f32>(
        textureSampleLevel(scene_color, linear_sampler, uv2 + ca_dir, 0.0).r,
        textureSampleLevel(scene_color, linear_sampler, uv2, 0.0).g,
        textureSampleLevel(scene_color, linear_sampler, uv2 - ca_dir, 0.0).b));
    // the sky to a deep indigo, the land dimmed, so the crystals' light carries
    let night = vec3<f32>(0.008, 0.008, 0.03) + vec3<f32>(0.05, 0.03, 0.12) * exp(-abs(rd.y) / 0.1) * wake;
    if (sky) {
        col = mix(col, night, dark * k);
    } else {
        col = col * (1.0 - 0.7 * dark * k);
    }
    var add = vec3<f32>(0.0);
    let amb_c = mix(vec3<f32>(0.012, 0.014, 0.035), vec3<f32>(0.22, 0.25, 0.32), day) * (1.0 - 0.6 * dark);
    let sun_c = vec3<f32>(1.6, 1.5, 1.35) * day * (1.0 - 0.7 * dark);
    let hazec = srgb_to_linear(frame.fog_color.rgb) * (0.3 + 0.7 * day) * (1.0 - 0.7 * dark);

    var heaved = false;
    // ---- the ground over the first shards heaving before they break it: the land forced up in plates, cracked between
    //      them, the crystal's light leaking up through the cracks, earth crumbling off their edges ----------------------
    for (var i = 0; i < CB_LEADS; i = i + 1) {
        let pl = cb_place(i, seed);
        let s = time - pl.z;
        if (s < -CB_BULGE || s > 0.35) {
            continue;
        }
        let sb = smoothstep(-CB_BULGE, 0.0, s);
        let g = sb * (0.8 + 0.2 * sb) + 0.25 * saturate(s * 4.0);
        let fm = cb_form(i, seed, pl);
        let S0 = crel + vec3<f32>(pl.x, 0.0, pl.y);
        let Rd = fm.x * 1.55;
        let Hm = fm.x * 0.32;
        // (shuddering as it is pushed)
        let shk = vec2<f32>(sin(time * 43.0 + f32(i)), sin(time * 37.0 + f32(i) * 2.0)) * 0.12 * sb;
        let tr = cb_cyl(rd, S0, Rd, -0.5, Hm * 1.4 + 1.0);
        if (tr.y <= tr.x || tr.x > scene_len + 2.0) {
            continue;
        }
        // (marched down the ray to where it first goes under the land's new face, then closed in on it)
        let NS = 40;
        let dtm = (tr.y - tr.x) / f32(NS);
        var tprev = tr.x;
        var thit = -1.0;
        for (var m = 0; m <= NS; m = m + 1) {
            let tm = tr.x + dtm * f32(m);
            let X = rd * tm - S0;
            let hv = cb_heave(X.xz + shk, Rd, Hm, g, i);
            if (X.y < hv.x) {
                var a0 = tprev;
                var a1 = tm;
                for (var b = 0; b < 6; b = b + 1) {
                    let am = (a0 + a1) * 0.5;
                    let Xm = rd * am - S0;
                    if (Xm.y < cb_heave(Xm.xz + shk, Rd, Hm, g, i).x) {
                        a1 = am;
                    } else {
                        a0 = am;
                    }
                }
                thit = a1;
                break;
            }
            tprev = tm;
        }
        if (thit < 0.0 || thit > scene_len + 1.5) {
            continue;
        }
        let X = rd * thit - S0;
        let q = X.xz + shk;
        let hv = cb_heave(q, Rd, Hm, g, i);
        if (hv.x < 0.04 && hv.y > hv.w) {
            continue;      // (the land as it was: left as the game drew it)
        }
        let e = 0.35;
        let hx = cb_heave(q + vec2<f32>(e, 0.0), Rd, Hm, g, i).x;
        let hz = cb_heave(q + vec2<f32>(0.0, e), Rd, Hm, g, i).x;
        let nrm = normalize(vec3<f32>(hv.x - hx, e, hv.x - hz));
        // the land's own colour and light: the game's ground under it, where it lay before it was lifted
        let G = project_rel(S0 + vec3<f32>(q.x, 0.0, q.y));
        var gc = col;
        if (G.z > 0.0 && all(G.xy > vec2<f32>(0.0)) && all(G.xy < vec2<f32>(1.0))) {
            gc = srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, G.xy, 0.0).rgb) * (1.0 - 0.7 * dark * k);
        }
        // (lit again for the way it now faces, darkened as it is forced up and torn)
        let Ls = normalize(select(vec3<f32>(0.3, 1.0, 0.2), sun, sun.y > 0.05));
        let lam = (0.45 + 0.75 * max(dot(nrm, Ls), 0.0)) / (0.45 + 0.75 * max(Ls.y, 0.0));
        var lc_ = gc * lam * (1.0 - 0.3 * sb) * (0.85 + 0.3 * hv.z);
        // the plates' broken edges: raw earth, crumbling off them (grains of it, flickering as they fall)
        let dirt = vec3<f32>(0.075, 0.055, 0.04) * (0.35 + 0.65 * day) * (1.0 - 0.5 * dark);
        let steep = 1.0 - nrm.y;
        let crumb = hash21(floor(q * 2.5 + vec2<f32>(0.0, time * 6.0)));
        let torn = saturate(steep * 2.2 + smoothstep(hv.w * 3.5, hv.w * 1.2, hv.y) * (0.6 + 0.4 * crumb)) * sb;
        lc_ = mix(lc_, dirt * (0.6 + 0.6 * crumb), torn);
        // the cracks: deep, and the crystal's light coming up out of them, brightest as it is about to break
        let hc = cb_hue(f32(i) * 0.17 + hue_t);
        let pw = thit * px_a;
        let in_crack = smoothstep(hv.w + pw, max(hv.w - pw, 0.0), hv.y) * step(0.01, hv.w);
        // (and up the plates' broken sides a little way, from the bottom of the crack)
        let leak = exp(-max(hv.y - hv.w, 0.0) / (0.25 + hv.w * 0.6)) * exp(-max(X.y, 0.0) / (0.6 + hv.w));
        let rq = length(q) / Rd;
        let bright = (0.6 + 2.4 * sb * sb) * (0.85 + 0.15 * sin(time * 30.0 + hv.z * 20.0)) * (1.0 - 0.5 * rq);
        // (the crack a dark chasm, the light a jagged seam down its bottom, flickering along it)
        let seam = exp(-hv.y / max(hv.w * 0.3 + pw, 0.05)) * (0.6 + 0.4 * gnoise2(q * 1.3 + vec2<f32>(time * 3.0, f32(i))));
        col = mix(lc_, dirt * 0.25, in_crack);
        add = hc * (seam * in_crack * 2.4 + in_crack * 0.12 + leak * 0.5 * (1.0 - in_crack)) * bright * k;
        scene_len = thit;
        heaved = true;
        sky = false;
        cloud = false;
    }

    // ---- the spires: solid, the nearest drawn and hiding what is behind it, hidden by anything nearer -------------
    var best = -1;
    var best_t = scene_len;
    var best_k = 0.0;
    var best_out = 0.0;
    // their light, from the first shards and each cluster's tallest: where (camera-relative, w how bright) and its colour
    var lp: array<vec4<f32>, 16>;
    var lc: array<vec3<f32>, 16>;
    var li: array<i32, 16>;                                     // (which spires, for the shards round them)
    var ltip: array<vec3<f32>, 16>;                             // (their tips and frames, for the light out of them)
    var lax: array<vec3<f32>, 16>;
    var le1: array<vec3<f32>, 16>;
    var nl = 0;
    var near_glint = 0.0;                                       // (the light round them in the air, close to their faces)
    var near_col = vec3<f32>(0.0);
    for (var i = 0; i < CB_N; i = i + 1) {
        var brk = vec4<f32>(0.0);
        if (det) {
            // after the burst: its stump, until the real one has been built where it stands
            let pl = cb_place(i, seed);
            brk = cb_break(i, seed, pl.w);
            if (brk.x < 0.5 || time > cb_dig_t(length(pl.xy) + cb_form(i, seed, pl).x * 1.3 + brk.x * 0.8 + 20.0) + 0.15) {
                continue;
            }
        }
        var c = cb_crystal(i, seed, time, crel);
        if (c.s <= 0.0) {
            continue;
        }
        // (their glow: waking as they come up, swelling as they resonate)
        let glow_i = (0.5 + 0.5 * smoothstep(0.0, 1.5, c.s)) * (1.0 + 2.0 * res) * (1.0 - breath * 0.85);
        let H = c.Hb + c.tip;
        if (det) {
            c.cut = vec4<f32>(brk.x, brk.z, brk.w, 1.0);
            c.R = c.R * CB_STUMP;
            c.Rt = c.R * 0.8;
        }
        if ((i < CB_LEADS || (i - 6) % 4 == 0) && nl < 16 && !det) {
            lp[nl] = vec4<f32>(c.B + c.a * H * 0.45, glow_i * saturate(c.g) * (0.25 + H / 300.0));
            lc[nl] = cb_hue(c.hue + hue_t);
            li[nl] = i;
            ltip[nl] = c.B + c.a * H;
            lax[nl] = c.a;
            le1[nl] = c.e1;
            nl = nl + 1;
        }
        let q = ray_seg(rd, c.B - c.a * 6.0, c.B + c.a * H);
        // (the air close to it lit by it as it resonates)
        near_glint = near_glint + exp(-max(q.x - c.R, 0.0) / (c.R * 0.7 + 2.0)) * glow_i * res * cb_occ(q.y, scene_len, sky, cloud) * saturate(c.g) * 0.06;
        if (q.x > c.R * 1.2 + 1.0 || q.y - c.R * 2.0 > best_t) {
            continue;
        }
        let h = cb_hit(c, cb_to(c, -c.B), cb_to(c, rd));
        if (h.x > 0.0 && h.x < best_t) {
            best = i;
            best_t = h.x;
            best_k = h.z;
            best_out = h.y;
        }
    }
    if (best >= 0) {
        var c = cb_crystal(best, seed, time, crel);
        if (det) {
            let br = cb_break(best, seed, cb_place(best, seed).w);
            c.cut = vec4<f32>(br.x, br.z, br.w, 1.0);
            c.R = c.R * CB_STUMP;
            c.Rt = c.R * 0.8;
        }
        let X = rd * best_t;
        let ql = cb_to(c, X - c.B);
        let dl = cb_to(c, rd);
        let pl = cb_plane(c, i32(best_k));
        let nlc = normalize(pl.xyz);
        let n = normalize(cb_from(c, nlc));
        let H = c.Hb + c.tip;
        let base_c = cb_hue(c.hue + hue_t);
        let burst_w = smoothstep(CB_DET - 0.6, CB_DET, time);
        let glow_c = mix(base_c, vec3<f32>(1.0, 0.97, 1.0), burst_w * 0.7);
        // the light caught on its face: the sky and the sun, more of it towards the edge on
        let cosi = max(dot(-rd, n), 0.0);
        let fres = 0.045 + 0.955 * pow(1.0 - cosi, 5.0);
        let lglow = base_c * 0.15 * (1.0 + 2.0 * res);
        let refl = cb_env(reflect(rd, n), sky_c, sun, day, dark, lglow);
        // inside it: the view ray bent in, each colour a little differently, to the face it leaves by, and out again;
        // what it sees there the sky bent and split into colours, through the crystal's body (deeper the further it goes)
        var inner = vec3<f32>(0.0);
        var path = 0.0;
        var core = 0.0;
        var kout = 0.0;
        for (var ch = 0; ch < 3; ch = ch + 1) {
            let eta = 1.0 / (1.52 + 0.025 * f32(ch));
            var dr = refract(dl, nlc, eta);
            if (dot(dr, dr) < 1.0e-6) {
                dr = reflect(dl, nlc);
            }
            dr = normalize(dr);
            let ex = cb_exit(c, ql + dr * 0.01, dr);
            let n2 = normalize(cb_plane(c, i32(ex.y)).xyz);
            var vo = refract(dr, -n2, 1.52 + 0.025 * f32(ch));
            if (dot(vo, vo) < 1.0e-6) {
                vo = reflect(dr, -n2);
            }
            let vw = normalize(cb_from(c, vo));
            let e = cb_env(vw, sky_c, sun, day, dark, lglow);
            inner[ch] = e[ch];
            if (ch == 1) {
                path = ex.x;
                kout = ex.y;
                // (how close the bent ray passes to its heart: the glow inside it, strongest down its middle)
                let mid = ql + dr * ex.x * 0.5;
                core = exp(-length(mid.xz) / (c.R * 0.5));
                // (cleavage inside it catching the light: a few flat sheets across it, each its own way)
                for (var fk = 0; fk < 3; fk = fk + 1) {
                    let hv = cb_h3(best * 3 + fk, 777u, seed);
                    let fn_ = normalize(hv - 0.5 + vec3<f32>(0.0, 0.2, 0.0));
                    let off_ = (hv.x - 0.5) * c.R * 0.8;
                    let a0 = dot(ql, fn_) - off_;
                    let a1 = dot(ql + dr * ex.x, fn_) - off_;
                    // (the sheet's light where the ray crosses it, softer the more face-on it is seen)
                    core = core + select(0.0, 0.55 * (0.4 + 0.6 * abs(dot(dr, fn_))), a0 * a1 < 0.0);
                }
            }
        }
        // its body: a deep, saturated colour, darker the further the light goes through it
        let deepc = base_c * base_c;
        let absorb = exp(-path / (c.R * 1.6) * (vec3<f32>(1.0) - deepc * 0.9) * 2.5);
        // the facets inside it: each face it comes out by a little brighter or darker than the next
        let facet = 0.35 + 1.3 * pow(fract(sin(kout * 12.9898 + f32(best) * 3.7) * 43758.5), 2.0);
        // its light from inside: down its heart, pulses running up all of them together as they resonate
        let yw = X.y + cam.y - tgt.y;
        let pls = pow(0.5 + 0.5 * sin(yw * 0.045 - pulse_ph * TAU), 10.0) * res * 3.0;
        let wakeg = (0.3 + 0.7 * smoothstep(0.0, 1.6, c.s)) * (1.0 - breath * 0.9);
        let lit_up = (0.12 + 0.9 * core * core + pls * (0.3 + core)) * wakeg * (1.0 + 1.5 * res) + burst_w * 2.0 * f32(!det);
        var cc = inner * absorb * facet * 0.35 + glow_c * lit_up * facet * absorb * 1.6 + glow_c * glow_c * 0.03 * wakeg;
        // its edges catching the light: where the face it went in by meets the next
        var edge = 1.0e9;
        for (var kk = 0; kk < 14; kk = kk + 1) {
            if (kk == i32(best_k)) {
                continue;
            }
            let pk = cb_plane(c, kk);
            edge = min(edge, (pk.w - dot(pk.xyz, ql)) / length(pk.xyz));
        }
        let ew = max(0.15, best_t * px_a * 0.8);
        let edg = exp(-max(edge, 0.0) / ew) * min(1.0, 0.15 / ew * 2.0);
        cc = cc + (refl * 0.5 + glow_c * (0.5 + 1.8 * res) * wakeg) * edg;
        // its faces: the sky and the sun on them
        cc = cc + refl * fres * 1.1 + sun_c * pow(max(dot(n, normalize(sun - rd)), 0.0), 300.0) * 3.0;
        // the last seconds before they burst: a few hairline cracks of light along where the larger will break, spreading
        // a little (cb_chunk breaks them there)
        let plb = cb_place(best, seed);
        if (!det && time > CB_DET - 2.6 && (best < CB_LEADS || plb.w > 150.0)) {
            let brk = cb_break(best, seed, plb.w);
            let h0 = select(0.0, brk.x, brk.x > 0.5);
            let nseg = cb_nseg(c.R, H - h0);
            let ang = atan2(ql.z, ql.x);
            let ew = max(0.08, best_t * px_a * 0.7);
            var crk = 0.0;
            for (var kk = 1; kk < 6; kk = kk + 1) {
                if (kk >= nseg) {
                    break;
                }
                let hc = cb_h3(best * 16 + kk, 507u, seed);
                let g = time - (CB_DET - 2.4 + hc.y * 1.7);
                if (hc.x > 0.5 || g < 0.0) {
                    continue;
                }
                let cp = cb_cut_plane(best, kk, nseg, h0, H - h0, c.R, seed);
                let dpl = (dot(cp.xyz, ql) - cp.w) / length(cp.xyz);
                var da = ang - hc.z * TAU;
                da = da - TAU * floor(da / TAU + 0.5);
                let wig = (gnoise2(vec2<f32>(ang * c.R * 0.3, f32(kk) * 7.1)) - 0.5) * 2.4 + (gnoise2(vec2<f32>(ang * c.R * 1.1, f32(kk) * 3.3)) - 0.5) * 0.7;
                let arc = c.R * abs(da);
                let mask = smoothstep(2.0 + 7.0 * g, 0.5 + 4.0 * g, arc);
                crk = crk + exp(-abs(dpl - wig) / ew) * min(1.0, 0.1 / ew) * mask;
            }
            let flick = 0.6 + 0.4 * sin(time * 37.0 + f32(best));
            cc = cc + mix(glow_c, vec3<f32>(1.0), 0.6) * saturate(crk) * (1.5 + 2.5 * flick) * (1.0 - breath * 0.5);
        }
        let earth = smoothstep(4.0, -2.0, yw - (1.0 - saturate(c.s * 0.35)) * 10.0) * f32(c.cut.w < 0.5);
        cc = mix(cc, vec3<f32>(0.07, 0.058, 0.045) * (0.3 + 0.6 * day) * (1.0 - 0.4 * dark), earth * 0.85);
        let haze = 1.0 - exp(-best_t / 3000.0);
        col = mix(cc * k + col * (1.0 - k), hazec, haze * 0.7);
        add = vec3<f32>(0.0);
        scene_len = best_t;
        sky = false;
        cloud = false;
        solid = true;
    }
    add = add + near_glint * vec3<f32>(0.7, 0.6, 1.0) * k;

    // ---- on the land: cracks of light spreading out as it wakes, the spires' coloured light, the shock running out, the
    //      crater and the fissures glowing where they have opened -----------------------------------------------------
    let rel2 = P.xz - tgt.xz;
    let r = length(rel2);
    let dy = P.y - tgt.y;
    if (!sky && !solid) {
        let on_ground = 1.0 - smoothstep(20.0, 40.0, dy);
        // the spires' light, each cluster its own colour, a little on everything round
        var lt = vec3<f32>(0.0);
        for (var j = 0; j < nl; j = j + 1) {
            let L = lp[j].xyz - (P - cam);
            let dd = dot(L, L);
            lt = lt + lc[j] * lp[j].w * 9000.0 / (dd + 3000.0);
        }
        let ltc = lt / (1.0 + luminance(lt) * 0.5);
        col = col + col * ltc * 0.6 * k;
        add = add + ltc * 0.002 * on_ground * k;
        // light through the crystals playing over the land round them: moving caustics, each colour bent a little apart
        if (!det && time > CB_BLOOM0 && on_ground > 0.01) {
            let cf = saturate(1.5 - scene_len * px_a * 1.2);
            let near = smoothstep(CB_FIELD + 20.0, 30.0, r);
            if (near > 0.01 && cf > 0.01) {
                let tt = time * 0.5;
                var cs = vec3<f32>(0.0);
                for (var ch = 0; ch < 3; ch = ch + 1) {
                    let q = rel2 * 0.075 + vec2<f32>(f32(ch) * 0.03, f32(ch) * 0.014);
                    let n1 = gnoise2(q + vec2<f32>(tt, -tt * 0.7));
                    let n2 = gnoise2(q * 1.6 + vec2<f32>(-tt * 0.8, tt * 0.55) + vec2<f32>(3.1, seed));
                    cs[ch] = pow(saturate(1.0 - abs(n1 + n2 - 1.0) * 3.5), 8.0);
                }
                add = add + ltc * cs * cf * near * (0.25 + 0.9 * res) * (1.0 - breath) * on_ground * 1.0 * k;
            }
        }
        // the cracks: a web spreading out over the land as it wakes, light seeping up through it, brighter as the spires
        // resonate, gone as they burst (only light: the land is broken for real once they have)
        let front = (CB_FIELD + 40.0) * smoothstep(0.0, 3.6, time) * (0.6 + 0.4 * smoothstep(3.0, CB_BLOOM0 + 2.0, time));
        // (its edge soft and broken: a wide ramp, pushed in and out by two scales of noise, so no line shows from anywhere)
        let en = gnoise2(rel2 * 0.013 + vec2<f32>(seed, 1.7)) * 0.65 + gnoise2(rel2 * 0.041 + vec2<f32>(4.1, seed)) * 0.35 - 0.5;
        let rw = min(75.0, front * 0.45 + 4.0);
        let reach = smoothstep(front, front - rw, r + rw * 1.1 * en);
        if (reach > 0.01 && !det && on_ground > 0.01 && !heaved) {
            let pw = scene_len * px_a;
            let w1 = max(0.004, pw * 0.05);
            let warp = vec2<f32>(gnoise2(rel2 * 0.011 + vec2<f32>(3.0, seed)), gnoise2(rel2 * 0.011 + vec2<f32>(seed, 7.0))) * 40.0;
            let cn1 = abs(gnoise2((rel2 + warp) * 0.022 + vec2<f32>(seed * 0.37)) - 0.5);
            let cn2 = abs(gnoise2((rel2 + warp * 0.6) * 0.07 + vec2<f32>(5.0, seed)) - 0.5);
            let crk = (exp(-cn1 / w1) * min(1.0, 0.016 / w1) + 0.5 * exp(-cn2 / (w1 * 0.8)) * min(1.0, 0.008 / w1) * smoothstep(1.0, 3.0, time))
                * reach;
            let throb = 0.7 + 0.3 * sin(time * 2.2 - r * 0.04) + 1.2 * res * pow(0.5 + 0.5 * sin(pulse_ph * TAU - r * 0.03), 6.0);
            let hc = cb_hue(atan2(rel2.y, rel2.x) / TAU + r * 0.002 + hue_t);
            add = add + hc * crk * (0.6 + 1.4 * wake) * throb * (1.0 - breath * 0.8) * (1.0 + 0.5 * exp(-r / 40.0)) * on_ground * 4.5 * k;
            // (and a glow over it, low, the light coming up out of the ground)
            add = add + hc * exp(-cn1 / 0.07) * reach * 0.12 * wake * on_ground * k;
        }
        if (det) {
            // the shock running out over the land, a prismatic flash along its front, dust lifted behind it
            let rs = CB_SHOCK_V * dt * (1.0 - 0.18 * saturate(dt / 2.5));
            let fr = exp(-pow((r - rs) / 5.0, 2.0)) * exp(-dt * 1.4) * on_ground;
            add = add + mix(vec3<f32>(0.95, 0.9, 1.05), cb_spectrum(saturate((r - rs) / 16.0 + 0.5)), 0.18) * fr * 1.3 * k;
            col = mix(col, vec3<f32>(0.32, 0.29, 0.3) * (0.3 + 0.7 * day) * (1.0 - 0.4 * dark), exp(-pow((r - rs + 9.0) / 14.0, 2.0)) * 0.5 * exp(-dt * 0.4) * on_ground * k);
            // the crater where it has really been opened: its crystal lining glowing, cooling slowly, veins of light
            // through it, the well at its middle glowing deepest
            let open = cb_open(rel2, r, time);
            if (open > 0.0 && r < CB_BOWL * 1.25) {
                let n = gfbm2(rel2 * 0.07 + vec2<f32>(P.y * 0.15, seed));
                // (its glow thinning out over the rim, the edge broken)
                let rim = smoothstep(CB_BOWL * 1.22, CB_BOWL * 0.85, r + 30.0 * (n - 0.5));
                let veins = exp(-pow((n - 0.5) / 0.05, 2.0));
                let deep = saturate(-dy / CB_BOWL_D);
                let fresh = exp(-max(time - cb_dig_t(r), 0.0) / 6.0);
                let hc = cb_hue(atan2(rel2.y, rel2.x) / TAU + 0.02 * r);
                add = add + hc * (veins * (0.5 + 1.2 * fresh) + 0.5 * fresh * deep + smoothstep(CB_WELL * 1.6, 0.0, r) * 2.0) * open * rim * after * 1.3 * k;
                // (and after: the seams still glowing a little, a pool of light in the well and round its mouth)
                let late = (1.0 - after) * (1.0 - smoothstep(CB_LATE - 12.0, CB_LATE, time));
                let wp = smoothstep(CB_WELL * 2.6, CB_WELL * 0.3, r) * (0.5 + 0.5 * deep);
                add = add + mix(hc, vec3<f32>(0.85, 0.8, 1.0), 0.4) * (veins * 0.2 * smoothstep(CB_BOWL, CB_BOWL * 0.45, r + 20.0 * (n - 0.5)) + wp * 1.6 * (0.85 + 0.15 * sin(time * 1.7))) * open * late * k;
            }
            // the fissures as they open, light pulsing out along them
            let ang = atan2(rel2.y, rel2.x);
            if (r > CB_BOWL * 0.8 && r < CB_CRACK_R + 10.0) {
                var crack = 0.0;
                for (var i = 0; i < CB_CRACKS; i = i + 1) {
                    let cr = cb_crack(i, seed);
                    if (r > cr.y) {
                        continue;
                    }
                    let a = cr.x + 0.08 * sin(r * 0.05 + f32(i) * 3.0) + 0.04 * sin(r * 0.13 + f32(i));
                    var da = ang - a;
                    da = da - TAU * floor(da / TAU + 0.5);
                    let lat = abs(da) * r;
                    let hw = 1.0 + 2.2 * (1.0 - (r - CB_BOWL) / (cr.y - CB_BOWL));
                    let opened = smoothstep(0.0, 0.2, time - cb_crack_t(r));
                    // (tapering away at both its ends rather than stopping)
                    let tap = smoothstep(cr.y, cr.y - 35.0, r + 10.0 * sin(r * 0.21 + f32(i) * 2.3)) * smoothstep(CB_BOWL * 0.8, CB_BOWL * 0.98, r);
                    crack = max(crack, ((1.0 - smoothstep(hw * tap - 0.3, hw * tap + 0.7, lat)) + exp(-lat / (hw * 2.0)) * 0.3) * opened * tap);
                }
                let fade = 0.35 + 0.65 * exp(-max(dt - 1.5, 0.0) / 5.0);
                add = add + cb_hue(ang / TAU + 0.3) * crack * fade * on_ground * after * 1.8 * k;
            }
        }
    }
    // the light welling up out of the waking land: a low haze of colour over it, thickest over the middle, pulsing with
    // the hum, carried up by the bloom, gone as they burst
    if (!det) {
        let front = (CB_FIELD + 40.0) * smoothstep(0.0, 3.6, time);
        let Hh = 14.0 + 30.0 * smoothstep(CB_BLOOM0, CB_RES, time);
        // (where the view ray is in the slab of air over the land, up to what it meets)
        let y0 = tgt.y - 40.0 - cam.y;
        let y1 = tgt.y + Hh - cam.y;
        var ta = 0.0;
        var tb = select(scene_len, 1.0e4, sky);
        if (abs(rd.y) > 1.0e-4) {
            ta = max(min(y0 / rd.y, y1 / rd.y), 0.0);
            tb = min(tb, max(y0 / rd.y, y1 / rd.y));
        } else if (cam.y < tgt.y - 40.0 || cam.y > tgt.y + Hh) {
            tb = -1.0;
        }
        if (tb > ta) {
            // (its strength where the ray passes nearest the middle within the slab)
            let tcl = clamp(dot(crel.xz, rd.xz) / max(dot(rd.xz, rd.xz), 1.0e-6), ta, tb);
            let mid = rd * tcl - crel;
            let rm = length(mid.xz);
            let m = smoothstep(front, front * 0.4, rm) * exp(-rm / 90.0);
            let hc = mix(cb_hue(hue_t + 0.1), cb_hue(atan2(mid.z, mid.x) / TAU + hue_t), smoothstep(20.0, 120.0, rm));
            let path = min(tb - ta, 400.0);
            let throb = 0.75 + 0.25 * sin(time * 2.2) + 0.6 * res * pow(0.5 + 0.5 * sin(pulse_ph * TAU), 4.0);
            add = add + hc * (1.0 - exp(-path / 160.0)) * m * wake * throb * (1.0 - breath) * 0.6 * k;
        }
    }
    // the clouds lit from under by the spires' light, in colour
    if (cloud && nl > 0) {
        var lt = vec3<f32>(0.0);
        for (var j = 0; j < nl; j = j + 1) {
            let L = lp[j].xyz - (P - cam);
            lt = lt + lc[j] * lp[j].w * 30000.0 / (dot(L, L) + 30000.0);
        }
        add = add + lt * 0.06 * k;
    }

    // ---- prism light: the spires splitting their light into beams of colour across the sky and the clouds ------------
    let beam_k = smoothstep(CB_BLOOM0 + 2.0, CB_RES + 3.0, time) * (0.3 + 0.7 * res) * (1.0 - breath) * f32(!det) * k;
    if (beam_k > 0.001) {
        for (var j = 0; j < nl; j = j + 1) {
            let O = ltip[j];
            let A = lax[j];
            let E1 = le1[j];
            let E2 = cross(A, E1);
            for (var b = 0; b < 2; b = b + 1) {
                let hb = cb_w3(cb_sp(li[j]) + 33u + u32(b) * 3u);
                let phi = hb.x * TAU + time * (0.04 + 0.06 * hb.y) * select(-1.0, 1.0, b == 0);
                let tilt = 0.3 + 0.55 * hb.z;
                let D = normalize(A * cos(tilt) + (E1 * cos(phi) + E2 * sin(phi)) * sin(tilt) + vec3<f32>(0.0, 0.25, 0.0));
                let Lb = 1800.0;
                let q = ray_seg(rd, O, O + D * Lb);
                let along = q.z * Lb;
                let w = 1.6 + 0.05 * along;
                let pulse = 0.55 + 0.45 * pow(0.5 + 0.5 * sin(pulse_ph * TAU - along * 0.008 + hb.y * 6.0), 3.0);
                let fall = exp(-along / 1100.0) * smoothstep(0.0, 30.0, along) * (0.6 + 0.4 * hb.y);
                if (q.x < w * 1.6) {
                    let S = normalize(cross(D, vec3<f32>(0.0, 1.0, 0.0)) + vec3<f32>(1.0e-4, 0.0, 0.0));
                    let lat = dot(rd * q.y - O - D * along, S) / w;
                    let prof = exp(-pow(q.x / w, 2.0) * 1.6);
                    let cov = min(1.0, w / max(q.y * px_a, 1.0e-3));
                    add = add + cb_prism(lat, lc[j]) * prof * fall * pulse * cov * cb_occ(q.y, scene_len, sky, cloud) * beam_k * 0.26;
                }
                if (cloud) {
                    // (where it strikes the cloud deck, a splash of its colours on it)
                    let X = P - cam;
                    let sa = clamp(dot(X - O, D), 0.0, Lb);
                    let v = X - O - D * sa;
                    let wc = (1.6 + 0.05 * sa) * 1.8;
                    let S = normalize(cross(D, vec3<f32>(0.0, 1.0, 0.0)) + vec3<f32>(1.0e-4, 0.0, 0.0));
                    add = add + cb_prism(dot(v, S) / wc, lc[j]) * exp(-dot(v, v) / (wc * wc)) * exp(-sa / 1400.0) * pulse * beam_k * 0.8;
                }
            }
        }
    }
    // an aurora over it as the hum builds: curtains of the crystals' colours high over the land, rippling
    let aur_k = smoothstep(CB_RES - 2.0, CB_RES + 5.0, time) * (1.0 - smoothstep(CB_DET, CB_DET + 7.0, time)) * (1.0 - 0.6 * day * (1.0 - dark)) * k;
    if (aur_k > 0.001 && sky && rd.y > 0.0) {
        var acc = vec3<f32>(0.0);
        let ya = tgt.y + 400.0 - cam.y;
        let yb = tgt.y + 680.0 - cam.y;
        let t0 = max(ya / rd.y, 0.0);
        let t1 = min(max(yb / rd.y, 0.0), t0 + 2600.0);
        let jit_a = ign(in.position.xy);
        for (var l = 0; l < 10; l = l + 1) {
            let t = mix(t0, t1, (f32(l) + jit_a) / 10.0);
            let pw3 = cam + rd * t - tgt;
            let pxz = pw3.xz;
            let fl = saturate((pw3.y - 400.0) / 280.0);
            let R = length(pxz);
            let fold = gnoise2(pxz * 0.003 + vec2<f32>(-time * 0.04, 2.0 + seed));
            let line = gnoise2(pxz * 0.0011 + vec2<f32>(time * 0.01, seed)) + 0.2 * fold;
            let band = exp(-pow((line - 0.5) / 0.03, 2.0));
            let rays = 0.6 + 0.4 * sin(pxz.x * 0.03 + pxz.y * 0.021 + fold * 9.0 + time * 1.3);
            let colr = mix(mix(vec3<f32>(0.25, 0.9, 0.85), vec3<f32>(0.6, 0.4, 1.0), smoothstep(0.0, 0.45, fl)), vec3<f32>(1.0, 0.4, 0.85), smoothstep(0.45, 1.0, fl));
            acc = acc + colr * band * rays * pow(1.0 - fl, 1.5) * smoothstep(2800.0, 800.0, R) * (t1 - t0) / 10.0 / 120.0;
        }
        add = add + acc * aur_k * (0.35 + 0.4 * res) * (0.8 + 0.2 * sin(time * 0.9));
    }

    // ---- what the first shards throw up as they break the ground, and rock flung out ------------------------------
    for (var i = 0; i < CB_LEADS; i = i + 1) {
        let pl = cb_place(i, seed);
        let s = time - pl.z;
        if (s < 0.0 || s > 5.0 || det) {
            continue;
        }
        let fm = cb_form(i, seed, pl);
        let F = crel + vec3<f32>(pl.x, 0.0, pl.y);
        if (ray_seg(rd, F, F + vec3<f32>(0.0, 120.0, 0.0)).x > fm.x * 6.0 + 40.0) {
            continue;
        }
        // rock flung up and out as it breaks the ground, and again as it surges, falling back
        for (var j = 0; j < 12; j = j + 1) {
            let hv = vec3<f32>(pcg3d(vec3<u32>(u32(j), u32(i), u32(seed)))) * (1.0 / 4294967295.0);
            let t_th = select(0.0, CB_STRUGGLE, j % 2 == 1);
            let a = s - t_th;
            if (a < 0.0 || a > 4.0) {
                continue;
            }
            let az = hv.x * TAU;
            let vh = 8.0 + 30.0 * hv.y;
            let vy = 18.0 + 40.0 * hv.z * hv.z;
            let s3 = F + vec3<f32>(cos(az), 0.0, sin(az)) * fm.x * 1.1 + vec3<f32>(0.0, 2.0, 0.0);
            let a1 = max(a - 0.05, 0.0);
            let pa = s3 + vec3<f32>(cos(az) * vh * a, vy * a - 16.0 * a * a, sin(az) * vh * a);
            let pb = s3 + vec3<f32>(cos(az) * vh * a1, vy * a1 - 16.0 * a1 * a1, sin(az) * vh * a1);
            if (pa.y < F.y - 2.0) {
                continue;
            }
            let qj = ray_seg(rd, pa, pb);
            let wj = 0.6 + 1.6 * hv.y;
            let cov = smoothstep(1.0, 0.5, qj.x / max(wj, qj.y * px_a)) * (wj / max(wj, qj.y * px_a));
            let vj = select(1.0, 1.0 - smoothstep(scene_len - 0.5, scene_len + 0.5, qj.y), !sky);
            col = mix(col, vec3<f32>(0.045, 0.038, 0.032) * (0.4 + 0.6 * day), cov * vj);
            add = add * (1.0 - cov * vj * 0.8);
        }
    }
    // the bloom's spires breaking the ground: a spray of earth round each as it comes up
    if (!det && time > CB_BLOOM0 - 0.1) {
        for (var i = CB_LEADS; i < CB_N; i = i + 1) {
            let pl = cb_place(i, seed);
            let s = time - pl.z;
            if (s < 0.0 || s > 2.2) {
                continue;
            }
            let F = crel + vec3<f32>(pl.x, 0.0, pl.y);
            if (ray_seg(rd, F, F + vec3<f32>(0.0, 40.0, 0.0)).x > 45.0) {
                continue;
            }
            let fm = cb_form(i, seed, pl);
            for (var j = 0; j < 6; j = j + 1) {
                let hv = vec3<f32>(pcg3d(vec3<u32>(u32(j), u32(i) + 77u, u32(seed)))) * (1.0 / 4294967295.0);
                let az = hv.x * TAU;
                let vh = 6.0 + 18.0 * hv.y;
                let vy = 12.0 + 22.0 * hv.z;
                let s3 = F + vec3<f32>(cos(az), 0.0, sin(az)) * fm.x + vec3<f32>(0.0, 1.0, 0.0);
                let a1 = max(s - 0.05, 0.0);
                let pa = s3 + vec3<f32>(cos(az) * vh * s, vy * s - 16.0 * s * s, sin(az) * vh * s);
                let pb = s3 + vec3<f32>(cos(az) * vh * a1, vy * a1 - 16.0 * a1 * a1, sin(az) * vh * a1);
                if (pa.y < F.y - 1.0) {
                    continue;
                }
                let qj = ray_seg(rd, pa, pb);
                let wj = 0.4 + 0.8 * hv.y;
                let cov = smoothstep(1.0, 0.5, qj.x / max(wj, qj.y * px_a)) * (wj / max(wj, qj.y * px_a));
                let vj = select(1.0, 1.0 - smoothstep(scene_len - 0.5, scene_len + 0.5, qj.y), !sky);
                col = mix(col, vec3<f32>(0.05, 0.042, 0.035) * (0.4 + 0.6 * day), cov * vj);
                add = add * (1.0 - cov * vj * 0.8);
            }
        }
    }

    // ---- the dust they throw up as they come up (cb_rise, cb_surge, the bloom's wall, the haze they leave), up to
    //      whatever is nearer, the land or a spire: dust in front of a spire veils it, dust behind it is hidden by it --
    let dfade = 1.0 - smoothstep(CB_RES - 1.0, CB_DET - 1.5, time);
    if (!det && time > CB_PUNCH0 - CB_BULGE && dfade > 0.0) {
        let tmax_d = select(scene_len, 1.0e9, sky);
        var L: CbDL;
        L.crel = crel;
        L.Ld = normalize(vec3<f32>(sun.x * 0.6, 1.0, sun.z * 0.6));
        L.sky_l = (amb_c * 3.0 + hazec * 0.3) * dfade;
        L.sun_l = sun_c * 0.45 * saturate(sun.y * 3.0) * dfade;
        L.time = time;
        L.seed = seed;
        L.glow_k = 0.8 * (1.0 + 0.5 * res) * dfade;
        let jit = ign(in.position.xy);
        // (the parts put together whatever their order: their light summed, weighted by how much each hides)
        var sum_c = vec3<f32>(0.0);
        var sum_a = 0.0;
        var Tall = 1.0;
        // the haze they leave over the land, low, drifting and thinning (where the view ray is in it, its strength
        // where the ray passes nearest the middle)
        let tau = time - CB_BLOOM0;
        let rw = 235.0 * (1.0 - pow(1.0 - saturate(tau / 8.0), 1.6));
        let Rh = max(70.0 + 120.0 * cb_ease((time - CB_PUNCH0 - 1.0) / 6.0), rw);
        let Hh = 14.0 + 36.0 * cb_ease((time - CB_PUNCH0 - 1.0) / 7.0);
        let ha = smoothstep(CB_PUNCH0 + 0.8, CB_PUNCH0 + 3.5, time) * (0.6 + 0.4 * smoothstep(CB_BLOOM0, CB_BLOOM0 + 3.0, time)) * dfade;
        let th = cb_cyl(rd, crel, Rh, -3.0, Hh);
        let th1 = min(th.y, tmax_d);
        if (th1 > th.x && ha > 0.0) {
            let tm = clamp(dot(crel.xz, rd.xz) / max(dot(rd.xz, rd.xz), 1.0e-6), th.x, th1);
            let mid = rd * tm - crel;
            let pat = gnoise2(mid.xz * 0.012 + vec2<f32>(seed - time * 0.05, time * 0.03));
            let m = smoothstep(Rh, Rh * 0.4, length(mid.xz)) * (0.4 + 1.2 * pat * pat);
            // (thinning with height: the depth of it along the ray through a haze falling off over hs)
            let hs = Hh * 0.4;
            let ya = max(th.x * rd.y - crel.y, 0.0);
            let yb = max(th1 * rd.y - crel.y, 0.0);
            var od = (th1 - th.x) * exp(-ya / hs);
            if (abs(rd.y) > 1.0e-3) {
                od = min(od, hs * abs(exp(-ya / hs) - exp(-yb / hs)) / abs(rd.y));
            }
            let a = (1.0 - exp(-od * 0.006 * m)) * ha * 0.85;
            let hc = (vec3<f32>(0.62, 0.55, 0.47) * (amb_c * 3.0 + hazec * 0.3) + cb_hue(hue_t + 0.1) * 0.05 * wake) * dfade;
            sum_c = sum_c + hc * a;
            sum_a = sum_a + a;
            Tall = Tall * (1.0 - a);
        }
        // round each of the first shards, the heart and each cluster of the bloom's
        for (var u = 0; u < CB_LEADS + 10; u = u + 1) {
            let bloom = u >= CB_LEADS;
            let i = select(u, CB_LEADS + (u - CB_LEADS) * 4, bloom);
            let pl = cb_place(i, seed);
            let s = time - pl.z;
            if (s < -CB_BULGE || s > 14.0) {
                continue;
            }
            let fm = cb_form(i, seed, pl);
            var S = 32.0;
            var R = fm.x;
            var dp = 0.0;
            if (i == 5) {
                S = 44.0;
                R = 24.0;
            }
            if (bloom) {
                R = fm.x + 7.0;
                S = 0.7 * fm.x + 6.0;
                dp = 1.3 + 2.2 * saturate(pl.w / 260.0);
            }
            let F = crel + vec3<f32>(pl.x, 0.0, pl.y);
            let sc = select(s - CB_STRUGGLE, s, bloom);
            let hue = cb_hue_of(i);
            let gc = cb_hue(hue + hue_t) * (0.5 + 0.5 * smoothstep(0.0, 1.5, s)) * select(1.0, 0.7, bloom);
            // its burst and column
            if (sc < CB_RISE_END) {
                let g = cb_grow(i, max(s, 0.0), pl.w).x;
                let Hc = S * 0.7 + min(g * pl.w * select(0.6, 0.45, bloom), S * select(5.0, 3.6, bloom));
                // (bounded by its column, and by its bursts while they last)
                let bursts = s < select(5.5, 4.6 + 0.55 * dp, bloom);
                let Rc = (R * 1.02 + S * 0.85 + Hc * 0.16) * 1.35;
                let tr = cb_cyl(rd, F, select(Rc, max(Rc, R + S * 2.4), bursts), -3.0, select(Hc * 1.1, max(Hc * 1.1, S * 4.2), bursts));
                let t1 = min(tr.y, tmax_d);
                if (t1 > tr.x) {
                    let o = cb_dseg(rd, tr.x, t1, 0, select(5, 3, bloom), F, vec4<f32>(s, S, R, Hc), dp, gc, L, jit);
                    sum_c = sum_c + o.xyz;
                    sum_a = sum_a + 1.0 - o.w;
                    Tall = Tall * o.w;
                }
            }
            // its surge (the bloom's soon taken up into its wall)
            if (sc > -0.2 && sc < select(CB_SURGE_END, CB_SURGE_BLOOM, bloom)) {
                let g = cb_surge_at(sc, S, R);
                let tr = cb_cyl(rd, F, g.x + g.y * 2.0, -3.0, g.z * 1.1);
                let t1 = min(tr.y, tmax_d);
                if (t1 > tr.x) {
                    let o = cb_dseg(rd, tr.x, t1, 1, 5, F, vec4<f32>(s, S, R, 0.0), dp, gc, L, jit);
                    sum_c = sum_c + o.xyz;
                    sum_a = sum_a + 1.0 - o.w;
                    Tall = Tall * o.w;
                }
            }
        }
        // the bloom's wall of dust, running out ahead of the spires and slowing (marched where the ray crosses its
        // ring: in through it, and out through it beyond)
        if (tau > 0.0) {
            let xw = saturate(tau / 8.0);
            let ww = 12.0 + 16.0 * xw;
            let Hw = 14.0 + 52.0 * cb_ease(tau / 5.0);
            let wamp = smoothstep(0.0, 1.2, tau) * (0.4 + 0.6 * exp(-max(tau - 4.6, 0.0) / 2.5)) * 1.7;
            let wv = vec4<f32>(rw, ww, Hw, wamp);
            let to = cb_cyl(rd, crel, rw + ww * 2.2, -3.0, Hw * 1.4);
            if (to.y > to.x) {
                let ti = cb_cyl(rd, crel, max(rw - ww * 2.2, 0.0), -3.0, Hw * 1.4);
                var a0 = to.x;
                var a1 = to.y;
                var b0 = 1.0;
                var b1 = 0.0;
                if (ti.y > ti.x) {
                    a1 = ti.x;
                    b0 = ti.y;
                    b1 = to.y;
                }
                a1 = min(a1, tmax_d);
                b1 = min(b1, tmax_d);
                if (a1 > a0) {
                    let o = cb_dseg(rd, a0, a1, 2, 5, crel, wv, 0.0, vec3<f32>(0.0), L, jit);
                    sum_c = sum_c + o.xyz;
                    sum_a = sum_a + 1.0 - o.w;
                    Tall = Tall * o.w;
                }
                if (b1 > b0) {
                    let o = cb_dseg(rd, b0, b1, 2, 4, crel, wv, 0.0, vec3<f32>(0.0), L, jit);
                    sum_c = sum_c + o.xyz;
                    sum_a = sum_a + 1.0 - o.w;
                    Tall = Tall * o.w;
                }
            }
        }
        if (sum_a > 1.0e-4) {
            let dc = sum_c / sum_a * (1.0 - Tall);
            col = col * Tall + dc * k + col * (1.0 - k) * (1.0 - Tall);
            add = add * mix(1.0, Tall, 0.85);
        }
    }

    // ---- shards breaking off them as they resonate and orbiting them, faster and faster ---------------------------
    var sh_t = scene_len;
    var sh_n = vec3<f32>(0.0);
    var sh_hue = 0.0;
    var sh_glow = 0.0;
    if (time > CB_ORBIT && !det) {
        for (var j = 0; j < CB_ORBITERS; j = j + 1) {
            let hv = cb_w3(CB_ORB + u32(j) * 3u);
            // (round the first shards and the clusters' tallest)
            let pi = j % 16;
            if (pi >= nl) {
                continue;
            }
            let born = CB_ORBIT + 4.0 * hv.x;
            let ot = time - born;
            if (ot < 0.0) {
                continue;
            }
            // (round the spire as it stands grown: they have all grown by now)
            let si = li[pi];
            let pl = cb_place(si, seed);
            let fm = cb_form(si, seed, pl);
            let ax = cb_axis(fm);
            let B = crel + vec3<f32>(pl.x, 0.0, pl.y);
            let ro = fm.x * (1.4 + 1.6 * hv.z) + 4.0 * saturate(ot * 0.7);
            let y0 = pl.w * (0.25 + 0.6 * hv.y);
            let qa = ray_seg(rd, B + ax * (y0 - 4.0), B + ax * (y0 + 4.0));
            if (qa.x > ro + 8.0) {
                continue;
            }
            let fr = cb_frame(ax, fm.w);
            var c: Crystal;
            c.B = B;
            c.a = ax;
            c.e1 = fr[0];
            c.e2 = fr[1];
            c.hue = cb_hue_of(si);
            let w = (0.5 + 0.8 * hv.z) * (1.0 + 3.0 * res * res) * select(-1.0, 1.0, hv.x > 0.5);
            let ph = hv.y * TAU + w * ot + 0.6 * res * res * ot * ot;
            let A = c.B + c.a * (y0 + 3.0 * sin(time * 1.3 + hv.x * 9.0));
            let Cs = A + (c.e1 * cos(ph) + c.e2 * sin(ph)) * ro;
            let sz = (0.6 + 1.2 * hv.z) * smoothstep(0.0, 0.4, ot) * (1.0 + 0.15 * c.R / 10.0);
            let sh = cb_shard(rd, Cs, sz, sz * 2.4, normalize(hv - 0.5 + vec3<f32>(0.0, 0.01, 0.0)), time * (2.0 + 4.0 * hv.x), sh_t);
            if (sh.x > 0.0 && sh.x < sh_t) {
                sh_t = sh.x;
                sh_n = sh.yzw;
                sh_hue = c.hue;
                sh_glow = 1.0 + 2.0 * res;
            }
            // (a glint of light round each)
            let qd = ray_seg(rd, Cs, Cs + vec3<f32>(0.0, 0.01, 0.0));
            add = add + cb_hue(c.hue + hue_t) * exp(-qd.x / max(sz * 1.5, qd.y * px_a * 2.0)) * 0.08 * res * cb_occ(qd.y, scene_len, sky, cloud) * k;
        }
    }
    // ---- as they burst: each spire broken into its pieces (cb_chunk), thrown out, tumbling, coming down ---------------
    var sh_brk = 0.0;
    var sh_pc = -1;
    var sh_kin = 0;
    if (det && dt < 12.0) {
        for (var i = 0; i < CB_N; i = i + 1) {
            let sb = cb_sp(i);
            let pl = cb_w4(sb);
            let fm = cb_w4(sb + 4u);
            let F = vec3<f32>(pl.x, 0.0, pl.y);
            let Fc = crel + F;
            // (all of its pieces within reach of where it stood by now)
            let reach = fm.x * 1.5 + pl.w * sin(fm.y) + (40.0 + pl.w * 0.06) * min(dt, 6.0) + 10.0;
            if (ray_seg(rd, Fc - vec3<f32>(0.0, CB_BOWL_D + 4.0, 0.0), Fc + vec3<f32>(0.0, pl.w + 30.0, 0.0)).x > reach) {
                continue;
            }
            // (its frame as it stood when they burst, its pieces' run in the table)
            let fa = cb_w3(sb + 22u);
            let fe1 = cb_w3(sb + 25u);
            let fe2 = cb_w3(sb + 28u);
            let p0 = cb_u(sb + 31u);
            let p1 = p0 + cb_u(sb + 32u);
            for (var n = p0; n < p1; n = n + 1u) {
                let pb = CB_PCB + n * CB_PCW;
                let m = cb_w4(pb + 24u);            // (when it is built, its length, width, and the reach of it)
                // (held where it lies until its blocks are in, then gone over CB_FADE, a scatter of its pixels at a
                // time, so the blocks show through it and the two never fight)
                if (dt > m.x && frame.mod_params[3].z >= CB_DET + m.x - 0.01) {
                    let fu = (dt - m.x) / CB_FADE;
                    if (fu >= 1.0 || fract(sin(dot(rd, vec3<f32>(127.1, 311.7, 74.7)) * 1.0e3) * 43758.55) < fu) {
                        continue;
                    }
                }
                let vt = cb_w4(pb + 4u);
                let at = cb_piece_at(pb, vt, dt);
                let sc = cb_piece_scale(vt.w, dt);
                let Cw = crel + at.xyz;
                // (all of it within this of its middle: its slanted cuts and the spire's tip reach past its length)
                let bnd = m.w * sc;
                let tc = dot(Cw, rd);
                if (tc < -bnd || tc - bnd > sh_t || dot(Cw, Cw) - tc * tc > bnd * bnd) {
                    continue;
                }
                let spin = cb_w4(pb + 8u);
                let oo = cb_w3(pb) + rot_axis(-Cw, spin.xyz, -at.w) / sc - F;
                let dd = rot_axis(rd, spin.xyz, -at.w) / sc;
                let h = cb_hit_t(sb, vec3<f32>(dot(oo, fe1), dot(oo, fa), dot(oo, fe2)), vec3<f32>(dot(dd, fe1), dot(dd, fa), dot(dd, fe2)), pb);
                if (h.x > 0.0 && h.x < sh_t) {
                    let kin = i32(h.z);
                    let nl = cb_piece_plane(sb, pb, kin).xyz;
                    sh_t = h.x;
                    sh_n = normalize(rot_axis(fe1 * nl.x + fa * nl.y + fe2 * nl.z, spin.xyz, at.w));
                    sh_pc = i32(n);
                    sh_kin = kin;
                }
            }
        }
    }
    // (the piece in front: its light inside dying as it falls, each flickering its own way, out by when it lands; its
    // edges catching the light, as the spires' do, and the view through it bent by it)
    var sh_edge = 0.0;
    var sh_thru = vec3<f32>(-1.0);
    var sh_path = 0.0;
    var sh_sheet = 0.0;
    if (sh_pc >= 0) {
        let pb = CB_PCB + u32(sh_pc) * CB_PCW;
        let i = i32(cb_u(pb + 31u));
        let f = i32(cb_u(pb + 3u));
        let sb = cb_sp(i);
        let vt = cb_w4(pb + 4u);
        let m = cb_w4(pb + 24u);
        let spin = cb_w4(pb + 8u);
        sh_hue = cb_hue_of(i);
        sh_brk = f32(sh_kin >= 13);
        let hf_ = cb_h3(f, 508u, seed);
        let u = saturate(dt / vt.w);
        let flk = saturate(0.25 + 0.95 * gnoise2(vec2<f32>(dt * (2.5 + 6.0 * hf_.x), hf_.y * 61.0)) + 0.3 * (gnoise2(vec2<f32>(dt * 17.0, hf_.z * 43.0)) - 0.5));
        sh_glow = (0.15 + 1.2 * exp(-dt * 1.8)) * (1.0 + sh_brk * 0.6) * (1.0 - u) * (1.0 - u) * flk;
        if (sh_t < scene_len) {
            let fa = cb_w3(sb + 22u);
            let fe1 = cb_w3(sb + 25u);
            let fe2 = cb_w3(sb + 28u);
            let F = vec3<f32>(cb_w(sb), 0.0, cb_w(sb + 1u));
            let C0 = cb_w3(pb);
            let at = cb_piece_at(pb, vt, dt);
            let sc = cb_piece_scale(vt.w, dt);
            let Xo = C0 + rot_axis(rd * sh_t - crel - at.xyz, spin.xyz, -at.w) / sc - F;
            let ql = vec3<f32>(dot(Xo, fe1), dot(Xo, fa), dot(Xo, fe2));
            let rl = rot_axis(rd, spin.xyz, -at.w);
            let dl = vec3<f32>(dot(rl, fe1), dot(rl, fa), dot(rl, fe2));
            var e1 = 1.0e9;
            var e2 = 1.0e9;
            for (var kk = 0; kk < 16; kk = kk + 1) {
                let pk = cb_piece_plane(sb, pb, kk);
                let dpk = max((pk.w - dot(pk.xyz, ql)) / length(pk.xyz), 0.0) * sc;
                if (dpk < e1) {
                    e2 = e1;
                    e1 = dpk;
                } else {
                    e2 = min(e2, dpk);
                }
            }
            let nin = normalize(cb_piece_plane(sb, pb, sh_kin).xyz);
            let ew = max(0.06, sh_t * px_a * 0.6);
            // (a thin bright line along its edges, glinting here and there along them)
            let glint = 0.5 + 1.5 * pow(gnoise2(vec2<f32>(dot(ql, vec3<f32>(0.9, 0.6, 0.7)) * 0.8, f32(i) + dt * 2.0)), 6.0) * 6.0;
            sh_edge = exp(-e2 / ew) * min(1.0, 0.1 / ew * 2.0) * glint;
            // through it: bent in at the face it is seen by, out at the face it leaves by, to what lies behind
            var dr = refract(dl, nin, 1.0 / 1.52);
            if (dot(dr, dr) < 1.0e-6) {
                dr = reflect(dl, nin);
            }
            dr = normalize(dr);
            var tout = 1.0e9;
            var kout = 0;
            for (var kk = 0; kk < 16; kk = kk + 1) {
                let pk = cb_piece_plane(sb, pb, kk);
                let dn = dot(pk.xyz, dr);
                if (dn > 1.0e-6) {
                    let t = (pk.w - dot(pk.xyz, ql)) / dn;
                    if (t < tout) {
                        tout = t;
                        kout = kk;
                    }
                }
            }
            tout = clamp(tout, 0.0, 200.0);
            let nout = normalize(cb_piece_plane(sb, pb, kout).xyz);
            var vo = refract(dr, -nout, 1.52);
            if (dot(vo, vo) < 1.0e-6) {
                vo = reflect(dr, -nout);
            }
            let von = normalize(vo);
            let vw = rot_axis(fe1 * von.x + fa * von.y + fe2 * von.z, spin.xyz, at.w);
            let Xe = rd * sh_t + rot_axis(fe1 * dr.x + fa * dr.y + fe2 * dr.z, spin.xyz, at.w) * tout * sc;
            let behind = Xe + vw * clamp(select(scene_len, 300.0, sky) - sh_t, 3.0, 300.0);
            let Pb = project_rel(behind);
            if (Pb.z > 0.0) {
                let ub = clamp(Pb.xy, vec2<f32>(0.002), vec2<f32>(0.998));
                let bg = srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, ub, 0.0).rgb);
                // (darkened as the pass darkens the land and the sky behind)
                sh_thru = select(bg * (1.0 - 0.7 * dark * k), mix(bg, night, dark * k), is_sky(depth_at(ub)));
            } else {
                sh_thru = cb_env(vw, sky_c, sun, day, dark, vec3<f32>(0.0));
            }
            sh_path = tout * sc;
            // (and a cleavage sheet or two inside it, catching the light, for depth)
            let C0l = C0 - F;
            for (var fk = 0; fk < 2; fk = fk + 1) {
                let hv = cb_h3(f, 777u + u32(fk), seed);
                let fn_ = normalize(hv - 0.5);
                let a0 = dot(ql, fn_) - dot(vec3<f32>(dot(C0l, fe1), dot(C0l, fa), dot(C0l, fe2)), fn_) - (hv.x - 0.5) * m.z * 0.6;
                let a1 = a0 + dot(dr, fn_) * tout;
                sh_sheet = sh_sheet + select(0.0, 0.5 * (0.4 + 0.6 * abs(dot(dr, fn_))), a0 * a1 < 0.0);
            }
        }
    }
    if (sh_t < scene_len) {
        // a shard: its face catching the sky, its body clear, what is behind it seen through it bent and tinted
        let base_c = cb_hue(sh_hue + hue_t);
        let cosi = max(dot(-rd, sh_n), 0.0);
        let fres = 0.045 + 0.955 * pow(1.0 - cosi, 5.0);
        let refl = cb_env(reflect(rd, sh_n), sky_c, sun, day, dark, base_c * 0.2);
        let inner = cb_env(refract(rd, sh_n, 0.66), sky_c, sun, day, dark, base_c * 0.2);
        let facet = 0.6 + 0.8 * fract(sin(dot(sh_n, vec3<f32>(12.9, 78.2, 37.7))) * 43758.5);
        // (a broken face fresh and pale, glittering; the spire's own faces deep and clear)
        let deep = base_c * base_c;
        let glw_c = mix(deep, mix(base_c, vec3<f32>(1.0), 0.15), sh_brk * 0.8);
        // (light through it, bent and split: its faces each a little a different colour)
        let disp = cb_spectrum(fract(dot(sh_n, vec3<f32>(3.1, 1.7, 2.3)) + dt * 0.2));
        var cc: vec3<f32>;
        if (sh_thru.x >= 0.0) {
            // (the pieces: clear crystal, tinted deeper the further the light goes through it)
            let absorb = exp(-sh_path / 9.0 * (vec3<f32>(1.0) - deep * 0.9) * 1.6);
            let tint = mix(vec3<f32>(1.0), base_c * 1.3, 0.55);
            cc = sh_thru * absorb * tint * (1.0 - fres) * 0.95 + inner * deep * facet * 0.12
                + glw_c * sh_glow * 0.6 * facet * absorb + deep * disp * 0.1 * facet * (0.3 + sh_glow)
                + mix(base_c, vec3<f32>(1.0), 0.6) * sh_sheet * (0.04 + 0.25 * sh_glow) * (0.3 + 0.7 * day + 0.3 * dark)
                + refl * fres * 1.3 + sun_c * pow(max(dot(sh_n, normalize(sun - rd)), 0.0), 200.0) * 3.0;
            cc = cc + (refl * 0.6 + mix(base_c, vec3<f32>(1.0), 0.6) * (0.12 + sh_glow * 0.5)) * sh_edge;
        } else {
            cc = inner * deep * facet * 0.5 + glw_c * sh_glow * 0.6 * facet + refl * fres * 1.3
                + sun_c * pow(max(dot(sh_n, normalize(sun - rd)), 0.0), 160.0) * 3.0
                + deep * disp * 0.12 * facet * sh_glow;
            cc = cc + (refl * 0.5 + mix(base_c, vec3<f32>(1.0), 0.4) * (0.3 + sh_glow * 0.5)) * sh_edge;
        }
        let haze = 1.0 - exp(-sh_t / 3000.0);
        col = mix(cc * k + col * (1.0 - k), hazec, haze * 0.7);
        add = add * 0.1;
        scene_len = sh_t;
        sky = false;
    }

    // ---- the glitter: a cloud of tiny shards blown out and falling, each a point of coloured light that twinkles,
    //      in shells round the heart (found where the view ray crosses each shell, a star on it per cell) -------------
    if (det && dt < 10.0) {
        let fallc = vec3<f32>(0.0, -0.5 * 9.0 * dt * dt * 0.35, 0.0);
        for (var s = 0; s < 5; s = s + 1) {
            let fs = f32(s);
            let Rg = (35.0 + 48.0 * fs) * (0.25 + (1.0 - exp(-dt * (1.6 - 0.15 * fs))) * (1.1 + 0.3 * fs));
            let C = heart - vec3<f32>(0.0, 60.0 + 10.0 * fs, 0.0) + fallc * (1.0 + 0.2 * fs);
            let tc = dot(C, rd);
            let dc2 = dot(C, C) - tc * tc;
            if (dc2 > Rg * Rg) {
                continue;
            }
            let hq = sqrt(Rg * Rg - dc2);
            for (var side = 0; side < 2; side = side + 1) {
                let th = tc + select(-hq, hq, side == 1);
                if (th < 0.0 || th > scene_len) {
                    continue;
                }
                let Q = rd * th - C;
                let v = Q / Rg;
                // (the shell turns as it spreads, each its own way)
                let lon = atan2(v.z, v.x) + dt * (0.1 + 0.05 * fs) * select(-1.0, 1.0, s % 2 == 0);
                let lat = asin(clamp(v.y, -1.0, 1.0));
                let ncell = 55.0 + 14.0 * fs;
                let g2 = vec2<f32>(lon * ncell / TAU, lat * ncell / TAU * 2.0);
                let cid = floor(g2);
                let hv = vec3<f32>(pcg3d(vec3<u32>(bitcast<vec2<u32>>(vec2<i32>(cid)), u32(s) + u32(seed) * 7u))) * (1.0 / 4294967295.0);
                if (hv.z > 0.3) {
                    continue;
                }
                let star = cid + vec2<f32>(0.2, 0.2) + hv.xy * 0.6;
                // (its distance on the shell, in blocks)
                let dd = (g2 - star) * vec2<f32>(Rg * cos(lat) * TAU / ncell, Rg * TAU / ncell * 0.5);
                let w = max(0.25, th * px_a * 0.7);
                let tw = pow(0.5 + 0.5 * sin(time * (9.0 + 14.0 * hv.x) + hv.y * 40.0), 3.0);
                let lum = exp(-dot(dd, dd) / (w * w)) * min(1.0, 0.25 / w) * (0.2 + 3.0 * tw * tw);
                // (the bottom of the cloud thinning as it falls; the whole of it thinning out)
                let dens = smoothstep(-1.0, -0.3, v.y + 0.25 * dt / 3.0) * exp(-dt / (2.5 + 0.4 * fs)) * smoothstep(0.0, 0.2, dt);
                add = add + cb_spectrum(fract(hv.x * 3.7 + dt * 0.3)) * mix(1.0, 0.4, hv.y) * lum * dens * 2.4 * k;
            }
        }
    }

    // ---- the prismatic flash and the shock dome as they burst ------------------------------------------------------
    if (det && dt < 6.0) {
        let Rs = 40.0 + 260.0 * (1.0 - exp(-dt * 1.4));
        let tcs = dot(heart, rd);
        let ps = rd * max(tcs, 0.0) - heart;
        let dcs = length(ps);
        let wpx = max(6.0 + 10.0 * dt, max(tcs, 1.0) * 0.002);
        let limb = exp(-pow((dcs - Rs) / wpx, 2.0));
        add = add + mix(vec3<f32>(0.8, 0.85, 1.0), cb_spectrum(saturate((dcs - Rs) / (wpx * 2.0) + 0.5)), 0.15) * limb * exp(-dt * 2.5) * 0.18 * cb_occ(tcs, scene_len, sky, cloud) * k;
        // a ball of white light where the heart was, fading
        let ball = exp(-dcs / (30.0 + 40.0 * dt)) * exp(-dt * 2.2) * 3.0;
        add = add + mix(vec3<f32>(1.0), cb_hue(hue_t + dcs * 0.006 + dt * 0.4), 0.25 + 0.5 * saturate(dcs / (40.0 + 60.0 * dt))) * ball * cb_occ(tcs - 30.0, scene_len, sky, cloud) * k;
    }

    // ---- the motes: a slow, sparse drift of glowing specks over the crater after, fading over the best part of a
    //      minute (on a few rising sheets of air, found where the view ray crosses each, a mote on it per cell) -------
    if (det && dt > 1.0 && time < CB_LATE) {
        let mk = smoothstep(1.0, 5.0, dt) * (1.0 - smoothstep(CB_LATE - 28.0, CB_LATE, time)) * k;
        for (var l = 0; l < 5; l = l + 1) {
            let ph = fract(time * 0.03 + f32(l) * 0.2);
            let y = -CB_BOWL_D + ph * 80.0;
            let t = (tgt.y + y - cam.y) / rd.y;
            if (t <= 0.0 || t > scene_len) {
                continue;
            }
            let Q = (cam + rd * t - tgt).xz;
            let rq = length(Q);
            if (rq > 125.0) {
                continue;
            }
            let g = Q / 6.0 + vec2<f32>(f32(l) * 13.1, f32(l) * 7.7);
            let cid = floor(g);
            let hv = vec3<f32>(pcg3d(vec3<u32>(bitcast<vec2<u32>>(vec2<i32>(cid)), u32(l) + u32(seed) * 5u + 900u))) * (1.0 / 4294967295.0);
            if (hv.z > 0.16) {
                continue;
            }
            let star = cid + vec2<f32>(0.2) + hv.xy * 0.6 + 0.12 * vec2<f32>(sin(time * 0.4 + hv.x * 20.0), cos(time * 0.33 + hv.y * 17.0));
            let dd = (g - star) * 6.0;
            let w = max(0.12, t * px_a * 0.8);
            let tw = 0.55 + 0.45 * sin(time * (0.8 + 1.6 * hv.x) + hv.y * 30.0);
            let lum = exp(-dot(dd, dd) / (w * w)) * min(1.0, 0.18 / w) * tw;
            let edge = smoothstep(125.0, 50.0, rq + 25.0 * (gnoise2(Q * 0.02 + vec2<f32>(seed)) - 0.5));
            add = add + mix(cb_hue(hv.x + f32(l) * 0.13), vec3<f32>(1.0), 0.35) * lum * sin(ph * 3.14159265) * edge * mk * 3.0;
        }
    }

    // ---- the lens: bloom round the heart as they resonate and burst, a ring of colour round it ----------------------
    if (pH.z > 0.0) {
        let dd = (uv - pH.xy) * vec2<f32>(aspect, 1.0);
        let dl = length(dd);
        let l = res * res * 0.4 * (1.0 - breath) + select(0.0, exp(-dt * 1.2) * 1.5, det);
        add = add + mix(vec3<f32>(0.9, 0.8, 1.0), cb_hue(hue_t), 0.4) * l / (1.0 + dl * dl * 300.0) * 0.3 * k;
    }
    add = add + mix(vec3<f32>(1.0), vec3<f32>(1.0, 0.85, 1.1), 0.5) * flash * flash * 0.5 * k;

    // ---- combine --------------------------------------------------------------
    var outc = (col + add) * (1.0 - breath * 0.35 * k);
    let vg = length((uv - vec2<f32>(0.5)) * vec2<f32>(aspect, 1.0));
    outc = outc * (1.0 - smoothstep(0.3, 1.0, vg) * (0.2 + 0.3 * dark) * k);
    let lum_o = max(luminance(outc * 0.9), 1.0e-5);
    let hue = outc * 0.9 * (aces(vec3<f32>(lum_o)).x / lum_o);
    outc = mix(aces(outc * 0.9), hue / max(1.0, max(hue.r, max(hue.g, hue.b))), 0.45);
    let srgb = linear_to_srgb(outc);
    if (capture() > 2.5) {
        let sp = floor(in.position.xy);
        let chk = fract((sp.x + sp.y) * 0.5);
        let ycc_y = srgb.g * 0.5 + (srgb.r + srgb.b) * 0.25;
        let ycc_co = srgb.r - srgb.b;
        let ycc_cg = srgb.g - (srgb.r + srgb.b) * 0.5;
        return vec4<f32>(ycc_y, select(ycc_cg, ycc_co, chk < 0.25) * 0.5 + 0.5, 0.0, 1.0);
    }
    return vec4<f32>(srgb, 1.0);
}

@fragment
fn fs_main(in: StageIn) -> @location(0) vec4<f32> {
    return crystal_bloom(in);
}

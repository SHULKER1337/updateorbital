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


// Orbital Laser's post pass for the Downfall (laser 5). The mod builds it from shaders/strike.wgsl up to its fs_main
// (the helpers, the Mothership's hull and the Black Hole's lens, which this reuses) followed by this file, and sets it
// for a downfall strike only: one pass with every laser in it would be much bigger for the GPU's compiler to fit, and
// slower for all of them. Validate with tools/check-shader.sh.

// ---- laser 5: the downfall ----------------------------------------------------------------------------------------
// The mothership's last stand. It drops in exactly as the Mothership does and charges, but the charge is cut and the
// power thrown to the batteries along its roof as a meteor the size of a hill comes down on it. They break it up, and the
// pieces, coming on as fast, strike it anyway: it burns, sheds chunks, loses lift and falls stern first, drifting
// downrange, smoke streaming up from it, and its stern strikes the ground, it ploughs on and its bow slams down, a wall
// of dust rolling out. Then the black hole engine in its stern groans, cracks of light spreading over it, and ruptures:
// the black hole draws the wreck in after it, tears up the land round it, and collapses in a flash. The hull is the
// Mothership's (ms_tier, ms_hull), met analytically in its own frame as it tilts (df_trace); the black hole is the
// Black Hole's lens (bh_lens). strike.rs works out the same fall, crash, gouge, chunks and torn blocks (DfGeo): keep
// the DF_* and df_* in step.

const DF_XP: f32 = -480.0;         // keep in step with strike.rs: DF_*, DfGeo
const DF_CUT: f32 = 6.8;
const DF_TURN0: f32 = 7.2;
const DF_TURN1: f32 = 13.2;
const DF_FIRE0: f32 = 8.4;
const DF_FIRE1: f32 = 10.8;
const DF_PERIOD: f32 = 0.75;
const DF_BOLT: f32 = 1.4;          // a bolt's flight up to the meteor
const DF_SPLIT: f32 = 11.0;
const DF_MV: f32 = 260.0;
const DF_LS: f32 = 1150.0;
const DF_ELEV: f32 = 0.3;
const DF_MR: f32 = 34.0;           // the meteor's radius, and its pieces'
const DF_FR: f32 = 11.0;
const DF_ROCK: f32 = 15.4;
const DF_MET0: f32 = 2.5;         // the meteor is first seen, a point of light far up its path
const DF_FALL0: f32 = 17.0;
const DF_FALL1: f32 = 30.0;
const DF_SLIDE: f32 = 2.6;
const DF_BOW: f32 = 0.65;           // its bow strikes the ground this long after its stern
const DF_GROAN: f32 = 34.0;        // its engine starts to give
const DF_OPEN: f32 = 40.0;
const DF_LIFE: f32 = 15.0;
const DF_SINK0: f32 = 28.0;        // it ploughs in this deep, then settles over DF_SETTLE, buried DF_EMBED deep at the stern
const DF_SETTLE: f32 = 5.5;
const DF_EMBED: f32 = 72.0;
const DF_THC: f32 = 0.19;
const DF_THS: f32 = 0.05;
const DF_THR: f32 = 0.03;
const DF_REAL_A: f32 = 170.0;      // the slot under its keel is cut for real along its stern's this many blocks, this deep
const DF_SLOT: f32 = 32.0;
const DF_SHED: i32 = 48;           // the pieces it sheds as it falls, DF_SHED_PER every DF_SHED_DT from DF_SHED_T0
const DF_SHED_PER: i32 = 6;
const DF_SHED_T0: f32 = 15.9;
const DF_SHED_DT: f32 = 1.6;
const DF_SEC: i32 = 8;             // the black hole tears the wreck apart in this many sections, the last going in
const DF_SWALLOW: f32 = 10.4;      // this long after it opens
const DF_PHC: f32 = 0.12;
const DF_PHR: f32 = 0.035;
const DF_HOLE_H: f32 = 40.0;
const DF_BETA: f32 = 0.111;
const DF_RS: f32 = 13.0;           // the black hole's horizon, in blocks
const DFD_N: i32 = 96;
const DF_CHUNKS: i32 = 10;
const DF_G: f32 = 16.0;
const DF_KEEL_W: f32 = 70.0;
const DF_SKID_W: f32 = 60.0;
const DF_SLOPE: f32 = 1.1;          // the gouges' walls lean in this far across a block down (strike.rs's DF_SLOPE)
const DF_END: f32 = 64.0;          // the strike's length
const DF_REST: f32 = DF_FALL1 + DF_SLIDE + DF_SETTLE;   // it has come to rest, buried (strike.rs's DF_REST)

// Where everything is, from the strike (strike.rs's DfGeo): the way away from the player, the ship's heading as it
// arrives and once it has come about, its middle, its belly's height, the target's block level, where its stern comes to
// rest (the hole) and strikes, its pivot hanging there, the way the meteor goes, its roll and the hits' mirror.
struct DfGeo {
    ax: vec2<f32>,
    h0: vec2<f32>,
    hf: vec2<f32>,
    c: vec2<f32>,
    ps: vec2<f32>,
    c0: vec2<f32>,
    s1: vec2<f32>,
    side: vec2<f32>,
    y0: f32,
    by: f32,
    roll: f32,
    mz: f32,
    mode: i32,
}
fn df_geo() -> DfGeo {
    var g: DfGeo;
    let tgt = target_pos();
    g.ax = ms_axis();
    let right = vec2<f32>(-g.ax.y, g.ax.x);
    g.mode = approach();
    g.h0 = select(select(select(-g.ax, right, g.mode == 2), -right, g.mode == 3), g.ax, g.mode == 1);
    g.hf = select(g.h0, right, g.mode == 0 || g.mode >= 4);
    g.c = tgt.xz - g.h0 * MS_EM_X;
    g.s1 = g.c + g.hf * DF_XP;
    g.ps = tgt.xz + g.ax * frame.mod_params[3].z;
    g.c0 = g.ps - (g.ps - g.s1) * DF_BETA;
    g.y0 = tgt.y + MS_H;
    g.by = block_y();
    let s = u32(seed_v());
    g.side = select(-g.hf, right * select(-1.0, 1.0, mh(7u, s, 1u) < 0.5), g.mode == 1);
    let far = -g.hf.y * g.ax.x + g.hf.x * g.ax.y;
    g.roll = select(select(-1.0, 1.0, mh(7u, s, 2u) < 0.5), sign(far), abs(far) > 0.3);
    g.mz = select(-1.0, 1.0, mh(7u, s, 3u) < 0.5);
    return g;
}
fn df_heading(g: DfGeo, t: f32) -> vec2<f32> {
    if (g.mode == 0 || g.mode >= 4) {
        let a = -1.5707963 * smoothstep(DF_TURN0, DF_TURN1, t);
        return vec2<f32>(g.h0.x * cos(a) - g.h0.y * sin(a), g.h0.x * sin(a) + g.h0.y * cos(a));
    }
    return g.h0;
}
// A point of the hull (x along, y up, z across) while it hangs there level, in the world.
fn df_hover(g: DfGeo, t: f32, l: vec3<f32>) -> vec3<f32> {
    let h = df_heading(g, t);
    let xz = g.c + h * l.x + vec2<f32>(-h.y, h.x) * l.z;
    return vec3<f32>(xz.x, g.y0 + l.y, xz.y);
}

// The ship in its own frame: its plan's origin (camera-relative) and axes, its scale (the arrival's, along about `px`),
// and the black hole's hold on it: how far it has drawn the hull in, how far round it the hull is gone, and where it is
// in the hull's frame.
struct DfPose {
    o: vec3<f32>,
    a: vec3<f32>,
    u: vec3<f32>,
    d: vec3<f32>,
    s: vec3<f32>,
    px: f32,
    pull: f32,
    eat: f32,
    hl: vec3<f32>,
    // what is left of it between two torn planes across it (plan x), its torn edges jagged; and its stern crumpling in
    // towards the hole before it opens
    x0: f32,
    x1: f32,
    crush: f32,
    // a section falling in: how wide its near end still is, as a share of its far end's (it narrows towards the hole)
    tz: f32,
}
fn df_bare(o: vec3<f32>, a: vec3<f32>, u: vec3<f32>, d: vec3<f32>) -> DfPose {
    var P: DfPose;
    P.o = o;
    P.a = a;
    P.u = u;
    P.d = d;
    P.s = vec3<f32>(1.0);
    P.px = 0.0;
    P.pull = 0.0;
    P.eat = 0.0;
    P.hl = vec3<f32>(0.0);
    P.x0 = -1.0e4;
    P.x1 = 1.0e4;
    P.crush = 0.0;
    P.tz = 1.0;
    return P;
}
// The Mothership's arrival, as a pose.
fn df_from_ms(f: MsFrame, cam: vec3<f32>) -> DfPose {
    let c = f.c + f.ax * f.shift;
    var P = df_bare(vec3<f32>(c.x, f.y0, c.y) - cam, vec3<f32>(f.ax.x, 0.0, f.ax.y), vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(f.sd.x, 0.0, f.sd.y));
    P.s = vec3<f32>(f.sx, f.sy, f.sz);
    P.px = f.px;
    return P;
}
// The ship at `t` once it has stopped (strike.rs's DfGeo::pose): hanging there, coming about, rocked by the hits, falling
// stern first and drifting downrange, ploughing on along the ground as its bow slams down, at rest.
fn df_pose(g: DfGeo, t: f32, cam: vec3<f32>) -> DfPose {
    let h = df_heading(g, t);
    var s = g.c + h * DF_XP;
    var y = g.y0;
    var th = 0.0;
    var ph = 0.0;
    if (t > DF_ROCK) {
        let r = t - DF_ROCK;
        // (kicked over by the hits, rocking back)
        ph = 0.07 * exp(-r * 1.1) * sin(r * 4.5);
        th = 0.025 * exp(-r * 1.3) * sin(r * 5.2);
    }
    let yc = g.by + 6.0;
    let yr = g.by - DF_EMBED;
    if (t >= DF_FALL0 && t < DF_FALL1) {
        let u = (t - DF_FALL0) / (DF_FALL1 - DF_FALL0);
        s = g.s1 + (g.c0 - g.s1) * pow(max(u, 1.0e-6), 1.25);
        y = g.y0 - (g.y0 - yc) * df_drop(t - DF_FALL0).x;
        let lr = df_lurch(t - DF_FALL0);
        th = DF_THC * lr.x;
        ph = ph + DF_PHC * lr.y * g.roll;
    } else if (t >= DF_FALL1) {
        // it ploughs on through the ground as its bow slams down, then sinks on in, slowing, until it is buried
        let tau = min((t - DF_FALL1) / DF_SLIDE, 1.0);
        let e = 1.0 - (1.0 - tau) * (1.0 - tau);
        let f = 1.0 - pow(1.0 - saturate((t - DF_FALL1 - DF_SLIDE) / DF_SETTLE), 3.0);
        let ys = g.by - DF_SINK0;
        s = g.c0 + (g.ps - g.c0) * e;
        y = yc + (ys - yc) * e + (yr - ys) * f;
        // (its bow slams down well before it stops, rebounds, and the whole hull shudders with the blow)
        let b0 = t - DF_FALL1;
        let tp = min(b0 / DF_BOW, 1.0);
        th = DF_THS + (DF_THC - DF_THS) * (1.0 - tp * tp) + (DF_THR - DF_THS) * f;
        ph = ph + (DF_PHR + (DF_PHC - DF_PHR) * (1.0 - tp) * (1.0 - tp)) * g.roll;
        let bs = b0 - DF_BOW;
        if (bs > 0.0) {
            th = th + 0.03 * exp(-bs * 2.8) * sin(bs * 7.5);
            ph = ph + 0.02 * exp(-bs * 3.0) * sin(bs * 8.0) * g.roll;
        }
        y = y + 1.5 * exp(-b0 * 1.8) * sin(b0 * 29.0);
        th = th + 0.004 * exp(-b0 * 1.8) * sin(b0 * 23.0);
        let b = t - DF_FALL1 - DF_SLIDE;
        if (b > 0.0) {
            th = th + 0.012 * exp(-b * 2.5) * sin(b * 7.0);
        }
    }
    let a3 = vec3<f32>(h.x, 0.0, h.y);
    let s3 = vec3<f32>(-h.y, 0.0, h.x);
    let a = vec3<f32>(a3.x * cos(th), sin(th), a3.z * cos(th));
    let u1 = vec3<f32>(-a3.x * sin(th), cos(th), -a3.z * sin(th));
    return df_bare(vec3<f32>(s.x, y, s.y) - cam - a * DF_XP, a, u1 * cos(ph) + s3 * sin(ph), s3 * cos(ph) - u1 * sin(ph));
}
fn df_local(P: DfPose, p: vec3<f32>) -> vec3<f32> {
    let r = p - P.o;
    return vec3<f32>(dot(r, P.a), dot(r, P.u), dot(r, P.d));
}
fn df_world(P: DfPose, l: vec3<f32>) -> vec3<f32> {
    return P.o + P.a * l.x + P.u * l.y + P.d * l.z;
}

// How far a tear across the hull wanders, `y` across it and `h` up it: torn further in some decks than others, ragged.
fn df_jag(y: f32, h: f32) -> f32 {
    return 15.0 * (fvnoise(vec2<f32>(y * 0.045, floor(h / 7.0) * 1.7)) - 0.5) + 14.0 * (fvnoise(vec2<f32>(y * 0.09, h * 0.07)) - 0.5)
        + 6.0 * (fvnoise(vec2<f32>(y * 0.37, h * 0.31)) - 0.5);
}
// Where in the hull's plan a point of its frame is (xy), and z 1e4 once the black hole has had it: the hull is drawn in
// after the hole along its length, narrowing as it goes, and gone round the hole and behind it.
fn df_plan(P: DfPose, l: vec3<f32>) -> vec3<f32> {
    var q = vec2<f32>((l.x - P.px) / P.s.x + P.px, l.z / P.s.z);
    if (P.tz < 1.0) {
        // (a section falling in: narrower towards its near end, at px)
        q.y = q.y / mix(P.tz, 1.0, saturate((q.x - P.px) / (P.x1 - P.x0)));
    }
    var gone = 0.0;
    if (P.crush > 0.0) {
        // crumpling inwards: the plating round the hole drawn in towards it, in dents and folds
        let dq = q - P.hl.xz;
        let dent = 0.6 + 0.4 * sin(dq.x * 0.07 + l.y * 0.05) * sin(dq.y * 0.09 - l.y * 0.04);
        q = q + dq * P.crush * dent * exp(-dot(dq, dq) / 26000.0);
    }
    if (P.eat > 0.0) {
        gone = select(0.0, 1.0e4, length(l - P.hl) < P.eat);
    }
    if (P.x0 > -1.0e3 || P.x1 < 1.0e3) {
        // torn off along a rib: jagged, deeper in some decks than others
        let jag = df_jag(q.y, l.y);
        gone = max(gone, select(0.0, 1.0e4, q.x < P.x0 + jag || q.x > P.x1 + jag));
    }
    return vec3<f32>(q, gone);
}
// Where each battery is laid (12: the six down the right of the roof, then the left): its bearing round from the bow
// and its barrels' elevation, in the hull's frame; and that bearing's cosine and sine, and where on the roof it stands.
// Worked out once a frame (df_aim), for the trace and the shading.
var<private> df_aims: array<vec2<f32>, 12>;
var<private> df_bear: array<vec4<f32>, 12>;
// (worked out only for a pixel that needs them, the first time it does: df_lay; from the strike's time, and where the
// meteor is aimed and the way it goes)
var<private> df_laid: bool;
var<private> df_lay_t: f32;
var<private> df_lay_aim: vec3<f32>;
var<private> df_lay_mv: vec3<f32>;
const DF_TS: f32 = 1.4;            // a battery's size: its house about 28 blocks long
const DF_BARREL: f32 = 32.0;
const DF_RING_R: f32 = 19.0;       // the barbette each stands on: wider than its house, this high over the roof
const DF_RING_H: f32 = 2.5;
// Battery `i`'s middle on the roof (plan xz): inboard of the roof's edge, clear of where the hull's sides step in.
fn df_bat_c(i: i32) -> vec2<f32> {
    let x = -450.0 + 150.0 * f32(i % 6);
    return vec2<f32>(x, select(-1.0, 1.0, i < 6) * (ms_half_w(x) - 30.0));
}
// How far a point of the roof's plan is outside the nearest battery's barbette (below 0 inside).
fn df_ring(q: vec2<f32>) -> f32 {
    let i = i32(clamp(floor((q.x + 450.0) / 150.0 + 0.5), 0.0, 5.0)) + select(6, 0, q.y >= 0.0);
    return length(q - df_bat_c(i)) - DF_RING_R;
}
// Battery `i` laid on the meteor at `t`: stowed fore and aft until the charge is cut, then slewed round onto it, led by
// a bolt's flight; once it has broken up, on where its pieces come from; left where it was as the ship falls, and
// knocked flat in the crash.
fn df_aim(g: DfGeo, i: i32, t: f32, aim: vec3<f32>, mv: vec3<f32>) -> vec2<f32> {
    let tt = min(t, DF_FALL0);
    let c = df_bat_c(i);
    let piv = df_hover(g, tt, vec3<f32>(c.x, MS_TOP + 7.5, c.y));
    let at = select(df_met_head(aim, mv, min(tt + DF_BOLT, DF_SPLIT)), aim - mv * DF_LS, tt >= DF_SPLIT);
    let w = at - piv;
    let h = df_heading(g, tt);
    let l = vec3<f32>(dot(w.xz, h), w.y, dot(w.xz, vec2<f32>(-h.y, h.x)));
    let sl = smoothstep(DF_CUT, DF_CUT + 1.4, t);
    let el = clamp(atan2(l.y, length(l.xz)), 0.04, 1.3);
    return vec2<f32>(atan2(l.z, l.x) * sl, mix(0.03, el, sl) * (1.0 - 0.9 * smoothstep(DF_FALL1, DF_FALL1 + 0.5, t)));
}
fn df_lay() {
    if (df_laid) {
        return;
    }
    let g = df_geo();
    for (var i = 0; i < 12; i = i + 1) {
        df_aims[i] = df_aim(g, i, df_lay_t, df_lay_aim, df_lay_mv);
        df_bear[i] = vec4<f32>(cos(df_aims[i].x), sin(df_aims[i].x), df_bat_c(i));
    }
    df_laid = true;
}
// A battery's house at a point of the roof's plan: where in the battery's own frame (x towards where it is laid, y
// across), how far outside it (below 0 inside), and which battery. An armoured house on a ring, its face sloped in at
// the corners, its back rounded.
fn df_house(q: vec2<f32>) -> vec4<f32> {
    let idx = clamp(floor((q.x + 450.0) / 150.0 + 0.5), 0.0, 5.0);
    let i = i32(idx) + select(6, 0, q.y >= 0.0);
    df_lay();
    let b = df_bear[i];
    let dq = (q - b.zw) / DF_TS;
    let f = b.xy;
    let r = vec2<f32>(dot(dq, f), dq.y * f.x - dq.x * f.y);
    let front = max(max(abs(r.y) - 8.0, r.x - 9.0), max((r.x - 9.0) * 0.6 + (abs(r.y) - 8.0) * 0.8 + 2.2, -3.0 - r.x));
    let back = length(r - vec2<f32>(-3.0, 0.0)) - 8.0;
    return vec4<f32>(r, min(front, back) * DF_TS, f32(i));
}
// The batteries along both edges of the roof at height `h` over the belly, each house on its barbette (the ring under
// it, up to DF_RING_H over the roof): below 0 inside one.
fn df_turret(q: vec2<f32>, h: f32) -> f32 {
    let t = select(df_house(q).z, df_ring(q), h < MS_TOP + DF_RING_H);
    // and a raised spine down the middle of the roof, stepped in sections, from the engines to the bow's sensors
    let sec = floor(q.x / 90.0);
    let w = 34.0 + 14.0 * fh21(vec2<f32>(sec, 71.0));
    let spine = max(max(abs(q.y) - w, q.x - 300.0), -390.0 - q.x);
    return min(t, max(spine, abs(q.x - (sec + 0.5) * 90.0) - 42.0));
}
// Band `k`'s footprint at a point of the hull's frame (below 0 inside): the keel, the middle deck, the outer hull, each
// up to the next one's floor, and the batteries over the roof.
fn df_foot(P: DfPose, l: vec3<f32>, k: i32) -> f32 {
    let m = df_plan(P, l);
    if (k == 3) {
        return df_turret(m.xy, l.y / P.s.y) + m.z;
    }
    return ms_tier(m.xy, k) + m.z;
}
// Up the eye or the hangar from its mouth at `t_lo`: its ceiling, or its wall on the way (as ms_recess).
fn df_recess(P: DfPose, o: vec3<f32>, v: vec3<f32>, t_lo: f32, up: f32, which: i32) -> MsHit {
    var hit: MsHit;
    let t_c = (up * P.s.y - o.y) / v.y;
    let q_c = df_plan(P, o + v * t_c).xy;
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
        let qm = df_plan(P, o + v * m).xy;
        if (select(ms_hangar(qm), ms_eye(qm), which == 0) < 0.0) {
            a = m;
        } else {
            b = m;
        }
    }
    hit.t = b;
    hit.q = df_plan(P, o + v * b).xy;
    hit.h = (o.y + v.y * b) / P.s.y;
    hit.kind = select(7, 5, which == 0);
    return hit;
}
// Where a ray (from `ro`, camera-relative, along `rd`) meets the hull, from any side: the hull is the keel, the middle
// deck and the outer hull, each a prism from its floor to the next one's (each inside the next), and the batteries over
// the roof. Each prism is met at its floor or its top (found by where the ray crosses those heights) or else through
// its wall (stepping across it, then closing in by halves). The kinds are ms_trace's, and 9 a battery; the roof is a
// floor at MS_TOP.
fn df_trace(P: DfPose, ro: vec3<f32>, rd: vec3<f32>) -> MsHit {
    var hit: MsHit;
    hit.t = 1.0e9;
    hit.q = vec2<f32>(0.0);
    hit.h = 0.0;
    hit.kind = -1;
    let o = df_local(P, ro);
    let v = vec3<f32>(dot(rd, P.a), dot(rd, P.u), dot(rd, P.d));
    let iv = 1.0 / select(v, vec3<f32>(1.0e-6), abs(v) < vec3<f32>(1.0e-6));
    // the box round it, in its frame
    let lo = vec3<f32>((max(-560.0, P.x0 - 30.0) - P.px) * P.s.x + P.px, 0.0, -302.0 * P.s.z);
    let hi = vec3<f32>((min(560.0, P.x1 + 30.0) - P.px) * P.s.x + P.px, (MS_TOP + 12.0) * P.s.y, 302.0 * P.s.z);
    let t1 = (lo - o) * iv;
    let t2 = (hi - o) * iv;
    let tmin = min(t1, t2);
    let tmax = max(t1, t2);
    let bx0 = max(max(tmin.x, tmin.z), 0.0);
    let bx1 = min(tmax.x, tmax.z);
    if (bx1 < max(bx0, max(tmin.y, 0.0)) || tmax.y < bx0) {
        return hit;
    }
    var hangar = false;
    let below = o.y < 0.0 && v.y > 0.0;
    for (var k = 0; k < 4; k = k + 1) {
        if (below && hit.kind >= 0) {
            // (from below the bands come in order of height: the first met is the nearest)
            break;
        }
        let y0 = select(ms_tier_h(k), MS_TOP, k == 3) * P.s.y;
        let y1 = select(select(MS_TOP, ms_tier_h(k + 1), k < 2), MS_TOP + 12.0, k == 3) * P.s.y;
        var ta = bx0;
        var tb = min(bx1, hit.t);
        var floor_in = false;
        var roof_in = false;
        if (abs(v.y) > 1.0e-6) {
            let sa = (y0 - o.y) * iv.y;
            let sb = (y1 - o.y) * iv.y;
            if (min(sa, sb) > ta) {
                ta = min(sa, sb);
                floor_in = v.y > 0.0;
                roof_in = v.y < 0.0;
            }
            tb = min(tb, max(sa, sb));
        } else if (o.y < y0 || o.y > y1) {
            continue;
        }
        if (tb <= ta || (k == 2 && hangar)) {
            continue;
        }
        let la = o + v * ta;
        if (k == 1 && floor_in) {
            // from below into the hangar's mouth: up it to its ceiling, or its wall
            let qa = df_plan(P, la);
            if (ms_hangar(qa.xy) < 0.0 && ms_outline(qa.xy, 40.0) < 0.0 && qa.z < 1.0) {
                hangar = true;
                let rh = df_recess(P, o, v, ta, MS_HANGAR_UP, 1);
                if (rh.t < hit.t) {
                    hit = rh;
                }
                continue;
            }
        }
        if (df_foot(P, la, k) < 0.0) {
            let qa = df_plan(P, la).xy;
            if (k == 0 && floor_in && ms_eye(qa) < 0.0) {
                let re = df_recess(P, o, v, ta, MS_EYE_UP, 0);
                if (re.t < hit.t) {
                    hit = re;
                }
                continue;
            }
            hit.t = ta;
            hit.q = qa;
            hit.h = select(select((o.y + v.y * ta) / P.s.y, select(MS_TOP, MS_TOP + 12.0, k == 3), roof_in), ms_tier_h(k), floor_in);
            hit.kind = select(select(3, 2, roof_in && k == 2), k, floor_in && k < 3);
            hit.kind = select(hit.kind, 9, k == 3);
            continue;
        }
        if (k == 3) {
            // over the roof (the batteries' houses, under 30 blocks across, and the spine): stepped by how far off the
            // nearest of them is in the plan, then closed in on by halves
            let hl = max(length(v.xz), 1.0e-4);
            let sc = min(P.s.x, P.s.z);
            var a = ta;
            var fa = df_foot(P, la, 3);
            let yr = (MS_TOP + DF_RING_H) * P.s.y;
            for (var i = 0; i < 48; i = i + 1) {
                // (and not over the barbettes' top in one step)
                let dy = max(abs(o.y + v.y * a - yr), 0.3) / max(abs(v.y), 1.0e-4);
                let b = min(a + min(clamp(fa * sc, 0.4, 30.0) / hl, dy), tb);
                let fb = df_foot(P, o + v * b, 3);
                if (fb < 0.0) {
                    var lo_ = a;
                    var hi_ = b;
                    for (var j = 0; j < 5; j = j + 1) {
                        let m = 0.5 * (lo_ + hi_);
                        if (df_foot(P, o + v * m, 3) < 0.0) {
                            hi_ = m;
                        } else {
                            lo_ = m;
                        }
                    }
                    hit.t = hi_;
                    hit.q = df_plan(P, o + v * hi_).xy;
                    hit.h = (o.y + v.y * hi_) / P.s.y;
                    hit.kind = 9;
                    break;
                }
                if (b >= tb) {
                    break;
                }
                a = b;
                fa = fb;
            }
            continue;
        }
        // step across the band to where the ray first comes inside, then close in on the wall
        let n = clamp(i32(length((v * (tb - ta)).xz) / 40.0), 1, 14);
        var a = ta;
        for (var i = 1; i <= n; i = i + 1) {
            let b = ta + (tb - ta) * f32(i) / f32(n);
            if (df_foot(P, o + v * b, k) < 0.0) {
                var lo_ = a;
                var hi_ = b;
                for (var j = 0; j < 5; j = j + 1) {
                    let m = 0.5 * (lo_ + hi_);
                    if (df_foot(P, o + v * m, k) < 0.0) {
                        hi_ = m;
                    } else {
                        lo_ = m;
                    }
                }
                hit.t = hi_;
                hit.q = df_plan(P, o + v * hi_).xy;
                hit.h = (o.y + v.y * hi_) / P.s.y;
                hit.kind = select(3, 9, k == 3);
                break;
            }
            a = b;
        }
    }
    return hit;
}

// How fast its pivot is moving at `t` as it falls (strike.rs's DfGeo::vel; its spin left out).
fn df_vel(g: DfGeo, t: f32) -> vec3<f32> {
    if (t < DF_FALL0 || t >= DF_FALL1) {
        return vec3<f32>(0.0);
    }
    let tf = DF_FALL1 - DF_FALL0;
    let u = max((t - DF_FALL0) / tf, 1.0e-6);
    let kk = 1.25 * pow(u, 0.25) / tf;
    return vec3<f32>((g.c0.x - g.s1.x) * kk, -(g.y0 - g.by - 6.0) * df_drop(t - DF_FALL0).y, (g.c0.y - g.s1.y) * kk);
}
// How far it has dropped `r` seconds after it loses lift, as a share of the way down, and how fast (strike.rs's
// df_drop): a lurch as the lift first gives, its engines fighting back a little, a second lurch, then falling free,
// faster and faster, into the ground.
fn df_drop(r: f32) -> vec2<f32> {
    let a = saturate(r / 0.7);
    let b = saturate((r - 3.2) / 0.6);
    let c = saturate((r - 0.7) / 2.5);
    let dc = select(0.0, 1.0, c > 0.0 && c < 1.0);
    let f = max(r - 4.0, 0.0) / 9.0;
    return vec2<f32>(0.07 * a * a * (3.0 - 2.0 * a) + 0.05 * b * b * (3.0 - 2.0 * b) - 0.012 * sin(3.1415927 * c) + 0.88 * f * f,
        0.07 * 6.0 * a * (1.0 - a) / 0.7 + 0.05 * 6.0 * b * (1.0 - b) / 0.6 - 0.012 * 3.1415927 / 2.5 * cos(3.1415927 * c) * dc + 0.88 * 2.0 * f / 9.0);
}
// Its pitch and roll `r` seconds after it loses lift, as shares of those it strikes the ground with (strike.rs's
// df_lurch): jerked over at each lurch, wallowing, then tipping on over as it falls.
fn df_lurch(r: f32) -> vec2<f32> {
    let free = smoothstep(0.0, 1.0, (r - 4.0) / 9.0);
    let wal = (1.0 - smoothstep(0.0, 1.0, (r - 9.0) / 4.0)) * smoothstep(0.0, 1.0, r);
    return vec2<f32>(0.35 * smoothstep(0.0, 1.0, r / 0.8) + 0.25 * smoothstep(0.0, 1.0, (r - 3.2) / 0.7) + 0.4 * free + 0.16 * sin(r * 1.9) * wal,
        0.3 * smoothstep(0.0, 1.0, (r - 0.2) / 0.8) + 0.3 * smoothstep(0.0, 1.0, (r - 3.3) / 0.7) + 0.4 * free + 0.17 * sin(r * 2.3 + 1.0) * wal);
}
// The displaced ground heaped up beside the hull, `e` blocks out from its edge, `x` along it (strike.rs's df_berm_h).
fn df_berm_h(x: f32, e: f32) -> f32 {
    if (e < 0.0) {
        return 0.0;
    }
    return (14.0 * exp(-pow((e - 14.0) / 13.0, 2.0)) + 5.0 * exp(-pow((e - 52.0) / 6.0, 2.0))) * (1.0 - 0.35 * (x + 560.0) / 1120.0);
}

// The heap of ground the hull shoved aside, `xa` along it from its middle and `zb` across (band 0 and 1 beside either
// side, 2 the wave before its bow), how high over the land: df_berm_h's heaps, rising as the hull beside them sinks in
// (`sk`: how far its belly is down now, and at rest, as a + b x along it), surging up a little higher as it does, lumpy.
fn df_heap(xa: f32, zb: f32, band: i32, sk: vec4<f32>) -> f32 {
    let x = select(xa, 560.0, band == 2);
    let now = sk.x + sk.y * x;
    let fr = select(saturate(now / max(sk.z + sk.w * x, 1.0)), 0.0, now <= 0.0);
    let rise = smoothstep(0.0, 1.0, fr);
    let surge = 0.3 * exp(-pow((fr - 0.5) / 0.2, 2.0));
    var hb = 0.0;
    if (band < 2) {
        let side = select(1.0, -1.0, band == 1);
        let e = side * zb - ms_half_w(xa) - 18.0 * (1.0 - rise);
        hb = df_berm_h(xa, e) * step(abs(xa), 560.0);
    } else {
        hb = 22.0 * exp(-pow((xa - 576.0 - 14.0 * (1.0 - rise)) / 14.0, 2.0)) * (1.0 - smoothstep(180.0, 270.0, abs(zb)));
    }
    let lump = 0.8 + 0.35 * fvnoise(vec2<f32>(xa, zb) * 0.06) + 0.25 * (fvnoise(vec2<f32>(xa, zb) * 0.23) - 0.5);
    return hb * (rise + surge) * lump - 0.6 * (1.0 - rise);
}

// Whether the hull stands between the eye and `p` (camera-relative): where the line to it crosses the belly's and the
// roof's planes, is it inside the hull's outline? For fading the glare of what the hull hides.
fn df_blocks(P: DfPose, p: vec3<f32>) -> bool {
    let o = df_local(P, vec3<f32>(0.0));
    let e = df_local(P, p) - o;
    for (var i = 0; i < 2; i = i + 1) {
        let y = select(0.0, MS_TOP, i == 1) * P.s.y;
        let f = (y - o.y) / select(e.y, 1.0e-6, abs(e.y) < 1.0e-6);
        if (f > 0.0 && f < 1.0) {
            let m = df_plan(P, o + e * f);
            if (ms_outline(m.xy, 0.0) + m.z < 0.0) {
                return true;
            }
        }
    }
    return false;
}

// Where the meteor's piece `j` strikes the roof, in the hull's frame (strike.rs's DF_HITS, mirrored across by `mz`).
fn df_hit_l(j: i32, mz: f32) -> vec3<f32> {
    var l = vec3<f32>(-440.0, 150.0, 40.0);
    switch j {
        case 1: { l = vec3<f32>(-300.0, 150.0, -110.0); }
        case 2: { l = vec3<f32>(-520.0, 150.0, -150.0); }
        case 3: { l = vec3<f32>(-200.0, 150.0, 120.0); }
        case 4: { l = vec3<f32>(-545.0, 150.0, 60.0); }
        case 5: { l = vec3<f32>(-360.0, 150.0, 190.0); }
        default: {}
    }
    return vec3<f32>(l.x, l.y, l.z * mz);
}
// The way the meteor goes (strike.rs's DfGeo::meteor), and where it comes down on the roof.
fn df_met_dir(g: DfGeo) -> vec3<f32> {
    let h = normalize(g.side - g.ax * 0.2);
    return vec3<f32>(h.x * cos(DF_ELEV), -sin(DF_ELEV), h.y * cos(DF_ELEV));
}
// The meteor's middle at `t` (until it breaks up, DF_LS short of `aim`), in the world.
fn df_met_head(aim: vec3<f32>, mv: vec3<f32>, t: f32) -> vec3<f32> {
    return aim - mv * (DF_LS + DF_MV * (DF_SPLIT - t));
}

// The top block of the ground at column `xz` near the hole once the gouges are cut (strike.rs's DfGeo::ground).
fn df_ground(g: DfGeo, xz: vec2<f32>) -> f32 {
    let p = floor(xz) + 0.5;
    var top = g.by;
    let r = p - g.ps;
    let a = dot(r, g.hf);
    if (a >= -80.0 && a < DF_REAL_A) {
        let sl = df_slot(a);
        let j = df_step_depth(sl.x, sl.y, r.y * g.hf.x - r.x * g.hf.y);
        top = select(top, min(top, g.by - j - 1.0), j >= 0.0);
    }
    let sk = length(g.ps - g.c0);
    if (sk > 2.0) {
        let dir = (g.ps - g.c0) / sk;
        let r2 = p - g.c0;
        let a2 = dot(r2, dir);
        if (a2 >= 0.0 && a2 < sk) {
            let u = a2 / sk;
            let j = df_step_depth(DF_SKID_W, floor(12.5 + 8.0 * u + 2.5 * sin(u * 19.0 + 1.0) + 1.5 * sin(u * 41.0)), r2.y * dir.x - r2.x * dir.y);
            top = select(top, min(top, g.by - j - 1.0), j >= 0.0);
        }
    }
    return top;
}
// The deepest layer a gouge `hw` wide and `d` deep has dug `b` across from its middle, its walls sloping in in steps of
// three layers; -1 for none (strike.rs's df_step_depth).
fn df_step_depth(hw: f32, d: f32, b: f32) -> f32 {
    let m = (hw - abs(b)) / DF_SLOPE;
    return select(select(3.0 * floor((m - 2.0) / 3.0) + 2.0, -1.0, m < 2.0), d, d <= m);
}
// The slot the buried keel lies in, `a` along from the stern's pivot: its half-width at the top and its depth (strike.rs's
// df_slot): wide round the engine block, narrowing to the keel, wandering, shallowing out and closing at its far end.
fn df_slot(a: f32) -> vec2<f32> {
    let wide = smoothstep(0.0, 1.0, (62.0 - a) / 32.0);
    let wander = 0.94 + 0.04 * sin(a * 0.11 + 1.3) + 0.02 * sin(a * 0.29);
    let end = pow(saturate((DF_REAL_A - a) / 55.0), 0.8) * smoothstep(0.0, 1.0, (a + 80.0) / 55.0);
    let hw = min((70.0 + 60.0 * wide) * wander * (0.5 + 0.5 * end), select(DF_KEEL_W, 170.0, a < 50.0));
    return vec2<f32>(hw, floor(DF_SLOT * end + 0.5));
}
// How hot the gouges are at a point of the ground (0 to 1): fresh from the friction where the hull ploughed, cooling.
fn df_gouge_heat(g: DfGeo, p: vec3<f32>, time: f32) -> f32 {
    let r = p.xz - g.ps;
    let a = dot(r, g.hf);
    let b = abs(r.y * g.hf.x - r.x * g.hf.y);
    var heat = 0.0;
    let kw = df_slot(a).x;
    if (a > -80.0 && a < DF_REAL_A && b < kw + 4.0) {
        let age = time - DF_FALL1 - DF_SLIDE;
        heat = select(0.0, exp(-age / 12.0) * (1.0 - smoothstep(kw - 8.0, kw + 4.0, b)), age > 0.0);
    }
    let sk = length(g.ps - g.c0);
    if (sk > 2.0) {
        let dir = (g.ps - g.c0) / sk;
        let r2 = p.xz - g.c0;
        let a2 = dot(r2, dir);
        let b2 = abs(r2.y * dir.x - r2.x * dir.y);
        if (a2 > 0.0 && a2 < sk && b2 < DF_SKID_W + 4.0) {
            let age = time - (DF_FALL1 + DF_SLIDE * (1.0 - sqrt(1.0 - a2 / sk)));
            heat = max(heat, select(0.0, exp(-age / 9.0) * (1.0 - smoothstep(DF_SKID_W - 8.0, DF_SKID_W + 4.0, b2)), age > 0.0));
        }
    }
    return heat * saturate((g.by + 1.0 - p.y) / 3.0);
}
// Block `i` the black hole tears up (strike.rs's DfGeo::torn): x, z (the block), when (after DF_OPEN), and 1 for a piece
// of the wreck (or 0, the ground) + 2 for a big one.
// (`ks` holds pcg(seed ^ pcg(n)) for n = 21..25, worked out once: mh(i, seed, n) is then pcg(i ^ ks[n]))
fn df_torn(g: DfGeo, i: i32, ks: array<u32, 5>) -> vec4<f32> {
    let k = u32(i);
    let a = f32(pcg(k ^ ks[0])) * (TAU / 4294967296.0);
    let r = 46.0 + 36.0 * f32(pcg(k ^ ks[1])) * (1.0 / 4294967296.0);
    let t = 0.5 + 7.0 * f32(i) / f32(DFD_N) + 0.3 * f32(pcg(k ^ ks[2])) * (1.0 / 4294967296.0);
    let xz = floor(g.ps + vec2<f32>(cos(a), sin(a)) * r);
    return vec4<f32>(xz, t, select(0.0, 1.0, pcg(k ^ ks[3]) <= 1717986918u) + select(0.0, 2.0, pcg(k ^ ks[4]) > 3006477107u));
}

// A burning rock of radius `rr` (0: only its trail) at `head` (camera-relative), coming down along -`u` (`u` points back
// up its path), its trail `len` blocks back up it, `age0` seconds older than its head; `heat` how fiercely it burns, and
// `seen` how much of it there is to see yet. The Meteor Storm's big one: the smoke left in a widening wall, the fire
// streaming off it and bits of it breaking off and burning out in that, the rock itself dark and crusted, molten in
// patches over its leading face and in its cracks, a rim of burning air round it.
fn df_rock(col: ptr<function, vec3<f32>>, add: ptr<function, vec3<f32>>, rd: vec3<f32>, head: vec3<f32>, u: vec3<f32>, rr: f32, len: f32,
           age0: f32, heat: f32, seen: f32, scene_len: f32, sky: bool, ship_t: f32, dim: f32, seed: f32, k: f32) {
    let w0 = abs(rr);
    // the rock first, so what is behind it is hidden
    let th = dot(head, rd);
    var t_rock = 1.0e9;
    var rock_c = vec3<f32>(0.0);
    var dh = 1.0e9;
    var halo_c = vec3<f32>(0.0);
    if (rr > 0.0 && th > 0.0) {
        dh = length(head - rd * th);
        let rb = rr * 1.6;
        let hq = rb * rb - dh * dh;
        if (hq > 0.0) {
            // (a lumpy rock, longer than it is wide, tumbling slowly: marched in its own frame)
            let ax = normalize(vec3<f32>(sin(seed * 1.7), 0.6, cos(seed * 2.3)));
            let ang = seed * 2.1 + now() * 0.18;
            let ro = rot_axis(-head, ax, -ang);
            let rv = rot_axis(rd, ax, -ang);
            var t = max(th - sqrt(hq), 0.0);
            let t_end = min(th + sqrt(hq), min(scene_len, ship_t));
            var met = false;
            var dmin = 1.0e9;
            var pmin = vec3<f32>(0.0);
            for (var i = 0; i < 28; i = i + 1) {
                if (t > t_end) {
                    break;
                }
                let dd = df_lump(ro + rv * t, rr, seed);
                if (dd < dmin) {
                    dmin = dd;
                    pmin = ro + rv * t;
                }
                if (dd < 0.015 * rr) {
                    met = true;
                    break;
                }
                t = t + max(dd * 0.8, 0.01 * rr);
            }
            if (!met) {
                // past its edge: the air it tears through burning round it, streaming back off its sides
                let ul = rot_axis(u, ax, -ang);
                let back = dot(normalize(pmin), ul);
                let fl = 0.6 + 0.4 * gnoise3(pmin / rr * 3.0 + ul * now() * 4.0);
                let halo = exp(-max(dmin, 0.0) / (rr * (0.1 + 0.25 * saturate(back)))) * fl * (0.5 + 0.5 * saturate(back + 0.5));
                halo_c = lava_ramp(0.45 + 0.4 * halo) * halo * 2.2 * heat;
            }
            if (met && t < t_end) {
                let lp = ro + rv * t;
                let e = 0.03 * rr;
                let nl = normalize(vec3<f32>(1.0, -1.0, -1.0) * df_lump(lp + vec3<f32>(e, -e, -e), rr, seed)
                    + vec3<f32>(-1.0, -1.0, 1.0) * df_lump(lp + vec3<f32>(-e, -e, e), rr, seed)
                    + vec3<f32>(-1.0, 1.0, -1.0) * df_lump(lp + vec3<f32>(-e, e, -e), rr, seed)
                    + vec3<f32>(1.0, 1.0, 1.0) * df_lump(lp + vec3<f32>(e, e, e), rr, seed));
                let nrm = rot_axis(nl, ax, ang);
                let lpn = lp / rr;
                let front = saturate(dot(nrm, -u));
                // its crust: dark, scorched, lit a little by the sky and by its own fire
                let crust = gfbm3(lpn * 3.0 + vec3<f32>(seed * 0.7, 1.0, 2.0), 3);
                let cracks = smoothstep(0.55, 0.75, gfbm3(lpn * 4.0 + vec3<f32>(seed), 3));
                let rock = vec3<f32>(0.06, 0.05, 0.045) * (0.5 + gfbm3(lpn * 8.0, 2)) * dim * (0.5 + 0.5 * saturate(dot(nrm, vec3<f32>(0.3, 0.9, 0.2))));
                // molten where the air tears at its leading face, in patches between the crust; its cracks glowing,
                // brighter towards the front; and its edge, where the burning air streams past it
                let melt = pow(front, 2.0) * smoothstep(0.5, 0.68, crust + 0.12 * front);
                let edge = pow(1.0 - saturate(dot(nrm, -rd)), 2.5) * (0.3 + 0.7 * front);
                let hot = melt * 2.4 + cracks * (0.15 + 0.7 * front) + edge * 1.6;
                rock_c = rock * (1.0 - 0.6 * melt) * (1.0 + vec3<f32>(2.0, 0.9, 0.4) * front * heat)
                    + lava_ramp(0.25 + 0.5 * melt + 0.15 * cracks + 0.2 * edge) * hot * heat;
                t_rock = t;
            }
        }
    }
    let q = ray_seg(rd, head, head + u * len);
    let l = q.z * len;
    let age = l / DF_MV + age0;
    let burn = 1.0 - smoothstep(len * 0.6, len, l);
    let vis = select(1.0, 1.0 - smoothstep(scene_len - 2.0, scene_len + 2.0, q.y), !sky) * select(1.0, 0.0, q.y > ship_t || q.y > t_rock) * burn * seen;
    let sw = w0 * 1.3 + age * (3.0 + w0 * 0.25);
    let swp = max(sw, q.y * 0.004);
    if (vis > 0.0 && q.x < swp * 3.0) {
        let sn = gfbm2(vec2<f32>(l * 0.02 - age * 0.3, q.x / swp * 2.0 + seed));
        let sa = exp(-pow(q.x / swp, 2.0)) * (sw / swp) * smoothstep(0.05, 0.6, age) * exp(-age / 14.0) * (0.35 + 0.65 * sn) * saturate(heat * 2.0);
        *col = mix(*col, vec3<f32>(0.3, 0.26, 0.23) * dim * (0.5 + 0.8 * sn), saturate(sa * 0.9) * vis);
        let fw0 = w0 * (1.0 + age * 2.5);
        let fw = max(fw0, q.y * 0.003);
        let core = exp(-pow(q.x / (fw * 0.7), 2.0)) * sqrt(fw0 / fw) * exp(-age * 1.6);
        let flick = 0.75 + 0.5 * fvnoise(vec2<f32>(now() * 11.0, seed * 7.0));
        *add = *add + mix(vec3<f32>(4.0, 3.4, 2.2), vec3<f32>(3.0, 0.9, 0.15), smoothstep(0.0, 0.8, age)) * core * vis * heat * flick * k;
        // bits of it breaking off and burning out behind it
        let sp = fh21(vec2<f32>(floor(l * 0.08), floor(age * 9.0) + seed * 17.0));
        let off = (fract(sp * 53.0) - 0.5) * (w0 * 2.0 + age * 14.0);
        let spark = step(0.86, sp) * exp(-pow((q.x - abs(off)) / max(w0 * 0.12, q.y * 0.0015), 2.0)) * exp(-age * 1.8) * smoothstep(0.05, 0.3, age);
        *add = *add + vec3<f32>(3.0, 1.4, 0.35) * spark * vis * heat * k;
    }
    if (rr > 0.0 && th > 0.0) {
        // the glare round it: from far off a point of light getting brighter as it comes into the air and burns (over
        // the rock itself, only a little: it is seen through it)
        let glare = 1.0 / (1.0 + pow(dh / (rr * 2.5 + th * 0.004), 2.0));
        *add = *add + vec3<f32>(2.2, 1.4, 0.7) * glare * (0.4 + heat) * 0.3 * seen * select(select(1.0, 0.05, !sky && scene_len < th), 0.0, ship_t < th)
            * select(1.0, 0.25, t_rock < 1.0e8) * k;
    }
    *add = *add + halo_c * seen * k;
    if (t_rock < 1.0e8) {
        *col = mix(*col, rock_c, seen);
        *add = *add * (1.0 - seen);
    }
}

// The rock's surface, near `p` (in its own frame, from its middle; rr its size): a lump of rock longer than it is wide,
// knobbly, a face or two sheared flat where it broke off something bigger. Below 0 inside (a distance, roughly).
fn df_lump(p: vec3<f32>, rr: f32, seed: f32) -> f32 {
    let q = p * vec3<f32>(1.0 / 1.4, 1.0, 1.0 / 0.85);
    let r = length(q);
    let n = q / max(r, 1.0e-4);
    let sh = 0.8 + 0.75 * (gfbm3(n * 1.4 + vec3<f32>(seed * 0.37, seed * 0.11, 3.0), 3) - 0.5) + 0.12 * (gfbm3(n * 4.5 + vec3<f32>(seed), 2) - 0.5);
    var d = (r - rr * sh) * 0.7;
    let c1 = normalize(vec3<f32>(sin(seed * 3.7), cos(seed * 1.3), sin(seed * 2.9 + 1.0)));
    let c2 = normalize(vec3<f32>(cos(seed * 2.2), -0.5, sin(seed * 4.1)));
    d = max(d, dot(p, c1) - rr * 0.78);
    return max(d, dot(p, c2) - rr * 0.9);
}

// A ray (camera at the origin) against a box of half-size `hs` at `c` (camera-relative), turned `ang` about `ax`: how
// far (or -1), and the face's normal in the world.
fn df_box(c: vec3<f32>, rd: vec3<f32>, hs: vec3<f32>, ax: vec3<f32>, ang: f32) -> vec4<f32> {
    let ro = rot_axis(-c, ax, -ang) / hs;
    let rv = rot_axis(rd, ax, -ang) / hs;
    let inv = 1.0 / select(rv, vec3<f32>(1.0e-6), abs(rv) < vec3<f32>(1.0e-6));
    let ta = (vec3<f32>(-1.0) - ro) * inv;
    let tb = (vec3<f32>(1.0) - ro) * inv;
    let tlo = min(ta, tb);
    let tn = max(max(tlo.x, tlo.y), tlo.z);
    let tf = min(min(max(ta.x, tb.x), max(ta.y, tb.y)), max(ta.z, tb.z));
    if (tf < tn || tn < 0.0) {
        return vec4<f32>(-1.0);
    }
    let lp = abs(ro + rv * tn);
    var nl = vec3<f32>(0.0, sign((ro + rv * tn).y), 0.0);
    if (lp.x >= lp.y && lp.x >= lp.z) {
        nl = vec3<f32>(sign((ro + rv * tn).x), 0.0, 0.0);
    } else if (lp.z >= lp.y) {
        nl = vec3<f32>(0.0, 0.0, sign((ro + rv * tn).z));
    }
    return vec4<f32>(tn, normalize(rot_axis(nl, ax, ang)));
}

// The dust the crash raises, round `c` (xz) out to `R`: thick at the ground (`yg`) and thinning with height over `hs`,
// its front heaped up. Integrated along the view ray in closed form for its height, its spread and billows taken where
// the ray passes through it (three stretches), so it is soft, never blocky. How much of the view through it is left.
fn df_dust(cam: vec3<f32>, rd: vec3<f32>, scene_len: f32, c: vec2<f32>, R: f32, yg: f32, hs: f32, dens: f32, time: f32, seed: f32) -> vec2<f32> {
    let oc = cam.xz - c;
    let b = dot(oc, rd.xz);
    let a = max(dot(rd.xz, rd.xz), 1.0e-6);
    let cq = dot(oc, oc) - R * R;
    let disc = b * b - a * cq;
    if (disc <= 0.0) {
        return vec2<f32>(1.0, 0.0);
    }
    let sq = sqrt(disc);
    let t0 = max((-b - sq) / a, 0.0);
    let t1 = min((-b + sq) / a, min(scene_len, 6000.0));
    if (t1 <= t0) {
        return vec2<f32>(1.0, 0.0);
    }
    var tau = 0.0;
    var lit = 0.0;
    for (var i = 0; i < 3; i = i + 1) {
        let ta = mix(t0, t1, f32(i) / 3.0);
        let tb = mix(t0, t1, f32(i + 1) / 3.0);
        let pm = cam + rd * (0.5 * (ta + tb));
        let r = length(pm.xz - c);
        let nz = gfbm2(pm.xz * 0.012 + vec2<f32>(seed, time * 0.05));
        let front = exp(-pow((r - R * 0.85) / (R * 0.09), 2.0));
        let h = hs * (0.4 + 1.2 * nz) * (1.0 + 3.0 * front);
        // the height part in closed form: the density falls off as exp(-(y - yg) / h)
        let ea = exp(-max(cam.y + rd.y * ta - yg, -h) / h);
        let eb = exp(-max(cam.y + rd.y * tb - yg, -h) / h);
        let hint = select((tb - ta) * 0.5 * (ea + eb), h * (ea - eb) / rd.y, abs(rd.y) > 1.0e-3);
        let d = max(hint, 0.0) * (1.0 - smoothstep(R * 0.85, R, r)) * (0.12 + 0.35 * nz + 1.4 * front) * (1.0 - 0.5 * smoothstep(300.0, 700.0, r));
        tau = tau + d;
        // lit from above: brighter where it is heaped high and thin, darker low down in it
        lit = lit + d * saturate((pm.y - yg) / (h * 2.0) + 0.3 + 0.5 * nz);
    }
    return vec2<f32>(exp(-tau * dens), lit / max(tau, 1.0e-4));
}

// What is left of the wreck in the hole's grip, `sw` of the way through swallowing it: swung up on its far end so its
// torn end lifts towards the hole, and drawn in after it.
fn df_grip(P0: DfPose, sw: f32, H: vec3<f32>) -> DfPose {
    var P = P0;
    let be = 0.11 * sw * sw;
    let a = P0.a * cos(be) - P0.u * sin(be);
    let u = P0.u * cos(be) + P0.a * sin(be);
    let far = P0.o + P0.a * 560.0;
    P.a = a;
    P.u = u;
    P.o = far - a * (560.0 + 70.0 * sw * sw);
    P.hl = df_local(P, H);
    return P;
}
// Where a point of the wreck torn off at `p0` (camera-relative) is, `u` of the way through its fall into the hole at
// `H`: already moving as it comes away, faster and faster (bh_fall), settling into the disk's plane (normal `nd`) as it goes, and swung
// round the way the disk turns, faster the nearer it gets (`spin`: how much it had to start with).
const DF_FALL_U0: f32 = 0.3;
const DF_FALL_K: f32 = 1.0649;      // 1 / (1 - DF_FALL_U0^2)^(2/3)
fn df_fall_pt(p0: vec3<f32>, H: vec3<f32>, nd: vec3<f32>, u: f32, spin: f32) -> vec3<f32> {
    let rel = p0 - H;
    let r0 = length(rel);
    let z0 = dot(rel, nd);
    let e1 = normalize(rel - nd * z0 + vec3<f32>(1.0e-4));
    let e2 = cross(nd, e1);
    // (already falling as it is torn off: it comes away moving, its fall taken up part way through, from as far out as
    // makes it start where it was)
    let r = bh_fall(r0 * DF_FALL_K, DF_FALL_U0 + (1.0 - DF_FALL_U0) * u);
    let z = z0 * pow(r / r0, 1.5);
    let th = spin * (sqrt(r0 / max(r, 6.0)) - 1.0);
    return H + (e1 * cos(th) + e2 * sin(th)) * sqrt(max(r * r - z * z, 0.0)) + nd * z;
}
fn df_sec_spin(k: i32) -> f32 {
    return select(0.06, 0.3, k % 3 == 1) * (0.7 + 0.6 * fh21(vec2<f32>(f32(k), 9.0)));
}
// Section `k` torn off the wreck (`R` what is left of it), `age` seconds since, all of it gone in 1.25 `dur`. Its near
// end (towards the hole) falls in first, its far end after it (further out, it takes longer to fall), so the
// section is drawn out between them along the way in, its length pointing at the hole, thinner as it stretches and
// narrowing to its near end as it is pulled in; nothing of it inside the horizon (`rs`). Turning only about its length.
// `pull` how far through its fall its far end is.
fn df_section(R: DfPose, k: i32, age: f32, dur: f32, H: vec3<f32>, nd: vec3<f32>, rs: f32) -> DfPose {
    var P = R;
    let fk = f32(k);
    let x0 = -370.0 + 930.0 / f32(DF_SEC) * fk;
    let x1 = x0 + 930.0 / f32(DF_SEC);
    let A0 = df_world(R, vec3<f32>(x0, 75.0, 0.0));
    let B0 = df_world(R, vec3<f32>(x1, 75.0, 0.0));
    let ra = length(A0 - H);
    let rb = length(B0 - H);
    // (its far end falls in close behind its near end, so it is never left hanging once that has gone)
    let lag = min(pow(rb / ra, 0.6), 1.25);
    let s = max(age, 0.0) * lag / (1.25 * dur);
    let spin = df_sec_spin(k);
    let A = df_fall_pt(A0, H, nd, s, spin);
    let B = df_fall_pt(B0, H, nd, s / lag, spin);
    let ab = B - A;
    let len = max(length(ab), 1.0);
    let a = ab / len;
    let hand = sign(dot(cross(R.a, R.u), R.d));
    let u = rot_axis(normalize(R.u - a * dot(R.u, a) + vec3<f32>(0.0, 1.0e-4, 0.0)), a, (0.4 + 0.8 * fh21(vec2<f32>(fk, 3.0))) * s * s);
    P.a = a;
    P.u = u;
    P.d = cross(a, u) * hand;
    let kx = len / (x1 - x0);
    let wa = pow(saturate(length(A - H) / ra), 0.6);
    let wb = pow(saturate(length(B - H) / rb), 0.6);
    let thin = inverseSqrt(max(kx, 1.0));
    P.s = vec3<f32>(kx, max(wb, 0.02) * thin, max(wb, 0.02) * thin);
    P.tz = clamp(wa / max(wb, 0.02), 0.12, 0.999);
    P.px = x0;
    P.o = A - a * x0 - u * (75.0 * P.s.y);
    P.x0 = x0;
    P.x1 = x1;
    P.hl = df_local(P, H);
    P.eat = rs;
    P.pull = s / lag;
    return P;
}

// What is up on the roof too thin to trace: each battery's twin barrels (raised as it charges, scorched once it has
// fired), and the masts and antennae along the roof's edges and over the bow, their lights blinking while it has power.
// Each is a capsule, met where the view ray passes closest to it (coverage from how near, kept a pixel wide far off,
// shaded as a cylinder), nearer than `tmax`: their colour, how much of the pixel they cover, how far, and the lights' glare.
struct DfRig {
    c: vec3<f32>,
    w: f32,
    t: f32,
    glow: vec3<f32>,
}
fn df_rig(P: DfPose, rd: vec3<f32>, tmax: f32, time: f32, boost: f32, haze: vec3<f32>, day: f32, sun: vec3<f32>) -> DfRig {
    var out: DfRig;
    out.c = vec3<f32>(0.0);
    out.w = 0.0;
    out.t = 1.0e9;
    out.glow = vec3<f32>(0.0);
    let o = df_local(P, vec3<f32>(0.0));
    let v = vec3<f32>(dot(rd, P.a), dot(rd, P.u), dot(rd, P.d));
    let sl = vec3<f32>(dot(sun, P.a), dot(sun, P.u), dot(sun, P.d));
    // (only where the ray passes through the band over the roof)
    let iv = 1.0 / select(v, vec3<f32>(1.0e-6), abs(v) < vec3<f32>(1.0e-6));
    let bx0 = (vec3<f32>(-580.0, MS_TOP, -330.0) - o) * iv;
    let bx1 = (vec3<f32>(580.0, MS_TOP + 60.0, 330.0) - o) * iv;
    let t0 = max(max(max(min(bx0.x, bx1.x), min(bx0.y, bx1.y)), min(bx0.z, bx1.z)), 0.0);
    let t1 = min(min(min(max(bx0.x, bx1.x), max(bx0.y, bx1.y)), max(bx0.z, bx1.z)), tmax);
    if (t1 <= t0) {
        return out;
    }
    // (what of the roof the ray passes over: only what stands there is looked at)
    let pa = o + v * t0;
    let pb = o + v * t1;
    let lo = min(pa, pb) - vec3<f32>(30.0, 0.0, 30.0);
    let hi = max(pa, pb) + vec3<f32>(30.0, 0.0, 30.0);
    let pix = 2.0 / (frame.projection[1][1] * frame.resolution.y);
    var best = tmax;
    let burnt = smoothstep(DF_FIRE0, DF_FIRE1, time);
    for (var ii = 0; ii < 32; ii = ii + 1) {
        var A = vec3<f32>(0.0);
        var B = vec3<f32>(0.0);
        var r = 1.2;
        var light = 0.0;
        // (24 barrels, two to each battery, then the masts)
        let i = select(ii - 12, ii / 2, ii < 24);
        if (ii < 24) {
            // a battery's barrels: two to each, out of its face, laid on the meteor, kicked back as they fire
            let c2 = df_bat_c(i);
            df_lay();
            let ae = df_aims[i];
            let fw = vec2<f32>(cos(ae.x), sin(ae.x));
            let pv = c2 + fw * 8.4 * DF_TS / 1.4;
            let base = vec3<f32>(pv.x, MS_TOP + 7.5, pv.y);
            if (any(base.xz < lo.xz) || any(base.xz > hi.xz)) {
                continue;
            }
            let dir = vec3<f32>(cos(ae.y) * fw.x, sin(ae.y), cos(ae.y) * fw.y);
            let across = vec3<f32>(-fw.y, 0.0, fw.x);
            let ph = fract(f32(i) * 0.618034) * DF_PERIOD;
            let since = time - DF_FIRE0 - ph;
            let shot = since - DF_PERIOD * floor(since / DF_PERIOD);
            let kick = select(0.0, 4.0 * exp(-shot * 6.0), since > 0.0 && time < DF_FIRE1 + 0.5);
            A = base - dir * kick;
            B = A + dir * DF_BARREL;
            r = 1.4;
            let sgn = select(-1.0, 1.0, ii % 2 == 0);
            let mid = base + dir * (DF_BARREL * 0.5) + across * 3.0 * sgn - o;
            let tq = dot(mid, v);
            if (tq < 0.0 || length(mid - v * tq) > DF_BARREL * 0.5 + 8.0) {
                continue;
            }
            A = A + across * 3.0 * sgn;
            B = B + across * 3.0 * sgn;
            light = -1.0;
        } else {
            // a mast: tall and thin, a yard across it, a light on top; the bow's is the tallest
            let j = i - 12;
            let side = select(-1.0, 1.0, j % 2 == 0);
            let x = select(-470.0 + 125.0 * f32(j), 455.0, j == 7);
            let h = select(20.0 + 16.0 * fh21(vec2<f32>(f32(j), 5.0)), 52.0, j == 7);
            let z = select(side * (ms_half_w(x) - 9.0), 0.0, j == 7);
            A = vec3<f32>(x, MS_TOP, z);
            B = A + vec3<f32>(0.0, h, 0.0);
            if (any(A.xz < lo.xz) || any(A.xz > hi.xz)) {
                continue;
            }
            r = 0.55;
            let mid = A + vec3<f32>(0.0, h * 0.5, 0.0) - o;
            let tq = dot(mid, v);
            if (tq < 0.0 || length(mid - v * tq) > h * 0.5 + 8.0) {
                continue;
            }
            light = 1.0 + f32(j);
        }
        if (df_plan(P, A).z > 0.0) {
            continue;
        }
        // (in the hull's frame, from the eye)
        let Aw = A - o;
        let Bw = B - o;
        var q = ray_seg(v, Aw, Bw);
        var rr = r;
        if (light < 0.0) {
            // the muzzle brake at its end
            let qb = ray_seg(v, Bw - normalize(Bw - Aw) * 3.5, Bw);
            if (qb.x - 2.0 < q.x - rr) {
                q = qb;
                rr = 2.0;
            }
        }
        if (light > 0.0) {
            // the yard across the mast's top
            let ax2 = vec3<f32>(0.0, 0.0, 4.0);
            let Y = Bw - (Bw - Aw) * 0.12;
            let qy = ray_seg(v, Y - ax2, Y + ax2);
            if (qy.x < q.x) {
                q = qy;
                rr = 0.4;
            }
        }
        let pw = max(q.y * pix, 1.0e-4);
        let cov = (1.0 - smoothstep(rr - 0.5 * pw, rr + 0.5 * pw, q.x)) * min(1.0, 2.0 * rr / pw);
        if (cov <= 0.002 || q.y > best) {
            if (light > 0.0) {
                // its light, glaring a little past it
                let tl = dot(Bw, v);
                let dl = length(Bw - v * tl);
                let on = step(0.6, fract(time * 0.8 + light * 0.37)) * min(boost * 2.0, 1.0) * f32(time < DF_GROAN + 2.0 + light * 0.5);
                if (tl > 0.0 && tl < tmax) {
                    out.glow = out.glow + select(vec3<f32>(3.5, 0.5, 0.3), ship_tint(vec3<f32>(2.5, 3.2, 2.5)), light > 7.5) * exp(-pow(dl / max(0.8, tl * pix * 1.5), 2.0)) * on * 2.0;
                }
            }
            continue;
        }
        best = q.y;
        // shaded as a cylinder: its normal from how far across it the ray passes, round towards the eye
        let P0 = v * q.y;
        let ax_ = normalize(Bw - Aw);
        let C = Aw + ax_ * dot(P0 - Aw, ax_);
        let pr = P0 - C;
        let side_ = pr - ax_ * dot(pr, ax_);
        let f = saturate(q.x / rr);
        let tow = normalize(-v - ax_ * dot(-v, ax_));
        let nl = normalize(side_ / max(length(side_), 1.0e-4) * f + tow * sqrt(1.0 - f * f));
        var tone = 0.5;
        if (light < 0.0) {
            // scorched towards the muzzle once it has fired
            tone = 0.55 * (1.0 - 0.6 * burnt * smoothstep(0.5, 1.0, q.z));
        }
        out.c = mix(out.c, df_metal(nl, v, sl, haze, day, tone, 0.3), cov);
        out.w = max(out.w, cov);
        out.t = q.y;
    }
    return out;
}

// A running light on some of the spine's sections (at `q`, its section `sec_`), dying with the power (`bl`).
fn emit_spine(c: ptr<function, vec3<f32>>, q: vec2<f32>, sec_: f32, ts: f32, bl: f32, fp: f32) {
    let lx = (sec_ + 0.5) * 90.0;
    let d = length(vec2<f32>(q.x - lx, abs(q.y) - 12.0));
    let on = step(0.45, fh21(vec2<f32>(sec_, 77.0)));
    let blink = step(0.7, fract(ts * 0.6 + sec_ * 0.23));
    *c = *c + vec3<f32>(3.2, 0.5, 0.3) * ms_line(d, 0.9, fp) * on * (0.3 + 1.7 * blink) * min(bl * 2.0, 1.0);
}
// Dark metal in the hull's frame (normal `n`, view `v`, sun `sl`): it mirrors the land and the sky, sharply where it is
// smooth, blurred where it is `rough`, more the more glancing the look; lit by the sun, and where smooth catching a glint
// of it. `tone` how bright it is.
fn df_metal(n: vec3<f32>, v: vec3<f32>, sl: vec3<f32>, haze: vec3<f32>, day: f32, tone: f32, rough: f32) -> vec3<f32> {
    let r = reflect(v, n);
    let cosv = max(dot(-v, n), 0.0);
    let fres = 0.3 + 0.7 * pow(1.0 - cosv, 5.0);
    let grey = mix(haze, vec3<f32>(luminance(haze)), 0.65);
    let env = mix(ms_env(r, haze, sl, day), grey * 0.55 + vec3<f32>(0.05, 0.05, 0.045) * day, rough * 0.85);
    let sun_c = vec3<f32>(1.0, 0.92, 0.8) * 2.5 * day * step(0.0, sl.y);
    let ndl = max(dot(n, sl), 0.0);
    let glint = sun_c * pow(max(dot(r, sl), 0.0), mix(300.0, 20.0, rough)) * (1.0 - rough) * ndl * 3.0;
    let metal = vec3<f32>(0.42, 0.43, 0.44) * tone;
    return metal * (env * fres + glint) + metal * (sun_c * 0.07 * ndl + grey * 0.06);
}

// The roof, seen once the ship rolls, falls and lies buried (plan `q`, `t` away, the view `v` and the sun `sl` in its
// frame): heavy armour laid in long courses out from the spine, each course's lip over the next, each plate its own
// tone, tilt and wear, their joints staggered; conduits along the spine; hatches, vent grilles, radiator fields and
// sensor domes let into it; rows of lit windows in districts along the lips (`bl` its lights, failing with the power);
// a gutter and rim along its edges with running lights; soot over the engines, grime trailing aft from everything, and
// once it has crashed, soil thrown over it. Every pattern fades to its average where a pixel covers it.
fn df_roof(q: vec2<f32>, t: f32, v: vec3<f32>, sl: vec3<f32>, haze: vec3<f32>, day: f32, ts: f32, bl: f32) -> vec3<f32> {
    let pix = 2.0 / (frame.projection[1][1] * frame.resolution.y);
    let fp = max(t * pix / max(abs(v.y), 0.15), 0.02);
    let af = saturate(1.5 - fp / 1.5);          // fine detail's weight
    let am = saturate(2.0 - fp / 5.0);          // middling detail's
    let ay = abs(q.y);
    let sd = sign(q.y);
    let e = ms_half_w(q.x) - ay;
    let ed = -ms_outline(q, 0.0);               // in from the roof's edge
    var tone = 0.6;
    var rough = 0.5;
    var nx = 0.0;
    var nz = 0.0;
    var emit = vec3<f32>(0.0);
    // the armour courses, out from the spine
    let cw = 36.0;
    let cz = max(ay - 54.0, 0.0) / cw;
    let ci = floor(cz);
    let cf = fract(cz);
    let pl_len = 40.0 + 30.0 * fh21(vec2<f32>(ci, 3.0 + sd));
    let pxx = q.x / pl_len + 0.37 * ci + fh21(vec2<f32>(ci, sd));
    let pi = floor(pxx);
    let pf = fract(pxx);
    let hv = vec3<f32>(pcg3d(bitcast<vec3<u32>>(vec3<i32>(i32(pi), i32(ci), i32(sd) + 7)))) * (1.0 / 4294967295.0);
    if (ay < 54.0) {
        // conduits beside the spine: bundles of pipes along it, clamped every so often
        let pp = fract(ay / 3.2);
        nz = (pp - 0.5) * 1.2 * sd * af;
        tone = 0.42 + 0.25 * (1.0 - abs(pp - 0.5) * 2.0) * af;
        let clamp_ = 1.0 - smoothstep(0.8, 0.8 + fp, abs(fract(q.x / 14.0) - 0.5) * 14.0);
        tone = mix(tone, 0.75, clamp_ * af);
        rough = 0.35;
    } else {
        tone = 0.5 + 0.18 * hv.x;
        rough = 0.25 + 0.45 * hv.y;
        nx = (hv.z - 0.5) * 0.07;
        nz = (hv.y - 0.5) * 0.07 + 0.05 * sd;   // each course tilted a little down to its lip
        // the lip of the course further in casting a shadow over this one's inner edge, this one's own lip catching
        // the light at its outer edge; the joints between its plates
        let shadow = exp(-cf * cw / max(2.5, fp * 0.7));
        let lip = exp(-(1.0 - cf) * cw / max(0.8, fp * 0.7)) * min(1.0, 1.6 / max(fp, 0.4));
        tone = tone * (1.0 - 0.5 * shadow) + 0.55 * lip;
        let jd = min(pf, 1.0 - pf) * pl_len;
        tone = tone * (1.0 - 0.6 * (1.0 - smoothstep(0.25, 0.25 + fp, jd)) * min(1.0, 0.6 / max(fp, 0.3)));
        // rivets along the joints
        let rv = length(vec2<f32>(jd - 1.2, (fract(q.y / 2.0) - 0.5) * 2.0));
        tone = tone + 0.25 * (1.0 - smoothstep(0.3, 0.3 + fp, rv)) * af;
        // what is let into some plates
        let lq = vec2<f32>((pf - 0.5) * pl_len, (cf - 0.5) * cw);
        if (hv.x > 0.86 && e > 30.0) {
            // a hatch: a heavy square lid in a frame, its hinge side darker, a handle
            let b = max(abs(lq.x), abs(lq.y)) - 5.0;
            tone = mix(tone, 0.25, (1.0 - smoothstep(0.0, 0.5 + fp, abs(b))) * am);
            tone = mix(tone, tone * 1.15 - 0.08 * step(lq.x, -3.5), step(b, 0.0) * am);
            tone = mix(tone, 0.85, (1.0 - smoothstep(0.3, 0.3 + fp, length(lq - vec2<f32>(2.8, 0.0)))) * af);
        } else if (hv.x > 0.74 && e > 30.0) {
            // a vent grille: slots across it, dark inside, warm air shimmering out of the hot ones while it has power
            let inb = step(abs(lq.x), pl_len * 0.3) * step(abs(lq.y), 6.0);
            let slot = 1.0 - smoothstep(0.25, 0.25 + fp, abs(fract(lq.x / 1.6) - 0.5) * 1.6 - 0.35);
            tone = tone * mix(1.0, mix(0.35, 0.65, 1.0 - af), inb * slot * am + inb * (1.0 - am) * 0.35);
            emit = emit + vec3<f32>(1.2, 0.5, 0.15) * inb * slot * step(0.95, hv.y) * bl * 0.12 * af * af;
        } else if (hv.x < 0.08) {
            // a sensor dome, mirroring the sky round it
            let dd = length(lq);
            if (dd < 3.5) {
                let dv = lq / 3.5;
                nx = dv.x;
                nz = dv.y;
                tone = 1.1;
                rough = 0.08;
            } else {
                tone = tone * (1.0 - 0.45 * (1.0 - smoothstep(0.0, 0.6 + fp, abs(dd - 4.2))) * am);
            }
        }
        // radiator fields: banks of fins across whole stretches of the courses
        let fc = vec2<f32>(floor(q.x / 110.0), ci);
        if (fh21(fc + vec2<f32>(13.0, 29.0 + sd)) > 0.72 && e > 30.0 && abs(fract(q.x / 110.0) - 0.5) < 0.38 && cf > 0.15 && cf < 0.85) {
            let fin = fract(ay / 2.2 + 0.25 * sign(v.z * sd));
            tone = mix(tone, mix(0.32, 0.32 + 0.5 * smoothstep(0.2, 0.8, fin), af), am);
            rough = 0.55;
        }
        // windows: rows of small lights along the lips in districts, lit and dark, like the belly's
        let dist_ = fh21(vec2<f32>(floor(q.x / 85.0), ci + sd * 31.0) + vec2<f32>(3.0, 17.0));
        let wx = floor(q.x / 2.5);
        let wh = fh21(vec2<f32>(wx, ci + sd * 17.0) + vec2<f32>(41.0, 5.0));
        if (dist_ > 0.55 && wh > 0.55 && cf > 0.86) {
            let d = length(vec2<f32>(q.x - wx * 2.5 - 1.25, (cf - 0.93) * cw));
            let flick = 0.6 + 0.4 * step(0.2, fract(wh * 13.0 + floor(ts * 0.5) * 0.37));
            emit = emit + mix(vec3<f32>(0.55, 1.5, 0.6), vec3<f32>(1.4, 1.3, 1.0), step(0.85, wh)) * ms_line(d, 0.4, fp) * flick * bl * 0.55;
        }
    }
    // the gutter and rim along the long edges: a dark channel, drain grates, the rim's lip catching the light
    if (ed < 26.0) {
        let gut = smoothstep(4.0, 6.0, ed) * (1.0 - smoothstep(18.0, 20.0, ed));
        let grate = 1.0 - smoothstep(0.3, 0.3 + fp, abs(fract(q.x / 1.5) - 0.5) * 1.5 - 0.3);
        tone = mix(tone, mix(0.3 + 0.2 * grate, 0.38, 1.0 - af), gut);
        tone = tone + 0.6 * (1.0 - smoothstep(0.0, 1.5 + fp, ed)) + 0.35 * exp(-abs(ed - 20.0) / max(0.6, fp));
        rough = mix(rough, 0.6, gut);
        // running lights along it, on all along with any power at all
        let cx = floor(q.x / 40.0);
        let lx = cx * 40.0 + 20.0;
        let d = length(vec2<f32>(q.x - lx, ed - 12.0));
        let blink = step(0.82, fract(ts * 0.9 - cx * 0.11));
        let rc = select(vec3<f32>(0.4, 2.6, 0.5), vec3<f32>(0.08, 1.1, 0.18), q.y > 0.0);
        emit = emit + mix(rc, vec3<f32>(3.5, 4.0, 3.5), blink) * ms_line(d, 1.0, fp) * (0.6 + 1.4 * blink) * min(bl * 2.0, 1.0);
    }
    // weathering: whole stretches lighter or darker, grime trailing aft from everything, soot over the engines
    tone = tone * (0.82 + 0.3 * gnoise2(q * 0.007 + vec2<f32>(3.1, 7.7)));
    let streak = smoothstep(0.5, 0.8, gnoise2(vec2<f32>(q.x * 0.012, q.y * 0.32)));
    tone = tone * (1.0 - 0.35 * streak * am);
    tone = tone * mix(1.0, 0.35 + 0.3 * gnoise2(q * 0.05), smoothstep(-420.0, -540.0, q.x));
    // shadowed round the batteries' barbettes where they stand on it
    tone = tone * (1.0 - 0.6 * exp(-max(df_ring(q), 0.0) / 7.0));
    var c = df_metal(normalize(vec3<f32>(nx, 1.0, nz)), v, sl, haze, day, tone, rough);
    // the soil thrown over it as it ploughed in, heaped deepest along its edges
    if (ts > DF_FALL1) {
        let soil = smoothstep(0.55, 0.7, gnoise2(q * 0.018 + vec2<f32>(5.0, 1.0)) + 0.35 * (1.0 - smoothstep(0.0, 120.0, ed)) - 0.1)
            * smoothstep(DF_FALL1, DF_FALL1 + 2.0, ts);
        let sc = vec3<f32>(0.075, 0.058, 0.04) * (0.75 + 0.5 * gnoise2(q * 0.35)) * (0.25 + 0.75 * day);
        c = mix(c, sc * (0.5 + 0.5 * max(sl.y, 0.0)), soil * 0.85);
    }
    let hz = 1.0 - exp(-t / 3000.0);
    return mix(c, haze * 0.6, hz * 0.35) + ship_tint(emit) * exp(-t / 3000.0);
}


// The hull's colour where a ray (`rd`, world) met it in pose `P` at `ts`: the Mothership's plating and lights in its own
// frame, its roof, spine and batteries, and what the downfall does to it: the meteor's hits burning through it, its
// stern crumpling as the engine fails, the black hole's light on it and its torn sections laid open as it is drawn in.
fn df_shade(h: MsHit, P: DfPose, g: DfGeo, rd: vec3<f32>, X: vec3<f32>, ts: f32, lit: f32, chase_on: f32, core: f32, focus: vec3<f32>, haze: vec3<f32>,
            day: f32, sun: vec3<f32>, boost: f32, wake: f32, eng: f32, groan: f32, ht0: vec3<f32>, ht1: vec3<f32>) -> vec3<f32> {
    let v = vec3<f32>(dot(rd, P.a), dot(rd, P.u), dot(rd, P.d));
    let sl = vec3<f32>(dot(sun, P.a), dot(sun, P.u), dot(sun, P.d));
    let fl = vec3<f32>(dot(focus, P.a), dot(focus, P.u), dot(focus, P.d));
    var f0: MsFrame;
    f0.ax = vec2<f32>(1.0, 0.0);
    f0.sd = vec2<f32>(0.0, 1.0);
    var c = vec3<f32>(0.0);
    let q = h.q;
    // its lights after the crash: on here and there, then failing section by section from the stern, each with a last
    // flare, until none is left
    var bl = boost;
    if (ts > DF_FALL1) {
        let sec = floor((q.x + 560.0) / 70.0);
        let tf = DF_GROAN + 5.8 * (0.25 * fh21(vec2<f32>(sec, sign(q.y) + 5.0)) + 0.75 * (q.x + 560.0) / 1120.0);
        bl = 0.35 * f32(ts < tf) * (0.55 + 0.45 * step(0.3, fh21(vec2<f32>(sec, floor(ts * 7.0))))) + 2.0 * exp(-pow((ts - tf) / 0.08, 2.0));
    }
    let pix = 2.0 / (frame.projection[1][1] * frame.resolution.y);
    if (h.kind == 9) {
        let fp = max(h.t * pix / 0.5, 0.02);
        let af = saturate(1.5 - fp / 1.5);
        let top = h.h > MS_TOP + 11.5;
        let hs = df_house(q);
        // scorched by its own firing, and blackened more where the meteor's pieces struck near it
        let burnt = smoothstep(DF_FIRE0, DF_FIRE1, ts);
        let ring = df_ring(q);
        if (h.h < MS_TOP + DF_RING_H + 0.05 && ring < 0.8) {
            // its barbette: an armoured ring let into the roof, bolted round its rim, dark in the gap the house turns in
            // and down where it meets the plating
            let dq = q - df_bat_c(i32(hs.w));
            let ang = atan2(dq.y, dq.x);
            var tone = 0.46;
            var n = vec3<f32>(0.0, 1.0, 0.0);
            if (ring < -0.2) {
                let lip = 1.0 - smoothstep(0.0, 1.2 + fp, -ring);
                tone = tone + 0.25 * lip;
                let bolt = length(vec2<f32>((fract(ang / TAU * 48.0) - 0.5) * TAU * (DF_RING_R - 1.6) / 48.0, -ring - 1.6));
                tone = tone + 0.3 * (1.0 - smoothstep(0.25, 0.25 + fp, bolt)) * af;
                tone = tone * (0.3 + 0.7 * smoothstep(0.0, 2.5, max(hs.z, 0.0)));
            } else {
                n = vec3<f32>(dq.x, 0.0, dq.y) / max(length(dq), 1.0e-3);
                let sf = fract(ang / TAU * 36.0);
                tone = tone * (1.0 - 0.35 * (1.0 - smoothstep(0.1, 0.1 + fp, min(sf, 1.0 - sf) * TAU * DF_RING_R / 36.0)) * af);
                tone = tone * (0.4 + 0.6 * smoothstep(MS_TOP, MS_TOP + 1.6, h.h));
            }
            c = df_metal(n, v, sl, haze, day, tone * (1.0 - 0.4 * burnt), 0.4);
        } else if (hs.z < 0.8) {
            // a battery: an armoured house turned on its ring towards the meteor; plates in panels round it, a band of
            // vents low down, a slit glowing green along its face as it fires; on its roof the plates' seams, hatches,
            // a cupola, a rangefinder across its back, and soot blown back over it from the barrels
            let r = hs.xy;
            var tone = 0.5 + 0.1 * fh21(vec2<f32>(hs.w, 3.0));
            var n = vec3<f32>(0.0, 1.0, 0.0);
            var glow = vec3<f32>(0.0);
            let fpt = fp / DF_TS;
            if (top) {
                let seam = min(abs(fract(r.x / 5.0) - 0.5) * 5.0, abs(abs(r.y) - 4.0));
                let cup = abs(length(r - vec2<f32>(-5.0, 4.0)) - 2.2);
                let hatch = abs(max(abs(r.x - 1.0), abs(r.y + 3.5)) - 1.8);
                let rf = max(abs(r.x + 9.0) - 0.8, abs(r.y) - 9.5);
                tone = tone * (1.0 - 0.3 * (1.0 - smoothstep(0.15, 0.15 + fpt, seam)) * af);
                tone = tone * (1.0 - 0.45 * (1.0 - smoothstep(0.3, 0.3 + fpt, min(cup, hatch))) * af);
                tone = mix(tone, 0.2, (1.0 - smoothstep(0.0, fpt, rf)) * af);
                tone = tone * (1.0 - 0.55 * burnt * (1.0 - smoothstep(2.0, 10.0, length(r - vec2<f32>(9.0, 0.0)))));
            } else {
                // its walls: the normal from its outline
                let e = 0.3;
                let gx = df_house(q + vec2<f32>(e, 0.0)).z - df_house(q - vec2<f32>(e, 0.0)).z;
                let gz = df_house(q + vec2<f32>(0.0, e)).z - df_house(q - vec2<f32>(0.0, e)).z;
                n = normalize(vec3<f32>(gx, 0.0, gz) + vec3<f32>(0.0, 1.0e-4, 0.0));
                let ang = atan2(r.y, r.x);
                let pan = abs(fract((r.x + abs(r.y)) / 4.0) - 0.5) * 4.0;
                tone = tone * (1.0 - 0.35 * (1.0 - smoothstep(0.12, 0.12 + fpt, pan)) * af);
                let band = step(abs(h.h - MS_TOP - 5.0), 1.2);
                tone = tone * mix(1.0, 0.45 + 0.4 * step(0.5, fract(ang / TAU * 70.0)), band * af);
                tone = tone * (1.0 - 0.5 * burnt * smoothstep(0.4, 0.8, gnoise2(vec2<f32>(ang * 6.0, h.h * 0.15))) * smoothstep(MS_TOP + 2.0, MS_TOP + 12.0, h.h));
                // its foot: shadowed down by the barbette, a dark join where it turns on it
                tone = tone * (0.5 + 0.5 * smoothstep(MS_TOP + DF_RING_H, MS_TOP + DF_RING_H + 2.5, h.h));
                tone = tone * (1.0 - 0.7 * (1.0 - smoothstep(0.2, 0.2 + fp, abs(h.h - MS_TOP - DF_RING_H - 0.4))));
                let face = step(7.0, r.x) * (1.0 - smoothstep(0.6, 0.6 + fp, abs(h.h - MS_TOP - 10.0))) * step(abs(r.y), 5.5);
                glow = ship_tint(vec3<f32>(0.6, 3.5, 1.0)) * face * (0.15 + 0.8 * lit);
            }
            c = df_metal(n, v, sl, haze, day, tone, 0.3 + 0.3 * f32(top)) + glow;
        } else {
            // the spine: ribbed along its top, a vent strip down its middle, conduits along its sides; ribs and a
            // band of hatches down its walls
            var tone = 0.52;
            var n = vec3<f32>(0.0, 1.0, 0.0);
            let rib = abs(fract(q.x / 6.0) - 0.5) * 6.0;
            if (top) {
                let sec_ = floor(q.x / 90.0);
                let w = 34.0 + 14.0 * fh21(vec2<f32>(sec_, 71.0));
                let ay = abs(q.y);
                tone = tone * (1.0 - 0.35 * (1.0 - smoothstep(0.5, 0.5 + fp, rib)) * af * step(ay, w - 10.0));
                let vent = step(ay, 5.0) * (1.0 - smoothstep(0.25, 0.25 + fp, abs(fract(q.x / 1.4) - 0.5) * 1.4 - 0.3));
                tone = mix(tone, 0.18, vent * af + step(ay, 5.0) * (1.0 - af) * 0.4);
                let pp = fract((w - ay) / 2.6);
                let pipes = step(w - 10.0, ay);
                n = normalize(vec3<f32>(0.0, 1.0, (pp - 0.5) * 1.2 * sign(q.y) * pipes * af));
                tone = mix(tone, 0.38 + 0.3 * (1.0 - abs(pp - 0.5) * 2.0), pipes * af);
                // a light on some of its sections, dying with the power
                emit_spine(&c, q, sec_, ts, bl, fp);
            } else {
                // (a wall: its normal across the spine or along it)
                let sec_ = floor(q.x / 90.0);
                let w = 34.0 + 14.0 * fh21(vec2<f32>(sec_, 71.0));
                let along = abs(abs(q.x - (sec_ + 0.5) * 90.0) - 42.0) < abs(abs(q.y) - w);
                n = select(vec3<f32>(0.0, 0.0, sign(q.y)), vec3<f32>(sign(q.x - (sec_ + 0.5) * 90.0), 0.0, 0.0), along);
                let u_ = select(q.x, q.y, along);
                let wr = abs(fract(u_ / 4.0) - 0.5) * 4.0;
                tone = tone * (1.0 - 0.4 * (1.0 - smoothstep(0.4, 0.4 + fp, wr)) * af);
                let band = step(abs(h.h - MS_TOP - 7.0), 1.8);
                let hatch = step(0.6, fh21(vec2<f32>(floor(u_ / 8.0), sec_)));
                tone = tone * mix(1.0, 0.4, band * hatch * af);
            }
            c = c + df_metal(n, v, sl, haze, day, tone * (1.0 - 0.3 * burnt * smoothstep(0.5, 0.8, gnoise2(q * 0.03))), 0.4);
        }
    } else if (h.kind == 2 && h.h >= MS_TOP - 0.01) {
        c = df_roof(q, h.t, v, sl, haze, day, ts, bl);
    } else {
        c = ms_hull(h, f0, v, ts, lit, chase_on, core, 0.0, fl, haze, day, sl, bl, wake, eng);
    }
    // the hits: craters burning through the plating, scorched round, and fire breaking out through its belly under them
    for (var j = 0; j < 6; j = j + 1) {
        let e = df_hit_l(j, g.mz);
        let age = ts - select(ht1[max(j - 3, 0)], ht0[min(j, 2)], j < 3);
        if (age <= 0.0 || q.x > -60.0) {
            continue;
        }
        let dp = length(q - e.xz);
        // (on the roof, or on its batteries; the belly's and the hangar's fires come later, breaking out under them)
        let roof = h.h > MS_TOP - 0.5;
        let up = select(0.5, 1.0, roof);
        let R = (24.0 + 26.0 * (1.0 - exp(-age * 0.6))) * up;
        if (dp < R * 2.5) {
            // scorched round, glowing in the middle: the fire breathing in slow surges
            let n = gnoise2(q * 0.05 + vec2<f32>(f32(j) * 7.0, ts * 0.4));
            let core = exp(-pow(dp / (R * (0.55 + 0.3 * n)), 2.0));
            c = c * (1.0 - 0.7 * exp(-pow(dp / (R * 1.6), 2.0)));
            // the hole torn through the plating: a ragged edge of plates bent up and back, the decks under it laid
            // open in rings, dark, burning deeper in
            let rr = R * (0.62 + 0.25 * gnoise2(normalize(q - e.xz + vec2<f32>(1.0e-3)) * 3.0 + vec2<f32>(f32(j), 2.0)));
            if (dp < rr + 2.0 && roof) {
                let ring = abs(fract((rr - dp) / 6.0) - 0.5) * 6.0;
                let lipc = exp(-abs(dp - rr) / 1.2);
                let deep = saturate((rr - dp) / rr);
                let deckc = vec3<f32>(0.03, 0.028, 0.026) * (0.4 + 0.6 * smoothstep(0.4, 1.4, ring)) * (1.0 - deep * 0.7);
                c = mix(c, deckc, smoothstep(rr + 1.5, rr - 1.0, dp));
                c = c + vec3<f32>(0.12, 0.11, 0.1) * lipc * (0.3 + 0.7 * day);
            }
            let heat = core * (0.6 + 0.4 * exp(-age * 0.3)) * (0.8 + 0.25 * sin(ts * 3.0 + f32(j) * 3.0) + 0.15 * n) * select(smoothstep(1.5, 4.5, age), 1.0, roof);
            c = c + lava_ramp(0.3 + 0.65 * heat) * heat * 2.6;
        }
    }
    let lx = df_local(P, X);
    let dh = length(lx - P.hl);
    let wall = h.kind == 3 || h.kind == 5 || h.kind == 7 || h.kind == 9;
    let cq = select(q, vec2<f32>(q.x + q.y, h.h * 1.5), wall);
    if ((groan > 0.0 || P.eat > 0.0) && dh < 420.0) {
        // the stern crumpling in towards the engine as it fails: its plating folded and creased, and gaps torn open in
        // it showing the engine's glow deep inside, pulsing slowly, growing
        let w = exp(-dh * dh / 45000.0);
        let gr = max(groan, f32(P.eat > 0.0));
        let fold = abs(gnoise2(cq * 0.06 + vec2<f32>(3.0, 1.0)) - 0.5) * 2.0;
        c = c * mix(1.0, 0.3 + 0.9 * smoothstep(0.0, 0.3, fold), w * gr);
        // tears opening in it: dark holes into the hull, a deep heat glowing far down in them
        let gn = gnoise2(cq * 0.045 + vec2<f32>(11.0, 4.0));
        let th = 0.74 - 0.1 * gr * w;
        let gap = smoothstep(th, th + 0.02, gn) * w;
        let down = smoothstep(th + 0.02, th + 0.12, gn);
        let deep = vec3<f32>(1.6, 0.42, 0.08);
        let inner = deep * down * (0.25 + 0.9 * gr * gr) * (0.7 + 0.3 * sin(ts * 1.7 + dh * 0.02));
        c = mix(c, vec3<f32>(0.006) + inner, gap * min(gr * 1.5, 1.0));
    }
    if (P.x0 > -1.0e3 || P.x1 < 1.0e3) {
        // where it was torn apart: the hull's cross-section open to the sky, its decks' torn edges catching the light,
        // the bulkheads and girders between them, the rooms behind dark, a few lit by fires inside; its rim hot nearer
        // the hole
        let jag = df_jag(q.y, lx.y);
        let edge = min(abs(q.x - P.x0 - jag), abs(q.x - P.x1 - jag));
        if (edge < 6.0) {
            let pix = 2.0 / (frame.projection[1][1] * frame.resolution.y);
            let fpw = max(length(X) * pix / 0.6, 0.05);
            let hh = h.h;
            let deck = abs(fract(hh / 7.0) - 0.5) * 7.0;
            let dk = floor(hh / 7.0);
            // the bulkheads: their spacing and place their own on each deck
            let bw = 11.0 + 9.0 * fh21(vec2<f32>(dk, 5.0));
            let yb = q.y / bw + fh21(vec2<f32>(dk, 6.0));
            let cell = floor(yb);
            let bulk = abs(fract(yb) - 0.5) * bw * select(1.0, 4.0, fh21(vec2<f32>(cell, dk + 40.0)) > 0.6);
            let rh = fh21(vec2<f32>(cell, dk) + vec2<f32>(3.0, 1.0));
            // the rooms: dark, darker up under the deck above, some only gutted, now and then one burning
            let fy = fract(hh / 7.0);
            var inside = vec3<f32>(0.012, 0.012, 0.014) * (0.5 + 0.8 * fy) * (0.6 + 0.8 * rh);
            let fire = step(0.93, rh) * (0.6 + 0.4 * fvnoise(vec2<f32>(ts * 3.0 + rh * 40.0, cell)));
            inside = inside + vec3<f32>(1.1, 0.42, 0.1) * fire * (0.25 + 0.75 * (1.0 - fy)) * 0.5;
            // a brace across some of them, twisted
            let br = abs(fract(yb) - select(fy, 1.0 - fy, rh > 0.5)) * 7.0;
            let brace = (1.0 - smoothstep(0.5, 0.5 + fpw, br)) * step(0.55, fract(rh * 7.3)) * saturate(1.5 - fpw);
            // the decks' torn edges and the bulkheads: metal, lit from round the hole and the sky
            // (a deck's edge torn back in places)
            let torn_d = step(0.25, fvnoise(vec2<f32>(q.y * 0.08, dk * 3.1)));
            let fr = max((1.0 - smoothstep(0.55, 0.55 + fpw, deck)) * torn_d, (1.0 - smoothstep(0.7, 0.7 + fpw, bulk)) * 0.8);
            let fr_a = mix(fr, 0.22, smoothstep(1.5, 4.0, fpw));
            let metal = vec3<f32>(0.05, 0.05, 0.055) * (0.5 + 0.6 * day) * (0.7 + 0.6 * fh21(vec2<f32>(cell, dk + 9.0)));
            // some rooms choked with wreckage and machinery, crushed up against their decks
            let junk = step(0.55, rh) * smoothstep(0.35, 0.6, gnoise2(vec2<f32>(q.y * 0.4, hh * 0.4) + vec2<f32>(rh * 50.0)));
            inside = mix(inside, metal * (0.5 + 0.6 * gnoise2(vec2<f32>(q.y, hh) * 0.9)), junk * (1.0 - fire) * mix(1.0, 0.6, smoothstep(1.5, 4.0, fpw)));
            inside = mix(inside, metal * 0.8, max(fr_a, brace * 0.8));
            // the skin: a few blocks of armour round the outside, then the plating
            let skin = 1.0 - smoothstep(2.0, 4.0, -ms_outline(q, 0.0));
            inside = mix(inside, metal * 1.4, skin);
            c = mix(c, inside, 1.0 - smoothstep(3.5, 6.0, edge));
            // its rim, where the torn section meets the skin, glowing hot (hotter nearer the hole)
            let rim = 1.0 - smoothstep(0.0, 4.0, -ms_outline(q, 0.0));
            c = c + lava_ramp(0.55) * rim * (1.0 - smoothstep(2.0, 6.0, edge)) * 1.2 * exp(-dh / 220.0);
        }
    }
    if (P.eat > 0.0 || P.x0 > -1.0e3) {
        // in the black hole's grip: lit by its disk, heating as it nears the horizon, and there redder and dimmer, and
        // gone through it
        let sec = P.pull > 0.0;
        c = c + c * vec3<f32>(1.6, 0.8, 0.5) * 9000.0 / (dh * dh + 4000.0) + vec3<f32>(0.5, 0.22, 0.12) * 1200.0 / (dh * dh + 4000.0);
        c = c + vec3<f32>(2.4, 0.7, 0.22) * exp(-max(dh - select(max(P.eat, 20.0), P.eat * 1.3, sec), 0.0) / 14.0) * select(0.9, 0.6, sec);
        c = c * select(vec3<f32>(1.0), bh_redshift(dh, P.eat), sec);
    }
    return c;
}

fn downfall(in: StageIn) -> vec4<f32> {
    let uv = in.uv;
    let aspect = frame.resolution.x / frame.resolution.y;
    let time = now();
    let cam = frame.camera_position.xyz;
    let tgt = target_pos();
    let crel = tgt - cam;
    let k = intensity_v();
    let seed = seed_v();
    let su = u32(seed);
    let g = df_geo();
    let mode = g.mode;
    let style = arrival_style();

    // ---- timeline ---------------------------------------------------------------
    let ta = time - MS_ARRIVE;
    let present = time >= MS_ARRIVE;
    let stir = smoothstep(0.0, MS_ARRIVE, time) * f32(ta < 0.0);
    let stop = ms_stop(style);
    let wake = ta - stop;
    let arriving = ta >= 0.0 && ta < stop + MS_SHUTTER;
    let cut_t = time - DF_CUT;
    let charge = saturate((time - T_FIRE) / (DF_CUT - T_FIRE)) * f32(cut_t < 0.0);
    let conv_env = smoothstep(T_FIRE + 1.0, DF_CUT - 0.3, time) * (1.0 - smoothstep(DF_CUT, DF_CUT + 0.2, time));
    let core_env = smoothstep(T_FIRE + 1.5, DF_CUT, time) * (1.0 - smoothstep(DF_CUT, DF_CUT + 0.45, time)) * (1.0 + 0.8 * step(0.5, fract(time * 23.0)) * f32(cut_t > 0.0));
    // the batteries charged and firing
    let firing = smoothstep(DF_CUT, DF_FIRE0, time) * (1.0 - smoothstep(DF_FIRE1 + 0.4, DF_SPLIT + 1.5, time));
    let fall_u = saturate((time - DF_FALL0) / (DF_FALL1 - DF_FALL0));
    let crash_t = time - DF_FALL1;
    let crashed = crash_t > 0.0;
    let groan = smoothstep(DF_GROAN, DF_OPEN, time) * f32(time < DF_OPEN);
    let bt = time - DF_OPEN;                                    // the black hole's own clock
    let opened = bt > 0.0;
    let left = saturate((DF_LIFE - bt) / 1.6);
    let life = select(0.0, smoothstep(0.0, 0.6, bt) * pow(left, 0.4), opened);
    let ef = bt - DF_LIFE;                                      // its collapse's
    let evap = select(0.0, exp(-ef * 2.6), ef > 0.0);
    let open_ = select(0.0, exp(-bt * 9.0), opened);
    // its lights: the charge pulled out of them to the roof, browning out with each volley, failing under the hits and
    // as it falls; its engines sputtering as it goes down, its stern's bells strobing as the engine gives way
    let flick = step(0.35, fvnoise(vec2<f32>(time * 9.0, 3.0)));
    var boost = 1.0;
    if (cut_t > 0.0) {
        boost = mix(0.2, 0.8, smoothstep(0.0, 0.9, cut_t)) * (1.0 - 0.35 * firing * step(0.7, fract((time - DF_FIRE0) / DF_PERIOD)));
    }
    if (time > 15.2) {
        boost = 0.45 * (0.3 + 0.7 * flick);
    }
    if (time > DF_FALL0) {
        boost = (0.3 - 0.25 * fall_u) * flick;
    }
    if (crashed) {
        boost = 1.0;      // (df_shade fails its lights section by section)
    }
    var eng = 0.35;
    if (time > DF_FALL0) {
        eng = 0.3 + 2.2 * step(0.72, fvnoise(vec2<f32>(time * 5.0, 9.0))) * (1.0 - 0.6 * fall_u);
    }
    if (crashed) {
        // its engine's bells guttering as it fails, in uneven surges, dark at last
        eng = 0.06 + groan * (1.0 - groan) * 3.0 * step(0.55, fvnoise(vec2<f32>(time * 4.0, 2.0)));
    }
    let lit = select(charge, 0.25 + 0.5 * firing, cut_t > 0.0) * f32(time < DF_FALL0);
    let chase_on = select(charge, firing * 0.8, cut_t > 0.0);

    // ---- where things are -------------------------------------------------------
    var base: MsFrame;
    base.ax = g.h0;
    base.c = g.c;
    base.sd = vec2<f32>(-g.h0.y, g.h0.x);
    base.y0 = g.y0;
    base.shift = 0.0;
    base.sx = 1.0;
    base.sz = 1.0;
    base.sy = 1.0;
    base.px = 0.0;
    let f = ms_frame(base, time, mode, style);
    var P = df_from_ms(f, cam);
    if (time >= DF_TURN0) {
        P = df_pose(g, time, cam);
    }
    let Hw = vec3<f32>(g.ps.x, g.by + DF_HOLE_H, g.ps.y);
    let H = Hw - cam;
    // the wreck in the black hole's grip: its stern crumpling in towards the engine as it fails; once it opens, the
    // stern round it blown away at once, then the rest torn off section by section from the stern forward (`xc`, slowly
    // then faster), what is left swung round on its far end towards the hole and drawn in after it
    let sw = saturate(bt / DF_SWALLOW) * f32(opened);
    let sec_l = 930.0 / f32(DF_SEC);
    let kc = select(0, i32(floor(930.0 * pow(sw, 1.8) / sec_l)), opened);
    if (crashed) {
        P.hl = df_local(P, H);
        P.crush = 0.32 * groan * groan + 0.32 * f32(opened);
    }
    if (opened) {
        P = df_grip(P, sw, H);
        P.eat = 120.0 * smoothstep(0.0, 1.0, bt);
        P.x0 = -370.0 + sec_l * f32(kc);
    }
    let wreck_on = present && (!opened || kc < DF_SEC);
    let focus = vec3<f32>(tgt.x, base.y0 - MS_FOCUS, tgt.z) - cam;
    let mv = df_met_dir(g);
    let aim = df_hover(g, DF_TURN1, vec3<f32>(-380.0, 150.0, 0.0));
    let Bw = aim - mv * DF_LS;
    df_lay_t = time;
    df_lay_aim = aim;
    df_lay_mv = mv;
    // the hits: where each piece strikes the roof (plan xz, y height) and when
    var hits: array<vec4<f32>, 6>;
    for (var j = 0; j < 6; j = j + 1) {
        let l = df_hit_l(j, g.mz);
        hits[j] = vec4<f32>(l.x, l.y, l.z, DF_SPLIT + length(df_hover(g, DF_TURN1, l) - Bw) / DF_MV);
    }
    let c0w = vec3<f32>(g.c0.x, g.by, g.c0.y);
    let rsw = 150.0 * max(crash_t, 0.0) / (1.0 + max(crash_t, 0.0) * 0.1);   // the crash's shock running out

    // ---- the light and the sky ---------------------------------------------------
    let sun = frame.sun.xyz;
    let day = saturate(sun.y * 2.5 + 0.35);
    let haze = srgb_to_linear(saturate(frame.sky_color.rgb)) * 0.95 + vec3<f32>(0.01, 0.015, 0.03);

    // ---- the air bending: as it comes, the crash's shock along the ground, space round the hole -----------------
    let d0 = depth_at(uv);
    let sky0 = is_sky(d0);
    let p0 = cam + world_offset(uv, select(d0, 0.5, sky0));
    var off = vec2<f32>(0.0);
    if (time < 10.0) {
        off = ms_air(uv, cam, p0, sky0, stir, ta - stop, wake, base, f, time, seed, k);
    }
    if (crashed && crash_t < 7.0 && !sky0) {
        let pc = project_rel(c0w - cam);
        let m = exp(-pow((length(p0.xz - g.c0) - rsw) / 7.0, 2.0)) * exp(-crash_t * 0.35) * (1.0 - smoothstep(30.0, 70.0, abs(p0.y - g.by)));
        let dir = uv - pc.xy;
        off = off + dir / max(length(dir), 1.0e-4) * m * 0.035 * k * pc.z;
    }
    let pH = project_rel(H);
    let rs_now = DF_RS * life;
    let sdist = length((uv - pH.xy) * vec2<f32>(aspect, 1.0));
    var gw = 0.0;
    if (pH.z > 0.0) {
        if (opened && bt < 3.0) {
            gw = exp(-pow((sdist - bt * 2.0) / 0.07, 2.0)) * exp(-bt * 1.6);
            off = off + (uv - pH.xy) / max(sdist, 1.0e-4) * gw * 0.04 * k;
        }
        if (groan > 0.0 || opened) {
            // space bending round the engine: before it opens a faint warp of what lies past it, growing; once open, the
            // weak bending out past the lens's reach (what is near the hole, bh_lens bends). Light passing it at `b`
            // is turned towards it by 2 rs / b, so each pixel looks a little further in
            let rw = select(3.5 * groan * groan, rs_now, opened);
            let p11 = frame.projection[1][1];
            let b = max(length(H) * sdist * 2.0 / p11, 1.0);
            let fade_in = select(1.0, smoothstep(LENS_R * rw * 0.8, LENS_R * rw * 1.4, b) * 0.6, opened);
            let mag = min(rw * p11 / b, 0.5 * sdist) * fade_in;
            let dv = (pH.xy - uv) * vec2<f32>(aspect, 1.0) / max(sdist, 1.0e-4);
            off = off + dv * mag / vec2<f32>(aspect, 1.0) * k;
            // and only a faint shimmer of the air right round it
            let m = exp(-sdist / 0.08) * groan * groan;
            let hw = vec2<f32>(gnoise2(uv * 90.0 + vec2<f32>(0.0, time * 3.0)), gnoise2(uv * 90.0 + vec2<f32>(13.0, time * 2.6))) - 0.5;
            off = off + hw * 0.003 * m * k;
        }
    }
    let uv2 = clamp(uv + off, vec2<f32>(0.002), vec2<f32>(0.998));

    // ---- the scene --------------------------------------------------------------
    let d = depth_at(uv2);
    let sky = is_sky(d);
    let rel = world_offset(uv2, select(d, 0.5, sky));
    let scene_len = select(1.0e9, length(rel), !sky);
    let rd = normalize(world_offset(uv2, 0.5));
    let rdb = normalize(world_offset(uv, 0.5));
    let Pg = cam + rel;
    let cloud = !sky && abs(Pg.y - CLOUD_Y - 2.0) < 6.0;
    let ca = (open_ * 0.02 + evap * 0.015 + gw * 0.03) * k;
    let ca_dir = (uv2 - pH.xy) * ca;
    var col = srgb_to_linear(vec3<f32>(
        textureSampleLevel(scene_color, linear_sampler, uv2 + ca_dir, 0.0).r,
        textureSampleLevel(scene_color, linear_sampler, uv2, 0.0).g,
        textureSampleLevel(scene_color, linear_sampler, uv2 - ca_dir, 0.0).b));
    // the light: grey under the ship, the meteor lighting everything as it comes, brown under the dust after the crash,
    // drunk by the black hole
    let land = smoothstep(stop, stop + 0.3, ta) * (1.0 - smoothstep(DF_FALL1 - 2.0, DF_FALL1, time));
    let dust_env = smoothstep(DF_FALL1, DF_FALL1 + 5.0, time) * (1.0 - smoothstep(DF_END - 14.0, DF_END, time));
    let sky_env = smoothstep(DF_OPEN - 0.5, DF_OPEN + 2.5, time) * (1.0 - smoothstep(DF_OPEN + DF_LIFE + 1.0, DF_OPEN + DF_LIFE + 7.0, time));
    let met_env = smoothstep(DF_MET0 + 2.0, DF_SPLIT, time) * f32(time < DF_SPLIT);
    let dim = clamp(1.0 - (0.12 * stir + 0.14 * land + 0.18 * charge * charge + 0.3 * dust_env + 0.45 * sky_env) * k, 0.25, 1.0);
    col = col * dim * mix(vec3<f32>(1.0), vec3<f32>(1.1, 0.9, 0.75), dust_env * 0.7 * k);
    col = col * (1.0 + vec3<f32>(1.4, 0.75, 0.3) * met_env * met_env * 0.4 * k);
    // the flashes lighting the land and the sky: the meteor breaking up, the pieces striking, the crash, the rupture
    let st = time - DF_SPLIT;
    var flash = vec3<f32>(0.5, 0.4, 0.28) * select(0.0, exp(-st * 2.5), st > 0.0);
    for (var j = 0; j < 6; j = j + 1) {
        let dt = time - hits[j].w;
        flash = flash + vec3<f32>(1.4, 0.7, 0.3) * select(0.0, exp(-dt * 3.0) * 0.5, dt > 0.0);
    }
    flash = flash + vec3<f32>(1.5, 1.0, 0.6) * select(0.0, exp(-crash_t * 1.5), crashed) + vec3<f32>(1.2, 1.0, 1.8) * (open_ + evap);
    col = col * (1.0 + flash * 0.6 * k);
    if (sky) {
        let grad = pow(1.0 - uv2.y, 1.5);
        let dusty = vec3<f32>(0.2, 0.13, 0.08) + vec3<f32>(0.25, 0.14, 0.07) * grad * (0.6 + 0.6 * gfbm2(rd.xz / max(rd.y, 0.05) * 1.5 + vec2<f32>(time * 0.04, 0.0)));
        col = mix(col, dusty * (0.35 + 0.65 * day), dust_env * 0.55 * k);
        col = mix(col, bh_sky(rd, seed), sky_env * 0.65);
        let tow = max(dot(rd, normalize(df_met_head(aim, mv, min(time, DF_SPLIT)) - cam)), 0.0);
        col = col + vec3<f32>(1.6, 0.75, 0.25) * pow(tow, 14.0) * met_env * 1.4 * k;
    }

    // ---- its shadow on the land, while it is up there ---------------------------------
    if (!sky && present && time < DF_FALL1 + 1.0) {
        let ls = select(vec3<f32>(0.0, 1.0, 0.0), normalize(vec3<f32>(sun.x, max(sun.y, 0.6), sun.z)), sun.y > 0.0);
        let lo = df_local(P, rel);
        let lv = vec3<f32>(dot(ls, P.a), dot(ls, P.u), dot(ls, P.d));
        if (lo.y < 0.0) {
            let qm = df_plan(P, lo + lv * ((MS_TIER_C * 0.5 * P.s.y - lo.y) / max(lv.y, 0.2)));
            let pen = 4.0 + max(-lo.y, 0.0) * 0.012;
            col = col * (1.0 - (1.0 - smoothstep(-pen, pen, ms_tier(qm.xy, 2) + qm.z)) * (0.6 * day + 0.15) * land * k);
        }
    }
    var add = vec3<f32>(0.0);

    // ---- on the ground ------------------------------------------------------------
    if (!sky) {
        let dy = Pg.y - g.by;
        let on_ground = 1.0 - smoothstep(25.0, 40.0, dy);
        let r = length(Pg.xz - tgt.xz);
        if (charge > 0.0 || (cut_t > 0.0 && cut_t < 0.8)) {
            // the charge's glow under the eye and a ring closing in on the target, gone the moment it is cut
            let ch = select(charge, 1.0, cut_t > 0.0);
            let conv = mix(60.0, 5.0, pow(ch, 1.5));
            let gl = exp(-r / 14.0) * ch * ch * 1.4 + exp(-pow((r - conv) / 1.2, 2.0)) * ch * 1.6;
            add = add + ship_tint(vec3<f32>(0.3, 1.8, 0.45)) * gl * on_ground * select(1.0, exp(-cut_t * 7.0), cut_t > 0.0) * k;
        }
        let dustc = vec3<f32>(0.34, 0.28, 0.21) * (0.3 + 0.7 * day) * dim;
        let pw = time - (DF_FALL1 - 2.4);
        if (pw > 0.0 && pw < 9.0) {
            // the air under it blasted out along the ground as it comes down: a surge of dust racing out from under it
            let qd = df_plan(P, df_local(P, rel));
            let e = ms_outline(qd.xy, 0.0);
            let front = pw * 75.0 - 30.0;
            let dn = gfbm2(Pg.xz * 0.025 + vec2<f32>(time * 0.5, seed));
            let surge = (1.0 - smoothstep(front - 50.0, front + 15.0, e)) * (0.45 + 0.9 * dn) * (1.0 - smoothstep(4.0, 9.0, pw)) * on_ground;
            col = mix(col, dustc * (0.7 + 0.5 * dn), saturate(surge) * 0.75 * k);
        }
        if (crashed) {
            // the shock racing out from where the stern struck, the land behind it veiled in dust; the gouges glowing
            let rc = length(Pg.xz - g.c0);
            let dn = gfbm2(Pg.xz * 0.018 + vec2<f32>(time * 0.15, seed + 3.0));
            add = add + vec3<f32>(1.3, 1.0, 0.7) * exp(-pow((rc - rsw) / 6.0, 2.0)) * exp(-crash_t * 0.4) * on_ground * 2.0 * k;
            let behind = smoothstep(rsw + 6.0, rsw - 70.0, rc) * exp(-crash_t * 0.04) * on_ground;
            col = mix(col, dustc * (0.5 + 0.9 * dn), behind * (0.35 + 0.35 * dn) * k);
            let heat = df_gouge_heat(g, Pg, time);
            if (heat > 0.01) {
                let n = gfbm2(Pg.xz * 0.14 + vec2<f32>(Pg.y * 0.3, seed));
                let veins = exp(-pow((n - 0.5) / 0.07, 2.0));
                let molten = mix(veins * 0.9, 1.0, heat * heat);
                add = add + lava_ramp(heat * molten * (0.8 + 0.4 * n)) * smoothstep(0.03, 0.25, heat * molten) * 2.2 * k;
                col = col * (1.0 - 0.5 * smoothstep(0.0, 0.3, heat) * (1.0 - molten));
            }
        }
        if (opened && ef < 5.0) {
            // the land round the hole drawn in in streaks, the shockwave as it opens, lit by the disk
            let dxg = Pg.xz - g.ps;
            let rh = length(dxg);
            let ang = atan2(dxg.y, dxg.x);
            let lr = log(max(rh, 0.5));
            let near_y = on_ground / (1.0 + dy * dy / 200.0);
            let rw = bt * 65.0;
            add = add + vec3<f32>(1.1, 0.7, 1.8) * exp(-pow((rh - rw) / 3.5, 2.0)) * exp(-bt * 0.5) * near_y * 4.0 * k;
            col = col * (1.0 - exp(-pow((rh - rw + 7.0) / 5.0, 2.0)) * exp(-bt * 0.5) * near_y * 0.6);
            let arms = pow(0.5 + 0.5 * cos(4.0 * (ang - lr * 2.6) + time * 3.0), 6.0) * smoothstep(80.0, 95.0, rh) * (1.0 - smoothstep(140.0, 160.0, rh));
            add = add + vec3<f32>(0.6, 0.2, 1.1) * arms * life * near_y * 0.5 * k;
            let sa = ang - lr * 1.2;
            let flow = gfbm2(vec2<f32>(cos(sa), sin(sa)) * 9.0 + vec2<f32>(lr * 2.0 + time * 0.9, seed));
            add = add + vec3<f32>(0.5, 0.15, 0.9) * smoothstep(0.55, 0.8, flow) * smoothstep(20.0, 40.0, rh) * (1.0 - smoothstep(110.0, 170.0, rh)) * life * near_y * 0.6 * k;
            let lh = H - rel;
            col = col + col * vec3<f32>(1.8, 0.85, 0.4) * life * 9000.0 / (dot(lh, lh) + 4000.0) * k / max(dim, 0.25);
        }
    }

    // ---- the ship ----------------------------------------------------------------------
    // (once it has arrived, where the ray meets it is kept, and shaded once the sections torn off it are traced too:
    // whichever is nearest)
    var ship_t = 1.0e9;
    var dhit: MsHit;
    dhit.kind = -1;
    var dP = P;
    var dvis = 0.0;
    var dover = false;
    var dsec = false;
    if (wreck_on) {
        // averaged over the shutter while it moves fast as it arrives (as the Mothership)
        let n = select(1, 12, arriving);
        let jit = select(0.0, ign(in.position.xy), arriving);
        let film = arriving && style == 0;
        let t_film = MS_ARRIVE + floor(ta / MS_SHUTTER) * MS_SHUTTER;
        var acc = vec3<f32>(0.0);
        var cover = 0.0;
        for (var i = 0; i < n; i = i + 1) {
            let fr = (f32(i) + jit) / f32(n);
            let ts = select(time - select(0.0, MS_SHUTTER * fr, arriving), t_film + MS_SHUTTER * 0.5 * fr, film);
            if (ts < MS_ARRIVE) {
                continue;
            }
            var Pi = P;
            if (arriving) {
                Pi = df_from_ms(ms_frame(base, ts, mode, style), cam);
            }
            let hit = df_trace(Pi, vec3<f32>(0.0), rd);
            if (hit.kind < 0) {
                continue;
            }
            // behind a cloud: faint through it from under the clouds; solid under its tint from over them
            let over = cloud && cam.y > CLOUD_Y + 8.0;
            let vis = select(select(0.0, 0.3, cloud), 1.0, sky || hit.t < scene_len || over) * (1.0 - smoothstep(4000.0, 20000.0, hit.t));
            if (vis > 0.0 && !arriving) {
                dhit = hit;
                dvis = vis;
                dover = over;
                ship_t = hit.t;
            } else if (vis > 0.0) {
                // (as it arrives, unhurt: the Mothership's own shading, lighter for the shutter's twelve looks)
                var f0: MsFrame;
                f0.ax = vec2<f32>(1.0, 0.0);
                f0.sd = vec2<f32>(0.0, 1.0);
                let vl = vec3<f32>(dot(rd, Pi.a), dot(rd, Pi.u), dot(rd, Pi.d));
                let fl = vec3<f32>(dot(focus, Pi.a), dot(focus, Pi.u), dot(focus, Pi.d));
                let sl = vec3<f32>(dot(sun, Pi.a), dot(sun, Pi.u), dot(sun, Pi.d));
                var hc = ms_hull(hit, f0, vl, ts, lit, chase_on, core_env, 0.0, fl, haze, day, sl, 3.0, ts - MS_ARRIVE - stop, eng);
                if (over && hit.t > scene_len) {
                    hc = mix(hc, vec3<f32>(luminance(col)), 0.3);
                }
                var a = vis;
                if (style == 2 && arriving) {
                    let w = saturate((max(Pi.s.x, Pi.s.y) - 1.0) / 8.0);
                    let az = abs(hit.q.y) / max(ms_half_w(hit.q.x), 1.0);
                    let smear = (exp(-pow(az / 0.05, 2.0)) * 2.0 + pow(0.5 + 0.5 * cos(az * 40.0), 12.0) * 0.6 + 0.15)
                        * (0.4 + 0.6 * saturate((hit.q.x + MS_HL) / (2.0 * MS_HL)));
                    a = vis * (1.0 - 0.9 * w);
                    hc = hc * (1.0 - 0.9 * w) + ship_tint(vec3<f32>(1.2, 2.6, 1.5)) * smear * w;
                }
                // far off, the air between veils it
                acc = acc + hc * vis;
                cover = cover + a;
                ship_t = min(ship_t, hit.t);
            }
        }
        if (arriving) {
            let a = cover / f32(n);
            col = col * (1.0 - a) + acc / f32(n);
            add = add * (1.0 - a);
            // (a smear of it, while it moves fast, hides what is behind it only where it covers most of the shutter)
            ship_t = select(1.0e9, ship_t, a > 0.5);
        }
    }
    // ---- the black hole: how big, its disk filling from the wreck as it goes in ----------
    let wd = wing_dirs();
    let nd = normalize(vec3<f32>(0.0, 1.0, 0.0) + 0.32 * vec3<f32>(wd.x, 0.0, wd.y));
    let e1 = vec3<f32>(wd.z, 0.0, wd.w);
    let e2 = cross(nd, e1);
    let rs = DF_RS * life * (1.0 + 0.15 * exp(-bt * 5.0) + 0.03 * sin(time * 5.0));
    // (and flaring as the last of the wreck goes through, its last section's far end there 1.25 its fall's time after
    // it is torn off: df_section)
    let gulp = exp(-pow((bt - DF_SWALLOW - 1.25 * 2.1) / 0.4, 2.0)) * f32(opened);
    let disk_env = smoothstep(0.0, 0.4, bt) * pow(left, 0.5) * f32(opened) * (0.2 + 0.8 * smoothstep(0.05, 0.85, sw)) * (1.0 + 0.8 * gulp);
    let hot = 1.0 + 1.6 * (1.0 - left) + 2.2 * exp(-max(bt, 0.0) * 2.0) + 0.8 * sw + 2.0 * gulp;

    // ---- the sections torn off it, falling in: the nearest of them drawn, a stream of grit and dust off each --------
    var dust_c = vec3<f32>(0.0);
    var dust_a = 0.0;
    if (opened && bt < DF_LIFE) {
        var best: MsHit;
        best.kind = -1;
        best.t = min(ship_t, scene_len);
        var bestP = P;
        for (var kk = 1; kk <= 4; kk = kk + 1) {
            let kx = kc - kk;
            if (kx < 0) {
                continue;
            }
            let t_k = DF_SWALLOW * pow(f32(kx + 1) / f32(DF_SEC), 1.0 / 1.8);
            let dur = 2.6 - 0.5 * f32(kx) / f32(DF_SEC - 1);
            let Pk = df_section(P, kx, bt - t_k, dur, H, nd, rs);
            if (Pk.pull >= 1.0) {
                continue;
            }
            // (its near end, and its middle)
            let C = df_world(Pk, vec3<f32>(Pk.px, 75.0 * Pk.s.y, 0.0));
            let M = df_world(Pk, vec3<f32>(Pk.px + 0.5 * (Pk.x1 - Pk.x0) * Pk.s.x, 75.0 * Pk.s.y, 0.0));
            let tc = dot(M, rd);
            if (tc > -300.0 && length(M - rd * max(tc, 0.0)) < 300.0 * Pk.s.z + 60.0 * Pk.s.x + 80.0) {
                let hk = df_trace(Pk, vec3<f32>(0.0), rd);
                if (hk.kind >= 0 && hk.t < best.t) {
                    best = hk;
                    bestP = Pk;
                }
            }
            // grit and dust streaming off it, back along its near end's path, hot nearer the hole
            let A0 = df_world(P, vec3<f32>(Pk.px, 75.0, 0.0));
            let sp = max(bt - t_k - 0.3, 0.0) * pow(length(df_world(P, vec3<f32>(Pk.x1, 75.0, 0.0)) - H) / length(A0 - H), 0.6) / (1.25 * dur);
            let Cp = df_fall_pt(A0, H, nd, sp, df_sec_spin(kx));
            let q = ray_seg(rd, C, Cp);
            let w = max(25.0 + 50.0 * q.z, q.y * 0.002);
            if (q.x < w * 2.0 && q.y < min(scene_len, best.t) && length(rd * q.y - H) > rs) {
                let sn = gfbm2(vec2<f32>(q.z * 5.0 - bt * 2.0, q.x / w * 2.0 + f32(kx)));
                let dens = exp(-pow(q.x / w, 2.0)) * (0.25 + 0.7 * sn) * (1.0 - q.z) * 0.6 * saturate(1.0 - Pk.pull);
                let ai = saturate(dens);
                let ci = (vec3<f32>(0.13, 0.1, 0.09) * dim + lava_ramp(0.6) * exp(-length(C - H) / 120.0) * 0.8) * bh_redshift(length(rd * q.y - H), rs);
                let na = dust_a + ai - dust_a * ai;
                dust_c = (dust_c * dust_a * (1.0 - ai) + ci * ai) / max(na, 1.0e-4);
                dust_a = na;
            }
        }
        if (best.kind >= 0) {
            dhit = best;
            dP = bestP;
            dvis = 1.0;
            dover = false;
            dsec = true;
            ship_t = best.t;
        }
    }
    // the wreck, or the nearer of the sections torn off it
    if (dhit.kind >= 0) {
        var hc = df_shade(dhit, dP, g, rd, rd * dhit.t, time, select(lit, 0.0, dsec), select(chase_on, 0.0, dsec), select(core_env, 0.0, dsec), focus,
                          haze, day, sun, select(boost, 0.0, dsec), select(time - MS_ARRIVE - stop, 9.0, dsec), select(eng, 0.0, dsec), select(groan, 0.0, dsec),
                          vec3<f32>(hits[0].w, hits[1].w, hits[2].w), vec3<f32>(hits[3].w, hits[4].w, hits[5].w));
        if (dover && dhit.t > scene_len) {
            hc = mix(hc, vec3<f32>(luminance(col)), 0.3);
        }
        col = mix(col, hc, dvis);
        add = add * (1.0 - dvis);
    }
    if (dust_a > 0.0) {
        col = mix(col, dust_c, dust_a);
    }
    // ---- its batteries' barrels and the masts along its roof's edges: too thin to trace, drawn as lines ----------------
    if (wreck_on && !arriving && present) {
        let rg = df_rig(P, rd, min(ship_t, select(scene_len, 1.0e9, sky)), time, boost, haze, day, sun);
        col = mix(col, rg.c, rg.w);
        add = add * (1.0 - rg.w) + rg.glow * k;
        ship_t = select(ship_t, rg.t, rg.w > 0.5);
    }

    // ---- the lens: the land and the wreck bent round it, its disk ------------------
    var swallowed = false;
    if (rs > 0.02 && ship_t > dot(H, rd) - LENS_R * rs * 0.5) {
        let L = bh_lens(H, rs, rd, uv2, scene_len, sky, nd, e1, e2, disk_env, hot, seed, time, sky_env, dim);
        if (L.on) {
            var bent = mix(col, L.bent, smoothstep(0.0, 0.25, L.w));
            if (!L.captured && !L.hit && L.w > 0.01 && wreck_on) {
                // what is left of the wreck, seen round it
                let hb = df_trace(P, L.p, L.v);
                if (hb.kind >= 0) {
                    bent = mix(col, df_shade(hb, P, g, L.v, L.p + L.v * hb.t, time, 0.0, 0.0, 0.0, focus, haze, day, sun, 0.0, 9.0, 0.0, 0.0, vec3<f32>(hits[0].w, hits[1].w, hits[2].w), vec3<f32>(hits[3].w, hits[4].w, hits[5].w)) * dim, smoothstep(0.0, 0.25, L.w));
                }
            }
            col = bent * L.trans + L.acc * k;
            swallowed = L.captured;
            add = add * L.trans + vec3<f32>(2.6, 1.7, 1.0) * exp(-pow((L.rmin - 1.52) / 0.05, 2.0)) * disk_env * select(1.0, 0.0, L.captured) * 1.4 * k;
        }
    }

    // everything drawn after the wreck is hidden where it is in front: its distance is the scene's depth
    let scene_lh = min(scene_len, ship_t);
    let sky_h = sky && ship_t > 1.0e8;
    if (time < MS_ARRIVE + 1.0) {
        add = add + ms_arrival_fx(f, base, cam, rd, sky_h, scene_lh, ta, mode, style, arriving, present, k);
    }
    if (time > T_FIRE && time < DF_CUT + 0.6) {
        add = add + ms_charge_fx(f, cam, rdb, focus, sky, scene_len, ship_t, conv_env, core_env, present, time, k);
    }

    // ---- the batteries firing: green bolts racing up from the roof's edges at the meteor, flaring where they strike ----
    if (time > DF_FIRE0 && time < DF_FIRE1 + DF_BOLT + 0.4) {
        for (var i = 0; i < 12; i = i + 1) {
            let cb = df_bat_c(i);
            // (its bolts all fly near the line from it to where the meteor is now)
            let qc = ray_seg(rd, df_hover(g, time, vec3<f32>(cb.x, MS_TOP + 7.5, cb.y)) - cam, df_met_head(aim, mv, time) - cam);
            if (qc.x > 300.0 + qc.y * 0.02) {
                continue;
            }
            let ph = fract(f32(i) * 0.618034) * DF_PERIOD;
            let n0 = floor((time - DF_FIRE0 - ph) / DF_PERIOD);
            for (var j = 0; j < 2; j = j + 1) {
                let tf = DF_FIRE0 + ph + (n0 - f32(j)) * DF_PERIOD;
                let a = time - tf;
                if (tf < DF_FIRE0 || tf > DF_FIRE1 || a < 0.0 || a > DF_BOLT + 0.35) {
                    continue;
                }
                // (out of the muzzles: as it is laid now, near enough as it was then)
                df_lay();
                let ae = df_aims[i];
                let fw = vec2<f32>(cos(ae.x), sin(ae.x));
                // (from each barrel of the pair in turn)
                let sgn = select(-1.0, 1.0, fract((n0 - f32(j)) * 0.5) < 0.25);
                let mz = vec2<f32>(cb.x, cb.y) + fw * 8.4 + fw * cos(ae.y) * DF_BARREL + vec2<f32>(-fw.y, fw.x) * 3.0 * sgn;
                let M = df_hover(g, tf, vec3<f32>(mz.x, MS_TOP + 7.5 + sin(ae.y) * DF_BARREL, mz.y)) - cam;
                let Tg = df_met_head(aim, mv, tf + DF_BOLT) - cam + vec3<f32>(fh21(vec2<f32>(f32(i), tf)) - 0.5, fh21(vec2<f32>(tf, f32(i))) - 0.5, 0.0) * DF_MR * 1.2;
                let u = a / DF_BOLT;
                if (u < 1.0) {
                    let q = ray_seg(rd, mix(M, Tg, u), mix(M, Tg, max(u - 0.05, 0.0)));
                    let w = max(1.4, q.y * 0.0012);
                    let vis = select(1.0, 0.0, (!sky_h && q.y > scene_lh) || q.y > ship_t + 2.0);
                    add = add + ship_tint(vec3<f32>(2.4, 6.0, 2.8) * exp(-pow(q.x / (w * 0.6), 2.0)) + vec3<f32>(0.15, 1.5, 0.35) * exp(-pow(q.x / (w * 3.0), 2.0)))
                        * (1.4 / w) * vis * k;
                }
                // the muzzle's flash, glaring past the roof's edge even where the hull hides it, and the hit on the rock
                let fl_m = exp(-a * 14.0);
                let fl_h = select(0.0, exp(-(a - DF_BOLT) * 9.0), a > DF_BOLT);
                for (var e = 0; e < 2; e = e + 1) {
                    let pnt = select(Tg, M, e == 0);
                    let s = select(fl_h, fl_m, e == 0);
                    let tp = dot(pnt, rd);
                    if (s > 0.01 && tp > 0.0) {
                        let dp = length(pnt - rd * tp) / tp;
                        // (none of it on the hull where the hull stands between)
                        let bl = df_blocks(P, pnt);
                        let hid = select(select(1.0, 0.08, (!sky_h && tp > scene_lh) || bl), 0.0, tp > ship_t || (bl && ship_t < 1.0e8));
                        add = add + ship_tint(vec3<f32>(1.6, 4.0, 1.8)) * s * (exp(-pow(dp / 0.0025, 2.0)) * 3.0 + exp(-dp / 0.01) * 0.4) * hid * k;
                    }
                }
            }
        }
    }

    // ---- the meteor coming in, and its pieces ------------------------------------------------------------------------
    if (time > DF_MET0 && time < DF_SPLIT + 25.0) {
        // the meteor (-1): its head, then its trail left hanging across the sky_h; and its pieces coming on as fast, each
        // its own trail, into the hull
        let split = time >= DF_SPLIT;
        for (var j = -1; j < select(0, 6, split); j = j + 1) {
            var head = df_met_head(aim, mv, time) - cam;
            var u = -mv;
            var rr = DF_MR;
            var ln = DF_MV * (min(time, DF_SPLIT) - DF_MET0);
            var age0 = 0.0;
            var heat = smoothstep(DF_MET0, 9.0, time);
            if (j == -1 && split) {
                head = Bw - cam;
                rr = -DF_MR;
                age0 = st;
                heat = 1.0;
            }
            if (j >= 0) {
                let T = df_hover(g, DF_TURN1, hits[j].xyz);
                let fl = hits[j].w - DF_SPLIT;
                let uu = min(st / fl, 1.0);
                age0 = max(st - fl, 0.0);
                head = mix(Bw, T, uu) - cam;
                u = normalize(Bw - T);
                rr = select(-DF_FR, DF_FR, uu < 1.0);
                ln = length(T - Bw) * uu;
                heat = 1.0 - smoothstep(0.0, 12.0, age0);
            }
            // (the meteor fading in where it is first seen, far up its path, dark until the air sets it burning)
            let seen = select(1.0, smoothstep(DF_MET0, DF_MET0 + 1.0, time), j == -1 && !split);
            if (heat > 0.0 || (j == -1 && !split)) {
                df_rock(&col, &add, rd, head, u, rr, ln, age0, heat, seen, scene_lh, sky_h, ship_t, dim, seed + f32(j), k);
            }
        }
    }
    if (st > 0.0 && st < 24.0) {
        // it breaks up: a ball of fire bursting out of it, then a cloud of smoke and grit left hanging there, drifting
        let Bc = Bw - cam + vec3<f32>(6.0, 2.0, 2.0) * st;
        let tcb = dot(Bc, rd);
        if (tcb > 0.0) {
            let db = length(Bc - rd * tcb);
            let blb = df_blocks(P, Bc);
            let visb = select(select(1.0, select(0.0, 0.08, !blb), !sky_h && tcb > scene_lh), 0.0, tcb > ship_t || (blb && ship_t < 1.0e8));
            let Rf = 85.0 * (1.0 - exp(-st * 3.0)) + 8.0;
            let fire = exp(-pow(db / Rf, 2.0)) * exp(-st * 1.7);
            add = add + (lava_ramp(0.45 + fire * 0.6) * fire * 4.0 + vec3<f32>(2.0, 1.6, 1.2) / (1.0 + pow(db / (Rf * 2.5), 2.0)) * exp(-st * 3.0)) * visb * k;
            let Rs = 70.0 + st * 7.0;
            if (db < Rs * 2.0 && visb > 0.5) {
                let pq = (rd * tcb - Bc) / Rs;
                let sn = gfbm2(vec2<f32>(pq.x + pq.y * 0.7, pq.z - pq.y * 0.6) * 2.0 + vec2<f32>(st * 0.08, seed));
                let sd = exp(-pow(db / Rs, 2.0)) * (0.3 + 0.9 * sn) * smoothstep(0.2, 1.2, st) * (1.0 - smoothstep(8.0, 24.0, st));
                col = mix(col, vec3<f32>(0.22, 0.2, 0.19) * dim * (0.6 + 0.6 * sn) + lava_ramp(0.5) * exp(-st * 1.2) * 0.4, saturate(sd * 0.85));
            }
        }
    }
    // the pieces striking: fireballs bursting up off the roof (seen past its edges), fire left burning on it
    for (var j = 0; j < 6; j = j + 1) {
        let dt = time - hits[j].w;
        if (dt > 0.0 && dt < 5.0 && time < DF_FALL0 + 1.0) {
            let T = df_hover(g, DF_TURN1, hits[j].xyz) - cam;
            let Rf = 60.0 * (1.0 - exp(-dt * 3.5)) + 4.0;
            let C = T + vec3<f32>(0.0, Rf * 0.5 + dt * 10.0, 0.0);
            let tc = dot(C, rd);
            if (tc > 0.0) {
                let dc = length(C - rd * tc);
                // (hidden on the hull wherever it stands between: from below, all of it)
                let blf = df_blocks(P, C);
                let visf = select(select(1.0, select(0.0, 0.1, !blf), !sky_h && tc > scene_lh), 0.0, tc - Rf * 0.5 > ship_t || (blf && ship_t < 1.0e8));
                let fire = exp(-pow(dc / (Rf * (0.75 + 0.4 * gfbm2(vec2<f32>(dc * 0.05, dt * 2.0 + f32(j))))), 2.0)) * exp(-dt * 0.9);
                add = add + (lava_ramp(0.5 + 0.5 * fire) * fire * 4.0 + vec3<f32>(1.5, 0.8, 0.35) / (1.0 + pow(dc / (Rf * 3.0), 2.0)) * exp(-dt * 2.5)) * visf * k;
            }
        }
    }

    // ---- the chunks blown off the roof's edges, tumbling down, burning, trailing smoke; their dust where they land ----
    if (time > DF_ROCK + 0.1 && time < DF_FALL1 + 2.0) {
        for (var i = 0; i < DF_CHUNKS; i = i + 1) {
            let tb = DF_ROCK + 0.2 + 1.8 * mh(u32(i), su, 31u);
            let a = time - tb;
            if (a <= 0.0) {
                continue;
            }
            let side = select(-1.0, 1.0, i < DF_CHUNKS / 2);
            let x = -500.0 + 80.0 * f32(i % (DF_CHUNKS / 2));
            let hb = df_heading(g, tb);
            let nn = vec2<f32>(-hb.y, hb.x) * side;
            if (dot(nn, g.ax) < -0.25) {
                continue;
            }
            let vh = 22.0 + 14.0 * mh(u32(i), su, 32u);
            let vy = 8.0 + 10.0 * mh(u32(i), su, 33u);
            let p0 = df_hover(g, tb, vec3<f32>(x, 150.0, side * (ms_half_w(x) - 2.0))) - cam;
            let tl = (vy + sqrt(vy * vy + 2.0 * DF_G * (p0.y + cam.y - g.by))) / DF_G;
            let pos = p0 + vec3<f32>(nn.x * vh * a, vy * a - 0.5 * DF_G * a * a, nn.y * vh * a);
            if (a < tl) {
                let a1 = max(a - 1.6, 0.0);
                let tail = p0 + vec3<f32>(nn.x * vh * a1, vy * a1 - 0.5 * DF_G * a1 * a1, nn.y * vh * a1);
                let q = ray_seg(rd, pos, tail);
                let vis = select(1.0, 0.0, (!sky_h && q.y > scene_lh) || q.y > ship_t);
                let w = max(8.0 + 14.0 * q.z, q.y * 0.003);
                if (q.x > w * 3.0 + 10.0) {
                    continue;
                }
                if (vis > 0.0) {
                    let sn = gfbm2(vec2<f32>(q.z * 6.0 - a, q.x / w + f32(i)));
                    col = mix(col, vec3<f32>(0.09, 0.085, 0.08) * dim * (0.6 + 0.7 * sn), saturate(exp(-pow(q.x / w, 2.0)) * (0.3 + 0.7 * sn) * (8.0 / w)) * vis);
                    add = add + lava_ramp(0.7 - q.z * 0.5) * exp(-pow(q.x / (w * 0.3), 2.0)) * (1.0 - q.z) * (1.0 - q.z) * (8.0 / w) * vis * k;
                }
                let bx = df_box(pos, rd, vec3<f32>(14.0, 6.0, 10.0), normalize(vec3<f32>(fh21(vec2<f32>(f32(i), 1.0)), 0.5, fh21(vec2<f32>(f32(i), 2.0))) - 0.3), a * (1.0 + fh21(vec2<f32>(f32(i), 3.0))));
                if (bx.x > 0.0 && bx.x < min(scene_lh, ship_t)) {
                    let lam = 0.2 + 0.8 * max(dot(bx.yzw, sun), 0.0) * day;
                    col = vec3<f32>(0.06, 0.065, 0.07) * lam * dim + lava_ramp(0.6) * max(dot(bx.yzw, -normalize(vec3<f32>(nn.x, 0.0, nn.y))), 0.0) * 1.2;
                }
            } else if (a - tl < 3.0) {
                let ga = a - tl;
                let C = p0 + vec3<f32>(nn.x * vh * tl, 0.0, nn.y * vh * tl);
                let Cg = vec3<f32>(C.x, g.by - cam.y + 4.0 + ga * 4.0, C.z);
                let tc = dot(Cg, rd);
                if (tc > 0.0) {
                    let dc = length(Cg - rd * tc);
                    let Rf = 7.0 + 6.0 * (1.0 - exp(-ga * 4.0));
                    let visf = select(1.0, smoothstep(tc - Rf, tc, scene_lh), !sky_h);
                    add = add + lava_ramp(0.6) * exp(-pow(dc / Rf, 2.0)) * exp(-ga * 2.2) * 3.0 * visf * k;
                    col = mix(col, vec3<f32>(0.28, 0.23, 0.18) * dim, exp(-pow(dc / (Rf * 1.6), 2.0)) * smoothstep(0.1, 0.6, ga) * (1.0 - ga / 3.0) * 0.7 * visf);
                }
            }
        }
    }

    // ---- the smoke streaming up off the fires on its roof, then left behind along its fall --------------------------
    if (time > hits[0].w - 0.5 && time < DF_END - 4.0) {
        let tm = 0.5 * (DF_FALL0 + min(time, DF_FALL1 + DF_SLIDE));
        let Pm = df_pose(g, select(DF_FALL0, tm, time > DF_FALL0), cam);
        let fade = 1.0 - smoothstep(DF_OPEN, DF_END - 4.0, time);
        let burning = 1.0 - smoothstep(DF_OPEN, DF_OPEN + 1.5, time);
        let wind = vec3<f32>(4.0, 0.0, 1.5);
        for (var j = 0; j < 6; j = j + 1) {
            let tj = hits[j].w;
            if (time < tj) {
                continue;
            }
            let l = hits[j].xyz + vec3<f32>(0.0, 6.0, 0.0);
            let Wh = df_hover(g, DF_TURN1, l) - cam;
            let Wn = select(Wh, df_world(P, l), time > DF_FALL0);
            let Wm = select(Wh, df_world(Pm, l), time > DF_FALL0);
            let up = 20.0 * (min(time, DF_FALL0 + 4.0) - tj);
            var bq = vec3<f32>(1.0e9, 0.0, 0.0);
            var bage = 0.0;
            var bw = 1.0;
            var blen = 1.0;
            var bp = vec3<f32>(0.0);
            for (var sgm = 0; sgm < 3; sgm = sgm + 1) {
                // the column rising off the fire while it hung there; then the trail from where it is back up to it
                var a = Wh + wind * (time - tj) * 0.5;
                var b = Wh + vec3<f32>(0.0, up, 0.0) + wind * (time - tj);
                var age_a = max(time - DF_FALL0, 0.0);
                var age_b = time - tj;
                if (sgm == 1) {
                    a = Wn;
                    b = Wm + wind * (time - tm);
                    age_a = 0.0;
                    age_b = time - tm;
                } else if (sgm == 2) {
                    a = Wm + wind * (time - tm);
                    b = Wh + wind * (time - DF_FALL0);
                    age_a = time - tm;
                    age_b = time - DF_FALL0;
                }
                if (sgm > 0 && time <= DF_FALL0) {
                    continue;
                }
                let q = ray_seg(rd, a, b);
                let age = mix(age_a, age_b, q.z);
                let w = 14.0 + 5.0 * age + 6.0 * f32(j % 2);
                if (q.x / max(w, q.y * 0.0015) < bq.x / max(bw, bq.y * 0.0015)) {
                    bq = q;
                    bage = age;
                    bw = w;
                    blen = length(b - a) * q.z + f32(sgm) * 400.0;
                    bp = mix(a, b, q.z);
                }
            }
            let wp = max(bw, bq.y * 0.0015);
            var vis = select(1.0, 1.0 - smoothstep(scene_lh - 2.0, scene_lh + 2.0, bq.y), !sky_h) * select(1.0, 0.0, bq.y > ship_t + 4.0);
            if (bq.x < wp * 2.5 && vis > 0.0 && ship_t < 1.0e8) {
                // (on the hull, none of it where the hull stands between: from below, the columns over the roof)
                vis = select(vis, 0.0, df_blocks(P, bp));
            }
            if (bq.x < wp * 2.5 && vis > 0.0) {
                let sn = gfbm2(vec2<f32>(blen * 0.03 - time * 0.15, bq.x / wp * 1.5 + f32(j) * 5.0));
                let dens = exp(-pow(bq.x / wp, 2.0)) * (bw / wp) * (0.35 + 0.9 * sn) * exp(-bage / 40.0) * fade * 1.1;
                let fire = exp(-bage * 1.5) * exp(-pow(bq.x / (wp * 0.5), 2.0)) * burning;
                col = mix(col, vec3<f32>(0.1, 0.095, 0.09) * dim * (0.55 + 0.6 * sn) + lava_ramp(0.55) * fire * 0.8, saturate(dens) * vis);
                add = add * (1.0 - saturate(dens) * vis * 0.7) + lava_ramp(0.6 + 0.3 * sn) * fire * 1.5 * vis * k;
            }
        }
    }

    // ---- the crash: a fireball where the stern strikes, and the dust rolling out over everything -----------------
    if (crashed && crash_t < 6.0) {
        let C = c0w - cam + vec3<f32>(0.0, 20.0 + crash_t * 12.0, 0.0);
        let tc = dot(C, rd);
        if (tc > 0.0) {
            let dc = length(C - rd * tc);
            let Rf = 160.0 * (1.0 - exp(-crash_t * 3.5)) + 14.0;
            let nz = gfbm2(vec2<f32>(atan2(dot(rd * tc - C, vec3<f32>(0.0, 1.0, 0.0)), dot(rd * tc - C, vec3<f32>(rd.z, 0.0, -rd.x))) * 1.5, dc / Rf * 2.0 - crash_t * 2.0));
            let fire = exp(-pow(dc / (Rf * (0.7 + 0.5 * nz)), 2.0)) * exp(-crash_t * 0.7);
            let visf = select(1.0, smoothstep(tc - Rf * 1.2, tc - Rf * 0.2, scene_lh), !sky_h) * smoothstep(tc - Rf * 0.25, tc + Rf * 0.1, ship_t);
            add = add + (lava_ramp(0.45 + 0.55 * fire) * fire * 4.0 + vec3<f32>(1.6, 0.9, 0.4) / (1.0 + pow(dc / (Rf * 2.5), 2.0)) * exp(-crash_t * 1.8)) * visf * k;
        }
    }
    // ---- blasts bursting out of it: as each lurch tears its lift away, then all along it as it strikes, stern to bow ----
    if (time > DF_FALL0 && time < DF_FALL1 + 7.0 && wreck_on) {
        for (var j = 0; j < 14; j = j + 1) {
            let fj = f32(j);
            var tb = DF_FALL1 + 0.05 + 0.2 * (fj - 2.0) + 0.1 * fh21(vec2<f32>(fj, 4.0));
            var l = vec3<f32>(-520.0 + 85.0 * (fj - 2.0), select(30.0, 145.0, j % 2 == 1), 0.0);
            if (j < 2) {
                tb = DF_FALL0 + 0.05 + 3.2 * fj;
                l = vec3<f32>(-330.0 + 120.0 * fj, 90.0, 0.0);
            }
            let a = time - tb;
            if (a <= 0.0 || a > 4.0) {
                continue;
            }
            let big = select(1.0, 1.6, j < 2);
            let Rf = (55.0 * (1.0 - exp(-a * 3.2)) + 6.0) * big;
            // (bursting out of its side, clear of the plating)
            l.z = select(-1.0, 1.0, fh21(vec2<f32>(fj, 8.0)) < 0.5) * (ms_half_w(l.x) + Rf * 0.45);
            let C = df_world(P, l) + vec3<f32>(0.0, Rf * 0.35 + a * 9.0, 0.0);
            let tc = dot(C, rd);
            if (tc <= 0.0) {
                continue;
            }
            let dc = length(C - rd * tc);
            if (dc > Rf * 4.0) {
                continue;
            }
            let nz = gfbm2(vec2<f32>(dc / Rf * 2.0 - a * 1.5, fj * 3.7 + atan2(dot(rd * tc - C, vec3<f32>(0.0, 1.0, 0.0)), 1.0) * 2.0));
            let fire = exp(-pow(dc / (Rf * (0.6 + 0.55 * nz)), 2.0)) * exp(-a * 1.1);
            // (in front of the hull where it bursts out past its plating, hidden where the hull is nearer)
            let visx = smoothstep(tc - Rf * 0.4, tc + Rf * 0.1, ship_t) * select(1.0, smoothstep(tc - Rf, tc, scene_lh), !sky_h);
            add = add + (lava_ramp(0.4 + 0.6 * fire) * fire * 4.5 + vec3<f32>(1.6, 0.8, 0.3) * exp(-pow(dc / (Rf * 1.6), 2.0)) * exp(-a * 3.0)) * visx * k;
            // and the black smoke it leaves, rolling up
            let sm = exp(-pow(dc / (Rf * 1.3), 2.0)) * smoothstep(0.3, 1.5, a) * (0.4 + 0.8 * nz) * (1.0 - a / 4.0);
            col = mix(col, vec3<f32>(0.07, 0.065, 0.06) * dim, saturate(sm * 0.8) * visx);
        }
    }
    // ---- the shock of it: a pale dome of air racing out from where it struck, faint, gone in a second ----------------
    if (crashed && crash_t < 1.6) {
        let Cs = c0w - cam;
        let Rs = crash_t * 420.0;
        let tcs = dot(Cs, rd);
        let ds = length(Cs - rd * tcs);
        let pt = rd * tcs;
        if (tcs > 0.0 && pt.y + cam.y > g.by && tcs < scene_lh + Rs && tcs < ship_t) {
            let shell = exp(-pow((ds - Rs) / (4.0 + Rs * 0.035), 2.0)) * (1.0 - crash_t / 1.6);
            add = add + vec3<f32>(1.0, 0.95, 0.9) * shell * 0.5 * k;
            col = col * (1.0 + shell * 0.4);
        }
    }
    if (time > DF_FALL1 - 1.0) {
        let mid = 0.5 * (g.c0 + g.ps + g.hf * 480.0);
        let R = min(260.0 + max(crash_t, 0.0) * 120.0, 1000.0);
        let hs = 4.0 + 12.0 * sqrt(max(crash_t, 0.0));
        // (settling, and drawn into the black hole the moment it opens)
        let dd = 0.009 * smoothstep(DF_FALL1 - 1.0, DF_FALL1 + 1.5, time) * exp(-max(crash_t - 4.0, 0.0) / 14.0) * (1.0 - smoothstep(DF_OPEN, DF_OPEN + 3.0, time));
        if (dd > 0.0) {
            let tr = df_dust(cam, rd, scene_lh, mid, R, g.by, hs, dd, time, seed);
            let lightd = mix(vec3<f32>(0.16, 0.13, 0.1), vec3<f32>(0.5, 0.43, 0.34), tr.y) * (0.3 + 0.7 * day) * (1.0 + flash * 0.4)
                + lava_ramp(0.5) * 0.25 * exp(-max(crash_t, 0.0) / 3.0) * (1.0 - tr.y);
            col = col * tr.x + lightd * (1.0 - tr.x) * dim;
            add = add * tr.x;
        }
    }

    // ---- the earth it throws up: a splash of it round the stern the instant it strikes, curtains of it flung high off
    // both sides along the hull as its bow slams down, and a wave of it thrown on ahead of the bow; dark and thick at
    // their roots, lit above, ragged, falling back into the dust (drawn over the dust, which rolls out round them) ------
    if (crashed && crash_t < 11.0) {
        let hf = g.hf;
        let sd = vec2<f32>(-hf.y, hf.x);
        for (var j = 0; j < 42; j = j + 1) {
            let fj = f32(j);
            let h1 = fh21(vec2<f32>(fj, 2.0));
            let h2 = fh21(vec2<f32>(fj, 3.0));
            let stern = j < 6;
            let bow = j >= 36;
            // where along the hull (0 its stern, 1 its bow), and when that part strikes
            let u = select(select((floor((fj - 6.0) * 0.5) + 0.5 + 0.8 * (h1 - 0.5)) / 15.0, 1.0, bow), 0.0, stern);
            let tl = select(DF_BOW * pow(u, 0.7) + 0.15 * h2 + select(0.0, 0.3, bow), 0.06 * h2, stern);
            let a = crash_t - tl;
            if (a <= 0.0 || a > 9.0) {
                continue;
            }
            // (where its stern had ploughed to then: its pivot, as df_pose)
            let tau = min(tl / DF_SLIDE, 1.0);
            let piv = g.c0 + (g.ps - g.c0) * (1.0 - (1.0 - tau) * (1.0 - tau));
            let x = -560.0 + 1120.0 * u;
            let sg = select(-1.0, 1.0, j % 2 == 0);
            var out = normalize(sd * sg + hf * (h2 - 0.5) * 0.7);
            var base2 = piv + hf * (x - DF_XP) + sd * sg * (ms_half_w(x) + 12.0 + 18.0 * h2);
            var big = (0.6 + 0.8 * h1) * (1.0 - 0.35 * u);
            if (bow) {
                // (the wave before the bow, thrown on ahead and out)
                out = normalize(hf + sd * (fj - 38.5) * 0.5);
                base2 = piv + hf * (600.0 - DF_XP) + sd * (fj - 38.5) * 70.0;
                big = 1.1 + 0.4 * h1;
            } else if (stern) {
                // (round the stern where it strikes: out to either side and back)
                let an = (fj - 2.5) / 2.5 * 1.3 + 0.3 * (h1 - 0.5);
                out = normalize(-hf * cos(an) + sd * sin(an) * 1.4);
                base2 = g.c0 + hf * (-80.0) + out * (90.0 + 60.0 * h1);
                big = 1.4 + 0.4 * h2;
            }
            let v0 = (95.0 + 75.0 * h2) * big;
            let top = max(v0 * a - 16.0 * a * a, 0.0);
            let apex = v0 * v0 / 64.0;
            let falling = a > v0 / 32.0;
            let lo = select(0.0, apex - top, falling) * 0.6;
            let wb = (12.0 + 10.0 * h1) * big + 7.0 * a;
            let lean = vec3<f32>(out.x, 0.0, out.y);
            let A = vec3<f32>(base2.x, g.by + lo, base2.y) + lean * a * 10.0 - cam;
            let B = A + lean * (top * 0.45 + 12.0 * a) + vec3<f32>(0.0, select(top, apex, falling) - lo, 0.0);
            let q = ray_seg(rd, A, B);
            // (narrow at the root, flaring out into spray at the top)
            let ww = max(wb * (0.5 + 0.85 * q.z), q.y * 0.002);
            if (q.x > ww * 2.0 || q.y > min(scene_lh + ww, ship_t)) {
                continue;
            }
            // (its billows and clods as round along it as across it)
            let al = q.z * length(B - A) / ww;
            let sn = gfbm2(vec2<f32>(al * 0.6 - a * 0.8 + fj, q.x / ww * 0.6 + fj * 0.37));
            let clump = gnoise2(vec2<f32>(al * 2.0 + fj * 3.0, q.x / ww * 2.0 - a));
            // (ragged at the top, thinning out as it falls back)
            let ragged = 1.0 - smoothstep(0.7, 1.0, q.z + 0.35 * (sn - 0.5) + 0.2 * (clump - 0.5));
            let fall_ = select(1.0, exp(-(a - v0 / 32.0) * 0.7), falling);
            let dens = exp(-pow(q.x / ww, 2.0)) * (0.45 + 1.1 * sn + 0.4 * clump) * (1.5 - 0.8 * q.z) * ragged * fall_ * (1.0 - smoothstep(4.0, 7.0, a))
                * smoothstep(0.0, 0.12, a) * 1.2;
            let lit_ = 0.45 + 0.55 * smoothstep(0.2, 1.0, q.z + 0.4 * sn);
            let dirt = vec3<f32>(0.15, 0.11, 0.075) * (0.3 + 0.7 * day) * lit_ * (0.6 + 0.6 * clump) * dim + lava_ramp(0.5) * exp(-a * 2.5) * (1.0 - q.z) * 0.6;
            let da = saturate(dens) * 0.85;
            col = mix(col, dirt, da);
            add = add * (1.0 - da);
        }
    }

    // ---- the black hole's debris: wreck and ground torn up round it, tumbling in, eaten or flung --------------------
    if (opened && ef < 2.5) {
        let tch = dot(H, rd);
        var best = min(scene_lh, ship_t);
        let rsn = max(rs, 0.8);
        let E1 = normalize(vec3<f32>(1.0, 0.0, 0.0) - nd * nd.x);
        let E2 = normalize(vec3<f32>(0.0, 0.0, 1.0) - nd * nd.z - E1 * dot(vec3<f32>(0.0, 0.0, 1.0), E1));
        let ks = array<u32, 5>(pcg(su ^ pcg(21u)), pcg(su ^ pcg(22u)), pcg(su ^ pcg(23u)), pcg(su ^ pcg(24u)), pcg(su ^ pcg(25u)));
        // (until they are flung, all of them are within 100 blocks of the hole)
        let near_h = tch > -100.0 && length(H - rd * max(tch, 0.0)) < 100.0;
        for (var i = 0; i < DFD_N; i = i + 1) {
            let fi = f32(i);
            let h1 = fh21(vec2<f32>(fi, seed + 5.0));
            let flung = h1 < 0.22;
            if (!near_h && !flung) {
                continue;
            }
            let tr = df_torn(g, i, ks);
            let s = min(bt, DF_LIFE) - tr.z;
            if (s <= 0.0) {
                continue;
            }
            let big = tr.w >= 2.0;
            let wreck = fract(tr.w * 0.5) > 0.25;
            let hs = select(0.5, 1.0, big);
            let gy = df_ground(g, tr.xy + 0.5);
            let y_c = select(gy - select(0.0, 1.0, big), gy + 1.0, wreck) + select(0.5, 1.0, big);
            let src = vec3<f32>(tr.x + select(0.5, 0.0, big), y_c, tr.y + select(0.5, 0.0, big)) - cam;
            let h2 = fh21(vec2<f32>(fi, seed + 9.0));
            let T_in = 3.2 + 1.8 * h2;
            let u_f = 0.5 + 0.2 * h2;
            let ub = s / T_in;
            let a0 = atan2(src.z + cam.z - g.ps.y, src.x + cam.x - g.ps.x);
            let R0 = length(src.xz + cam.xz - g.ps);
            // falling in as the Black Hole's debris does (bh_fall): its near end through the horizon to the middle, its
            // far end after it, the tides drawing it out between them
            let l0 = 2.0 * hs;
            let lag = (R0 + l0) / R0 * sqrt((R0 + l0) / R0);
            let u = min(ub, select(lag, u_f, flung));
            let r = bh_fall(R0, u);
            let thd = a0 - (3.0 + 3.0 * h1) * u * u;
            let lift = smoothstep(0.0, 0.45, u);
            let ground_r = vec3<f32>(g.ps.x, y_c, g.ps.y) - cam + vec3<f32>(cos(thd), 0.0, sin(thd)) * r;
            let gp = mix(src, ground_r, smoothstep(0.0, 0.15, u));
            var c = mix(gp, H + (E1 * cos(thd) + E2 * sin(thd)) * r, lift) + vec3<f32>(0.0, sin(lift * 3.14159) * 12.0, 0.0);
            var alive = smoothstep(0.0, 0.05, s);
            var kt = bh_tide(R0, l0, r, u, lag);
            if (flung && ub > u_f) {
                let dt = (ub - u_f) * T_in;
                c = c + ((E1 * sin(thd) - E2 * cos(thd)) * 70.0 + nd * 18.0) * dt;
                alive = alive * (1.0 - smoothstep(2.5, 4.0, dt));
                kt = 1.0;
            } else if (!flung) {
                alive = alive * (1.0 - step(lag, ub));
            }
            if (ef > 0.0) {
                c = c + normalize(c - H) * ef * 70.0;
                alive = alive * (1.0 - smoothstep(1.0, 2.5, ef));
                kt = 1.0;
            }
            if (alive < 0.01) {
                continue;
            }
            let ur = normalize(c - H + vec3<f32>(1.0e-4));
            c = c + ur * (hs * kt);
            let tq = dot(c, rd);
            if (tq < 0.0 || length(c - rd * tq) > hs * 1.8 * kt || tq - hs * 1.8 * kt > best) {
                continue;
            }
            let ax = normalize(vec3<f32>(fh21(vec2<f32>(fi, 1.0)), fh21(vec2<f32>(fi, 2.0)), fh21(vec2<f32>(fi, 3.0))) - 0.5 + 1.0e-3);
            let ang = s * (1.5 + 3.0 * fh21(vec2<f32>(fi, 4.0)));
            let bx = bh_chunk(c, rd, ur, kt, hs, ax, ang, H, rs);
            if (bx.x < 0.0 || bx.x > best || (swallowed && bx.x > tch)) {
                continue;
            }
            best = bx.x;
            let nw = bh_chunk_n(bx.yzw, ur, kt, ax, ang);
            let lp = bx.yzw * hs;
            let px = floor((lp.xz + lp.y) * 8.0);
            let kind = min(i32(fh21(vec2<f32>(fi, seed + 13.0)) * 4.0), 3);
            var albedo = srgb_to_linear(debris_tex(kind, px, nw.y > 0.5, 0.0, seed + fi));
            if (wreck) {
                albedo = vec3<f32>(0.05, 0.055, 0.06) * (0.7 + 0.6 * fh21(px + vec2<f32>(fi)));
            }
            let rp = length(rd * bx.x - H);
            let rl = rp / rsn;
            let diskl = vec3<f32>(2.2, 1.0, 0.45) * max(dot(nw, -ur), 0.0) * disk_env * 6.0 / (1.0 + rl * 0.5);
            let glow = smoothstep(rsn * 4.0, rsn * 1.2, r) * f32(!(flung && ub > u_f));
            var cc = albedo * ((0.3 + 0.7 * max(dot(nw, sun), 0.0) * day) * dim + diskl);
            cc = cc + vec3<f32>(2.6, 0.7, 0.15) * glow * glow * 1.5 + ship_tint(vec3<f32>(0.3, 2.0, 0.6)) * f32(wreck) * step(0.85, fh21(px)) * 0.4 * (1.0 - glow);
            // redder and dimmer as it goes through the horizon
            col = cc * bh_redshift(rp, rs) * alive;
            add = add * 0.15;
        }
    }

    // ---- the ground it displaced as it dug in: clods of earth and rock flung out over the land (the heaps it shoves up
    // along its sides are real, strike.rs's df_berms) ---------------------------------------------------------------
    if (time > DF_FALL1 - 0.5 && time < DF_END) {
        let hf = g.hf;
        let sd = vec2<f32>(-hf.y, hf.x);
        let mw = g.ps + hf * (-DF_XP);
        // clods of earth and rock flung out over the land as it digs in
        if (time < DF_FALL1 + 12.0) {
            for (var i = 0; i < 28; i = i + 1) {
                let fi = f32(i);
                let t0 = DF_FALL1 + 0.2 + 4.0 * fh21(vec2<f32>(fi, 61.0));
                let a_ = time - t0;
                if (a_ <= 0.0 || a_ > 8.0) {
                    continue;
                }
                let side = select(-1.0, 1.0, fh21(vec2<f32>(fi, 63.0)) < 0.5);
                let xl = -560.0 + 1120.0 * fh21(vec2<f32>(fi, 65.0));
                let src = mw + hf * xl + sd * side * (ms_half_w(xl) + 6.0);
                let vh = 14.0 + 30.0 * fh21(vec2<f32>(fi, 67.0));
                let vy = 24.0 + 34.0 * fh21(vec2<f32>(fi, 69.0));
                let dir = sd * side;
                let pc = vec3<f32>(src.x + dir.x * vh * a_, g.by + 4.0 + vy * a_ - 8.0 * a_ * a_, src.y + dir.y * vh * a_) - cam;
                if (pc.y + cam.y < g.by - 2.0) {
                    continue;
                }
                let sz = 2.0 + 7.0 * pow(fh21(vec2<f32>(fi, 71.0)), 2.0);
                let tq = dot(pc, rd);
                if (tq > 0.0 && length(pc - rd * tq) < sz * 2.0) {
                    let bx = df_box(pc, rd, vec3<f32>(sz, sz * 0.8, sz), normalize(vec3<f32>(fi, 1.0, 2.0)), a_ * 3.0);
                    if (bx.x > 0.0 && bx.x < min(scene_lh, ship_t)) {
                        col = vec3<f32>(0.2, 0.14, 0.09) * (0.3 + 0.7 * max(dot(bx.yzw, sun), 0.0) * day) * dim;
                    }
                }
            }
        }
    }

    // ---- the pieces it sheds as it falls: plates, girders, chunks and burning fragments, tumbling down the whole way,
    // catching the light, the bigger trailing smoke; dust where they come down (strike.rs's DfGeo::shed) ------------
    if (time > DF_SHED_T0 && time < DF_FALL1 + 8.0) {
        let sk41 = pcg(su ^ pcg(41u));
        let sk42 = pcg(su ^ pcg(42u));
        let sk43 = pcg(su ^ pcg(43u));
        let sk44 = pcg(su ^ pcg(44u));
        let sk45 = pcg(su ^ pcg(45u));
        let sk46 = pcg(su ^ pcg(46u));
        let sk47 = pcg(su ^ pcg(47u));
        for (var e = 0; e < DF_SHED / DF_SHED_PER; e = e + 1) {
            let te = DF_SHED_T0 + DF_SHED_DT * f32(e);
            if (time < te) {
                break;
            }
            if (time > te + 13.0) {
                continue;
            }
            let Pe = df_pose(g, te, cam);
            let ve = df_vel(g, te);
            let a_ = time - te;
            // (all its pieces are still near where the ship was, falling with it)
            let cen = df_world(Pe, vec3<f32>(0.0, 75.0, 0.0)) + ve * a_ + vec3<f32>(0.0, -0.5 * DF_G * a_ * a_, 0.0);
            let tcen = dot(cen, rd);
            if (length(cen - rd * max(tcen, 0.0)) > 650.0 + 30.0 * a_) {
                continue;
            }
            for (var j = 0; j < DF_SHED_PER; j = j + 1) {
                let ku = u32(e * DF_SHED_PER + j);
                let x = -560.0 + 1120.0 * pow(f32(pcg(ku ^ sk41)) * (1.0 / 4294967296.0), 1.7);
                let hw = ms_half_w(x);
                let h42 = f32(pcg(ku ^ sk42)) * (1.0 / 4294967296.0);
                let h43 = f32(pcg(ku ^ sk43)) * (1.0 / 4294967296.0);
                let h44 = f32(pcg(ku ^ sk44)) * (1.0 / 4294967296.0);
                let sgn = select(1.0, -1.0, h43 < 0.5);
                var l = vec3<f32>(x, 150.0, sgn * (hw - 5.0));
                var nl = vec3<f32>(0.0, 0.6, sgn * 0.8);
                if (h42 < 0.5) {
                    l = vec3<f32>(x, 0.0, (h43 - 0.5) * 2.0 * (hw - 10.0));
                    nl = vec3<f32>(0.0, -1.0, 0.0);
                } else if (h42 < 0.8) {
                    l = vec3<f32>(x, 20.0 + 120.0 * h44, sgn * (hw - 1.0));
                    nl = vec3<f32>(0.0, 0.0, sgn);
                }
                let p0 = df_world(Pe, l);
                let nw = Pe.a * nl.x + Pe.u * nl.y + Pe.d * nl.z;
                let v = ve + nw * (6.0 + 14.0 * f32(pcg(ku ^ sk45)) * (1.0 / 4294967296.0)) + vec3<f32>(0.0, 4.0 * h44, 0.0);
                let cls = min(i32(f32(pcg(ku ^ sk46)) * (1.0 / 4294967296.0) * 4.0), 3);
                let size = 0.6 + f32(pcg(ku ^ sk47)) * (1.0 / 4294967296.0);
                let tl = (v.y + sqrt(v.y * v.y + 2.0 * DF_G * max(p0.y + cam.y - g.by, 0.0))) / DF_G;
                let fi = f32(ku);
                if (a_ < tl) {
                    let pos = p0 + v * a_ + vec3<f32>(0.0, -0.5 * DF_G * a_ * a_, 0.0);
                    var hs = vec3<f32>(10.0, 1.0, 7.0);
                    if (cls == 1) {
                        hs = vec3<f32>(16.0, 1.2, 1.2);
                    } else if (cls == 2) {
                        hs = vec3<f32>(6.0, 5.0, 6.0);
                    } else if (cls == 3) {
                        hs = vec3<f32>(2.0, 2.0, 2.0);
                    }
                    hs = hs * size;
                    // the smoke and fire it trails (chunks and burning fragments)
                    if (cls >= 2) {
                        let a1 = max(a_ - 1.4, 0.0);
                        let tail = p0 + v * a1 + vec3<f32>(0.0, -0.5 * DF_G * a1 * a1, 0.0);
                        let q = ray_seg(rd, pos, tail);
                        let w = max(hs.y * (1.2 + 3.0 * q.z), q.y * 0.002);
                        if (q.x < w * 2.5 && q.y < scene_lh) {
                            let sn = gfbm2(vec2<f32>(q.z * 6.0 - a_, q.x / w + fi));
                            col = mix(col, vec3<f32>(0.08, 0.075, 0.07) * dim * (0.6 + 0.7 * sn), saturate(exp(-pow(q.x / w, 2.0)) * (0.3 + 0.6 * sn) * (1.0 - q.z)));
                            add = add + lava_ramp(0.75 - 0.5 * q.z) * exp(-pow(q.x / (w * 0.35), 2.0)) * (1.0 - q.z) * (1.0 - q.z) * select(0.6, 1.6, cls == 3) * k;
                        }
                    }
                    let tq = dot(pos, rd);
                    let reach = length(hs);
                    if (tq > 0.0 && length(pos - rd * tq) < reach && tq - reach < scene_lh) {
                        let ax = normalize(vec3<f32>(fh21(vec2<f32>(fi, 1.0)), fh21(vec2<f32>(fi, 2.0)), fh21(vec2<f32>(fi, 3.0))) - 0.5 + 1.0e-3);
                        let bx = df_box(pos, rd, hs, ax, a_ * (0.8 + 2.0 * fh21(vec2<f32>(fi, 4.0))));
                        if (bx.x > 0.0 && bx.x < scene_lh) {
                            let n = bx.yzw;
                            let lam = 0.2 + 0.8 * max(dot(n, sun), 0.0) * day;
                            let glint = pow(max(dot(reflect(rd, n), sun), 0.0), 40.0) * 3.0 * day;
                            col = vec3<f32>(0.07, 0.075, 0.08) * lam * dim + vec3<f32>(1.0, 0.95, 0.85) * glint * select(1.0, 0.2, cls >= 2);
                            if (cls == 3) {
                                col = col + lava_ramp(0.7 + 0.2 * sin(time * 17.0 + fi)) * 2.5;
                            }
                        }
                    }
                } else if (a_ - tl < 2.5 && cls != 1) {
                    // where it comes down: a puff of dust and grit (a crater, for the big ones: strike.rs)
                    let ga = a_ - tl;
                    let C = p0 + vec3<f32>(v.x * tl, 0.0, v.z * tl);
                    let Cg = vec3<f32>(C.x, g.by - cam.y + 3.0 + ga * 5.0, C.z);
                    let tc = dot(Cg, rd);
                    if (tc > 0.0 && tc < scene_lh + 8.0) {
                        let dc = length(Cg - rd * tc);
                        let Rf = (3.0 + 5.0 * (1.0 - exp(-ga * 3.0))) * size;
                        col = mix(col, vec3<f32>(0.27, 0.22, 0.17) * dim, exp(-pow(dc / Rf, 2.0)) * (1.0 - ga / 2.5) * 0.75);
                        add = add + lava_ramp(0.6) * exp(-pow(dc / Rf, 2.0)) * exp(-ga * 3.0) * 1.5 * k;
                    }
                }
            }
        }
    }

    // ---- drawn in towards the engine as it fails, and into the hole: dust and grit streaming in, plating peeling off --
    if (time > DF_GROAN && ef < 0.5) {
        let rsn = max(rs, 3.0);
        let near_hole = length(H - rd * max(dot(H, rd), 0.0)) < 290.0;
        for (var i = 0; i < select(0, 40, near_hole); i = i + 1) {
            let fi = f32(i);
            let t0 = DF_GROAN + 1.0 + 14.0 * fh21(vec2<f32>(fi, 17.0));
            let dur = 2.2 + 1.5 * fh21(vec2<f32>(fi, 19.0));
            let a_ = time - t0;
            if (a_ < 0.0 || a_ > dur) {
                continue;
            }
            let ang0 = fh21(vec2<f32>(fi, 23.0)) * TAU;
            let r0 = 70.0 + 190.0 * fh21(vec2<f32>(fi, 29.0));
            let y0 = g.by + 2.0 + 60.0 * fh21(vec2<f32>(fi, 31.0));
            var pos = vec3<f32>(0.0);
            var pp = vec3<f32>(0.0);
            for (var m = 0; m < 2; m = m + 1) {
                let s_ = saturate((a_ - 0.12 * f32(m)) / dur);
                let r = r0 * (1.0 - s_ * s_) + rsn;
                let ang = ang0 + 2.5 * s_ * s_;
                let p = vec3<f32>(g.ps.x + cos(ang) * r, mix(y0, Hw.y, s_ * s_), g.ps.y + sin(ang) * r) - cam;
                if (m == 0) {
                    pos = p;
                } else {
                    pp = p;
                }
            }
            let q = ray_seg(rd, pos, pp);
            let w = max(0.8 + 2.5 * a_ / dur, q.y * 0.0012);
            if (q.x < w * 2.0 && q.y < scene_lh) {
                col = mix(col, vec3<f32>(0.14, 0.12, 0.1) * dim, exp(-pow(q.x / w, 2.0)) * 0.55);
                add = add + vec3<f32>(1.4, 0.6, 1.1) * exp(-pow(q.x / w, 2.0)) * smoothstep(0.6, 1.0, a_ / dur) * f32(opened) * 0.5 * k;
            }
        }
        // plating peeling off: before it opens from round the engine, then from just ahead of where it is breaking up;
        // pulled in, tumbling, stretched out as they near the hole, gone into the wreck, or into the hole
        for (var i = 0; i < 36; i = i + 1) {
            let fi = f32(i);
            let pre = i < 14;
            let t0 = select(DF_OPEN + 0.5 + 9.0 * fh21(vec2<f32>(fi, 41.0)), DF_GROAN + 1.5 + 4.5 * fh21(vec2<f32>(fi, 41.0)), pre);
            let dur = select(1.4 + fh21(vec2<f32>(fi, 43.0)), 2.4, pre);
            let a_ = time - t0;
            if (a_ < 0.0 || a_ > dur) {
                continue;
            }
            let s_ = a_ / dur;
            let xs = select(-370.0 + 930.0 * pow(saturate((t0 - DF_OPEN) / DF_SWALLOW), 1.8) + 15.0 + 80.0 * fh21(vec2<f32>(fi, 45.0)), -560.0 + 200.0 * fh21(vec2<f32>(fi, 45.0)), pre);
            let zs = (fh21(vec2<f32>(fi, 47.0)) - 0.5) * 2.0 * (ms_half_w(xs) - 10.0);
            let src = df_world(P, vec3<f32>(xs, MS_TOP, zs));
            let pos = H + rot_axis(mix(src, H, select(1.0, 0.8, pre) * s_ * s_) - H, nd, select(1.6, 0.4, pre) * s_ * s_);
            if (pre && length(pos - H) < 70.0) {
                continue;
            }
            let tq = dot(pos, rd);
            let hs = vec3<f32>(5.0 * (1.0 + 2.0 * s_ * s_ * s_), 0.6, 3.5) * (0.7 + 0.8 * fh21(vec2<f32>(fi, 49.0)));
            if (tq > 0.0 && length(pos - rd * tq) < length(hs) && tq - length(hs) < scene_lh) {
                let ax = normalize(vec3<f32>(fh21(vec2<f32>(fi, 51.0)) - 0.5, 0.7, fh21(vec2<f32>(fi, 53.0)) - 0.5));
                let bx = df_box(pos, rd, hs, ax, a_ * 2.5);
                if (bx.x > 0.0 && bx.x < scene_lh) {
                    let n = bx.yzw;
                    let near = exp(-length(pos - H) / 90.0);
                    col = vec3<f32>(0.06, 0.065, 0.07) * (0.25 + 0.75 * max(dot(n, sun), 0.0) * day) * dim
                        + vec3<f32>(1.0, 0.95, 0.85) * pow(max(dot(reflect(rd, n), sun), 0.0), 50.0) * 2.5 * day
                        + lava_ramp(0.5 + 0.5 * near) * near * 2.5 * f32(!pre);
                }
            }
        }
    }

    // ---- it collapses: a blinding flash, a shell of light running out, the light boring down into the ground --------
    if (ef > 0.0 && ef < 8.0) {
        let tcs = dot(H, rd);
        let bs = length(H - rd * max(tcs, 0.0));
        let re = ef * 90.0;
        let shell = exp(-pow((bs - re) / (2.0 + re * 0.06), 2.0)) * exp(-ef * 0.7) * select(0.0, 1.0, tcs > 0.0 || length(H) < re);
        add = add + vec3<f32>(1.6, 1.2, 2.4) * shell * 2.5 * k + vec3<f32>(2.2, 2.0, 2.6) * evap * evap * 1.4 * k;
        add = add + vec3<f32>(1.2, 0.9, 1.8) * exp(-bs * 0.05) * evap * 3.0 * k;
        let ah = axis_hit(H.xz, rd.xz, dot(rd.xz, rd.xz), cam.y, rd.y);
        if (ah.x > 0.0 && ah.z < Hw.y && ef < 1.2) {
            let visb = select(1.0, 1.0 - smoothstep(scene_lh - 0.6, scene_lh + 0.6, ah.x), !sky_h);
            add = add + vec3<f32>(3.0, 2.4, 5.0) * exp(-pow(ah.y / 3.0, 2.0)) * (1.0 - smoothstep(0.3, 1.2, ef)) * mix(0.3, 1.0, visb) * 4.0 * k;
        }
    }

    // ---- the lens: the meteor's glare as it comes, the disk's bloom, a streak through it -----------------------------
    if (time < DF_SPLIT) {
        let pm = project_rel(df_met_head(aim, mv, max(time, DF_MET0)) - cam);
        if (pm.z > 0.0 && !df_blocks(P, df_met_head(aim, mv, max(time, DF_MET0)) - cam)) {
            let dd = (uv - pm.xy) * vec2<f32>(aspect, 1.0);
            add = add + vec3<f32>(1.6, 0.9, 0.4) * met_env * met_env / (1.0 + dot(dd, dd) * 60.0) * 0.35 * k;
        }
    }
    if (pH.z > 0.0 && (opened || groan > 0.0)) {
        let dd = (uv - pH.xy) * vec2<f32>(aspect, 1.0);
        // the disk's glare and the streak through it come from the disk itself: only while it is in sight (not behind
        // the wreck or the land), and softer close to, where the disk itself fills the view
        var hole_vis = 0.0;
        if (all(pH.xy > vec2<f32>(0.0)) && all(pH.xy < vec2<f32>(1.0))) {
            let dh0 = depth_at(pH.xy);
            let land = is_sky(dh0) || length(world_offset(pH.xy, dh0)) > length(H) - rs * 3.0;
            hole_vis = select(0.0, 1.0, land && !(wreck_on && df_blocks(P, H)));
        }
        let near_k = mix(0.3, 1.0, smoothstep(120.0, 600.0, length(H)));
        add = add + vec3<f32>(1.6, 1.2, 2.4) * exp(-pow((sdist - bt * 2.0) / 0.02, 2.0)) * exp(-max(bt, 0.0) * 2.2) * f32(opened) * 0.8 * k;
        add = add + vec3<f32>(1.2, 0.6, 0.35) * disk_env * hot * 0.2 / (1.0 + dot(dd, dd) * 90.0) * hole_vis * near_k * k;
        add = add + vec3<f32>(1.2, 0.5, 2.6) * exp(-abs(dd.y) * 240.0) * exp(-abs(dd.x) * 2.6) * (disk_env * 0.6 * near_k + evap * 2.0) * hole_vis * k;
    }
    let ps_c = project_rel(c0w - cam);
    if (ps_c.z > 0.0 && crashed && crash_t < 3.0) {
        let dd = (uv - ps_c.xy) * vec2<f32>(aspect, 1.0);
        add = add + vec3<f32>(2.0, 1.3, 0.7) * exp(-crash_t * 1.8) / (1.0 + dot(dd, dd) * 25.0) * 0.6 * select(0.15, 1.0, ship_t > 1.0e8) * k;
    }
    add = add + vec3<f32>(1.0, 0.9, 0.75) * select(0.0, exp(-st * 5.0), st > 0.0) * 0.12 * select(0.25, 1.0, ship_t > 1.0e8) * k;

    // ---- combine --------------------------------------------------------------
    var outc = col + add;
    let vg = length((uv - vec2<f32>(0.5)) * vec2<f32>(aspect, 1.0));
    outc = outc * (1.0 - smoothstep(0.3, 1.0, vg) * (0.2 + 0.25 * f32(present) + 0.3 * sky_env + 0.15 * dust_env) * k);
    outc = aces(outc * 0.9);
    var srgb = linear_to_srgb(outc);
    // the instant the engine ruptures the picture goes negative
    srgb = mix(srgb, vec3<f32>(1.0) - srgb, saturate(open_ * 1.2 * k));
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
    return downfall(in);
}

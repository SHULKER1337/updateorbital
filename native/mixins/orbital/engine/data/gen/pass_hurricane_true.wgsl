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


// Orbital Laser's post pass for the Hurricane (laser 13). Like the Supercell's, the mod builds it from shaders/strike.wgsl
// up to its fs_main (the helpers: the noise, mh, ign) less the other lasers' own functions, followed by this file, and
// sets it for a hurricane strike only. Validate with tools/check-shader.sh.

// ---- laser 13: the hurricane --------------------------------------------------------------------------------------
// No beam. A ragged mass of towering storms gathers over the target and is drawn into a spiral, three trailing bands
// wound tighter round a dense core as it organises, the whole of it some 3,500 blocks across and 450 high: from the
// space station's height the picture of Florence. The eye opens from a pinhole into a stadium: its billowed wall
// flaring out as it rises, its far side sunlit from the rim, sky straight overhead; an open moat round the eyewall,
// cirrus fanned out over it all. Lightning bursts in the eyewall as it intensifies, bolts out of its flank across the
// moat. The wind spins up and from the eyewall out tears up the land and everything built on it: every block rises out
// of the land behind the front (`hu_debris`, filling the eyewall's column from the ground up), whole trees and pieces of
// buildings lifting off where they stood (`hu_trees`), a wall of dust and spray at its foot; rain in the world round
// the camera. At its height the carry draws the player into the calm of the eye. Then the winds drop: everything is
// flung out and falls, shattering to dust where it hits (the trees settle into the pose hurricane.rs lays them in as
// real fallen trees), the eye fills and the cloud breaks up.
// strike/hurricane.rs keeps the HU_* in step and hands the pass its table (render.set-data): the trees, each ring's
// colours (what was torn up under it) and the land's height round the middle.
const HU_LEN: f32 = 64.0;          // the strike's length (lasers.rs)
const HU_FORM: f32 = 10.0;         // the cloud formed and turning,
const HU_EYE_T: f32 = 14.0;        // the eye clear,
const HU_F0: f32 = 15.0;           // the wind tearing at the land from the eyewall,
const HU_F1: f32 = 35.0;           // out to HU_R_LIFT by here,
const HU_FLING: f32 = 46.0;        // the winds dropping, everything flung out,
const HU_CLEAR: f32 = 54.0;        // the cloud breaking up from here
const HU_R_EYE: f32 = 26.0;        // the eye (calm),
const HU_R_IN: f32 = 32.0;         // where the wind starts to tear at the land,
const HU_R_W: f32 = 62.0;          // the eyewall (the strongest wind),
const HU_R_LIFT: f32 = 150.0;      // how far out it uproots the trees,
const HU_R_PLANTS: f32 = 175.0;    // and strips the plants
const HU_V: f32 = 40.0;            // the wind at the eyewall at its height, blocks a second
const HU_SPIN: f32 = -1.0;         // cyclonic: seen from above, east to north
const HU_NR: i32 = 13;             // the rings the blocks fly round in (hurricane.rs's HU_NR, HU_RING0, HU_RING_W)
const HU_RING0: f32 = 30.0;
const HU_RING_W: f32 = 10.0;
const HU_CELL: f32 = 3.0;          // their cells, a block at most in each
const HU_PAL: u32 = 64u;           // the table: each ring's blocks from HU_PAL (HU_PN a ring, each a block type),
const HU_PN: u32 = 32u;
const HU_BK: u32 = 512u;           // the block types from HU_BK (HU_BKW words each: hurricane.rs's bk_words),
const HU_BKW: u32 = 12u;
const HU_T: u32 = 6656u;           // the trees from HU_T (HU_TW words each: hurricane.rs's TreeRec::words),
const HU_TW: u32 = 28u;
const HU_NT: u32 = 128u;
const HU_G: u32 = 10240u;           // the land's height round the middle from HU_G (HU_GR rings of HU_GA)
const HU_GR: u32 = 16u;
const HU_GA: u32 = 64u;
const HU_G_STEP: f32 = 11.0;
// The cloud (over the middle's ground): the bands' base, the eyewall's top at the storm's height, the central dense
// overcast's reach (a solid shield round the eye), how far out the rain bands reach, and the outflow's top.
const HU_BASE: f32 = 78.0;
const HU_TOP: f32 = 445.0;
const HU_CDO: f32 = 720.0;
const HU_DECK: f32 = 1750.0;
const HU_YHI: f32 = 480.0;

// The game's block textures (the atlas capability, the fork's API 10): every vanilla texture a layer of the first array,
// gamma-encoded, sampled nearest as the terrain is (docs/mods.md, "Block textures in a post pass").
@group(0) @binding(8) var block_sprites: texture_2d_array<f32>;
@group(0) @binding(9) var block_sampler: sampler;

fn hu_u(i: u32) -> u32 {
    if (i >= arrayLength(&mod_data)) {
        return 0u;
    }
    return mod_data[i];
}
fn hu_w(i: u32) -> f32 {
    return bitcast<f32>(hu_u(i));
}
fn hu_have() -> bool {
    return arrayLength(&mod_data) > HU_G;
}
fn rot2(v: vec2<f32>, a: f32) -> vec2<f32> {
    let c = cos(a);
    let s = sin(a);
    return vec2<f32>(c * v.x - s * v.y, s * v.x + c * v.y);
}
// 2D gradient noise (0 to 1 about 0.5) on the sin hash (a gradient from one hash a corner, cheaper here than an integer
// hash): the cloud's plan is made of it, never of value noise, whose lattice shows through any sharp threshold of it as
// straight cuts and chevrons.
fn hu_gn2(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = p - i;
    let u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let h = vec4<f32>(hash21(i), hash21(i + vec2<f32>(1.0, 0.0)), hash21(i + vec2<f32>(0.0, 1.0)), hash21(i + vec2<f32>(1.0, 1.0)));
    let gx = h * 2.0 - 1.0;
    let gy = fract(h * 37.13) * 2.0 - 1.0;
    let a = gx.x * f.x + gy.x * f.y;
    let b = gx.y * (f.x - 1.0) + gy.y * f.y;
    let c = gx.z * f.x + gy.z * (f.y - 1.0);
    let d = gx.w * (f.x - 1.0) + gy.w * (f.y - 1.0);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 0.8 + 0.5;
}
fn hu_565(c: u32) -> vec3<f32> {
    return srgb_to_linear(vec3<f32>(f32((c >> 11u) & 31u) / 31.0, f32((c >> 5u) & 63u) / 63.0, f32(c & 31u) / 31.0));
}

// ---- the wind (hurricane.rs's spin, spin_int, wind_shape, omega, phase, front_t) -----------------------------------
fn hu_spin(t: f32) -> f32 {
    var k = array<vec2<f32>, 7>(vec2<f32>(0.0, 0.04), vec2<f32>(8.0, 0.15), vec2<f32>(26.0, 1.0), vec2<f32>(44.0, 1.0), vec2<f32>(50.0, 0.35), vec2<f32>(58.0, 0.08), vec2<f32>(64.0, 0.0));
    for (var i = 0; i < 6; i = i + 1) {
        let a = k[i];
        let b = k[i + 1];
        if (t <= b.x) {
            return mix(a.y, b.y, clamp((t - a.x) / (b.x - a.x), 0.0, 1.0));
        }
    }
    return 0.0;
}
fn hu_spin_int(t: f32) -> f32 {
    var k = array<vec2<f32>, 7>(vec2<f32>(0.0, 0.04), vec2<f32>(8.0, 0.15), vec2<f32>(26.0, 1.0), vec2<f32>(44.0, 1.0), vec2<f32>(50.0, 0.35), vec2<f32>(58.0, 0.08), vec2<f32>(64.0, 0.0));
    var s = 0.0;
    for (var i = 0; i < 6; i = i + 1) {
        let a = k[i];
        let b = k[i + 1];
        if (t <= a.x) {
            break;
        }
        let e = min(t, b.x);
        let se = a.y + (b.y - a.y) * (e - a.x) / (b.x - a.x);
        s = s + 0.5 * (a.y + se) * (e - a.x);
    }
    return s;
}
fn hu_shape(r: f32) -> f32 {
    return select(pow(HU_R_W / max(r, 1.0), 0.55), r / HU_R_W, r < HU_R_W);
}
fn hu_omega(r: f32) -> f32 {
    return HU_V * hu_shape(r) / max(r, 1.0);
}
fn hu_front(r: f32) -> f32 {
    if (r < HU_R_IN || r > HU_R_PLANTS) {
        return 1.0e9;
    }
    if (r < HU_R_W) {
        return HU_F0 + 3.0 * (HU_R_W - r) / (HU_R_W - HU_R_IN);
    }
    return HU_F0 + (HU_F1 - HU_F0) * pow((r - HU_R_W) / (HU_R_LIFT - HU_R_W), 1.25);
}
// How far the storm has formed (cloud there at all), how organised it is (0 a ragged mass of storms, 1 a spiral wound
// tight round a dense core), how much of it is left as it breaks up, how clear its eye is, how strong it is (the
// eyewall's height, the stadium's flare).
fn hu_form(t: f32) -> f32 {
    return smoothstep(0.0, 6.0, t);
}
fn hu_org(t: f32) -> f32 {
    return smoothstep(2.0, 16.0, t);
}
fn hu_fade(t: f32) -> f32 {
    return 1.0 - smoothstep(HU_CLEAR, HU_LEN - 1.0, t);
}
// How far the storm has come together at pp (the bands' turning frame, r out; 0 to 1): the core first, then out along
// the bands, each place at its own time (a broad noise) and eased in, so no part of its forming is a step or a ramp
// over the whole of it at once.
fn hu_mature(pp: vec2<f32>, r: f32, t: f32) -> f32 {
    if (t > 21.0) {
        return 1.0;
    }
    let n = hu_gn2(pp * (1.0 / 430.0) + vec2<f32>(41.0, 13.0));
    let t0 = max(1.2 + 5.0 * smoothstep(0.0, 1500.0, r) + 8.0 * (n - 0.5), 0.6);
    let x = saturate((t - t0) / 9.5);
    return x * x * (3.0 - 2.0 * x);
}
// How much of the cloud is left at the very end (1 to 0; `n` a broad noise there, -0.5 to 0.5, `cov` how much cloud
// the plan has there): each place thinning away to nothing at its own time, the edges first, and all of it gone before
// the strike ends, so nothing is left to pop out of the sky.
fn hu_gone(n: f32, cov: f32, t: f32) -> f32 {
    if (t < 53.0) {
        return 1.0;
    }
    let te = 58.6 + 5.0 * n - 1.6 * (1.0 - cov);
    let x = saturate((te + 2.2 - t) / 4.4);
    return x * x * (3.0 - 2.0 * x) * (1.0 - smoothstep(60.4, 63.4, t));
}
fn hu_eye(t: f32) -> f32 {
    return smoothstep(10.0, HU_EYE_T + 3.0, t) * (1.0 - 0.9 * smoothstep(HU_FLING + 1.0, HU_CLEAR + 3.0, t));
}
// How soft the cloud's edges are: wispy while it gathers (each place till it has come together, `m`: `hu_mature`) and
// again as it breaks up (from the fling), the mature storm's solid deck in between.
fn hu_soft(t: f32, m: f32) -> f32 {
    return max(1.0 - smoothstep(0.45, 1.0, m), smoothstep(HU_FLING, HU_FLING + 7.0, t));
}
fn hu_inten(t: f32) -> f32 {
    return smoothstep(9.0, 30.0, t) * (1.0 - 0.45 * smoothstep(HU_FLING, HU_CLEAR + 4.0, t));
}
// How hard it rains (0 to 1), how far out the deck reaches.
fn hu_rain(t: f32) -> f32 {
    return smoothstep(4.0, 12.0, t) * (1.0 - smoothstep(HU_CLEAR - 3.0, HU_CLEAR + 4.0, t));
}
fn hu_deck_r(t: f32) -> f32 {
    return 700.0 + (HU_DECK - 700.0) * smoothstep(0.0, 16.0, t);
}
// The stadium: the eyewall slopes out as it rises, more as the storm strengthens, most at its height (36-46 s, the
// eye at its widest and clearest); its inner face and outer edge at height y over the land, and its top.
fn hu_widen(t: f32) -> f32 {
    return mix(0.55, 1.0, hu_inten(t)) * (1.0 + 0.2 * smoothstep(36.0, 43.0, t) * (1.0 - smoothstep(HU_FLING, HU_FLING + 6.0, t)));
}
fn hu_flare(y: f32, t: f32) -> f32 {
    let yy = max(y, 0.0);
    return (0.08 * yy + 0.00045 * yy * yy) * hu_widen(t);
}
fn hu_wall_in(y: f32, t: f32) -> f32 {
    return HU_R_EYE + 3.0 + hu_flare(y, t);
}
fn hu_wall_out(y: f32, t: f32) -> f32 {
    return hu_wall_in(y, t) + 46.0 + 0.1 * max(y, 0.0);
}
fn hu_wall_top(t: f32) -> f32 {
    return mix(260.0, HU_TOP, hu_inten(t));
}

// ---- the land's height round the middle (the table's HU_G) ----------------------------------------------------------
fn hu_g_at(i: u32, a: u32) -> f32 {
    let v = hu_w(HU_G + min(i, HU_GR - 1u) * HU_GA + (a % HU_GA));
    return select(0.0, v, v == v);
}
// The ground over the middle's at q (off the middle).
fn hu_ground(q: vec2<f32>) -> f32 {
    if (!hu_have()) {
        return 0.0;
    }
    let r = length(q) / HU_G_STEP - 0.5;
    let a = fract(atan2(q.y, q.x) / TAU) * f32(HU_GA) - 0.5;
    let ri = clamp(floor(r), 0.0, f32(HU_GR - 1u));
    let fr = clamp(r - ri, 0.0, 1.0);
    let ai = floor(a);
    let fa = a - ai;
    let i0 = u32(ri);
    let i1 = min(i0 + 1u, HU_GR - 1u);
    let a0 = u32(ai + f32(HU_GA)) % HU_GA;
    let a1 = (a0 + 1u) % HU_GA;
    // (the table's heights are over the target block's top; the pass's middle is over the middle's ground: gdy0 over it)
    return mix(mix(hu_g_at(i0, a0), hu_g_at(i0, a1), fa), mix(hu_g_at(i1, a0), hu_g_at(i1, a1), fa), fr) - hu_w(1u);
}

// ---- the blocks flying round the eyewall (hurricane.rs's ring_*; keep in step) ---------------------------------------
fn hu_ring_r(k: i32) -> f32 {
    return HU_RING0 + HU_RING_W * (f32(k) + 0.5);
}
fn hu_ring_h(r: f32) -> f32 {
    return 30.0 + 218.0 * (1.0 - smoothstep(70.0, 150.0, r));
}
fn hu_ring_rise(r: f32) -> f32 {
    return 2.0 + 13.0 * (1.0 - smoothstep(60.0, 140.0, r));
}
fn hu_ring_dens(r: f32) -> f32 {
    return 0.045 + 0.115 * (1.0 - smoothstep(105.0, 160.0, r));
}
// Whether a ring's blocks are about: from its front (they rise out of the land from then, `hu_block`) until they have
// all come back down after the fling (each shattering to dust where it hits the land), never faded in or out.
fn hu_ring_on(r: f32, t: f32) -> f32 {
    let f = hu_front(r);
    return smoothstep(f, f + 1.0, t) * (1.0 - smoothstep(HU_FLING + 7.0, HU_FLING + 8.0, t));
}
// The fling: how far out everything has been thrown since HU_FLING, and how far it has risen and fallen.
fn hu_flung(t: f32) -> vec2<f32> {
    let s = max(t - HU_FLING, 0.0);
    return vec2<f32>(9.0 * s, 4.0 * s - 7.0 * s * s);
}
// A turn by `a` about unit `ax` (Rodrigues), as a matrix.
fn hu_rot(ax: vec3<f32>, a: f32) -> mat3x3<f32> {
    let c = cos(a);
    let s = sin(a);
    let k = 1.0 - c;
    let x = ax.x;
    let y = ax.y;
    let z = ax.z;
    return mat3x3<f32>(
        vec3<f32>(k * x * x + c, k * x * y + s * z, k * x * z - s * y),
        vec3<f32>(k * x * y - s * z, k * y * y + c, k * y * z + s * x),
        vec3<f32>(k * x * z + s * y, k * y * z - s * x, k * z * z + c));
}
fn hu_unit(h: u32) -> vec3<f32> {
    let v = vec3<f32>(f32(h & 1023u), f32((h >> 10u) & 1023u), f32((h >> 20u) & 1023u)) / 511.5 - 1.0;
    return normalize(v + vec3<f32>(1.0e-3, 2.0e-3, 0.0));
}

struct HuHit {
    t: f32,
    n: vec3<f32>,
    // the block type it is (the table's HU_BK), which of its faces (0 its top, 1 its bottom, 2 a side) and where on
    // that face (0 to 1 across it), and how the face is lit apart from the light (a leaf's dapple)
    bk: u32,
    face: u32,
    uv: vec2<f32>,
    shade: f32,
    // what it was: -2048 nothing, -1 - i tree i, else a block (its packed cell, `hu_pack`)
    id: vec2<f32>,
    // the nearest block or tree the ray passed through the clear or the glass of, if nearer than what it hit (`ct`
    // 1e9 none, its id as two half floats): what the half-size stage hands on for that pixel, so the sharp stage draws
    // it whole; and the nearest translucent block in front of it (stained glass, ice, slime: `hu_see`), found again
    // for its colour once the search is done (`gt` 1e9 none). Kept small: the searches' loops hold it all the way.
    ct: f32,
    cid: u32,
    gt: f32,
    gid: u32,
    // (below 0: the search again for the translucent block, which is then taken as a hit)
    lo: f32,
}
fn hu_none() -> HuHit {
    var h: HuHit;
    h.t = 1.0e9;
    h.n = vec3<f32>(0.0, 1.0, 0.0);
    h.bk = 0u;
    h.face = 2u;
    h.uv = vec2<f32>(0.5);
    h.shade = 1.0;
    h.id = vec2<f32>(-2048.0, 0.0);
    h.ct = 1.0e9;
    h.cid = pack2x16float(vec2<f32>(-2048.0, 0.0));
    h.gt = 1.0e9;
    h.gid = 0u;
    h.lo = 0.0;
    return h;
}
// The mip level a block's sixteen texels are seen at `t` off.
fn hu_lod(t: f32) -> f32 {
    let px = 2.0 * tan(0.5 * frame.view_params.w) * frame.resolution.w;
    return log2(max(t * px * 16.0, 1.0e-4));
}
// Where on its sprite block type `bk`'s face (its word `m` of how the texture runs, hurricane.rs's face_words) shows `uv`.
fn hu_face_st(m: u32, uv: vec2<f32>) -> vec2<f32> {
    let q = vec3<f32>(vec3<u32>(m, m >> 2u, m >> 4u) & vec3<u32>(3u)) - 1.0;
    let r = vec3<f32>(vec3<u32>(m >> 6u, m >> 8u, m >> 10u) & vec3<u32>(3u)) - 1.0;
    // (u0, v0, du-u | du-v, dv-u, dv-v)
    return fract(vec2<f32>(q.x + uv.x * q.z + uv.y * r.y, q.y + uv.x * r.x + uv.y * r.z) * 0.99999 + 0.000005);
}
// How much of block type `bk`'s face `face` there is at `uv` on it, seen `t` off (the atlas's flags, as the game draws
// them): x 1 where it is solid, 0 where a cut-out texture is clear (leaves, glass, flowers, rails, bars), a translucent
// one's own alpha (stained glass, ice, slime); y what it is, 0 solid, 1 cut out, 2 translucent. Far off (a block a few
// pixels) all of it there, in its colour.
fn hu_see(bk: u32, face: u32, uv: vec2<f32>, t: f32) -> vec2<f32> {
    let o = HU_BK + bk * HU_BKW + 3u * face;
    let f0 = hu_u(o + 2u);
    let kind = select(select(0.0, 1.0, (f0 & 2u) != 0u), 2.0, (f0 & 0x8000u) != 0u);
    if ((f0 & 1u) == 0u || kind < 0.5) {
        return vec2<f32>(1.0, 0.0);
    }
    let lod = hu_lod(t);
    if (lod > 3.5) {
        return vec2<f32>(1.0, kind);
    }
    let lv = clamp(lod, 0.0, f32(textureNumLevels(block_sprites) - 1));
    let a = textureSampleLevel(block_sprites, block_sampler, hu_face_st(hu_u(o + 4u), uv), i32((f0 >> 2u) & 0x1FFFu), lv).a;
    return vec2<f32>(select(a, step(0.5, a), kind < 1.5), kind);
}
// A translucent face hit at `t`, kept if it is the nearest of them in front of what is solid.
fn hu_glass(best: ptr<function, HuHit>, t: f32, id: vec2<f32>) {
    if (t < (*best).gt && t < (*best).t) {
        (*best).gt = t;
        (*best).gid = pack2x16float(id);
    }
    hu_touch(best, t, id);
}
fn hu_touch(best: ptr<function, HuHit>, t: f32, id: vec2<f32>) {
    if (t < (*best).ct) {
        (*best).ct = t;
        (*best).cid = pack2x16float(id);
    }
}
// The colour of block type `bk`'s face `face` (0 top, 1 bottom, 2 a side) at `uv` on it (0 to 1 along the side's two
// axes, as the game's block sprites name them), linear, `lod` the mip level its texels are seen at: the game's own
// texture where the mod packed one for it (hurricane.rs's bk_words: the face, the overlay laid over it (a grass block's
// tinted side), each tinted as the game tints it; a cut-out texture's clear pixels, where the pass does not see
// through them (`hu_see`: past a few layers of them, and far off), dark, as fast leaves are), else
// (and far off, where a block is a few pixels) its texture's average colour.
fn hu_face(bk: u32, face: u32, uv: vec2<f32>, lod: f32) -> vec3<f32> {
    let o = HU_BK + bk * HU_BKW;
    let a = hu_u(o);
    let b = hu_u(o + 1u);
    let avg = hu_565(select(select(a >> 16u, b & 0xFFFFu, face == 1u), a & 0xFFFFu, face == 0u));
    let f0 = hu_u(o + 2u + 3u * face);
    if ((f0 & 1u) == 0u || lod > 3.5) {
        return avg;
    }
    let st = hu_face_st(hu_u(o + 4u + 3u * face), uv);
    let lv = clamp(lod, 0.0, f32(textureNumLevels(block_sprites) - 1));
    let c0 = textureSampleLevel(block_sprites, block_sampler, st, i32((f0 >> 2u) & 0x1FFFu), lv);
    var rgb = srgb_to_linear(c0.rgb * hu_tint(f0 >> 16u));
    if ((f0 & 2u) != 0u && c0.a < 0.5) {
        rgb = avg * 0.3;
    }
    let f1 = hu_u(o + 3u + 3u * face);
    if ((f1 & 1u) != 0u) {
        let c1 = textureSampleLevel(block_sprites, block_sampler, st, i32((f1 >> 2u) & 0x1FFFu), lv);
        rgb = mix(rgb, srgb_to_linear(c1.rgb * hu_tint(f1 >> 16u)), c1.a);
    }
    return rgb;
}
// A face's tint (5-6-5; 0xFFFF none), gamma-encoded as the game multiplies the texture by it.
fn hu_tint(c: u32) -> vec3<f32> {
    if (c == 0xFFFFu) {
        return vec3<f32>(1.0);
    }
    return vec3<f32>(f32((c >> 11u) & 31u) / 31.0, f32((c >> 5u) & 63u) / 63.0, f32(c & 31u) / 31.0);
}
// Which face of a block a local normal `nl` (its own axes) is.
fn hu_face_of(nl: vec3<f32>) -> u32 {
    return select(2u, select(1u, 0u, nl.y > 0.0), abs(nl.y) > 0.5);
}
// A block's cell (ring k, round it iu, up it iv) packed into two half-floats exactly (whole numbers to 2048 each,
// and y's sign), and back: x round it and k's low two bits; y up it (-512 to 511: the blocks low down late in the
// storm, their columns climbed hundreds of blocks, sit well under -128, which overflowed into k before and was found
// again as another cell in the half-size stage's join: nothing hit, the cloud behind showing white in its shape),
// k's third bit in it and its fourth as y's sign.
fn hu_pack(k: i32, iu: i32, iv: i32) -> vec2<f32> {
    let m = f32(clamp(iv + 512, 0, 1023) + 1 + 1024 * ((k >> 2u) & 1));
    return vec2<f32>(f32(iu + 512 * (k & 3)), select(m, -m, ((k >> 3u) & 1) == 1));
}
fn hu_unpack(id: vec2<f32>) -> vec3<i32> {
    let a = i32(id.x + 0.5);
    let b = i32(abs(id.y) + 0.5) - 1;
    let k = (a >> 9u) | ((b >> 10u) << 2u) | (select(0, 1, id.y < 0.0) << 3u);
    return vec3<i32>(k, a & 511, (b & 1023) - 512);
}

// Ray rd (from the eye) against the block in cell (k, iu, iv) at `t`, the middle at C (off the eye): its hit, if
// nearer than `best`. St: the wind's sum to now, Sf: to the fling (the climb stops there).
// Each column of a ring's cells (ring k, round it iu) its own: how fast it climbs (a share of the ring's rise) and how
// far its cells sit up it (in cells), so no row of blocks lines up with the next column's, nor stays in step with it.
fn hu_column(k: i32, iu: i32, seed: u32) -> vec2<f32> {
    let hc = pcg((u32(k) * 0x27D4EB2Fu) ^ (bitcast<u32>(iu) * 0x165667B1u) ^ seed);
    return vec2<f32>(0.65 + 0.7 * f32(hc & 0xFFFFu) / 65535.0, f32(hc >> 16u) / 65535.0);
}
// The block (or two) in cell (k, iu, iv): a cell holds one as its ring's density says, thinned and thickened in
// patches, and now and then two.
fn hu_block(rd: vec3<f32>, C: vec3<f32>, k: i32, iu: i32, iv: i32, t: f32, St: f32, Sf: f32, seed: u32, best: ptr<function, HuHit>) {
    let rk = hu_ring_r(k);
    let h = pcg(u32(k) * 0x9E3779B1u ^ pcg(bitcast<u32>(iu) ^ pcg(bitcast<u32>(iv) * 0x85EBCA6Bu ^ seed)));
    let tfr = hu_front(rk);
    let u = f32(h & 0xFFFFu) * (1.0 / 65535.0);
    let dens = hu_ring_dens(rk);
    if (t < tfr || t > HU_FLING + 8.0 || u >= dens * 1.7) {
        return;
    }
    if (u >= dens * (0.3 + 1.4 * vnoise(vec2<f32>(f32(iu) * 0.11 + f32(k) * 3.7, f32(iv) * 0.15 + f32(k) * 1.3)))) {
        return;
    }
    hu_block_one(rd, C, k, iu, iv, t, St, Sf, seed, h, best);
    if (((h >> 16u) & 255u) < 45u) {
        hu_block_one(rd, C, k, iu, iv, t, St, Sf, seed, pcg(h ^ 0xA511E9B3u), best);
    }
}
fn hu_block_one(rd: vec3<f32>, C: vec3<f32>, k: i32, iu: i32, iv: i32, t: f32, St: f32, Sf: f32, seed: u32, h: u32, best: ptr<function, HuHit>) {
    let rk = hu_ring_r(k);
    let tfr = hu_front(rk);
    let h2 = pcg(h);
    let h3 = pcg(h2 ^ 0x51u);
    let h4 = pcg(h3 ^ 0x77u);
    let nu = floor(TAU * rk / HU_CELL);
    // (anywhere in its cell, wobbling about there as it goes, its own way out from the ring's middle: never a lattice)
    let wf = 1.0 + 1.5 * f32(h4 & 255u) / 255.0;
    let wp = f32((h4 >> 8u) & 255u) * 0.0246;
    let ju = (f32(h2 & 255u) / 255.0 - 0.5) * 0.56 + 0.12 * sin(wf * t + wp);
    let jv = (f32((h2 >> 8u) & 255u) / 255.0 - 0.5) * 0.56 + 0.12 * sin(1.3 * wf * t + 2.0 * wp);
    let jr = (f32((h2 >> 16u) & 255u) / 255.0 - 0.5) * 8.0 + 0.8 * sin(0.7 * wf * t + 3.0 * wp);
    let pick = h2 >> 24u;
    var size = select(select(1.5, 0.55, pick < 230u), 1.0, pick < 166u) * (0.8 + 0.4 * f32((h4 >> 16u) & 255u) / 255.0);
    let fl = hu_flung(t);
    let cv = hu_column(k, iu, seed);
    let a = HU_SPIN * hu_omega(rk) * St + (f32(iu) + 0.5 + ju) * TAU / nu;
    let y0 = (f32(iv) + 0.5 + jv + cv.y) * HU_CELL;
    let y = cv.x * hu_ring_rise(rk) * Sf + y0 + fl.y;
    // (out along the eyewall's slope as it climbs: the blocks follow its inner face up, the eye clear of them)
    let r = rk + jr + fl.x + hu_flare(y - fl.y, t);
    let pc = vec2<f32>(cos(a), sin(a)) * r;
    // (every block torn out of the land: it rises out of it once the front has passed, never appearing in the air (the
    // cells over the land as the front came are left empty); thinning out at the top of its ring, in the eyewall's
    // cloud; as it falls after the fling, shattered to dust where it hits)
    let g = hu_ground(pc);
    if (cv.x * hu_ring_rise(rk) * hu_spin_int(tfr) + y0 > g - 0.5) {
        return;
    }
    let yr = y - g;
    let hk = hu_ring_h(rk);
    size = size * smoothstep(-1.0, 2.0, yr) * (1.0 - smoothstep(0.72 * hk, hk, yr - fl.y));
    if (size < 0.12) {
        return;
    }
    let P = C + vec3<f32>(pc.x, y, pc.y);
    // (bounding sphere first)
    let b = dot(P, rd);
    let hs = 0.5 * size;
    let c = dot(P, P) - 0.76 * size * size;
    if (b * b < c || b - 1.0 > (*best).t) {
        return;
    }
    let m = hu_rot(hu_unit(h3), (1.5 + 3.0 * f32(h3 >> 22u) / 1023.0) * t + f32(h3 & 63u));
    let o = m * (-P);
    let d = m * rd;
    let inv = 1.0 / select(d, vec3<f32>(1.0e-6), abs(d) < vec3<f32>(1.0e-6));
    let t0 = (vec3<f32>(-hs) - o) * inv;
    let t1 = (vec3<f32>(hs) - o) * inv;
    let tn = min(t0, t1);
    let tf = max(t0, t1);
    let near = max(max(tn.x, tn.y), tn.z);
    let far = min(min(tf.x, tf.y), tf.z);
    // (none closer than a block or two to the eye: one going past it would fill the picture)
    if (near > far || far < 0.0 || near >= (*best).t || near < 1.5) {
        return;
    }
    var nl = vec3<f32>(0.0);
    if (near == tn.x) {
        nl.x = -sign(d.x);
    } else if (near == tn.y) {
        nl.y = -sign(d.y);
    } else {
        nl.z = -sign(d.z);
    }
    // (which block it is, which face of it, and where on that face; seen through where it is clear, as the game draws
    // a lone block: its faces towards the eye only)
    let bk = hu_u(HU_PAL + u32(k) * HU_PN + ((h3 >> 8u) % HU_PN));
    let face = hu_face_of(nl);
    let pl = (o + d * near) / size + 0.5;
    let fuv = select(select(pl.xy, pl.xz, abs(nl.y) > 0.5), pl.zy, abs(nl.x) > 0.5);
    let see = hu_see(bk, face, fuv, near);
    if (see.x < 0.5 && see.y > 0.5 && see.y < 1.5) {
        hu_touch(best, near, hu_pack(k, iu, iv));
        return;
    }
    if (see.y > 1.5 && (*best).lo >= 0.0) {
        hu_glass(best, near, hu_pack(k, iu, iv));
        return;
    }
    (*best).t = near;
    (*best).n = transpose(m) * nl;
    (*best).bk = bk;
    (*best).face = face;
    (*best).uv = fuv;
    (*best).shade = 0.85 + 0.3 * f32((h3 >> 4u) & 15u) / 15.0;
    (*best).id = hu_pack(k, iu, iv);
}

// The blocks along ray rd up to `t_max`: marched through the rings' cells, nearest first; each cell's block (if any)
// tried once.
fn hu_debris(rd: vec3<f32>, C: vec3<f32>, t_max: f32, t: f32, St: f32, Sf: f32, seed: u32, steps: i32, best: ptr<function, HuHit>) {
    let fl = hu_flung(t);
    if (hu_ring_on(HU_R_W, t) + hu_ring_on(140.0, t) < 0.001) {
        return;
    }
    let o = -C;
    let ro = HU_RING0 + f32(HU_NR) * HU_RING_W + fl.x + 1.5;
    let ri = HU_RING0 + fl.x - 1.5;
    // (the rings' cylinder, and the heights its blocks reach)
    let qa = dot(rd.xz, rd.xz);
    let qb = dot(o.xz, rd.xz);
    let qc = dot(o.xz, o.xz) - ro * ro;
    let disc = qb * qb - qa * qc;
    if (disc <= 0.0 || qa < 1.0e-8) {
        return;
    }
    let sq = sqrt(disc);
    var t0 = max((-qb - sq) / qa, 0.0);
    var t1 = min((-qb + sq) / qa, t_max);
    let ylo = -60.0 + min(fl.y, 0.0);
    let yhi = 262.0 + max(fl.y, 0.0);
    if (abs(rd.y) > 1.0e-5) {
        let ta = (ylo - o.y) / rd.y;
        let tb = (yhi - o.y) / rd.y;
        t0 = max(t0, min(ta, tb));
        t1 = min(t1, max(ta, tb));
    }
    if (t1 <= t0) {
        return;
    }
    // (the eye's: the march leaps over it)
    let qci = dot(o.xz, o.xz) - ri * ri;
    let disci = qb * qb - qa * qci;
    var ti0 = 1.0e9;
    var ti1 = -1.0e9;
    if (disci > 0.0) {
        let s2 = sqrt(disci);
        ti0 = (-qb - s2) / qa;
        ti1 = (-qb + s2) / qa;
    }
    var tt = t0;
    var last = vec3<i32>(-99);
    var stop = 1.0e9;
    for (var i = 0; i < steps; i = i + 1) {
        if (tt > t1 || tt > stop) {
            break;
        }
        if (tt > ti0 && tt < ti1) {
            tt = ti1 + 0.01;
            continue;
        }
        let q = o + rd * tt;
        let r = length(q.xz);
        let dt = clamp(0.7 + 0.0045 * tt, 0.75, 2.4);
        let fy = hu_flare(q.y - fl.y, t);
        let k = i32(floor((r - fl.x - fy - HU_RING0) / HU_RING_W));
        if (k < 0 || k >= HU_NR) {
            tt = tt + dt;
            continue;
        }
        let rk = hu_ring_r(k);
        // (above where this ring's blocks go: on quickly)
        if (q.y > hu_ring_h(rk) + 30.0 + max(fl.y, 0.0)) {
            tt = tt + max(dt, 4.0);
            continue;
        }
        let nu = floor(TAU * rk / HU_CELL);
        let ph = HU_SPIN * hu_omega(rk) * St;
        let iu = i32(floor(fract((atan2(q.z, q.x) - ph) / TAU) * nu));
        let cv = hu_column(k, iu, seed);
        let iv = i32(floor((q.y - cv.x * hu_ring_rise(rk) * Sf - fl.y) / HU_CELL - cv.y));
        let cell = vec3<i32>(k, iu, iv);
        if (any(cell != last)) {
            last = cell;
            let before = (*best).t;
            hu_block(rd, C, k, iu, iv, t, St, Sf, seed, best);
            if ((*best).t < before) {
                stop = (*best).t + 2.5;
            }
        }
        tt = tt + dt;
    }
}

// ---- the trees, whole -------------------------------------------------------------------------------------------------
// Tree i's middle at `t` (off the target's middle, as hurricane.rs's tree_at), its turn, and whether it is up.
struct HuTree {
    p: vec3<f32>,
    m: mat3x3<f32>,
    cm: f32,
    up: bool,
}
fn hu_tree_lifted(base: u32, i: u32, t: f32, St: f32, seed: u32) -> vec3<f32> {
    let x0 = hu_w(base);
    let z0 = hu_w(base + 1u);
    let gdy = hu_w(base + 2u);
    let t_up = hu_w(base + 3u);
    let s_up = hu_w(base + 7u);
    let trunk = f32(hu_u(base + 4u) & 31u);
    let r_orb = 70.0 + 50.0 * mh(i, seed, 0xa1u);
    let y_orb = 25.0 + 115.0 * pow(mh(i, seed, 0xa2u), 1.4);
    let tau = max(t - t_up, 0.0);
    let r0 = length(vec2<f32>(x0, z0));
    let a0 = atan2(z0, x0);
    let r = r_orb + (r0 - r_orb) * exp(-tau / 5.0);
    let ly = 1.0 - exp(-max(tau - 0.5, 0.0) / 3.5);
    let cm = 0.6 * max(trunk, 3.0);
    let y = gdy + cm + (y_orb - gdy) * ly;
    let a = a0 + HU_SPIN * hu_omega(r) * (St - s_up);
    return vec3<f32>(r * cos(a), y, r * sin(a));
}
// (`rot`: its turn too; without it only where it is, for a first test against its bounding sphere. `Sf`: the wind's
// sum to the fling)
fn hu_tree_at(i: u32, t: f32, St: f32, Sf: f32, seed: u32, rot: bool) -> HuTree {
    var o: HuTree;
    o.m = mat3x3<f32>(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, 0.0, 1.0));
    let base = HU_T + i * HU_TW;
    let t_up = hu_w(base + 3u);
    o.cm = 0.6 * max(f32(hu_u(base + 4u) & 31u), 3.0);
    o.up = t >= t_up;
    if (!o.up) {
        return o;
    }
    if (t <= HU_FLING || t_up >= HU_FLING) {
        o.p = hu_tree_lifted(base, i, t, St, seed);
    } else {
        let pf = hu_tree_lifted(base, i, HU_FLING, Sf, seed);
        let rf = max(length(pf.xz), 1.0);
        let ov = pf.xz / rf;
        let tv = vec2<f32>(-ov.y, ov.x) * HU_SPIN;
        let vt = hu_omega(rf) * rf * hu_spin(HU_FLING) * 0.6;
        let vo = 6.0 + 6.0 * mh(i, seed, 0xa3u);
        let vu = 3.0 + 4.0 * mh(i, seed, 0xa4u);
        let s = t - HU_FLING;
        let v = tv * vt + ov * vo;
        o.p = vec3<f32>(pf.x + v.x * s, pf.y + vu * s - 7.0 * s * s, pf.z + v.y * s);
        // (it comes down where hurricane.rs lays it as a real fallen tree, at the moment it does: t_land, lying along
        // the way it was thrown (yaw) on the land there (yl): the drawn tree hands over to the real one where it lies)
        let tl = hu_w(base + 25u);
        if (tl > HU_FLING) {
            o.up = t < tl;
            if (!rot) {
                return o;
            }
            let yaw = hu_w(base + 27u);
            let dd = vec3<f32>(cos(yaw), 0.0, sin(yaw));
            let land = transpose(mat3x3<f32>(vec3<f32>(-dd.z, 0.0, dd.x), dd, vec3<f32>(0.0, 1.0, 0.0)));
            let tau = max(t - t_up, 0.0);
            let h = pcg(i * 0x2545F491u ^ seed);
            let x0 = hu_w(base);
            let z0 = hu_w(base + 1u);
            let a0 = atan2(z0, x0);
            let ax = normalize(vec3<f32>(cos(a0), 0.0, sin(a0)) + 0.7 * hu_unit(h));
            let rate = 0.6 + 1.4 * f32(h >> 22u) / 1023.0;
            let ang = 1.1 * smoothstep(0.0, 1.0, tau) + rate * (tau - 1.2 * (1.0 - exp(-tau / 1.2)));
            o.m = hu_slerp(hu_rot(ax, ang * HU_SPIN), land, smoothstep(0.0, 1.0, (t - HU_FLING) / max(tl - HU_FLING, 0.1)));
            return o;
        }
        // (one broken apart in the air: its blocks, spread far apart, each gone where it hits the land: `hu_trees`)
        o.up = o.p.y > hu_ground(o.p.xz) + select(1.0, -60.0, hu_w(base + 6u) < 1.0e8);
    }
    if (!rot) {
        return o;
    }
    // (it rocks over on its roots the way the wind blows, then tumbles end over end as it goes)
    let tau = max(t - t_up, 0.0);
    let x0 = hu_w(base);
    let z0 = hu_w(base + 1u);
    let a0 = atan2(z0, x0);
    let h = pcg(i * 0x2545F491u ^ seed);
    let ax = normalize(vec3<f32>(cos(a0), 0.0, sin(a0)) + 0.7 * hu_unit(h));
    let rate = 0.6 + 1.4 * f32(h >> 22u) / 1023.0;
    let ang = 1.1 * smoothstep(0.0, 1.0, tau) + rate * (tau - 1.2 * (1.0 - exp(-tau / 1.2)));
    o.m = hu_rot(ax, ang * HU_SPIN);
    return o;
}
// Rotations as quaternions (x, y, z, w), to turn one smoothly into another: a tumbling tree settling as it lands.
fn hu_q_of(m: mat3x3<f32>) -> vec4<f32> {
    let tr = m[0][0] + m[1][1] + m[2][2];
    if (tr > 0.0) {
        let s = sqrt(tr + 1.0) * 2.0;
        return vec4<f32>((m[1][2] - m[2][1]) / s, (m[2][0] - m[0][2]) / s, (m[0][1] - m[1][0]) / s, 0.25 * s);
    }
    if (m[0][0] > m[1][1] && m[0][0] > m[2][2]) {
        let s = sqrt(1.0 + m[0][0] - m[1][1] - m[2][2]) * 2.0;
        return vec4<f32>(0.25 * s, (m[1][0] + m[0][1]) / s, (m[2][0] + m[0][2]) / s, (m[1][2] - m[2][1]) / s);
    }
    if (m[1][1] > m[2][2]) {
        let s = sqrt(1.0 + m[1][1] - m[0][0] - m[2][2]) * 2.0;
        return vec4<f32>((m[1][0] + m[0][1]) / s, 0.25 * s, (m[2][1] + m[1][2]) / s, (m[2][0] - m[0][2]) / s);
    }
    let s = sqrt(1.0 + m[2][2] - m[0][0] - m[1][1]) * 2.0;
    return vec4<f32>((m[2][0] + m[0][2]) / s, (m[2][1] + m[1][2]) / s, 0.25 * s, (m[0][1] - m[1][0]) / s);
}
fn hu_m_of(q: vec4<f32>) -> mat3x3<f32> {
    let x = q.x;
    let y = q.y;
    let z = q.z;
    let w = q.w;
    return mat3x3<f32>(
        vec3<f32>(1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y + z * w), 2.0 * (x * z - y * w)),
        vec3<f32>(2.0 * (x * y - z * w), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z + x * w)),
        vec3<f32>(2.0 * (x * z + y * w), 2.0 * (y * z - x * w), 1.0 - 2.0 * (x * x + y * y)));
}
fn hu_slerp(a: mat3x3<f32>, b: mat3x3<f32>, u: f32) -> mat3x3<f32> {
    let qa = hu_q_of(a);
    var qb = hu_q_of(b);
    if (dot(qa, qb) < 0.0) {
        qb = -qb;
    }
    return hu_m_of(normalize(mix(qa, qb, u)));
}
// What tree `base`'s cell (i, y, j) of its 7 by 7 columns holds: 0 nothing, 1 its trunk, 2 leaves.
fn hu_tree_cell(base: u32, i: i32, y: i32, j: i32, trunk: i32) -> u32 {
    if (i < 0 || i > 6 || j < 0 || j > 6 || y < 0) {
        return 0u;
    }
    if (i == 3 && j == 3 && y < trunk) {
        return 1u;
    }
    let c = u32(j * 7 + i);
    let v = (hu_u(base + 8u + c / 3u) >> (10u * (c % 3u))) & 1023u;
    let lo = i32(v & 31u);
    let hi = i32(v >> 5u);
    if (hi >= lo && y + 1 >= lo && y + 1 <= hi) {
        return 2u;
    }
    return 0u;
}
// The ray (`o`, `d`: in tree i's own frame, its trunk's foot at 0, x and z its columns less 3.5, y up its trunk)
// through its cells from `blo` to `bhi` (exclusive; a box of them: the whole tree or one piece of it), the nearest
// block hit kept in `best` (`mt` its frame back to the world's; `ground`: none under the land, `C` the middle, for a
// piece flying free).
fn hu_vox(base: u32, i: u32, trunk: i32, o: vec3<f32>, d: vec3<f32>, blo: vec3<i32>, bhi: vec3<i32>, mt: mat3x3<f32>, rd: vec3<f32>, C: vec3<f32>, ground: bool, best: ptr<function, HuHit>) {
    let inv = 1.0 / select(d, vec3<f32>(1.0e-6), abs(d) < vec3<f32>(1.0e-6));
    let off = vec3<f32>(3.5, 0.0, 3.5);
    let ta = (vec3<f32>(blo) - off - o) * inv;
    let tb = (vec3<f32>(bhi) - off - o) * inv;
    let near = max(max(min(ta.x, tb.x), min(ta.y, tb.y)), min(ta.z, tb.z));
    let far = min(min(max(ta.x, tb.x), max(ta.y, tb.y)), max(ta.z, tb.z));
    if (near > far || far < 0.0 || near > (*best).t) {
        return;
    }
    let ts = max(near, 0.0) + 1.0e-3;
    let p0 = o + d * ts + off;
    var cell = clamp(vec3<i32>(floor(p0)), blo, bhi - vec3<i32>(1));
    let stp = vec3<i32>(sign(d));
    let tdel = abs(inv);
    var tmx = (vec3<f32>(cell) + max(sign(d), vec3<f32>(0.0)) - p0) * inv + vec3<f32>(ts);
    var axis = select(select(2, 1, near == min(ta.y, tb.y)), 0, near == min(ta.x, tb.x));
    // (through the clear of its leaves (and a building's glass) to what is behind, as the game draws them, a few layers
    // at most: past that, as if solid)
    var layers = 0;
    for (var s = 0; s < 40; s = s + 1) {
        let what = hu_tree_cell(base, cell.x, cell.y, cell.z, trunk);
        if (what > 0u) {
            let th = select(ts, select(select(tmx.z - tdel.z, tmx.y - tdel.y, axis == 1), tmx.x - tdel.x, axis == 0), s > 0);
            let wq = rd * th - C;
            if (th >= (*best).t || (ground && wq.y <= hu_ground(wq.xz) - 0.5)) {
                return;
            }
            var nl = vec3<f32>(0.0);
            if (axis == 0) {
                nl.x = -sign(d.x);
            } else if (axis == 1) {
                nl.y = -sign(d.y);
            } else {
                nl.z = -sign(d.z);
            }
            let kinds = hu_u(base + 5u);
            let bk = select(kinds >> 16u, kinds & 0xFFFFu, what == 1u);
            let face = hu_face_of(nl);
            let pl = fract(o + d * th + off);
            let fuv = select(select(pl.xy, pl.xz, axis == 1), pl.zy, axis == 0);
            var see = vec2<f32>(1.0, 0.0);
            if (what == 2u && layers < 6) {
                see = hu_see(bk, face, fuv, th);
            }
            // (a translucent block in a tree or a building's piece drawn as it is, solid)
            if (see.y > 0.5 && see.y < 1.5 && see.x < 0.5) {
                layers = layers + 1;
                hu_touch(best, th, vec2<f32>(-1.0 - f32(i), 0.0));
            } else {
                (*best).t = th;
                (*best).n = mt * nl;
                (*best).face = face;
                (*best).uv = fuv;
                (*best).bk = bk;
                if (what == 1u) {
                    (*best).shade = 1.0;
                } else {
                    let hh = pcg(u32(cell.x + 7 * cell.z) ^ pcg(u32(cell.y) ^ i));
                    (*best).shade = 0.7 + 0.5 * f32(hh & 255u) / 255.0;
                }
                (*best).id = vec2<f32>(-1.0 - f32(i), 0.0);
                return;
            }
        }
        if (tmx.x < tmx.y && tmx.x < tmx.z) {
            cell.x = cell.x + stp.x;
            tmx.x = tmx.x + tdel.x;
            axis = 0;
        } else if (tmx.y < tmx.z) {
            cell.y = cell.y + stp.y;
            tmx.y = tmx.y + tdel.y;
            axis = 1;
        } else {
            cell.z = cell.z + stp.z;
            tmx.z = tmx.z + tdel.z;
            axis = 2;
        }
        if (any(cell < blo) || any(cell >= bhi)) {
            return;
        }
    }
}
// A tree breaking apart in the air comes apart into HU_PCS pieces: its 7 by 7 columns split in two each way, its
// height in three (the canopy's top third its leaves, shredding into the smaller, faster-flying bits).
const HU_PCS: i32 = 12;
fn hu_piece_box(c: i32, hm: i32) -> array<vec3<i32>, 2> {
    let px = c & 1;
    let pz = (c >> 1u) & 1;
    let py = c >> 2u;
    let h3 = max((hm + 2) / 3, 1);
    // (uneven: a 4 and a 3 across, the cut wandering a column from tree to tree)
    let lo = vec3<i32>(select(0, 4, px == 1), py * h3, select(0, 3, pz == 1));
    let hi = vec3<i32>(select(4, 7, px == 1), select((py + 1) * h3, hm + 1, py == 2), select(3, 7, pz == 1));
    return array<vec3<i32>, 2>(lo, hi);
}
fn hu_trees(rd: vec3<f32>, C: vec3<f32>, t: f32, St: f32, Sf: f32, seed: u32, only: i32, best: ptr<function, HuHit>) {
    if (!hu_have()) {
        return;
    }
    let n = min(u32(hu_w(0u) + 0.5), HU_NT);
    var i0 = 0u;
    var i1 = n;
    if (only >= 0) {
        i0 = u32(only);
        i1 = min(i0 + 1u, n);
    }
    for (var i = i0; i < i1; i = i + 1u) {
        let base = HU_T + i * HU_TW;
        if (t < hu_w(base + 3u)) {
            continue;
        }
        let tp = hu_tree_at(i, t, St, Sf, seed, false);
        if (!tp.up) {
            continue;
        }
        let shape = hu_u(base + 4u);
        let trunk = i32(shape & 31u);
        let hm = f32((shape >> 5u) & 31u) + 1.0;
        // (a tree's heights are over the target block's top, as the real blocks' are: the middle's ground is gdy0 over it)
        let P = C + tp.p - vec3<f32>(0.0, hu_w(1u), 0.0);
        let tbrk = hu_w(base + 6u);
        let broken = t > tbrk;
        // (flying apart: its pieces spread at up to 7 blocks a second from where they were)
        // (spreading for 8 s, then carried on together, apart)
        let dsp = min(t - tbrk, 8.0);
        let rad = 0.5 * sqrt(98.0 + hm * hm) + 0.8 + abs(tp.cm - 0.5 * hm) + select(0.0, 7.0 * dsp + 2.0, broken);
        let b = dot(P, rd);
        let c = dot(P, P) - rad * rad;
        if (b * b < c || b - rad > (*best).t || length(P) < 6.0) {
            continue;
        }
        let cmv = vec3<f32>(0.0, tp.cm, 0.0);
        if (!broken) {
            let tr = hu_tree_at(i, t, St, Sf, seed, true);
            // (the ray in the tree's own frame: its trunk's foot at 0, its middle at cm)
            hu_vox(base, i, trunk, tr.m * (-P) + cmv, tr.m * rd, vec3<i32>(0), vec3<i32>(7, i32(hm) + 1, 7), transpose(tr.m), rd, C, false, best);
            continue;
        }
        // ---- broken apart: each piece its own body from the moment it breaks, starting where it was in the tree and
        // turned as the tree was then, then flung off on its own: the tree's way on with the wind, out from its middle
        // and some way of its own, tumbling about its own axis at its own rate; each block gone into the land where it
        // comes down
        let dt = t - tbrk;
        var mb = mat3x3<f32>(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, 0.0, 1.0));
        var have_mb = false;
        for (var pc = 0; pc < HU_PCS; pc = pc + 1) {
            let bx = hu_piece_box(pc, i32(hm));
            if (bx[1].y <= bx[0].y) {
                continue;
            }
            let lc = 0.5 * vec3<f32>(bx[0] + bx[1]) - vec3<f32>(3.5, 0.0, 3.5);
            let hp = pcg(i * 0x2545F491u ^ pcg(u32(pc) * 0x9E3779B1u ^ seed));
            let leaves = pc >= 8;
            let kick = hu_unit(hp) * (select(2.0, 4.0, leaves) + 3.0 * f32(hp & 255u) / 255.0) + vec3<f32>(0.0, -0.5 * dsp * select(0.4, 0.15, leaves), 0.0);
            // (first, wherever it is turned: within its distance from the tree's middle of where it is flung)
            let rr = 0.5 * length(vec3<f32>(bx[1] - bx[0])) + 0.6;
            let Pk = P + kick * dsp;
            let r0 = rr + length(lc - cmv);
            let b0 = dot(Pk, rd);
            if (b0 * b0 < dot(Pk, Pk) - r0 * r0 || b0 - r0 > (*best).t) {
                continue;
            }
            if (!have_mb) {
                mb = hu_tree_at(i, tbrk, hu_spin_int(tbrk), Sf, seed, true).m;
                have_mb = true;
            }
            let Pc = Pk + transpose(mb) * (lc - cmv);
            let bb = dot(Pc, rd);
            let cc = dot(Pc, Pc) - rr * rr;
            if (bb * bb < cc || bb - rr > (*best).t) {
                continue;
            }
            let mc = hu_rot(hu_unit(pcg(hp)), (select(1.2, 3.0, leaves) + 2.0 * f32((hp >> 8u) & 255u) / 255.0) * dt) * mb;
            hu_vox(base, i, trunk, mc * (-Pc) + lc, mc * rd, bx[0], bx[1], transpose(mc), rd, C, true, best);
        }
    }
}

// ---- the cloud, the rain and the dust -----------------------------------------------------------------------------------
fn hu_over(h: ptr<function, vec4<f32>>, c: vec3<f32>, x: f32) {
    *h = vec4<f32>((*h).rgb * (1.0 - x) + c * x, (*h).a * (1.0 - x));
}
// The cloud's turn by `t` at r: the bands and the shield go round all of a piece (a sweep you can see from above), the
// cloud close round the eye faster with the wind, sheared out into the streaks that ring a real eye.
fn hu_cloud_turn(r: f32, St: f32) -> f32 {
    return HU_SPIN * (0.09 + 0.45 * hu_omega(max(r, 25.0)) * (1.0 - smoothstep(110.0, 260.0, r))) * St;
}
// The cloud's top turns more gently (its streaks drawn out, never into scratches).
fn hu_top_turn(r: f32, St: f32) -> f32 {
    return HU_SPIN * (0.09 + 0.12 * hu_omega(max(r, 25.0)) * (1.0 - smoothstep(110.0, 360.0, r))) * St;
}
fn hu_arm_turn(St: f32) -> f32 {
    return HU_SPIN * 0.09 * St;
}
// The cloud's top at (pattern-frame) p, r out, in the texture frame p2: high over the eyewall, sloping down across the
// dense overcast to the bands, lumpy with the towers that overshoot it near the core, rippled round the eye.
fn hu_top(p2: vec2<f32>, r: f32, t: f32, m: f32) -> f32 {
    let core = hu_wall_top(t);
    var T = core - (core - 300.0) * smoothstep(90.0, 640.0, r) - 75.0 * smoothstep(640.0, 1600.0, r);
    let tur = hu_gn2(p2 * (1.0 / 52.0) + vec2<f32>(11.0, 3.0));
    let near = 1.0 - smoothstep(150.0, 700.0, r);
    T = T + (40.0 * near + 14.0) * (tur - 0.45) + 4.0 * sin(r * 0.21) * (1.0 - smoothstep(120.0, 380.0, r));
    // (rising as the storms first build: each place as it comes together, `m`)
    return mix(HU_BASE + 30.0, T, smoothstep(0.0, 0.75, m));
}
fn hu_base(r: f32, t: f32) -> f32 {
    // (lifted round the eyewall, a moat: from the land round it the eyewall's flank shows under the overcast)
    return HU_BASE + 30.0 * smoothstep(400.0, 1600.0, r) + 150.0 * hu_inten(t) * (1.0 - smoothstep(HU_FLING, HU_CLEAR, t)) * (1.0 - smoothstep(150.0, 300.0, r));
}

// The spiral bands at pp (in their turning frame, r out): x how strong (1 down a band's middle), y the warp that
// bends and breaks them. Three bands, loose as the storm gathers, wound tight round it as it organises (trailing:
// their outer ends behind the way it turns).
// (gradient noise, never value noise: a value noise's lattice shows through any sharp threshold of it as straight cuts
// and chevrons)
fn hu_arm(pp: vec2<f32>, r: f32, t: f32) -> vec2<f32> {
    let warp = hu_gn2(pp * (1.0 / 240.0) + vec2<f32>(5.0, 9.0));
    let kk = mix(1.4, 7.5, hu_org(t));
    let phi = 3.0 * atan2(pp.y, pp.x) + HU_SPIN * kk * log(max(r, 50.0) / 200.0) + 3.2 * (warp - 0.5);
    return vec2<f32>(0.5 + 0.5 * cos(phi), warp);
}

// The eye's face at q (off the middle's ground): the stadium's slope stepped in terraces, each a ledge stepping out
// over the one under it, wandering up and down round it (the texture frame's p2).
fn hu_eyeface(q: vec3<f32>, p2: vec2<f32>, t: f32) -> f32 {
    let tw = hu_gn2(p2 * (1.0 / 70.0) + vec2<f32>(31.0, 5.0));
    var f = hu_wall_in(q.y, t) + 8.0 * (tw - 0.5);
    // (and billowed with the towers it is built of, where it is near)
    if (abs(length(q.xz) - f) < 30.0) {
        f = f + 13.0 * (gnoise3(vec3<f32>(p2.x * (1.0 / 15.0), q.y * (1.0 / 12.0), p2.y * (1.0 / 15.0))) - 0.5);
    }
    return f;
}

struct HuDen {
    d: f32,       // the density (0 to 1)
    raw: f32,     // how far out of the cloud (tens of blocks, at least: the march strides over the clear air by it)
    wall: f32,    // how much of it is the eyewall
    arm: f32,     // the bands' rain cores
    top: f32,     // the cloud's top over here
    clear: f32,   // how much the point is in the clear eye
    face: f32,    // the eye's face here (how far out)
    soft: f32,    // how soft and thin it is here (`hu_soft`)
}
// The cloud's plan over the land at xz (off the middle): where it is, its base and its domed top.
struct HuCol {
    B: f32,       // its base
    T: f32,       // its top
    cov: f32,     // how much cloud there is over here (0 to 1)
    arm: f32,     // the bands (1 down a band's middle)
    warp: f32,
    bands: f32,
    cdo: f32,
    cn: f32,
    m: f32,       // how far it has come together here (`hu_mature`)
    h: f32,       // its depth's share of the full (thin at its edges, domed to the middle)
    n: f32,       // a broad noise (-0.5 to 0.5): when it goes at the end (`hu_gone`)
}
fn hu_col(xz: vec2<f32>, t: f32, St: f32) -> HuCol {
    var o: HuCol;
    let r = length(xz);
    let pp = rot2(xz, -hu_arm_turn(St));
    let lr = log(max(r, 50.0) / 200.0);
    let m = hu_mature(pp, r, t);
    o.m = m;
    // ---- the spiral: three bands wound in to the core, loose and ragged as it gathers, tightening as it organises
    // (trailing: their outer ends behind the way it turns), each warped and broken along its length, feathered at its
    // edges in streaks drawn out along it; close in they widen and run together into the overcast round the eye
    let aw = hu_arm(pp, r, t);
    o.arm = aw.x;
    o.warp = aw.y;
    let reach = hu_deck_r(t);
    let fp = rot2(pp, HU_SPIN * 2.5 * lr);
    let fray = hu_gn2(fp * (1.0 / 70.0) + vec2<f32>(2.0, 7.0));
    o.n = clamp(1.4 * (o.warp - 0.5) + 0.8 * (fray - 0.5), -0.5, 0.5);
    let merge = 0.5 * (1.0 - smoothstep(320.0, 1300.0, r));
    o.bands = smoothstep(0.4, 0.95, o.arm + 0.62 * (fray - 0.5) + merge) * (1.0 - smoothstep(reach * 0.45, reach * 0.95, r + 200.0 * (o.warp - 0.5)));
    // ---- the central dense overcast: one solid shield round the eye, the bands feathering out of it, its edge ragged
    let rc = HU_CDO * mix(0.35, 1.0, m);
    o.cdo = 1.0 - smoothstep(0.5 * rc, 1.12 * rc, r + 260.0 * (o.warp - 0.5) + 110.0 * (fray - 0.5) - 160.0 * (o.arm - 0.5));
    // ---- at first a ragged mass of storms: towering cells scattered over the target, drawn into the spiral
    // (gone where it has come together)
    o.cn = 0.5;
    var cells = 0.0;
    if (m < 0.999) {
        o.cn = 0.65 * hu_gn2(pp * (1.0 / 130.0) + vec2<f32>(17.0, 1.0)) + 0.35 * hu_gn2(rot2(pp, 0.7) * (1.0 / 52.0) + vec2<f32>(3.0, 8.0));
        // (condensing: the strongest cores first, each storm swelling out from its own as the rest gather)
        let thr = mix(0.8, 0.47, smoothstep(0.3, 7.5, t + 2.0 * o.n));
        cells = smoothstep(thr, thr + 0.22, o.cn) * (1.0 - smoothstep(350.0, 850.0, r)) * mix(1.0, o.arm + 0.2, m) * (1.0 - m);
    }
    // (the bands and the shield come in where the cells already stand first, and spread from them)
    let grow = smoothstep(0.0, 0.75, m + 0.5 * cells);
    var cov = max(cells, max(o.cdo, o.bands) * grow);
    o.cov = cov;
    // ---- its depth: from the base to the top, the cells' tops their own, each domed
    o.B = hu_base(r, t);
    var T = hu_top(rot2(xz, -hu_top_turn(r, St)), r, t, max(m, cells));
    T = mix(T, o.B + (T - o.B) * (0.2 + 0.55 * o.cn), (1.0 - m) * (1.0 - o.cdo));
    // (each cell, band and the overcast's edge thinner towards its edge, domed: an anvil's rounded shoulder, never a
    // sheer cliff)
    o.h = pow(smoothstep(0.12, 0.92, cov), 0.85);
    o.T = o.B + (T - o.B) * (0.1 + 0.9 * o.h);
    return o;
}
// The cloud's density at q (off the middle's ground).
// `mode`: 0 its shape alone (a sample towards the sun: no fine noise), 1 at half size, 2 at full size (finer noise).
fn hu_den(q: vec3<f32>, t: f32, St: f32, mode: i32) -> HuDen {
    let fine = mode == 2;
    var o: HuDen;
    let r = length(q.xz);
    let form = hu_form(t);
    let fade = hu_fade(t);
    let eye = hu_eye(t);
    let p2 = rot2(q.xz, -hu_cloud_turn(r, St));
    let pp = rot2(q.xz, -hu_arm_turn(St));
    let lr = log(max(r, 50.0) / 200.0);
    let cc = hu_col(q.xz, t, St);
    let arm = cc.arm;
    let warp = cc.warp;
    let bands = cc.bands;
    let cdo = cc.cdo;
    let B = cc.B;
    let T = cc.T;
    // ---- its billows: 3D noise in the frame the cloud turns in (sheared round the eye low down, the high cloud turning
    // all of a piece: never brushed into stripes), displacing its surfaces (tops, bases, edges) rather than thinning
    // its body: solid cloud, its detail at its edges
    let s = select(1.0 / 46.0, 1.0 / 32.0, fine);
    let pn = mix(p2, pp, max(smoothstep(90.0, 220.0, q.y), smoothstep(HU_FLING, HU_CLEAR, t)));
    var nz = 0.5;
    if (mode > 0) {
        nz = gnoise3(vec3<f32>(pn.x * s, q.y * s * 1.3 + t * 0.03, pn.y * s));
    }
    if (fine) {
        nz = 0.68 * nz + 0.32 * gnoise3(vec3<f32>(pn.x, q.y * 1.2, pn.y) * (1.0 / 13.0) + vec3<f32>(3.1, 0.0, 7.7));
    }
    // (breaking up: eaten from its edges and its top, unevenly, shredding before it is gone)
    let ero = 1.0 - fade;
    let Te = T - (T - B) * 0.7 * ero;
    // (billowed most at its edges and its thin shoulders, cauliflower towers there; the overcast's top smoother)
    let Tb = Te + (18.0 + 26.0 * (1.0 - cc.h)) * (nz - 0.5);
    let Bb = B + 9.0 * (nz - 0.5);
    // (the storms it gathers from towering, narrowing as they rise: cumulus, not prisms)
    let hf = saturate((q.y - B) / max(T - B, 1.0));
    // (soft-edged while it gathers and as it breaks up: its edges ramped wide, in wisps)
    let sft = hu_soft(t, cc.m);
    let wide = 1.0 + 3.0 * sft;
    var body = min(min((q.y - Bb) / (6.0 * wide), (Tb - q.y) / (5.0 * wide)), (cc.cov + (0.3 + 0.3 * (1.0 - cc.h) + 1.6 * ero) * (nz - 0.5) - 0.3 - 0.12 * hf * hf * (1.0 - cc.m) - 0.95 * ero) * 6.0 / wide);
    // ---- the eyewall: a towering ring of cloud from the land to its top, sloping out as it rises, in tall towers,
    // wound with striations that spiral up it the way it turns
    let wout = hu_wall_out(q.y, t);
    // (its noise only near it: further out the wall is far below the deck's density whatever it adds)
    let nearw = r < wout + 40.0;
    var win = hu_wall_in(q.y, t);
    if (nearw) {
        win = hu_eyeface(q, p2, t);
    }
    // (the moat: open sky between the eyewall and the overcast, narrowing as the eyewall flares up into it; from the
    // land round it the eyewall stands sunlit across it under the overcast's top, which from over it runs on unbroken
    // into the eyewall's, one shield round the eye)
    let cap = B + (T - B) * 0.7;
    let mo = smoothstep(wout + 4.0, wout + 26.0, r) * (1.0 - smoothstep(205.0 + 0.16 * q.y, 245.0 + 0.16 * q.y, r + 60.0 * (warp - 0.5))) * (1.0 - smoothstep(cap - 40.0, cap + 6.0, q.y + 14.0 * (nz - 0.5)));
    // (filling in as the eyewall collapses after the fling)
    body = body - 7.0 * mo * hu_inten(t) * (1.0 - smoothstep(HU_FLING, HU_CLEAR, t));
    var wtop = hu_wall_top(t);
    var wall = min((wout - r) / 14.0, -1.5);
    if (nearw) {
        wtop = wtop + 18.0 * (hu_gn2(p2 * (1.0 / 70.0) + vec2<f32>(31.0, 5.0)) - 0.4);
        let a2 = atan2(p2.y, p2.x);
        // (its base a little over the land, ragged: under it the land it tears up, the debris and the dust in plain
        // sight)
        let wbase = 26.0 + 10.0 * (hu_gn2(p2 * (1.0 / 30.0) + vec2<f32>(7.0, 2.0)) - 0.5);
        wall = min(min((r - win) / 4.0, (wout - r) / 14.0), min((q.y - wbase) / 7.0, (wtop - q.y) / 14.0));
        let stri = 0.5 + 0.5 * sin(a2 * 14.0 + q.y * 0.05 * HU_SPIN + 2.0 * warp);
        let tow = hu_gn2(vec2<f32>(p2.x * (1.0 / 26.0) + q.y * (1.0 / 45.0), p2.y * (1.0 / 26.0)));
        // (none before it forms: out of the cloud, not at its edge, so no haze of noise round it; its towers rising
        // each at its own time, round it and up it, as the core comes together)
        let wk = smoothstep(6.0, 15.0, t + 6.0 * (tow - 0.5) + 3.0 * cc.n) * (0.3 + 0.7 * cc.m);
        wall = mix(-6.0, wall + 0.5 * (stri - 0.5) + 1.3 * (tow - 0.5), wk);
    }
    // ---- the eye: clear, opening from a pinhole as the storm organises, its edge sharp; filling in as it dies
    let er = win * smoothstep(0.0, 0.5, eye);
    let clear = eye * (1.0 - smoothstep(er - 2.0, er + 1.5, r + 5.0 * (nz - 0.5)));
    // (the eyewall collapsing once the winds drop, shredding as it goes)
    let wero = smoothstep(HU_FLING, HU_CLEAR, t);
    let rawn = max(wall + (1.2 + 2.5 * wero) * (nz - 0.5) - wero * 9.0, body) - 6.0 * (1.0 - smoothstep(0.0, 1.5, t));
    let raw = rawn + sft * 1.6 * (nz - 0.5) - 9.0 * clear;
    // (in the clear eye, how far off its face is: the march strides over it, never through the face)
    // (the clear eye's own edge left out of it: near the face the march steps as finely as in the cloud)
    o.raw = select(rawn * 0.4, min(rawn * 0.4, -0.06 * (er - r) - 0.05), r < er - 2.0 && eye > 0.5);
    // (and at the very end thinning away, each place at its own time: `hu_gone`)
    let gone = hu_gone(cc.n, cc.cov, t);
    o.d = saturate(raw) * gone;
    o.raw = mix(-3.0, o.raw, saturate(gone * 4.0));
    o.soft = max(sft, 1.0 - gone);
    o.wall = saturate(wall * 0.6 + 0.3) * step(body, wall);
    o.arm = bands * (1.0 - cdo) * smoothstep(0.55, 0.95, arm);
    // (lit from the top it has left as it is eaten away, so what is left of it is no darker than the cloud was)
    o.top = max(Te, wtop * step(body, wall));
    o.clear = clear;
    o.face = win;
    return o;
}
// How much of the sun reaches q (off the middle's ground, r out, `win` the eye's edge at its height, `wtop` the
// eyewall's top) down the clear eye: through the wall to the eye, across it and out over the rim on the sun's side.
// The stadium: its far wall lit from its rim down, its lower half in the near wall's shadow.
fn hu_eyelit(q: vec3<f32>, r: f32, win: f32, wtop: f32, L: vec3<f32>, t: f32) -> f32 {
    let lh = length(L.xz);
    if (L.y <= 0.0) {
        return 0.0;
    }
    if (lh < 1.0e-3) {
        return exp(-0.07 * max(r - win, 0.0));
    }
    let Lh = L.xz / lh;
    let tn = L.y / lh;
    let b = dot(q.xz, Lh);
    let c = r * r - win * win;
    let disc = b * b - c;
    if (disc <= 0.0) {
        return 0.0;
    }
    let sq = sqrt(disc);
    let s_in = max(-b - sq, 0.0);
    // (the eye wider higher up: out at the far side where the sun's way has risen to)
    let y1 = q.y + (-b + sq) * tn;
    let w1 = win + 0.5 * (hu_flare(y1, t) - hu_flare(q.y, t));
    let disc1 = b * b - (r * r - w1 * w1);
    let s_out = -b + sqrt(max(disc1, 0.0));
    if (s_out <= 0.0) {
        return 0.0;
    }
    return smoothstep(wtop - 110.0, wtop - 20.0, q.y + s_out * tn) * exp(-0.07 * s_in);
}

// The dust, spray and fine debris churned up round the eyewall, at q: x the dust (thick at the eyewall's foot, in
// streaks), y the haze of debris too small to see one by one, filling the rings as high as their blocks go.
fn hu_dust(q: vec3<f32>, t: f32, St: f32, g: f32) -> vec2<f32> {
    let r = length(q.xz);
    let on = hu_ring_on(clamp(r, HU_R_IN, 160.0), t);
    // (after the fling, the dust of everything coming down, shattering where it hits, spreading out with it)
    let sf = t - HU_FLING;
    let land = smoothstep(0.8, 2.2, sf) * (1.0 - smoothstep(7.0, 12.0, sf)) * smoothstep(HU_RING0, HU_RING0 + 15.0, r) * (1.0 - smoothstep(60.0 + 22.0 * sf, 100.0 + 24.0 * sf, r));
    if (on + land < 0.01) {
        return vec2<f32>(0.0);
    }
    let yr = q.y - g;
    let p2 = rot2(q.xz, -HU_SPIN * hu_omega(max(r, 30.0)) * St * 0.9);
    let n = gnoise3(vec3<f32>(p2.x * (1.0 / 16.0), yr * (1.0 / 11.0) - t * 0.5, p2.y * (1.0 / 16.0)));
    let hgt = 8.0 + 34.0 * (1.0 - smoothstep(70.0, 190.0, r));
    let foot = smoothstep(HU_R_IN - 2.0, HU_R_IN + 12.0, r) * (1.0 - smoothstep(110.0, 200.0, r)) * (1.0 - smoothstep(0.25 * hgt, hgt, yr)) * smoothstep(-3.0, 1.0, yr);
    var dust = on * hu_spin(t) * foot * smoothstep(0.45, 0.8, n) * (0.4 + 1.4 * hu_shape(r));
    dust = dust + land * (1.0 - smoothstep(2.0, 6.0 + 2.0 * sf, yr)) * smoothstep(-3.0, 0.5, yr) * smoothstep(0.4, 0.75, n) * 0.9;
    // (the haze follows the blocks out along the stadium's slope as they climb: the eye stays clear)
    let rf = r - hu_flare(yr, t);
    let fill = hu_ring_rise(rf) * (hu_spin_int(min(t, HU_FLING)) - hu_spin_int(hu_front(clamp(rf, HU_R_IN, 160.0))));
    let rh = min(hu_ring_h(rf), max(fill, 0.0) + 6.0);
    let haze = on * smoothstep(HU_RING0, HU_RING0 + 8.0, rf) * (1.0 - smoothstep(150.0, 165.0, rf)) * smoothstep(-2.0, 2.0, yr) * (1.0 - smoothstep(0.6 * rh, rh, yr)) * hu_ring_dens(rf) * (0.6 + 0.8 * n);
    return vec2<f32>(dust, haze);
}

// ---- the lightning: flashes deep in the eyewall, now and then a bolt to the land --------------------------------------
// As a real hurricane's: little in the bands, bursts of it in the eyewall as the storm intensifies (16-28 s), less once
// it is at its height, a last burst as it peaks (43-46 s), dying away with it. Each flash a few flickering strokes over
// half a second lighting the cloud round it from inside; about one in three a bolt from the wall to the land at its
// foot. Up to three at once (the last 0.6 s's, a fifth of a second a slot, a flash at most in each).
const HU_SLOT: f32 = 0.2;
fn hu_flash_rate(t: f32) -> f32 {
    var k = array<vec2<f32>, 10>(vec2<f32>(11.0, 0.0), vec2<f32>(15.0, 1.0), vec2<f32>(18.0, 4.0), vec2<f32>(27.0, 3.2), vec2<f32>(32.0, 1.3), vec2<f32>(41.0, 1.5), vec2<f32>(44.5, 3.6), vec2<f32>(47.0, 1.2), vec2<f32>(52.0, 0.4), vec2<f32>(55.0, 0.0));
    if (t <= k[0].x) {
        return 0.0;
    }
    for (var i = 0; i < 9; i = i + 1) {
        let a = k[i];
        let b = k[i + 1];
        if (t <= b.x) {
            return mix(a.y, b.y, (t - a.x) / (b.x - a.x));
        }
    }
    return 0.0;
}
// The strokes of a flash `a` seconds after it began: 1 at a stroke's peak (the Supercell's sc_stroke).
fn hu_stroke(a: f32, n: u32) -> f32 {
    if (a < 0.0 || a > 0.6) {
        return 0.0;
    }
    let count = 1u + n % 4u;
    var s = 0.0;
    var ts = 0.0;
    for (var k = 0u; k <= count; k = k + 1u) {
        let h = f32(pcg(n * 13u + k) & 1023u) / 1023.0;
        ts = ts + select(0.04 + 0.09 * h, 0.0, k == 0u);
        s = s + select(0.5 + 0.4 * h, 1.0, k == 0u) * exp(-max(a - ts, 0.0) / 0.04) * step(ts, a);
    }
    return (s + 0.08 * exp(-a / 0.25)) * (1.0 - smoothstep(0.45, 0.6, a));
}
// A bolt's own timing (the user's reference: a game's lightning strike filmed at 60 fps): a thin jagged leader
// flickering for the first ~75 ms, its shape new every two frames; then the return stroke, a thick glowing column of
// light from the cloud to the land, straight but for a gentle wave, the land at its foot lit; from 0.17 s it draws up
// off the land into the cloud, its foot a point, gone by 0.27 s; then a thin jagged re-stroke or two, a frame or two
// each, out to 0.42 s. `a` seconds after the flash began.
const HU_LEAD: f32 = 0.075;
const HU_BOLT_END: f32 = 0.42;
fn hu_flick(a: f32, n: u32, k: u32) -> f32 {
    return f32(pcg(n * 31u + k * 7u + u32(max(a, 0.0) * 30.0)) & 1023u) / 1023.0;
}
// (the column's strength: 0 to 1)
fn hu_beam_k(a: f32, n: u32) -> f32 {
    return smoothstep(0.05, HU_LEAD, a) * (1.0 - smoothstep(0.19, 0.27, a)) * (0.88 + 0.12 * hu_flick(a, n, 1u));
}
// (the leader's and the re-strokes' strength, and which shape: a new one each two frames)
fn hu_lead_k(a: f32, n: u32) -> f32 {
    if (a < HU_LEAD) {
        return 0.55 + 0.45 * hu_flick(a, n, 2u);
    }
    let r0 = 0.28 + 0.05 * f32(n & 7u) / 7.0;
    let r1 = 0.35 + 0.05 * f32((n >> 3u) & 7u) / 7.0;
    return 0.8 * (step(r0, a) * step(a, r0 + 0.034) + 0.7 * step(r1, a) * step(a, r1 + 0.018));
}
// (how brightly it lights the cloud round its root)
fn hu_bolt_stroke(a: f32, n: u32) -> f32 {
    if (a < 0.0 || a > HU_BOLT_END) {
        return 0.0;
    }
    return (max(hu_beam_k(a, n), 0.6 * hu_lead_k(a, n)) + 0.12 * exp(-a / 0.15)) * (1.0 - smoothstep(0.36, HU_BOLT_END, a));
}
struct HuFlash {
    // where each flash is (off the middle's ground) and how bright it is now; its bolt's foot (w 1: one under way) and
    // how long since its flash began
    p: array<vec4<f32>, 3>,
    b: array<vec4<f32>, 3>,
    a: vec3<f32>,
    n: vec3<u32>,
}
fn hu_flashes(t: f32, seed: u32) -> HuFlash {
    var f: HuFlash;
    f.a = vec3<f32>(0.0);
    f.n = vec3<u32>(0u);
    let s0 = i32(floor(t / HU_SLOT));
    let sh = pcg(seed ^ 0x7a11u);
    for (var j = 0; j < 3; j = j + 1) {
        f.p[j] = vec4<f32>(0.0);
        f.b[j] = vec4<f32>(0.0);
        let s = s0 - j;
        let ts = f32(s) * HU_SLOT;
        let rate = hu_flash_rate(ts);
        if (s < 0 || rate <= 0.0) {
            continue;
        }
        // (a slot's flash, if any, from one hash chain: sixteen bits a number)
        let h = pcg(u32(s) * 0x9E3779B1u ^ sh);
        if (f32(h & 0xFFFFu) / 65535.0 >= rate * HU_SLOT) {
            continue;
        }
        let ha = pcg(h);
        let hb = pcg(ha);
        let hc = pcg(hb);
        let u = vec4<f32>(f32(ha & 0xFFFFu), f32(ha >> 16u), f32(hb & 0xFFFFu), f32(hb >> 16u)) / 65535.0;
        let w = vec2<f32>(f32(hc & 0xFFFFu), f32(hc >> 16u)) / 65535.0;
        let age = t - (ts + HU_SLOT * f32(h >> 16u) / 65535.0);
        let bolt = u.y >= 0.2 && w.x < 0.36;
        let br = select(hu_stroke(age, h >> 3u), hu_bolt_stroke(age, h >> 3u), bolt);
        if (br <= 0.0) {
            continue;
        }
        f.a[j] = age;
        f.n[j] = h >> 3u;
        let ang = TAU * u.x;
        let dir = vec2<f32>(cos(ang), sin(ang));
        if (u.y < 0.2) {
            // (out in a band)
            let r = 280.0 + 900.0 * u.z;
            f.p[j] = vec4<f32>(dir.x * r, 110.0 + 80.0 * u.w, dir.y * r, 0.6 * br);
            continue;
        }
        if (w.x < 0.36) {
            // (a bolt out of the eyewall's flank, low down, across the open moat to the land, the flash lighting
            // the flank round its root)
            let y = 70.0 + 90.0 * u.z;
            let r = hu_wall_out(y, t) - 6.0;
            f.p[j] = vec4<f32>(dir.x * r, y, dir.y * r, br * 0.6);
            let fa = ang + HU_SPIN * 0.15 * (w.y - 0.3);
            let fr = hu_wall_out(0.0, t) + 6.0 + 55.0 * fract(w.x * 2.77 + w.y);
            let fp = vec2<f32>(cos(fa), sin(fa)) * fr;
            f.b[j] = vec4<f32>(fp.x, hu_ground(fp), fp.y, 1.0);
            continue;
        }
        // (deep in the eyewall, lighting it from inside)
        let y = 90.0 + 250.0 * u.z;
        let r = hu_wall_in(y, t) + 12.0 + 26.0 * u.w;
        f.p[j] = vec4<f32>(dir.x * r, y, dir.y * r, br);
    }
    return f;
}
// How the flashes light a point of the cloud (off the middle's ground).
fn hu_flash_at(fl: HuFlash, q: vec3<f32>) -> f32 {
    var e = 0.0;
    for (var j = 0; j < 3; j = j + 1) {
        let f = fl.p[j];
        if (f.w > 0.001) {
            let d = q - f.xyz;
            e = e + f.w / (1.0 + dot(d, d) * (1.0 / 4500.0));
        }
        // (a bolt's column lighting the land round its foot)
        let b = fl.b[j];
        if (b.w > 0.5) {
            let k = hu_beam_k(fl.a[j], fl.n[j]) + 0.4 * hu_lead_k(fl.a[j], fl.n[j]);
            let d = q - b.xyz;
            e = e + 2.4 * k / (1.0 + dot(d, d) * (1.0 / 700.0));
        }
    }
    return e;
}
// A bolt's channel on the picture (the Supercell's): kinked at every scale, sharp bends, never smooth.
fn hu_lin(x: f32, s: f32) -> f32 {
    let i = floor(x);
    return mix(fh21(vec2<f32>(i, s)), fh21(vec2<f32>(i + 1.0, s)), x - i) * 2.0 - 1.0;
}
fn hu_kink(u: f32, s: f32, fq: f32) -> f32 {
    let v = u * fq;
    return (0.11 * hu_lin(v * 4.0, s) + 0.05 * hu_lin(v * 11.0, s + 1.7) + 0.024 * hu_lin(v * 29.0, s + 3.1) + 0.011 * hu_lin(v * 70.0, s + 5.3)) / sqrt(fq);
}
fn hu_channel(px: vec2<f32>, sa: vec2<f32>, sb: vec2<f32>, s: f32, w: f32, pin: bool, fq: f32, jag: f32) -> vec3<f32> {
    let ab = sb - sa;
    let L = max(length(ab), 1.0);
    let dir = ab / L;
    let nrm = vec2<f32>(-dir.y, dir.x);
    let ap = px - sa;
    let u = clamp(dot(ap, dir) / L, 0.0, 1.0);
    let env = select(1.0, sqrt(max(1.0 - u, 0.0)) * 1.15, pin) * smoothstep(0.0, 0.04, u);
    let k0 = hu_kink(u, s, fq) * env * jag;
    let k1 = hu_kink(u + 0.002, s, fq) * env * jag;
    let slope = (k1 - k0) / 0.002;
    let off = (dot(ap, nrm) - k0 * L) / sqrt(1.0 + slope * slope);
    let d = length(vec2<f32>(off, dot(ap, dir) - u * L));
    let g = 1.0 / (1.0 + pow(d / (w * 9.0), 2.0));
    return vec3<f32>(exp(-pow(d / w, 2.0)), g * g, u);
}
// Bolt from a to b (camera-relative) on the picture with three forks: x its core, y its bloom, each as far as it is
// seen (hidden by the land and what flies in front of it, `near`, and by the cloud in front of it: `ct` how far off
// the cloud is, `ca` how much of what is behind it shows through).
fn hu_bolt(px: vec2<f32>, a: vec3<f32>, b: vec3<f32>, seed: f32, near: f32, ct: f32, ca: f32) -> vec2<f32> {
    let pa = project_rel(a);
    let pb = project_rel(b);
    if (pa.z < 0.0 || pb.z < 0.0) {
        return vec2<f32>(0.0);
    }
    let res = frame.resolution.xy;
    let sa = pa.xy * res;
    let sb = pb.xy * res;
    let ab = sb - sa;
    let L = max(length(ab), 1.0);
    let la = length(a);
    let lb = length(b);
    let focal = res.y / (2.0 * tan(frame.view_params.w * 0.5));
    let w = clamp(0.5 * focal / (0.5 * (la + lb)), 0.7, 4.0);
    let u0 = saturate(dot(px - sa, ab) / (L * L));
    if (length(px - (sa + ab * u0)) > 0.45 * L + 40.0 * w) {
        return vec2<f32>(0.0);
    }
    let fq = max(length(a - b) / 100.0, 1.0);
    let m = hu_channel(px, sa, sb, seed, w, true, fq, 1.35);
    let dm = mix(la, lb, m.z);
    let seen = select(0.0, 1.0, near > dm - 3.0) * select(1.0, ca, dm > ct);
    var core = m.x * seen;
    var glow = m.y * seen;
    let dir = ab / L;
    let nrm = vec2<f32>(-dir.y, dir.x);
    for (var k = 0; k < 3; k = k + 1) {
        let fk = f32(k);
        let u = 0.15 + 0.55 * fract(seed * 0.618 + fk * 0.377);
        let root = sa + ab * u + nrm * hu_kink(u, seed, fq) * sqrt(1.0 - u) * 1.15 * 1.35 * L;
        let side = select(-1.0, 1.0, fract(seed * 0.71 + fk * 0.53) > 0.5);
        let bdir = normalize(dir + nrm * side * (0.55 + 0.6 * fract(seed * 1.3 + fk * 0.7)));
        let f = hu_channel(px, root, root + bdir * L * (0.16 + 0.26 * fract(seed * 0.9 + fk * 0.77)), seed + 7.0 + fk * 3.3, w * 0.6, false, fq, 1.6);
        let fs = select(0.0, 1.0, near > mix(la, lb, u) - 3.0) * select(1.0, ca, mix(la, lb, u) > ct) * pow(1.0 - f.z, 1.6);
        core = core + f.x * fs;
        glow = glow + f.y * fs * 0.7;
    }
    return vec2<f32>(core, glow);
}

// The return stroke's column from a to b (camera-relative) on the picture: a thick soft rod of light, straight but for
// a gentle wave, HU_BEAM_R blocks round, drawn up off the land from `ue` (1: down to b, 0: none), its foot a point:
// x its core, y its halo, as far as it is seen (as hu_bolt).
const HU_BEAM_R: f32 = 2.6;
fn hu_beam(px: vec2<f32>, a: vec3<f32>, b: vec3<f32>, seed: f32, ue: f32, near: f32, ct: f32, ca: f32) -> vec2<f32> {
    let pa = project_rel(a);
    let pb = project_rel(b);
    if (pa.z < 0.0 || pb.z < 0.0 || ue <= 0.01) {
        return vec2<f32>(0.0);
    }
    let res = frame.resolution.xy;
    let sa = pa.xy * res;
    let sb = pb.xy * res;
    let ab = sb - sa;
    let L = max(length(ab), 1.0);
    let dir = ab / L;
    let nrm = vec2<f32>(-dir.y, dir.x);
    let la = length(a);
    let lb = length(b);
    let focal = res.y / (2.0 * tan(frame.view_params.w * 0.5));
    let ap = px - sa;
    let u = clamp(dot(ap, dir) / L, 0.0, 1.0);
    let dm = mix(la, lb, u);
    let wc = max(HU_BEAM_R * focal / max(dm, 1.0), 1.2);
    let off0 = dot(ap, nrm);
    if (abs(off0) > 0.12 * L + 14.0 * wc) {
        return vec2<f32>(0.0);
    }
    // (a gentle wave, the large scales of the leader's kinks only)
    let wave = (0.03 * hu_lin(u * 3.0, seed) + 0.015 * hu_lin(u * 8.0, seed + 1.7)) * L * smoothstep(0.0, 0.05, u);
    let along = dot(ap, dir) - u * L;
    let d = length(vec2<f32>(off0 - wave, along));
    // (drawn up: thinning to a point at its foot)
    let taper = sqrt(saturate((ue - u) / 0.18)) * smoothstep(0.0, 0.03, u);
    let r = wc * taper;
    let seen = select(0.0, 1.0, near > dm - 3.0) * select(1.0, ca, dm > ct) * step(u, ue);
    let core = exp(-pow(d / max(r * 0.7, 0.6), 2.0)) * step(0.001, taper);
    let halo = 1.0 / (1.0 + pow(d / max(r * 2.2, 1.0), 2.0)) * taper;
    return vec2<f32>(core, halo * halo) * seen;
}

struct HuVol {
    c: vec4<f32>,
    t: f32,
    // the colour of the cloud nearest the end of the way (deep in it, where a hidden block is)
    lc: vec3<f32>,
}
// The cloud, the rain and the dust along rd (camera-relative), as far as `len` (the land, or a block in front of it).
// `amb` and `sunc` the light over the storm (the cloud's top in full sun), dimmed under it for the rain and the dust.
// (`dlen`: how far the way goes past a block on it, to the land: the cloud's strides are set by it, the same as
// round the block, so a block hidden in the cloud is never a hole in it)
fn hu_volume(rd: vec3<f32>, len: f32, dlen: f32, C: vec3<f32>, t: f32, St: f32, j: f32, L: vec3<f32>, amb0: vec3<f32>, sunc0: vec3<f32>, flv: vec4<f32>, fine: bool) -> HuVol {
    var acc = vec4<f32>(0.0, 0.0, 0.0, 1.0);
    var tmid = 0.0;
    var wmid = 0.0;
    var lc = vec3<f32>(0.0);
    let o = -C;
    let form = hu_form(t);
    let fade = hu_fade(t);
    let eye = hu_eye(t);
    let amb = amb0 * mix(1.0, 0.6, form);
    let sunc = sunc0 * mix(1.0, 0.55, form);
    let qa = dot(rd.xz, rd.xz);
    let qb = dot(o.xz, rd.xz);
    let wtop = hu_wall_top(t);
    // ---- the cloud: from the eyewall's foot to the outflow's top, inside its reach --------------------------------
    let reach = hu_deck_r(t) + 60.0;
    var t0 = 0.0;
    var t1 = dlen;
    let ylo = -6.0;
    let yhi = HU_YHI;
    if (abs(rd.y) > 1.0e-5) {
        let ta = (ylo - o.y) / rd.y;
        let tb = (yhi - o.y) / rd.y;
        t0 = max(t0, min(ta, tb));
        t1 = min(t1, max(ta, tb));
    } else if (o.y < ylo || o.y > yhi) {
        t1 = -1.0;
    }
    let qc = dot(o.xz, o.xz) - reach * reach;
    let disc = qb * qb - qa * qc;
    if (disc <= 0.0 || qa < 1.0e-8) {
        if (qc > 0.0) {
            t1 = -1.0;
        }
    } else {
        let sq = sqrt(disc);
        t0 = max(t0, (-qb - sq) / qa);
        t1 = min(t1, (-qb + sq) / qa);
    }
    // (the low sun's way through the cloud: how far a point's depth under the top reaches along it)
    let ly = max(L.y, 0.12);
    let flc = vec3<f32>(0.78, 0.83, 1.0) * 2.6;
    let span = t1 - t0;
    t1 = min(t1, len);
    if (t1 > t0 && form * fade > 0.001) {
        let n = select(40, 56, fine);
        // (strides: a fixed share of the way through, no finer than a few blocks, longer far off)
        let dt0 = clamp(span / f32(n), 3.0, 30.0);
        var dt = dt0;
        var tt = t0 + min(dt, 8.0) * j;
        for (var i = 0; i < 96; i = i + 1) {
            if (tt > t1 || acc.a < 0.05) {
                break;
            }
            let q = o + rd * tt;
            // (the fine noise only while the cloud in front is thin)
            let dn = hu_den(q, t, St, select(1, 2, fine && acc.a > 0.25));
            let r = length(q.xz);
            let win = dn.face;
            let lod = max(dt0, 0.006 * tt);
            if (dn.d > 0.004) {
                // (lit by the sun from the cloud's top down: brilliant on the top, its towers' sunward sides brighter,
                // greying with depth, the bands' undersides dark; a little of it scattered on through the cloud)
                let dv = (max(dn.top - q.y, 0.0) + 2.0) / ly;
                var sun_t = 0.72 * exp(-0.035 * dv) + 0.28 * exp(-0.005 * dv);
                // (the eye's walls lit down it from its rim on the far side, the near side's in shadow, each terrace's
                // ledge shading the face under it)
                let face = eye * (1.0 - smoothstep(win, win + 22.0, r));
                if (face > 0.01) {
                    sun_t = max(sun_t, hu_eyelit(q, r, win, wtop, L, t) * eye);
                }
                // (the eyewall's outer flank lit across the open moat, on its side towards the sun)
                let wo = hu_wall_out(q.y, t);
                let fs = dot(q.xz, L.xz) / max(r * length(L.xz), 1.0e-3);
                let moat = max(240.0 + 0.16 * q.y - r, 0.0);
                let ml = hu_inten(t) * smoothstep(0.0, 0.5, fs) * exp(-0.06 * max(wo - r, 0.0)) * smoothstep(wo - 60.0, wo - 10.0, r) * smoothstep(wtop - 120.0, wtop - 30.0, q.y + moat * L.y / max(length(L.xz), 0.05));
                // (its foot in the rain and the spray it throws up: dark under the sunlit flank)
                sun_t = max(sun_t, 0.85 * ml * smoothstep(30.0, 170.0, q.y));
                // (each billow shading the next: the cloud a few blocks towards the sun, if any, in the way)
                // (only while the cloud in front still lets most of it through: deeper, it hardly shows)
                if (sun_t > 0.12 && acc.a > 0.3) {
                    sun_t = sun_t * (0.35 + 0.65 * exp(-1.6 * hu_den(q + L * 7.0, t, St, 0).d));
                }
                let deep = max(dn.top - q.y, 0.0);
                // (the sky's light: from above, from the open eye on its walls, and the sunlit walls' glow on each other)
                let ak = mix(0.3, 1.0, exp(-deep / 90.0)) + 0.45 * face;
                let alb = mix(vec3<f32>(0.92, 0.93, 0.95), vec3<f32>(0.4, 0.42, 0.45), max(dn.arm * 0.7, dn.wall * (1.0 - smoothstep(0.0, 140.0, q.y)) * 0.8 * (1.0 - face)));
                var c = alb * (amb0 * ak * 1.25 + sunc0 * (sun_t * 1.4 + 0.12 * face * smoothstep(0.0, 0.4, L.y)));
                if (flv.w > 0.001) {
                    let fd = q - flv.xyz;
                    c = c + flc * flv.w / (1.0 + dot(fd, fd) * (1.0 / 4500.0)) * mix(1.0, 0.35, exp(-deep / 60.0));
                }
                // (thin, translucent wisps while it gathers and breaks up; the mature storm solid)
                let ext = dn.d * mix(0.35, 0.09, dn.soft) * dt;
                let al = 1.0 - exp(-ext);
                hu_over(&acc, c, al);
                lc = c;
                tmid = tmid + acc.a * al * tt;
                wmid = wmid + acc.a * al;
                // (finely while the cloud in front is thin, in longer strides once it hides most of what is behind)
                dt = min(lod, 4.0 + 0.004 * tt) * (0.6 + 0.8 * fract(j * 3.17 + f32(i) * 0.618)) * select(1.0, 2.0, acc.a < 0.3);
            } else {
                // (over the clear air in long strides, the further out of the cloud the longer, shortening as it nears
                // the cloud so its edge is found sharp)
                dt = clamp(-dn.raw * 10.0, 2.0 + 0.002 * tt, lod * 3.5) * (0.65 + 0.7 * fract(j * 7.31 + f32(i) * 0.618));
            }
            // (the eye's still air, lit where the sun pours down it: a shaft of light seen from over it)
            if (dn.clear > 0.5) {
                let el = hu_eyelit(q, r, max(win, r + 1.0), wtop, L, t);
                let hz = (1.0 - exp(-0.0007 * dt)) * dn.clear * (0.3 + 0.7 * el);
                hu_over(&acc, sunc0 * (0.15 + 0.8 * el) + amb0 * 0.5, hz);
            }
            tt = tt + dt;
        }
    }
    // ---- the rain: grey veils falling out of the bands, driven slanting round by the wind, and the murk under it ----
    let rk = hu_rain(t) * fade;
    if (rk > 0.001) {
        let rr = hu_deck_r(t) * 0.8;
        var r0 = 0.0;
        var r1 = len;
        if (abs(rd.y) > 1.0e-5) {
            let ta = (-8.0 - o.y) / rd.y;
            let tb = (HU_BASE + 20.0 - o.y) / rd.y;
            r0 = max(r0, min(ta, tb));
            r1 = min(r1, max(ta, tb));
        }
        let qc2 = dot(o.xz, o.xz) - rr * rr;
        let disc2 = qb * qb - qa * qc2;
        if (disc2 > 0.0 && qa > 1.0e-8) {
            let sq = sqrt(disc2);
            r0 = max(r0, (-qb - sq) / qa);
            r1 = min(r1, (-qb + sq) / qa);
        } else if (qc2 > 0.0) {
            r1 = -1.0;
        }
        // (only as far as the cloud it is in front of: never laid over the cloud from beyond it)
        r1 = min(min(r1, r0 + 900.0), select(1.0e9, tmid / max(wmid, 1.0e-4), wmid > 0.05));
        if (r1 > r0) {
            let nr = select(5, 10, fine);
            let dtr = (r1 - r0) / f32(nr);
            var tr = 1.0;
            var cr = vec3<f32>(0.0);
            for (var i = 0; i < nr; i = i + 1) {
                let tt = r0 + (f32(i) + j) * dtr;
                let q = o + rd * tt;
                let r = length(q.xz);
                // (the bands it falls in, the wind driving it round: the curtains lean over and drift with it)
                let p2 = rot2(q.xz, -hu_arm_turn(St) - 0.004 * q.y * HU_SPIN);
                let arm = hu_arm(p2, r, t).x;
                let curtain = gnoise3(vec3<f32>(p2.x * (1.0 / 30.0), q.y * (1.0 / 120.0), p2.y * (1.0 / 30.0)));
                var fall = 0.6;
                if (fine) {
                    fall = vnoise(vec2<f32>(p2.x * (1.0 / 4.0) + p2.y * (1.0 / 5.0), (q.y + 40.0 * t) * (1.0 / 26.0)));
                }
                var den = rk * mix(0.25, 1.0, smoothstep(0.4, 0.8, arm)) * smoothstep(hu_wall_out(q.y, t) - 20.0, hu_wall_out(q.y, t) + 30.0, r) * smoothstep(0.38, 0.62, curtain) * (0.55 + 0.9 * smoothstep(0.45, 0.75, fall));
                den = den * (1.0 - smoothstep(rr * 0.75, rr, r)) * smoothstep(HU_R_EYE, HU_R_EYE + 30.0, r) * smoothstep(20.0, 90.0, tt);
                den = den * smoothstep(-6.0, 4.0, q.y) * (1.0 - smoothstep(HU_BASE, HU_BASE + 18.0, q.y));
                if (den > 0.001) {
                    let c = vec3<f32>(0.42, 0.45, 0.48) * (amb * 0.85 + sunc * 0.12);
                    let al = 1.0 - exp(-den * 0.04 * dtr);
                    cr = cr + tr * al * c;
                    tr = tr * (1.0 - al);
                }
            }
            // (the murk of the rain over the whole of the land under the storm: what is far off greys out)
            let murk = exp(-max(r1 - max(r0, 40.0), 0.0) * 0.0018 * rk * form);
            let mc = vec3<f32>(0.4, 0.43, 0.46) * (amb * 0.9 + sunc * 0.1);
            cr = cr + tr * (1.0 - murk) * mc;
            tr = tr * murk;
            // (under the cloud: in front of what the cloud gathered for an eye under it, never hiding all behind it)
            let keep = max(tr, 0.3);
            cr = cr * (1.0 - keep) / max(1.0 - tr, 1.0e-4);
            acc = vec4<f32>(cr + keep * acc.rgb, keep * acc.a);
            if (tr < 0.98 && wmid < 1.0e-3) {
                tmid = 0.5 * (r0 + r1);
                wmid = 1.0;
            }
        }
    }
    // ---- the dust and the spray round the eyewall's foot, churning round with the debris -------------------------------
    if (hu_ring_on(HU_R_W, t) > 0.01 || (t > HU_FLING && t < HU_FLING + 12.0)) {
        let rd0 = select(230.0, 330.0, t > HU_FLING);
        let qc3 = dot(o.xz, o.xz) - rd0 * rd0;
        let disc3 = qb * qb - qa * qc3;
        if (disc3 > 0.0 && qa > 1.0e-8) {
            let sq = sqrt(disc3);
            var d0 = max((-qb - sq) / qa, 0.0);
            var d1 = min((-qb + sq) / qa, len);
            if (abs(rd.y) > 1.0e-5) {
                let ta = (-50.0 - o.y) / rd.y;
                let tb = (250.0 - o.y) / rd.y;
                d0 = max(d0, min(ta, tb));
                d1 = min(d1, max(ta, tb));
            }
            if (d1 > d0) {
                let nd = select(16, 24, fine);
                let ddt = (d1 - d0) / f32(nd);
                var da = vec4<f32>(0.0, 0.0, 0.0, 1.0);
                var dtm = 0.0;
                let g = hu_ground(vec2<f32>(0.0));
                for (var i = 0; i < nd; i = i + 1) {
                    let tt = d0 + (f32(i) + j) * ddt;
                    let q = o + rd * tt;
                    let dd = hu_dust(q, t, St, g) * smoothstep(8.0, 50.0, tt);
                    if (dd.x + dd.y > 0.002) {
                        let c = (vec3<f32>(0.3, 0.26, 0.21) * dd.x + vec3<f32>(0.12, 0.1, 0.085) * dd.y) / (dd.x + dd.y) * (amb * 1.2 + sunc * 0.25);
                        let al = 1.0 - exp(-(dd.x * 0.05 + dd.y * 0.014) * ddt);
                        dtm = dtm + tt * al * da.a;
                        hu_over(&da, c, al);
                        if (da.a < 0.05) {
                            break;
                        }
                    }
                }
                // (in front of the cloud if nearer than what the cloud gathered, else behind it: under the deck, its top
                // lost in the cloud)
                if (da.a < 0.999) {
                    let dmid = dtm / max(1.0 - da.a, 1.0e-3);
                    let cmid = tmid / max(wmid, 1.0e-4);
                    if (wmid < 1.0e-3 || dmid < cmid) {
                        acc = vec4<f32>(da.rgb + da.a * acc.rgb, da.a * acc.a);
                    } else {
                        acc = vec4<f32>(acc.rgb + acc.a * da.rgb, da.a * acc.a);
                    }
                }
            }
        }
    }
    var v: HuVol;
    v.c = acc;
    v.t = select(1.0e9, tmid / max(wmid, 1.0e-4), wmid > 1.0e-4);
    v.lc = lc;
    return v;
}

// The bolts of the flashes under way, on the picture (camera-relative middle C): out of the wall's cloud to the land.
fn hu_bolts(px: vec2<f32>, fl: HuFlash, C: vec3<f32>, near: f32, ct: f32, ca: f32, seed: u32, t: f32) -> vec3<f32> {
    var c = vec3<f32>(0.0);
    for (var j = 0; j < 3; j = j + 1) {
        let b = fl.b[j];
        if (b.w < 0.01) {
            continue;
        }
        let root = fl.p[j].xyz;
        let a = fl.a[j];
        let n = fl.n[j];
        let s0 = f32(pcg(bitcast<u32>(b.x) ^ seed) & 1023u) * 0.37;
        // (the leader, and the re-strokes after: thin and jagged, a new shape each two frames; a re-stroke now and
        // then across the cloud instead, out of the root sideways)
        let lk = hu_lead_k(a, n);
        if (lk > 0.0) {
            let shape = f32(u32(a * 30.0));
            var tip = C + b.xyz;
            if (a > HU_LEAD && (n & 16u) != 0u) {
                let side = normalize(vec3<f32>(-root.z, 0.0, root.x)) * select(-1.0, 1.0, (n & 32u) != 0u);
                tip = C + root + side * (70.0 + 50.0 * f32((n >> 6u) & 7u) / 7.0) - vec3<f32>(0.0, 25.0, 0.0);
            }
            let m = hu_bolt(px, C + root, tip, s0 + shape * 5.3, near, ct, ca);
            c = c + (vec3<f32>(1.0, 0.98, 1.0) * m.x * 2.4 + vec3<f32>(0.62, 0.6, 1.0) * m.y * 0.6) * lk;
        }
        // (the return stroke's column)
        let bk = hu_beam_k(a, n);
        if (bk > 0.0) {
            let ue = 1.0 - smoothstep(0.17, 0.27, a);
            let m = hu_beam(px, C + root, C + b.xyz, s0, ue, near, ct, ca);
            c = c + (vec3<f32>(1.0, 0.98, 1.0) * m.x * 3.0 + vec3<f32>(0.66, 0.64, 1.0) * m.y * 1.1) * bk;
        }
    }
    return c;
}

// Rain in the world: drops falling along lines in the way they fall (`vel`, blocks a second: down, and blown), the
// lines' feet on a grid across that way, a jittered line a cell, the drops strung along each its own (length, speed,
// spacing, brightness, whether it is there: a hash a cell). Four layers out from the camera (`cq`, off the middle),
// each a coarser grid than the last: near drops big, fast and few, far ones fine and many. Only the cells the ray
// crosses in each layer are tried, so no direction is special: looking along the rain (straight up or down) the drops
// come end on, as dots, never converging on a point; nothing repeats on the picture. Hidden past `near`.
fn hu_rain_lines(rd: vec3<f32>, cq: vec3<f32>, vel: vec3<f32>, near: f32, time: f32) -> f32 {
    let spd = length(vel);
    let w = vel / max(spd, 1.0e-3);
    let e1 = normalize(cross(w, select(vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(1.0, 0.0, 0.0), abs(w.x) < 0.9)));
    let e2 = cross(w, e1);
    let c2 = vec2<f32>(dot(cq, e1), dot(cq, e2));
    let r2 = vec2<f32>(dot(rd, e1), dot(rd, e2));
    let rr = dot(r2, r2);
    let rw = dot(rd, w);
    let aw0 = dot(cq, w);
    let focal = frame.resolution.y / (2.0 * tan(frame.view_params.w * 0.5));
    var sum = 0.0;
    for (var k = 0; k < 4; k = k + 1) {
        let fk = f32(k);
        let cell = 0.45 * pow(2.1, fk);
        let ta = 1.3 * pow(2.1, fk);
        let tb = min(ta * 2.1, near);
        if (ta >= tb) {
            break;
        }
        let pa = c2 + r2 * ta;
        let pb = c2 + r2 * tb;
        var last = vec2<f32>(1.0e9);
        for (var n = 0; n < 5; n = n + 1) {
            let g = floor(mix(pa, pb, (f32(n) + 0.5) / 5.0) / cell);
            if (all(g == last)) {
                continue;
            }
            last = g;
            let hb = pcg(bitcast<u32>(i32(g.x)) * 0x9E3779B1u ^ pcg(bitcast<u32>(i32(g.y)) * 0x85EBCA6Bu ^ u32(k) * 0x27D4EB2Fu));
            // (in gusty sheets: the rain thicker and thinner in broad patches that drift past with the wind)
            let gust = vnoise(g * cell * (1.0 / 38.0) + vec2<f32>(0.0, time * 0.9 * spd / 38.0));
            if (f32(hb & 0xFFFFu) / 65535.0 > (0.4 + 0.12 * fk) * (0.25 + 1.5 * gust * gust)) {
                continue;
            }
            let hc = pcg(hb);
            var p = (g + vec2<f32>(0.15, 0.15) + 0.7 * vec2<f32>(f32(hc & 0xFFFFu), f32(hc >> 16u)) / 65535.0) * cell;
            // (where the ray passes nearest the line, and how near)
            var ts = clamp(select(0.5 * (ta + tb), dot(p - c2, r2) / rr, rr > 1.0e-6), ta, tb);
            // (each line a little off the wind's way: tilted its own way across it)
            let tilt = (vec2<f32>(f32((hc >> 3u) & 255u), f32((hc >> 11u) & 255u)) / 255.0 - 0.5) * 0.14;
            p = p + tilt * (aw0 + rw * ts);
            ts = clamp(select(0.5 * (ta + tb), dot(p - c2, r2) / rr, rr > 1.0e-6), ta, tb);
            let d = length(c2 + r2 * ts - p);
            let px = d * focal / ts;
            let wpx = 0.55 + 1.1 / (1.0 + fk);
            if (px > 3.0 * wpx) {
                continue;
            }
            // (the drops along it: is there one where the ray passes, over the stretch of the line the ray is that near)
            let hd = pcg(hc ^ 0x51u);
            let period = cell * (1.6 + 2.4 * f32(hd & 255u) / 255.0);
            let hl = f32((hd >> 8u) & 255u) / 255.0;
            let len = (cell * (0.15 + 0.9 * hl * hl) + spd * 0.008) / (1.0 + 0.3 * fk);
            let half_t = min(wpx * ts / focal / max(sqrt(rr), 1.0e-3), 0.5 * (tb - ta));
            let x0 = (aw0 + rw * (ts - half_t) - spd * (0.9 + 0.2 * f32((hd >> 16u) & 255u) / 255.0) * time) / period + f32(hd >> 24u) / 255.0;
            let x1 = x0 + 2.0 * abs(rw) * half_t / period;
            let lf = len / period;
            // (its head bright, its tail fading behind it)
            let fx = fract(x0);
            let on = select(step(fx, lf) * (0.25 + 0.75 * smoothstep(0.0, lf, fx)), 0.7, floor(x1) != floor(x0) || x1 - x0 >= 1.0);
            let hb2 = f32(hc & 255u) / 255.0;
            sum = sum + on * exp(-px * px / (wpx * wpx)) * (0.6 - 0.07 * fk) * (0.3 + 1.2 * hb2 * hb2);
        }
    }
    return sum;
}

struct PlOut {
    c: vec4<f32>,
    e: vec4<f32>,
}

// A block or tree hit, lit: the storm's grey daylight on it, its own colour.
fn hu_lit(h: HuHit, L: vec3<f32>, amb: vec3<f32>, sunc: vec3<f32>, under: f32) -> vec3<f32> {
    // (the mip level a block's sixteen texels are seen at, this far off)
    let lod = hu_lod(h.t);
    let alb = hu_face(h.bk, h.face, h.uv, lod) * h.shade;
    let n = h.n;
    let dif = max(dot(n, L), 0.0) * mix(1.0, 0.25, under);
    return alb * (amb * (1.5 + 0.6 * n.y) + sunc * dif * 0.9 + vec3<f32>(0.012));
}

// The pass, in one of three stages: 0 the whole of it at full size (fs_main); 1 the half-size stage (fs_half: the
// cloud, the rain, the dust and which block or tree each two by two of the picture's pixels sees), as premultiplied
// colour and transmittance with what it saw; 2 the join (fs_join: the blocks and the trees the half-size stage found
// round this pixel tried again sharp, then the rest, with the half-size stage's cloud laid over: `hj` the join's
// gathering of the four half-size pixels round it, `HuJoin`).
struct HuJoin {
    up: vec4<f32>,    // their cloud upsampled against the depth of the land here (joint bilateral)
    ct: f32,          // and its middle
    upn: vec4<f32>,   // the cloud of the one that marched the shortest way (it stopped at a block or tree)
    ctn: f32,
    ml: f32,          // how far that was
    ids: array<vec2<f32>, 4>,
}
fn hurricane(in: StageIn, stage: u32, hj: HuJoin) -> PlOut {
    var uv = in.uv;
    let time = now();
    let k = intensity_v();
    let seed = u32(seed_v());
    let anc = anchor_xz();
    let cam = frame.camera_position.xyz;
    let gy = block_y() + 1.0 + select(0.0, hu_w(1u), hu_have());
    // (off the camera without its f32 rounding: 92,000 out, camera_position moves in 1/128 block steps, and what flies
    // close by jumped with them; `camera_rest` is what the rounding left out, on a fork that gives it, else nothing)
    let C = (vec3<f32>(anc.x, gy, anc.y) - cam) - camera_rest();
    let sun = frame.sun.xyz;
    let day = saturate(sun.y * 2.5 + 0.35);
    let sun_up = smoothstep(-0.12, 0.06, sun.y);
    let warm = (1.0 - smoothstep(0.02, 0.4, sun.y)) * smoothstep(-0.2, -0.02, sun.y);
    let moon = smoothstep(-0.02, -0.2, sun.y);
    let L = normalize(select(-sun, sun, sun.y > -0.04) + vec3<f32>(0.0, 0.03, 0.0));
    var d = 0.0;
    if (stage == 1u) {
        let full = vec2<i32>(frame.resolution.xy);
        let q = vec2<i32>(floor(in.position.xy)) * 2;
        let q1 = min(q + vec2<i32>(1), full - vec2<i32>(1));
        let d0 = textureLoad(scene_depth, q, 0);
        let d1 = textureLoad(scene_depth, vec2<i32>(q1.x, q.y), 0);
        let d2 = textureLoad(scene_depth, vec2<i32>(q.x, q1.y), 0);
        let d3 = textureLoad(scene_depth, q1, 0);
        let hq = vec2<i32>(floor(in.position.xy));
        d = select(min(min(d0, d1), min(d2, d3)), max(max(d0, d1), max(d2, d3)), ((hq.x + hq.y) & 1) == 0);
        uv = (vec2<f32>(q) + 1.0) * frame.resolution.zw;
    } else {
        d = depth_at(uv);
    }
    let sky = is_sky(d);
    let rel = world_offset(uv, select(d, 0.5, sky));
    let scene_len = select(1.0e9, length(rel), !sky);
    let rd = normalize(world_offset(uv, 0.5));
    let scene = srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, uv, 0.0).rgb);
    var col = scene;
    let form = hu_form(time) * hu_fade(time);
    let St = hu_spin_int(time);
    let Sf = hu_spin_int(min(time, HU_FLING));

    // (the light, matched to the scene's, dimmed and greyed under the storm)
    let skyl = srgb_to_linear(frame.sky_color.rgb);
    let amb0 = mix(vec3<f32>(0.02, 0.025, 0.035), skyl * 0.55 + vec3<f32>(0.03), day);
    let amb = amb0 * mix(1.0, 0.6, form);
    let sunc0 = mix(vec3<f32>(1.25, 1.18, 1.05), vec3<f32>(1.4, 0.62, 0.3), warm) * sun_up + vec3<f32>(0.05, 0.07, 0.11) * moon;
    let sunc = sunc0 * mix(1.0, 0.55, form);
    // (where the eye is: the camera in it sees the sky clear over it; over the cloud's top, the sky's own)
    let cq = -C;
    let in_eye = hu_eye(time) * (1.0 - smoothstep(hu_wall_in(cq.y, time) - 8.0, hu_wall_in(cq.y, time) + 2.0, length(cq.xz)));
    let over = smoothstep(hu_wall_top(time) - 60.0, hu_wall_top(time) + 30.0, cq.y);
    let open = max(in_eye, over);

    // ---- what it carries: the blocks round the eyewall and the trees, nearest first ---------------------------------
    var hit = hu_none();
    if (time < HU_LEN && hu_have()) {
        if (stage == 2u) {
            // (the ones the half-size stage saw round this pixel, tried again sharp)
            for (var n = 0; n < 4; n = n + 1) {
                let id = hj.ids[n];
                if (id.x <= -2047.0) {
                    continue;
                }
                if (id.x < 0.0) {
                    hu_trees(rd, C, time, St, Sf, seed, i32(-id.x - 0.5), &hit);
                } else {
                    let c = hu_unpack(id);
                    hu_block(rd, C, c.x, c.y, c.z, time, St, Sf, seed, &hit);
                }
            }
        } else {
            hu_debris(rd, C, min(scene_len, 2500.0), time, St, Sf, seed, select(240, 145, stage == 1u), &hit);
            hu_trees(rd, C, time, St, Sf, seed, -1, &hit);
        }
    }
    let hit_len = min(scene_len, hit.t);
    // ---- the half-size stage's cloud round this pixel: as upsampled against the land's depth, or, for a block or tree
    // found sharp here that the half-size pixel nearest it in depth stopped at, that one's (the cloud in front of it)
    var up = hj.up;
    var ct = hj.ct;
    let ml = hj.ml;
    if (stage == 2u && hit.t < scene_len && abs(hj.ml - hit.t) < 0.08 * hit.t + 3.0) {
        up = hj.upn;
        ct = hj.ctn;
    }
    // (the flashes worked out once what flies is found: little to keep in hand through that)
    let fl = hu_flashes(time, seed);

    // ---- the land under the storm: darker, greyer, wet ------------------------------------------------------------------
    var glass = vec4<f32>(0.0);
    var gt = 1.0e9;
    if (stage != 1u) {
        if (!sky) {
            let rr = length((rel - C).xz);
            // (its edge ragged, never a disc of shade spreading)
            let ce = hu_deck_r(time) * (0.95 + 0.4 * (hu_gn2(rot2((rel - C).xz, -hu_arm_turn(St)) * (1.0 / 380.0) + vec2<f32>(41.0, 13.0)) - 0.5));
            let cover = form * (1.0 - smoothstep(ce * 0.55, ce, rr));
            let wet = hu_rain(time) * hu_fade(time) * (1.0 - smoothstep(hu_deck_r(time) * 0.6, hu_deck_r(time) * 0.85, rr));
            let shade = form * (1.0 - smoothstep(hu_deck_r(time), hu_deck_r(time) * 1.8, rr));
            // (the eye's land lit where the sun reaches down the stadium, and the flashes lighting the land)
            let gq = rel - C;
            var eye = hu_eye(time) * (1.0 - smoothstep(HU_R_EYE - 4.0, HU_R_EYE + 6.0, rr));
            if (eye > 0.0) {
                eye = eye * (0.35 + 0.65 * hu_eyelit(gq, rr, hu_wall_in(gq.y, time), hu_wall_top(time), L, time));
            }
            col = col * (1.0 + 1.6 * hu_flash_at(fl, gq) * form);
            col = col * (1.0 - 0.28 * form - 0.4 * cover * (1.0 - 0.7 * eye)) * (1.0 - 0.25 * shade * (1.0 - cover)) * mix(vec3<f32>(1.0), vec3<f32>(0.86, 0.9, 0.94), wet);
        } else {
            let lum = dot(col, vec3<f32>(0.2126, 0.7152, 0.0722));
            let gf = form * (1.0 - open);
            col = mix(col, vec3<f32>(lum) * vec3<f32>(0.93, 0.97, 1.0), 0.65 * gf) * (1.0 - 0.55 * gf);
            // (the sky over the eye a deeper blue, high and clear)
            col = mix(col, col * vec3<f32>(0.62, 0.78, 1.08), 0.6 * in_eye * form);
        }
        if (hit.t < scene_len) {
            let under = form * (1.0 - hu_eye(time) * 0.6);
            // (in the cloud, as dim as the cloud round it: seen in the eyewall as dark specks, never pale ghosts)
            let hq = rd * hit.t - C;
            let inc = select(0.0, hu_den(hq, time, St, 0).d * form, stage == 0u);
            col = hu_lit(hit, L, amb, sunc, under) * (1.0 + 1.6 * hu_flash_at(fl, hq) * form) * mix(1.0, 0.3, inc);
        }
        // (a translucent block in front: what is behind it seen through it, tinted, as the game blends its glass; laid
        // over the cloud too where the cloud is behind it, below)
        var g = hu_none();
        if (hit.gt < min(scene_len, hit.t)) {
            g.lo = -1.0;
            let c = hu_unpack(unpack2x16float(hit.gid));
            hu_block(rd, C, c.x, c.y, c.z, time, St, Sf, seed, &g);
        }
        if (g.t < min(scene_len, hit.t)) {
            let gq = rd * g.t - C;
            glass = vec4<f32>(hu_lit(g, L, amb, sunc, form * (1.0 - hu_eye(time) * 0.6)) * (1.0 + 1.6 * hu_flash_at(fl, gq) * form), 0.2 + 0.75 * hu_see(g.bk, g.face, g.uv, g.t).x);
            gt = g.t;
        }
    }

    // ---- the cloud, the rain and the dust -----------------------------------------------------------------------------
    // (a block or a tree deep in the cloud, mostly hidden, goes as the cloud round it does: no pale ghosts of them)
    let hidden = select(0.0, 1.0 - smoothstep(0.06, 0.4, select(up.a, 1.0, stage != 2u)), hit.t < scene_len);
    if (stage == 2u) {
        // (a block or tree well in front of the cloud the half-size stage gathered (it saw past this one: by its edge,
        // or through its leaves or glass) has none of that cloud laid over it)
        let front = hit.t < scene_len && ct < 1.0e8 && hit.t + 6.0 < min(ct, ml);
        if (!front) {
            col = mix(col, 0.55 * up.rgb / max(1.0 - up.a, 1.0e-3), hidden) * select(1.0, mix(0.35, 1.0, smoothstep(0.35, 0.85, up.a)), hit.t < scene_len);
            col = mix(col, glass.rgb, glass.a * step(ct, gt));
            col = col * up.a + up.rgb;
        }
        col = mix(col, glass.rgb, glass.a * select(step(gt, ct), 1.0, front));
        col = col + hu_bolts(in.position.xy, fl, C, hit_len, ct, up.a, seed, time) * k;
    } else if (time < HU_LEN) {
        // (the march's start a pixel's own, white, so no slice of its strides lines up with the next pixel's: grain,
        // never sheets or hatching)
        let pj = vec2<u32>(floor(in.position.xy));
        let j = f32(pcg(pj.x * 0x9E3779B1u ^ pcg(pj.y * 0x85EBCA6Bu ^ u32(time * 60.0))) & 0xFFFFu) / 65536.0;
        // (the brightest flash lights the cloud: one, so the march keeps little in hand)
        var flv = fl.p[0];
        if (fl.p[1].w > flv.w) {
            flv = fl.p[1];
        }
        if (fl.p[2].w > flv.w) {
            flv = fl.p[2];
        }
        let v = hu_volume(rd, hit_len, scene_len, C, time, St, j, L, amb0, sunc0, flv, stage == 0u);
        let hid = select(hit.id, unpack2x16float(hit.cid), hit.ct < min(hit.t, scene_len));
        if (stage == 0u) {
            if (hit.t < scene_len) {
                // (and one seen through the murk a dark shape in it, as debris in a storm is, never paler than it)
                col = mix(col, 0.55 * v.lc, 1.0 - smoothstep(0.06, 0.4, v.c.a)) * mix(0.35, 1.0, smoothstep(0.35, 0.85, v.c.a));
            }
            // (a translucent block in front of the cloud's middle laid over it, else under it)
            col = mix(col, glass.rgb, glass.a * step(v.t, gt));
            col = col * mix(1.0, v.c.a, k) + v.c.rgb * k;
            col = mix(col, glass.rgb, glass.a * step(gt, v.t));
            col = col + hu_bolts(in.position.xy, fl, C, hit_len, v.t, v.c.a, seed, time) * k;
        } else {
            return PlOut(vec4<f32>(v.c.rgb * k, mix(1.0, v.c.a, k)), vec4<f32>(min(hit_len, 6.0e4), select(1.0e9, v.t, v.t < 1.0e8), hid.x, hid.y));
        }
    }

    // ---- the rain close by: streaks in the world (`hu_rain_lines`), driven by the wind where the camera is (round the
    // storm, nearly sideways near the eyewall), hidden by the land and what flies in front, lit by the flashes. None
    // in the calm eye, none over the cloud's base.
    let rk = hu_rain(time) * hu_fade(time);
    if (rk > 0.01) {
        let rc = length(cq.xz);
        let near = (1.0 - smoothstep(hu_deck_r(time) * 0.6, hu_deck_r(time) * 0.8, rc)) * (1.0 - in_eye) * (1.0 - smoothstep(HU_BASE, HU_BASE + 60.0, cq.y)) * smoothstep(HU_R_EYE, HU_R_EYE + 20.0, rc);
        if (near > 0.01) {
            let tang = normalize(vec2<f32>(-cq.z, cq.x) * HU_SPIN + vec2<f32>(1.0e-4, 0.0));
            let wv = HU_V * hu_shape(max(rc, 1.0)) * hu_spin(time) * 1.4;
            let streak = hu_rain_lines(rd, cq, vec3<f32>(tang.x * wv, -14.0, tang.y * wv), min(scene_len, hit.t), time);
            let flash = hu_flash_at(fl, cq);
            col = col + vec3<f32>(0.55, 0.59, 0.65) * streak * rk * near * (amb0 * 0.8 + vec3<f32>(0.03) + vec3<f32>(0.8, 0.85, 1.0) * flash * 0.6) * k;
        }
    }

    let srgb = linear_to_srgb(max(col, vec3<f32>(0.0)));
    if (capture() > 2.5) {
        let sp = floor(in.position.xy);
        let chk = fract((sp.x + sp.y) * 0.5);
        let ycc_y = srgb.g * 0.5 + (srgb.r + srgb.b) * 0.25;
        let ycc_co = srgb.r - srgb.b;
        let ycc_cg = srgb.g - (srgb.r + srgb.b) * 0.5;
        return PlOut(vec4<f32>(ycc_y, select(ycc_cg, ycc_co, chk < 0.25) * 0.5 + 0.5, 0.0, 1.0), vec4<f32>(0.0));
    }
    return PlOut(vec4<f32>(srgb, 1.0), vec4<f32>(0.0));
}

fn hu_no_join() -> HuJoin {
    var j: HuJoin;
    j.up = vec4<f32>(0.0, 0.0, 0.0, 1.0);
    j.ct = 1.0e9;
    j.upn = j.up;
    j.ctn = 1.0e9;
    j.ml = 1.0e9;
    j.ids = array<vec2<f32>, 4>(vec2<f32>(-2048.0), vec2<f32>(-2048.0), vec2<f32>(-2048.0), vec2<f32>(-2048.0));
    return j;
}

@fragment
fn fs_main(in: StageIn) -> @location(0) vec4<f32> {
    return hurricane(in, 0u, hu_no_join()).c;
}

// [half stage]
// QUALITY FAST (mod/src/lib.rs keeps this only then): the cloud, the rain and the dust drawn at half the width and
// height by fs_half, which also finds the block or tree each of its pixels sees; fs_join lays the cloud over the
// full-size picture and draws the blocks and trees its four nearest found sharp, at full size. A game without the
// stages compiles these too and draws fs_main alone, at full size.
@group(0) @binding(6) var half_picture: texture_2d<f32>;
@group(0) @binding(7) var half_extra: texture_2d<f32>;

struct PlHalf {
    @location(0) c: vec4<f32>,
    @location(1) e: vec4<f32>,
}
@fragment
fn fs_half(in: StageIn) -> PlHalf {
    let o = hurricane(in, 1u, hu_no_join());
    return PlHalf(o.c, o.e);
}
@fragment
fn fs_join(in: StageIn) -> @location(0) vec4<f32> {
    let hs = vec2<i32>(textureDimensions(half_picture));
    let h = floor(in.position.xy) * 0.5 - 0.25;
    let i0 = vec2<i32>(floor(h));
    var j = hu_no_join();
    // (the cloud upsampled against the depth it was marched to: the land's, or a block's in front of it)
    let d = depth_at(in.uv);
    let len = select(1.0e9, length(world_offset(in.uv, d)), !is_sky(d));
    let f = h - floor(h);
    let lp = min(len, 6.0e4);
    var acc = vec4<f32>(0.0);
    var sw = 0.0;
    var near_dz = 1.0e9;
    var near_c = vec4<f32>(0.0, 0.0, 0.0, 1.0);
    for (var n = 0; n < 4; n = n + 1) {
        let o = vec2<i32>(n & 1, n >> 1u);
        let q = clamp(i0 + o, vec2<i32>(0), hs - vec2<i32>(1));
        let c = textureLoad(half_picture, q, 0);
        let e = textureLoad(half_extra, q, 0);
        j.ids[n] = e.zw;
        let bw = select(1.0 - f.x, f.x, o.x == 1) * select(1.0 - f.y, f.y, o.y == 1);
        let dz = abs(min(e.x, lp) - lp) / max(lp, 1.0);
        let w = bw * exp(-dz * 24.0);
        acc = acc + c * w;
        sw = sw + w;
        if (dz < near_dz) {
            near_dz = dz;
            near_c = c;
            j.ct = e.y;
        }
        // (and the one that marched the shortest way: what it stopped at may be what this pixel finds sharp)
        if (e.x < j.ml) {
            j.ml = e.x;
            j.upn = c;
            j.ctn = e.y;
        }
    }
    j.up = select(acc / max(sw, 1.0e-6), near_c, sw < 1.0e-3);
    return hurricane(in, 2u, j).c;
}
// [end half stage]

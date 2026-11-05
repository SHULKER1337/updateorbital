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


// Orbital Laser's post pass for the Nuke (laser 10): the Payload's (payload.wgsl) grown into a nuclear bomb. Like it,
// the mod builds it from shaders/strike.wgsl up to its fs_main less the other lasers' own functions, followed by this
// file, and sets it for a nuke strike only. Validate with tools/check-shader.sh.

// ---- laser 10: the nuke -------------------------------------------------------------------------------------------
// No beam. The bomb comes in from orbit, a white-hot streak across the sky with a thick trail, sheds its heat, arcs
// over into a steep dive (a finned casing, spinning up, glinting), faster and faster, a vapour collar round it; it bursts
// PL_BURST over the land (the real ground under it: pl_g0), low enough that the fireball meets it at once and spreads
// over it (pl_foot) before it lifts: a blinding white flash whites out the picture and lights the land and the sky; a fireball
// swells white-orange, rises and darkens into a mushroom cloud hundreds of blocks tall (a fat, churning toroidal cap
// with a ragged underside, glowing orange inside for tens of seconds, a stem pulled up out of the land, a condensation
// ring round the stem, a ground-hugging base surge); the shockwave races out as a shell of distortion over the land,
// raising a wall of dust; debris flies and rains down far round it.
// strike/nuke.rs samples the path into the table (nk_table, render.set-data): keep the PL_* in step with its NK_*.
const PL_SEEN: f32 = 0.8;          // the bomb shows, coming in from orbit white-hot,
const PL_COOL: f32 = 6.0;          // sheds its heat and arcs over into its fall,
const PL_DIVE: f32 = 8.0;          // dives faster and faster, its nose heating again,
const PL_HIT: f32 = 11.0;          // and bursts,
const PL_BURST: f32 = 12.0;        // this high over the ground under the target (pl_g0)
const PL_LEN: f32 = 90.0;          // the strike's length (lasers.rs): everything fades out over its last PL_FADE
const PL_FADE: f32 = 10.0;
const PL_SOFT0: f32 = 48.0;        // the cloud keeps its crisp billows this long after the burst, then loses them
const PL_SOFT1: f32 = 72.0;        // by this, a soft, drifting haze thinning away (gone by PL_LEN)
const PL_CHURN: f32 = 7.0;        // the roll's lumps carried this long before they are let go (pl_col_sdf)
const PL_V: f32 = 343.0;           // the shockwave's front, blocks a second (with the blast's sound: nuke.rs)
const PL_P: u32 = 16u;             // the table: the path's samples from PL_P, three words each,
const PL_PF: u32 = 400u;
const PL_PW: u32 = 8u;
const PL_HF: u32 = 1024u;          // the land's heightfield (nuke.rs's nk_hf_words): its size, then heights, shelter
const PL_FR: u32 = 560u;           // the pieces it sheds coming in (none for the nuke)
const PL_FW: u32 = 12u;
const PL_DEBRIS: i32 = 160;
const PL_DB: u32 = 10496u;         // the debris (nuke.rs's nk_debris_words), PL_DW words each
const PL_DW: u32 = 10u;

fn pl_w(i: u32) -> f32 {
    if (i >= arrayLength(&mod_data)) {
        return 0.0;
    }
    return bitcast<f32>(mod_data[i]);
}
fn pl_u(i: u32) -> u32 {
    if (i >= arrayLength(&mod_data)) {
        return 0u;
    }
    return mod_data[i];
}
fn pl_n() -> i32 {
    return i32(pl_w(0u) + 0.5);
}
fn pl_sample(i: i32) -> vec3<f32> {
    let b = PL_P + 3u * u32(clamp(i, 0, pl_n() - 1));
    return vec3<f32>(pl_w(b), pl_w(b + 1u), pl_w(b + 2u));
}
// Where the object is at strike time t (from the target's ground): the samples, smoothly between (Catmull-Rom).
fn pl_head(t: f32) -> vec3<f32> {
    let u = (t - pl_w(1u)) / max(pl_w(2u), 1.0e-3);
    let i = i32(floor(u));
    let f = u - floor(u);
    let p0 = pl_sample(i - 1);
    let p1 = pl_sample(i);
    let p2 = pl_sample(i + 1);
    let p3 = pl_sample(i + 2);
    let f2 = f * f;
    let f3 = f2 * f;
    return 0.5 * (2.0 * p1 + (p2 - p0) * f + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f2 + (3.0 * p1 - p0 - 3.0 * p2 + p3) * f3);
}
fn pl_wind() -> vec3<f32> {
    return vec3<f32>(pl_w(3u), 0.0, pl_w(4u));
}
// How far a bit of the trail (sample i) has drifted `age` seconds after it was laid: carried by the wind, rising a
// little, wandering.
fn pl_trail_drift(i: i32, age: f32, seed: u32) -> vec3<f32> {
    let fi = f32(i);
    let wob = vec3<f32>(sin(fi * 0.21 + f32(seed % 61u)), 0.4 * sin(fi * 0.13 + 2.0), cos(fi * 0.17 + f32(seed % 37u)));
    return pl_wind() * age + vec3<f32>(0.0, 0.35 * age, 0.0) + wob * (0.35 * age);
}
// Where a bit of the trail laid at time te has drifted to by time t.
fn pl_trail_at(i: i32, te: f32, t: f32, seed: u32) -> vec3<f32> {
    return pl_sample(i) + pl_trail_drift(i, max(t - te, 0.0), seed);
}
// Where a shed piece is `s` seconds after it let go at p0 with velocity v0: slowed by the air (drag k a second),
// falling (under gravity with that drag).
fn pl_frag(p0: vec3<f32>, v0: vec3<f32>, k: f32, s: f32) -> vec3<f32> {
    let e = (1.0 - exp(-k * s)) / k;
    return p0 + v0 * e - vec3<f32>(0.0, 20.0 * (s - e) / k, 0.0);
}
// The ray against the line through a and b, its nearest point kept between lo and hi along it (0 at a, 1 at b): the
// distance between them, how far along the ray, how far along ab.
fn pl_ray_seg(rd: vec3<f32>, a: vec3<f32>, b: vec3<f32>, lo: f32, hi: f32) -> vec3<f32> {
    let ab = b - a;
    let l2 = max(dot(ab, ab), 1.0e-6);
    let rab = dot(rd, ab);
    let den = l2 - rab * rab;
    var s = clamp(select(0.0, (rab * dot(rd, a) - dot(a, ab)) / den, den > 1.0e-6), lo, hi);
    let t = max(dot(rd, a + ab * s), 0.0);
    s = clamp(dot(rd * t - a, ab) / l2, lo, hi);
    return vec3<f32>(length(rd * t - (a + ab * s)), t, s);
}
// Point j of the trail at strike time t: laid at its sample's time, drifted since; the one past the last laid is the
// head's.
fn pl_trail_pt(j: i32, last: i32, thead: f32, t: f32, seed: u32) -> vec3<f32> {
    if (j > last) {
        return pl_head(thead);
    }
    return pl_trail_at(max(j, 0), pl_w(1u) + pl_w(2u) * f32(max(j, 0)), t, seed);
}
// Where along the ray (from, to) it is on the side of the plane through p that n faces.
fn pl_half(rd: vec3<f32>, p: vec3<f32>, n: vec3<f32>) -> vec2<f32> {
    let r = dot(rd, n);
    let c = dot(p, n);
    if (abs(r) < 1.0e-6) {
        return select(vec2<f32>(1.0, 0.0), vec2<f32>(-1.0e9, 1.0e9), c <= 0.0);
    }
    let tc = c / r;
    return select(vec2<f32>(-1.0e9, tc), vec2<f32>(tc, 1.0e9), r > 0.0);
}
fn pl_erf(x: f32) -> f32 {
    let y = clamp(x, -4.0, 4.0);
    return tanh(1.1284 * y + 0.1009 * y * y * y);
}
fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// ---- the bomb's shape (the fall's): a casing, its fins, the vapour round it in the dive ------------------------------------------------
const NK_BS: f32 = 1.3;            // the casing's scale: about 16 long and 3.4 across
// A cone from radius r1 at y 0 to r2 at y h, its ends rounded (iq's round cone).
fn nk_rcone(p: vec3<f32>, r1: f32, r2: f32, h: f32) -> f32 {
    let q = vec2<f32>(length(p.xz), p.y);
    let b = (r1 - r2) / h;
    let a = sqrt(1.0 - b * b);
    let k = dot(q, vec2<f32>(-b, a));
    if (k < 0.0) {
        return length(q) - r1;
    }
    if (k > a * h) {
        return length(q - vec2<f32>(0.0, h)) - r2;
    }
    return dot(q, vec2<f32>(a, b)) - r1;
}
// The bomb at p (its own frame: y along it, nose first, from its middle): the distance, and what is there (0 the body,
// 1 the fins and tail, 2 the nose, 3 the vapour collar). `spin`: how far it has turned; `vc`: how much of the collar
// there is (none at 0).
fn nk_bomb(p0: vec3<f32>, spin: f32, vc: f32) -> vec2<f32> {
    let p = p0 / NK_BS;
    var d = nk_rcone(p - vec3<f32>(0.0, -4.2, 0.0), 1.3, 1.3, 7.4);
    d = min(d, nk_rcone(p - vec3<f32>(0.0, -6.0, 0.0), 0.75, 1.3, 1.8));
    var m = 0.0;
    let dn = nk_rcone(p - vec3<f32>(0.0, 3.2, 0.0), 1.3, 0.28, 2.9);
    if (dn < d) {
        m = 2.0;
        d = dn;
    }
    // (four fins, turned with it, swept back)
    let cs = cos(spin);
    let sn = sin(spin);
    var f = abs(vec2<f32>(p.x * cs - p.z * sn, p.x * sn + p.z * cs));
    if (f.y > f.x) {
        f = f.yx;
    }
    let df = max(max(f.y - 0.09, f.x - 2.9), max(-6.5 - p.y, p.y + 3.4 + 0.6 * (f.x - 1.0)));
    if (df < d) {
        m = 1.0;
        d = df;
    }
    d = d * NK_BS;
    if (vc > 0.0) {
        // (the vapour collar of its dive near the speed of sound: a thin cone of cloud opening back from its shoulders,
        // growing as it gathers speed)
        let yc = 2.4 * NK_BS - p0.y;
        let rc = length(p0.xz);
        let ln = 9.0 * vc;
        let dcn = abs(dot(vec2<f32>(rc, yc), vec2<f32>(0.82, -0.57))) - 0.25;
        let dv = max(dcn, max(-yc, yc - ln));
        if (dv < d) {
            m = 3.0;
            d = dv;
        }
    }
    return vec2<f32>(d, m);
}


// How much of the sun's light the cap lets through to a point `o` under it (camera-relative): the sun's ray from it
// crossing the cap's level, through its broad soft disc. For the stem, the surge and the dust, which the full march
// (pl_shadow) would cost too much for at every step.
fn pl_cap_shade(o: vec3<f32>, L: vec3<f32>, a: f32, C: vec3<f32>, hc: f32, R: f32) -> f32 {
    let capy = C.y + hc;
    if (L.y < 0.02 || o.y > capy) {
        return 1.0;
    }
    let s = (capy - o.y) / L.y;
    let r = length((o + L * s - C - pl_wind() * a).xz);
    let thin = 1.0 - 0.8 * smoothstep(PL_SOFT0, PL_LEN, a);
    return 1.0 - 0.8 * (1.0 - smoothstep(0.55 * R, 1.1 * R, r)) * smoothstep(2.0, 6.0, a) * thin;
}

// ---- the dust of the shockwave: a low wall racing out over the land, rising and hanging behind it ---------------
// The ground at r out where the heightfield does not reach (or before it is in): the target's, rising or falling to
// the player's as it goes out to them.
fn pl_gref(r: f32, me: vec3<f32>, C: vec3<f32>, dme: f32) -> f32 {
    return mix(0.0, me.y - C.y, smoothstep(0.0, max(dme, 1.0), r));
}
// The land at q (level, from the target): its ground (from the target's) and how sheltered it is from the blast by the
// land between (0 to 1), from the heightfield, smoothly between its cells; `gref` until it is in.
fn pl_land(q: vec2<f32>, gref: f32) -> vec2<f32> {
    let nf = pl_w(PL_HF);
    if (nf < 2.0) {
        return vec2<f32>(gref, 0.0);
    }
    let n = u32(nf + 0.5);
    if (arrayLength(&mod_data) < PL_HF + 8u + n * n) {
        return vec2<f32>(gref, 0.0);
    }
    let R = pl_w(PL_HF + 1u);
    let step = 2.0 * R / (nf - 1.0);
    let fc = clamp((q + R) / step, vec2<f32>(0.0), vec2<f32>(nf - 1.001));
    let i0 = vec2<u32>(floor(fc));
    let t = fc - floor(fc);
    var hv = vec4<f32>(0.0);
    var sv = vec4<f32>(0.0);
    for (var j = 0u; j < 4u; j = j + 1u) {
        let c = mod_data[PL_HF + 8u + (i0.y + (j >> 1u)) * n + i0.x + (j & 1u)];
        hv[j] = f32(c & 0xffffu) / 8.0 - 512.0;
        sv[j] = f32((c >> 16u) & 0xffu) / 255.0;
    }
    // (past its edge, the edge's ground carried on: not `gref`, which rises to wherever the player stood, up a tower
    // or in the air)
    let g = mix(mix(hv.x, hv.y, t.x), mix(hv.z, hv.w, t.x), t.y);
    let sh = mix(mix(sv.x, sv.y, t.x), mix(sv.z, sv.w, t.x), t.y);
    let e = smoothstep(-step, 3.0 * step, max(abs(q.x), abs(q.y)) - R);
    return vec2<f32>(g, sh * (1.0 - e));
}
// The ground under the burst (from the target's): the heightfield's round the target, so a strike aimed at a
// treetop, a ledge or the top of a slope still bursts just over the land, not over the air beside it; the target's own
// until the heightfield is in. Never over the target's (the designator hit something there).
fn pl_g0() -> f32 {
    var g = pl_land(vec2<f32>(0.0), 0.0).x;
    for (var i = 0; i < 4; i = i + 1) {
        let an = 1.5708 * f32(i) + 0.785;
        g = g + pl_land(vec2<f32>(cos(an), sin(an)) * 14.0, 0.0).x;
    }
    return clamp(g / 5.0, -40.0, 0.0);
}
// How strongly the fireball's foot is there at `a` seconds after the burst: from the first frames, letting go of the
// ground over its third and fourth seconds as the ball lifts away on its stem.
fn pl_foot_k(a: f32) -> f32 {
    return 1.0 - smoothstep(1.2, 3.8, a);
}
// The fireball's foot at (rho, hy) from the burst's ground (`rt` the ball's radius): a broad dome hugging the land, a
// third wider than the ball and half as high, so the fire spreads along the ground under it; below the ground a ball
// (hidden by the land, there so the foot meets every slope round it). Its distance, sunk away as it lets go.
fn pl_foot(a: f32, rt: f32, rho: f32, hy: f32) -> f32 {
    let s = pl_foot_k(a);
    let rf = 1.3 * rt + 6.0;
    let hf = select(0.55 * rt + 4.0, rf, hy < 0.0) * (0.35 + 0.65 * s);
    let e = vec2<f32>(rho / rf, hy / hf);
    return (length(e) - 1.0) * min(rf, hf) + (1.0 - s) * (0.6 * rt + 40.0);
}
// How far under the burst's ground the foot reaches (the cloud's box).
fn pl_foot_low(a: f32, rt: f32) -> f32 {
    return select(0.0, 1.3 * rt + 6.0, pl_foot_k(a) > 0.0);
}
// The dust at p (camera-relative), `side`: how square the ray crosses the ring there (0 along it): a dense, opaque wall
// a few blocks high just behind a crisp, billowing front, thinning behind it into haze that rises and hangs. All of it
// over the land's own ground (the heightfield, and close to where this pixel's ray meets the land, that point's own
// height: `loc`, its xz from the target, how far it stands off the heightfield there, and the reach of that squared),
// climbing the rises, filling the hollows, thinner and later in the lee of a ridge. Its density, and its height over
// the ground.
fn pl_dust(p: vec3<f32>, C: vec3<f32>, a: f32, me: vec3<f32>, dme: f32, side: f32, loc: vec4<f32>) -> vec2<f32> {
    let q = p - C;
    let r = length(q.xz);
    let w = p + frame.camera_position.xyz;
    let land = pl_land(q.xz, pl_gref(r, me, C, dme));
    let dl = q.xz - loc.xy;
    let h = q.y - land.x - loc.z * exp(-dot(dl, dl) / loc.w);
    let sh = land.y;
    if (h > 120.0 || h < -4.0) {
        return vec2<f32>(0.0, h);
    }
    // (the front billows: pushed on and held back by the turbulence it churns, more so higher up)
    let rf = PL_V * a;
    let n1 = gnoise3(w * vec3<f32>(1.0 / 9.0, 1.0 / 6.0, 1.0 / 9.0) + vec3<f32>(0.0, -1.2 * a, 0.0));
    // (its fine churn only near the front: well behind it, where the wall has gone, the haze's patches are big ones)
    var n2 = 0.5;
    if (rf - r - 0.25 * max(h, 0.0) - 22.0 * sh < 170.0) {
        n2 = gnoise3(w * (1.0 / 3.5) + vec3<f32>(5.0, -2.0 * a, 1.0));
    }
    // (held back in the lee of a ridge, more so the deeper it lies under it)
    let s = rf - r + (n1 - 0.5) * 14.0 + (n2 - 0.5) * 5.0 - 0.25 * max(h, 0.0) - 22.0 * sh;
    if (s < -3.0) {
        return vec2<f32>(0.0, h);
    }
    let since = max(s, 0.0) / PL_V;
    // (the wall: a person's height and more, higher as it goes and behind its front; its top ragged)
    let n3 = gnoise3(w * (1.0 / 38.0) + vec3<f32>(0.0, -0.3 * a, 9.0));
    // (tallest a little behind the front, settling lower behind it)
    // (low, as in the clips: a person's height to a tree's, not a cliff of it, so the picture over it stays clear)
    let rise = 1.0 + 0.8 * smoothstep(0.0, 25.0, s) - 0.7 * smoothstep(30.0, 140.0, s);
    let hw = (9.0 + 0.012 * r) * rise * (0.35 + 1.2 * n1) * (0.6 + 0.8 * n3) + 1.5 * min(since, 6.0);
    let up = smoothstep(hw, hw * 0.35, h) * smoothstep(-4.0, 0.0, h);
    let lead = smoothstep(-3.0, 1.5, s);
    let wall = 1.6 * exp(-s / (18.0 + 0.02 * r)) * (0.75 + 0.25 * side) * (1.0 - 0.6 * sh);
    let haze = (0.009 * exp(-since / 2.5) + 0.0025 * exp(-since / 6.0)) * (0.5 + n2);
    // (none round the column's foot: the blast cleared it, and it would tint the smoke)
    let mid = smoothstep(80.0, 230.0, r);
    // (and what it leaves low over the land for a few seconds, in drifting patches)
    let low = 0.22 * (1.0 - 0.45 * sh) * exp(-since / 3.0) * smoothstep(0.0, 30.0, s) * exp(-max(h, 0.0) / (2.5 + 2.0 * n1)) * smoothstep(0.35, 0.7, n3);
    return vec2<f32>(((wall * saturate(1.5 * n1 + 0.25 * n2) * (0.35 + 1.3 * n3) + haze * (1.0 - 0.4 * sh)) * up + low) * lead * mid, h);
}
// ---- the debris: chunks and specks of earth thrown out, falling back far round it ---------------------------------
struct PlChunk {
    p: vec3<f32>,
    v: vec3<f32>,
    s: f32,
    live: f32,
}
fn pl_chunk(i: i32, a: f32, eka: f32, C: vec3<f32>) -> PlChunk {
    var o: PlChunk;
    // (its numbers worked out once by payload.rs's pl_debris_words: its bearing, how far out it is torn up as the blast
    // reaches it, its speed out and up (most thrown a few hundred blocks, a third far), when, its size, e^(k t0))
    let b = PL_DB + PL_DW * u32(i);
    let tau = a - pl_w(b + 5u);
    o.s = pl_w(b + 6u);
    o.live = 0.0;
    if (tau <= 0.0) {
        return o;
    }
    let dir = vec3<f32>(pl_w(b), 0.0, pl_w(b + 1u));
    let vh = pl_w(b + 3u);
    let vy = pl_w(b + 4u);
    // (a little drag: they slow, and fall less than straight)
    let k = 0.06;
    let ek = eka * pl_w(b + 7u);
    let e = (1.0 - ek) / k;
    let g = 9.8;
    o.p = C + dir * (pl_w(b + 2u) + vh * e) + vec3<f32>(0.0, 2.0 + vy * e - g * (tau - e) / k, 0.0);
    o.v = dir * (vh * ek) + vec3<f32>(0.0, (vy + g / k) * ek - g / k, 0.0);
    o.live = 1.0;
    return o;
}
// How much of a chunk is still in the air (0 once it is down): the land under it looked up only when it is down near the
// highest of it, and only for the chunks near this pixel's ray.
fn pl_chunk_up(ch: PlChunk, C: vec3<f32>, me: vec3<f32>, dme: f32) -> f32 {
    let r = length((ch.p - C).xz);
    var gref = C.y + pl_gref(r, me, C, dme);
    if (ch.p.y < max(gref, C.y + pl_w(PL_HF + 3u)) + 3.0) {
        gref = C.y + pl_land((ch.p - C).xz, gref - C.y).x;
    }
    return smoothstep(gref - 1.0, gref + 2.0, ch.p.y);
}

const PL_DM: f32 = 70.0;           // the most the cloud's lumps stand out of its smooth body (pl_col_sdf), which the
// ---- the mushroom cloud: a fireball rising into a toroidal cap on a stem, a ring round the stem, a base surge -----
struct PlCol {
    a: f32,
    C: vec3<f32>,
    // (the cap: its core circle's height over the ground and radius, the roll's radius about it; the stem's top height
    // and its radius at the foot, in the middle and at the top; the ring round the stem: its height, radius and how
    // much of it shows; the base surge: its radius and its roll's width and height)
    hc: f32,
    Rt: f32,
    rt: f32,
    st: f32,
    sr: vec3<f32>,
    ring: vec3<f32>,
    surge: vec3<f32>,
    lo: vec3<f32>,
    hi: vec3<f32>,
}
fn pl_column(a: f32, C: vec3<f32>) -> PlCol {
    var o: PlCol;
    o.a = a;
    o.C = C + pl_wind() * (0.0 * a);
    // (the fireball: swelling to sixty in half a second, then slowly on; rising, slowly at first, then climbing to
    // over four hundred as its rise slows; its roll opening out into the cap's ring)
    o.rt = 56.0 * (1.0 - exp(-a / 0.45)) + 26.0 * (1.0 - exp(-a / 14.0)) + 0.15 * a;
    o.hc = PL_BURST + 385.0 * (1.0 - exp(-a / 15.0)) * smoothstep(0.0, 2.5, a + 0.5);
    o.Rt = 80.0 * (1.0 - exp(-a / 6.0)) + 70.0 * (1.0 - exp(-a / 28.0)) + 0.3 * a;
    // (the stem pulled up out of the land under it, from a couple of seconds on)
    o.st = min(o.hc - 0.15 * o.rt, max(a - 1.0, 0.0) * 55.0);
    o.sr = vec3<f32>(34.0 + 30.0 * saturate(a / 6.0), 20.0 + 8.0 * saturate(a / 20.0), 26.0 + 0.3 * o.Rt);
    // (the condensation ring: a thin white collar round the stem, from 4 s, gone by 30)
    o.ring = vec3<f32>(0.42 * o.hc + 10.0, o.sr.y * 2.0 + 30.0 + 0.6 * a, smoothstep(4.0, 9.0, a) * (1.0 - smoothstep(16.0, 30.0, a)));
    // (the base surge: dust rolling out over the ground round the stem's foot)
    o.surge = vec3<f32>(30.0 + 160.0 * (1.0 - exp(-a / 12.0)), 24.0 + 0.1 * a, 8.0 + 9.0 * saturate(a / 12.0));
    let top = o.hc + 1.4 * o.rt;
    let w = max(o.Rt + o.rt * 1.6, o.surge.x + o.surge.y) + 90.0;
    let lean = pl_wind() * a;
    o.lo = C + vec3<f32>(-w + min(lean.x, 0.0), -20.0 - pl_foot_low(a, o.rt), -w + min(lean.z, 0.0));
    o.hi = C + vec3<f32>(w + max(lean.x, 0.0), top + 90.0, w + max(lean.z, 0.0));
    return o;
}
// The cloud's lean with the wind at p (its head carried furthest, its foot staying put).
fn pl_lean(col: ptr<function, PlCol>, hy: f32) -> vec3<f32> {
    return pl_wind() * ((*col).a * pow(saturate(hy / max((*col).hc, 1.0)), 1.5));
}
// The cloud's smooth body at p (camera-relative): the cap (the roll round its core circle, a dome over it), the stem,
// the base surge; and in .y how much of the ring is there instead (the ring kept apart: it is white).
fn pl_col_base2(col: ptr<function, PlCol>, p: vec3<f32>) -> vec2<f32> {
    let C = (*col).C;
    let hy0 = p.y - C.y;
    let q = p - C - pl_lean(col, hy0);
    let hy = q.y;
    let rho = length(q.xz);
    let Rt = (*col).Rt;
    let rt = (*col).rt;
    let hc = (*col).hc;
    // (the cap: a fat roll, its underside a little flattened, a dome over its middle. As the ring forms its outer edge
    // curls down and under, hanging lower than its inner edge, where the air is drawn in and up)
    let fold = smoothstep(3.0, 14.0, (*col).a);
    let lo_k = mix(1.6, mix(1.9, 1.12, smoothstep(-0.4 * rt, 0.6 * rt, rho - Rt)), fold);
    let tq = vec2<f32>(rho - Rt, (hy - hc) * select(1.6, lo_k, hy < hc));
    var d = length(tq) - rt;
    // (the dome over it higher than the roll's top, so the cap is one rounded crown, not two lobes with a dip between)
    // (an ellipsoid's distance near enough true all round it, not squeezed sideways: squeezed, the dome's smoke
    // thickened too slowly into it and its middle was a thin haze the glow showed through)
    let er = vec3<f32>(Rt + 0.8 * rt, 1.0 * rt, Rt + 0.8 * rt);
    let eq = vec3<f32>(q.x, hy - hc - 0.3 * rt, q.z);
    let ek0 = length(eq / er);
    var dome = ek0 * (ek0 - 1.0) / max(length(eq / (er * er)), 1.0e-6);
    // (its underside drawn up into a hollow as the ring forms, the stem rising into it: from a ball with a flat bottom
    // to a cap over an open ring, by degrees)
    dome = max(dome, hc - mix(0.9, 0.12, fold) * rt - hy);
    d = smin(d, dome, 0.35 * rt);
    // (the fireball's foot: for its first seconds spread over the ground it burst just over, a flattened dome on the
    // land (pl_foot), not a ball floating over it)
    d = smin(d, pl_foot((*col).a, rt, rho, hy), 0.3 * rt + 4.0);
    // (the stem: from under the land up into the cap, wide at its dusty foot, narrow in the middle, flaring into the cap)
    if ((*col).st > 0.0) {
        let u = saturate(hy / max((*col).st, 1.0));
        let sr = (*col).sr;
        let rs = mix(mix(sr.x, sr.y, smoothstep(0.0, 0.3, u)), sr.z, smoothstep(0.65, 1.0, u)) * (0.92 + 0.16 * sin(hy * 0.045 + 1.3));
        let ds = max(rho - rs, max(hy - (*col).st, -hy - 20.0));
        d = smin(d, ds, 26.0);
    }
    // (the base surge: a low roll of dust round the foot, out where the land is)
    let sg = (*col).surge;
    if ((*col).a > 0.2) {
        let e = vec2<f32>((rho - sg.x) / sg.y, (hy - 0.3 * sg.z) / sg.z);
        let inner = vec2<f32>(max(sg.x - rho, 0.0) / (sg.x * 0.9), 0.0);
        let k0 = length(e);
        let ds = (k0 - 1.0) * min(sg.y, sg.z);
        // (a roll, not a disc: thin inside it, thinning away as the dust settles)
        // (and rising out of the ground as the blast reaches it, not there all at once)
        let settle = 22.0 * smoothstep(18.0, 70.0, (*col).a) + 40.0 * (1.0 - smoothstep(0.2, 2.5, (*col).a));
        d = smin(d, ds + 14.0 * smoothstep(0.0, 0.6, inner.x) + settle, 22.0);
        // (and a low sheet of dust inside the roll, from it in to the stem's foot: a skirt, not a tyre)
        let sheet = max(rho - sg.x, abs(hy - 0.2 * sg.z) - 0.32 * sg.z);
        d = smin(d, sheet + 11.0 + settle, 18.0);
    }
    // (the ring round the stem: a thin flat collar)
    var dr = 1.0e6;
    let rg = (*col).ring;
    if (rg.z > 0.01) {
        let e = vec2<f32>((rho - rg.y) / 34.0, (hy - rg.x) / 13.0);
        dr = (length(e) - 1.0) * 13.0;
    }
    return vec2<f32>(d, dr);
}
fn pl_col_base(col: ptr<function, PlCol>, p: vec3<f32>) -> f32 {
    let b = pl_col_base2(col, p);
    return min(b.x, b.y);
}
// Cauliflower lumps: domes over a jittered lattice (a feature point in each of the eight cells round p, well jittered),
// each its own size, rounded on top and meeting in creases: about 1 on a big dome's crown, 0 in a crease.
fn pl_dome(p: vec3<f32>) -> f32 {
    let b = floor(p - 0.5);
    var hmax = 0.0;
    for (var c = 0u; c < 8u; c = c + 1u) {
        let o = vec3<f32>(f32(c & 1u), f32((c >> 1u) & 1u), f32(c >> 2u));
        let cell = b + o;
        let q = bitcast<vec3<u32>>(vec3<i32>(cell));
        let h = pcg(q.x ^ pcg(q.y ^ pcg(q.z + 0x51u)));
        let jit = vec3<f32>(f32(h & 1023u), f32((h >> 10u) & 1023u), f32((h >> 20u) & 1023u)) * (0.7 / 1023.0) + 0.15;
        let sz = 0.7 + 0.55 * f32(pcg(h) & 1023u) / 1023.0;
        let e = cell + jit - p;
        hmax = max(hmax, sz * sqrt(saturate(1.0 - dot(e, e) * 1.7 / (sz * sz))));
    }
    return hmax;
}
fn pl_rot(k: i32, p: vec3<f32>) -> vec3<f32> {
    if (k == 0) {
        return mat3x3<f32>(-0.0014, 0.9977, -0.0674, -0.2224, -0.0660, -0.9727, -0.9750, 0.0136, 0.2220) * p;
    }
    if (k == 1) {
        return mat3x3<f32>(-0.6616, 0.1124, 0.7414, -0.4826, -0.8205, -0.3063, 0.5739, -0.5605, 0.5971) * p;
    }
    return mat3x3<f32>(-0.9891, -0.1223, 0.0816, 0.0968, -0.9594, -0.2651, 0.1107, -0.2543, 0.9608) * p;
}
// The cloud's surface at p: its smooth body bulged out in lumps on lumps (as the Payload's column), the lumps carried
// round the cap's roll as it churns (up its inside, out over its top, down its outside), boiling slowly up the stem.
// .x the distance, .y how far up a dome it lies, .z how soft its edge is, .w the fine fray.
fn pl_col_sdf(col: ptr<function, PlCol>, p: vec3<f32>, d0: f32, fine: bool) -> vec4<f32> {
    let a = (*col).a;
    let C = (*col).C;
    var q = p - C - pl_lean(col, p.y - C.y);
    // (the roll: the cap's big lumps carried round its core circle, up the inside, out over the top, down the outside
    // and back in under it, nearly as one through the roll and letting go outside it. Turned on and on they would wind
    // up into streaks, so they are carried for a while and then let go, two sets of them half a turn of that apart,
    // each fading in as the other fades out: the flow goes on and never winds up. The smaller lumps stay put.)
    let rho = max(length(q.xz), 1.0e-3);
    let dir = q.xz / rho;
    let uv = vec2<f32>(rho - (*col).Rt, q.y - (*col).hc);
    let wq = dot(uv, uv) / pow(1.6 * (*col).rt, 2.0);
    // (none on the axis: the lumps either side of it turn opposite ways, and turned there they parted in a seam down
    // the cap's middle)
    let wr = exp(-wq * wq) * smoothstep(0.0, 0.8 * (*col).Rt + 10.0, rho);
    // (how fast it turns, radians a second: quickening as the ring forms, slowing as it spreads)
    let om = 0.25 * (1.0 - exp(-a / 2.0)) * exp(-a / 12.0) + 0.04;
    let ph = fract(a / PL_CHURN);
    let wA = 1.0 - abs(2.0 * ph - 1.0);
    // (and the stem's boiling up it: its lumps carried up, the same way all down it to the land, so they move without
    // stretching; let go of over most of the cap's height, under its roll, where the roll's own churn takes over)
    q.y = q.y - 3.5 * min(a, 18.0) * (1.0 - exp(-wq * wq)) * (1.0 - smoothstep((*col).hc - 1.7 * (*col).rt, (*col).hc - 0.5 * (*col).rt, q.y));
    let S = 2.2;
    let w = gnoise3(pl_rot(1, q * (1.0 / (55.0 * S))));
    let w2 = gnoise3(pl_rot(2, q * (1.0 / (23.0 * S)) + vec3<f32>(9.2, -0.05 * a, 4.4)));
    var b1 = 0.0;
    // (the light's look at it, not the eye's: only the set more there, near enough)
    let kd = select(0, 1, wA < 0.5);
    var wsum = 0.0;
    for (var k = select(kd, 0, fine); k < select(kd + 1, 2, fine); k = k + 1) {
        let tk = fract(ph + 0.5 * f32(k)) * PL_CHURN;
        let ang = om * tk * wr;
        let cs = cos(ang);
        let sn = sin(ang);
        let uv2 = vec2<f32>(uv.x * cs - uv.y * sn, uv.x * sn + uv.y * cs);
        let qk = vec3<f32>(dir.x * (uv2.x + (*col).Rt), q.y + uv2.y - uv.y, dir.y * (uv2.x + (*col).Rt));
        // (each set its own lumps, a new lot each time it starts over)
        let cyc = floor(a / PL_CHURN + 0.5 * f32(k));
        wsum = wsum + select(1.0 - wA, wA, k == 0);
        b1 = b1 + select(1.0 - wA, wA, k == 0) * pl_dome(pl_rot(0, qk * (1.0 / (36.0 * S)) + vec3<f32>(3.1 + 7.3 * cyc, 0.0, 7.7 - 4.1 * cyc + 2.9 * f32(k)) + 0.3 * vec3<f32>(w2 - 0.5)));
    }
    // (two half sets added are evener than one: their spread put back)
    b1 = select(b1 / max(wsum, 1.0e-3), 0.62 + (b1 - 0.62) / sqrt(wA * wA + (1.0 - wA) * (1.0 - wA)), fine);
    let hy = p.y - C.y;
    let lump = 1.6 * (0.6 + 0.4 * smoothstep(20.0, 160.0, hy));
    let soft = smoothstep(PL_SOFT0, PL_SOFT1, a);
    let crisp = 1.0 - 0.8 * soft;
    let b2 = pl_dome(pl_rot(1, q * (1.0 / (14.0 * S)) + vec3<f32>(0.0, -0.15 * a, 1.3)));
    let up = smoothstep(40.0, 200.0, hy);
    // (the crown over the middle smoother than the roll: its big swells let down, so it stays one rounded dome)
    let crown = (1.0 - smoothstep(0.3 * (*col).Rt, (*col).Rt + 0.3 * (*col).rt, rho)) * smoothstep((*col).hc, (*col).hc + 0.5 * (*col).rt, hy);
    var d = d0 - (26.0 * (b1 - 0.45) * crisp * (0.4 + 0.6 * up) * (1.0 - 0.2 * crown) + 9.0 * (b2 - 0.45) * (1.0 - 0.7 * soft) + (18.0 + 8.0 * soft) * (w - 0.5) * (1.0 - 0.35 * crown) + 8.0 * (w2 - 0.5)) * lump;
    let ew = smoothstep(0.6, 0.82, w2);
    let edge = mix(1.5, 6.0, ew) + 10.0 * (1.0 - smoothstep(0.0, 60.0, hy));
    var fray = 0.5;
    if (fine && d < 20.0 && soft < 0.99) {
        let b3 = pl_dome(pl_rot(2, q * (1.0 / (5.5 * S)) + vec3<f32>(1.7, -0.25 * a, -2.1)));
        d = d - 4.0 * (b3 - 0.45) * (1.0 - soft) * lump;
        fray = gnoise3(pl_rot(0, q * (1.0 / (1.8 * S))) + vec3<f32>(5.0, 1.0, -0.4 * a));
        d = d - 3.5 * (fray - 0.5) * (1.0 - soft) * (0.25 + 0.75 * ew);
    }
    // (the lumps' height capped smoothly at PL_DM, so that nothing stands out past the bounds the march allows)
    let bump = max(d0 - d, 0.0);
    d = d0 - bump / sqrt(sqrt(1.0 + pow(bump / PL_DM, 4.0))) + max(d - d0, 0.0);
    return vec4<f32>(d, b1 * (0.45 + 0.55 * b2), edge, fray);
}
// A ray against a box, camera-relative: the entry and exit distances.
fn pl_box(rd: vec3<f32>, lo: vec3<f32>, hi: vec3<f32>) -> vec2<f32> {
    let inv = 1.0 / select(rd, vec3<f32>(1.0e-6), abs(rd) < vec3<f32>(1.0e-6));
    let ta = lo * inv;
    let tb = hi * inv;
    let tmin = min(ta, tb);
    let tmax = max(ta, tb);
    return vec2<f32>(max(max(tmin.x, tmin.y), max(tmin.z, 0.0)), min(min(tmax.x, tmax.y), tmax.z));
}

// How much of the sun's light reaches land point `o` (camera-relative) through the cloud: its smooth body marched
// towards the sun in a dozen steps, soft-edged (a little of its lumps' reach counted in). 1 in full sun.
fn pl_shadow(o: vec3<f32>, L: vec3<f32>, a: f32, C: vec3<f32>, j: f32) -> f32 {
    var cs = pl_column(a, C);
    let tb = pl_box(L, cs.lo - o, cs.hi - o);
    if (tb.y <= tb.x) {
        return 1.0;
    }
    // (first, whether the sun's ray passes near the cloud at all: the stick from its foot to its cap's core)
    let ctop = C + vec3<f32>(0.0, cs.hc, 0.0) + pl_wind() * a;
    let sg = pl_ray_seg(L, C - o, ctop - o, 0.0, 1.0);
    if (sg.x > max(cs.Rt + cs.rt, cs.surge.x + cs.surge.y) + 40.0) {
        return 1.0;
    }
    let n = 14;
    let dt = (tb.y - tb.x) / f32(n);
    var tau = 0.0;
    for (var i = 0; i < n; i = i + 1) {
        let d = pl_col_base2(&cs, o + L * (tb.x + (f32(i) + j) * dt)).x;
        tau = tau + saturate(0.35 - d / 45.0);
    }
    // (thinning as the cloud does, late on)
    let thin = 1.0 - 0.8 * smoothstep(PL_SOFT0, PL_LEN, a);
    return exp(-tau * dt * 0.022 * thin * smoothstep(0.3, 2.0, a));
}
// What a stage of the pass gives: the picture (the whole pass and the join), or the half-size stage's (premultiplied
// colour and transmittance) and beside it how far its ray went and the column's distance (`fs_half`).
struct PlOut {
    c: vec4<f32>,
    e: vec4<f32>,
}
// Over what a half-size stage has gathered so far: smoke of colour c covering x of what is behind (col * (1 - x) + c * x).
fn pl_over(h: ptr<function, vec4<f32>>, c: vec3<f32>, x: f32) {
    *h = vec4<f32>((*h).rgb * (1.0 - x) + c * x, (*h).a * (1.0 - x));
}
// The pass, in one of three stages: 0 the whole of it at full size (fs_main); 1 the half-size stage (fs_half: the
// smoke, the trail, the dust and the pieces' smoke, over a two by two of the picture's pixels, marched to alternately
// the nearest and the farthest of their depths), returned as premultiplied colour and transmittance; 2 the join
// (fs_join: the rest, sharp, at full size, with the half-size stage's `up` (colour, transmittance) laid over the picture
// where that stage drew them; `up_e`: the column's distance, and the first and last of the debris that may be near
// this pixel, each one more than its number (0: none)).
fn nuke(in: StageIn, stage: u32, up: vec4<f32>, up_e: vec3<f32>) -> PlOut {
    let up_t = up_e.x;
    var uv = in.uv;
    let time = now();
    let cam = frame.camera_position.xyz;
    let k = intensity_v();
    let seed = u32(seed_v());
    let px_a = frame.view_params.w / frame.resolution.y;      // (the angle a pixel spans)
    let anc = anchor_xz();
    let gy = block_y() + 1.0;
    let C = vec3<f32>(anc.x, gy, anc.y) - cam;              // the strike's point, on the target's ground
    let Cb = C + vec3<f32>(0.0, pl_g0(), 0.0);              // the ground under the burst (the cloud's foot)
    let me = vec3<f32>(frame.mod_params[3].x, frame.mod_params[3].y, frame.mod_params[3].z) - cam;
    let dme = length((me - C).xz);
    let sun = frame.sun.xyz;
    let day = saturate(sun.y * 2.5 + 0.35);
    // (the light: the sun's, warm orange-red as it nears the horizon and fading out as it sets; under the horizon the
    // moon's, faint and cold, from the other side of the sky)
    let sun_up = smoothstep(-0.12, 0.06, sun.y);
    let warm = (1.0 - smoothstep(0.02, 0.4, sun.y)) * smoothstep(-0.2, -0.02, sun.y);
    let moon = smoothstep(-0.02, -0.2, sun.y);
    let L = normalize(select(-sun, sun, sun.y > -0.04) + vec3<f32>(0.0, 0.03, 0.0));

    var d = 0.0;
    if (stage == 1u) {
        // (the two by two of the picture's pixels this one stands for: its middle, and alternately the nearest and the
        // farthest of their depths, so that at an edge both sides are marched and the join finds the one it matches)
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
    // (the half-size stage's own: what it has gathered, over what lies behind)
    var hc = vec4<f32>(0.0, 0.0, 0.0, 1.0);
    // (leaves and grass whipped as the blast's front goes through them: what is green near it shaken on the screen)
    if (stage != 1u && !sky && time > PL_HIT && time < PL_HIT + 6.0) {
        let rfr = PL_V * (time - PL_HIT);
        let rs = length((rel - (vec3<f32>(anchor_xz().x, block_y() + 1.0, anchor_xz().y) - cam)).xz);
        let e = rfr - rs;
        let gust = exp(-pow(e / 14.0, 2.0)) + 0.4 * exp(-max(e, 0.0) / 50.0) * step(0.0, e);
        let green = scene.g > scene.r * 1.1 && scene.g > scene.b * 1.05;
        if (gust > 0.03 && green) {
            let fpx0 = frame.resolution.y / (2.0 * tan(frame.view_params.w * 0.5));
            let amp = min(0.45 * fpx0 / max(scene_len, 1.0), 7.0) * gust;
            let ph = dot(floor(in.position.xy / 6.0), vec2<f32>(0.37, 0.71));
            let off = vec2<f32>(sin(time * 29.0 + ph * 5.0), cos(time * 23.0 + ph * 3.0)) * amp;
            let s2 = srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, uv + off * frame.resolution.zw, 0.0).rgb);
            if (s2.g > s2.r * 1.1 && s2.g > s2.b * 1.05) {
                col = s2;
            }
        }
    }
    let fade = 1.0 - smoothstep(PL_LEN - PL_FADE, PL_LEN, time);
    let a = time - PL_HIT;                                    // seconds since it struck
    let have = pl_n() > 1;

    // (the light, matched to the scene's: its sky from the top of the picture where it is sky, and the sun's)
    var skyl = srgb_to_linear(frame.sky_color.rgb);
    var nsk = 1.0;
    for (var s = 0; s < 3; s = s + 1) {
        let su = vec2<f32>(0.2 + 0.3 * f32(s), 0.04);
        if (is_sky(depth_at(su))) {
            skyl = skyl + srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, su, 0.0).rgb);
            nsk = nsk + 1.0;
        }
    }
    skyl = skyl / nsk;
    let amb = mix(vec3<f32>(0.03, 0.035, 0.05), skyl * 0.85 + vec3<f32>(0.04), day);
    let sunc = mix(vec3<f32>(1.35, 1.24, 1.06), mix(vec3<f32>(1.5, 0.68, 0.3), vec3<f32>(1.3, 0.38, 0.14), smoothstep(0.0, -0.1, sun.y)), warm) * sun_up + vec3<f32>(0.07, 0.09, 0.14) * moon;
    // (the haze along the horizon, reddened by a low sun: the light the sky gives from round about)
    let fogl = srgb_to_linear(frame.fog_color.rgb);
    let haze_c = mix(vec3<f32>(0.02, 0.025, 0.04), skyl * 1.05, day);

    // ---- the shockwave: a shell racing out from the burst at the speed of sound, bending the light where the eye looks
    // along it (its edge on the picture), a faint white sheen of condensation on it for the first seconds ------------
    let Pb = Cb + vec3<f32>(0.0, PL_BURST, 0.0);
    if (stage != 1u && a > 0.0 && a < 9.0) {
        let Rs = PL_V * a;
        let bq = dot(rd, Pb);
        let cq = dot(Pb, Pb) - Rs * Rs;
        let disc = bq * bq - cq;
        if (disc > 0.0) {
            let sq = sqrt(disc);
            // (where the ray meets the shell, in front of the scene, over the land: the near side, else the far)
            var th = bq - sq;
            if (th < 0.0) {
                th = bq + sq;
            }
            let hp = rd * th;
            if (th > 0.0 && th < scene_len + 4.0 && hp.y > Cb.y - 4.0) {
                // (grazing: the shell seen edge-on, a band some tens of blocks thick along its outline)
                let edge = exp(-sq / (0.045 * Rs + 8.0));
                let sf = (1.0 - smoothstep(4.0, 9.0, a)) * k;
                let pb = project_rel(Pb);
                var dirs = uv - pb.xy;
                if (pb.z < 0.0) {
                    dirs = -dirs;
                }
                let off = normalize(dirs + vec2<f32>(1.0e-5)) * (0.012 * edge + 0.003 * exp(-sq / (0.25 * Rs))) * sf;
                let sc = srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, uv - off, 0.0).rgb);
                col = mix(col, sc, saturate(edge * 4.0 + 0.5) * sf);
                col = col + vec3<f32>(0.9, 0.93, 1.0) * (0.22 * edge + 0.03 * exp(-sq / (0.3 * Rs))) * exp(-a / 1.6) * sf * (0.3 + 0.7 * day);
            }
        }
    }

    // ---- the flash: the burst lighting the land and the sky, white then orange, the sky staying brighter a while ----
    // (the light it gives: blinding for a moment, strong for seconds, a glow under the cloud for tens of seconds)
    let fl = select(0.0, 9.0 * exp(-a / 0.15) + 1.0 * exp(-a / 1.2) + 0.15 * exp(-a / 10.0), a > 0.0) * fade;
    if (stage != 1u && a > 0.0) {
        let Pf = Cb + vec3<f32>(0.0, PL_BURST + 80.0 * saturate(a / 15.0), 0.0);
        let df = length(Pf);
        let cth = dot(rd, Pf / df);
        let th = sqrt(max(2.0 * (1.0 - cth), 0.0));
        let fire_c = mix(vec3<f32>(3.0, 1.35, 0.42), vec3<f32>(3.2, 3.0, 2.8), exp(-a / 0.6));
        // (the glow in the air round it, seen through anything: it lights the haze)
        col = col + fire_c * fl * (0.05 / (1.0 + pow(th / 0.08, 2.0)) + 0.012 * exp(-th / 0.7)) * k;
        if (sky) {
            // (the sky itself brighter, warm, for a while)
            col = col + vec3<f32>(1.0, 0.78, 0.52) * (0.25 * exp(-a / 0.8) + 0.025 * exp(-a / 8.0)) * (0.35 + 0.65 * (1.0 - day)) * k * fade;
        } else {
            // (and the land lit by it, far out)
            let dl = length(rel - Pf);
            col = col + scene * fire_c * fl * 0.9 / (1.0 + pow(dl / 320.0, 2.0)) * k;
            // (and the ground the fireball spreads over glowing hot round its foot, for its first seconds)
            let rg = length((rel - Cb).xz);
            let rtg = 56.0 * (1.0 - exp(-a / 0.45));
            let hot = (2.0 * exp(-a / 0.8) + 0.5 * exp(-a / 3.0)) * (1.0 - smoothstep(0.9 * rtg + 6.0, 1.7 * rtg + 24.0, rg)) * (1.0 - smoothstep(10.0, 40.0, abs(rel.y - Cb.y)));
            col = col + scene * vec3<f32>(3.0, 1.15, 0.32) * hot * k * fade;
        }
    }

    // ---- the cloud's shadow on the land: the sun's light through the cloud's own body, marched from the land towards
    // the sun, so it falls where the cloud really is: under it at noon, long and far across the land at a low sun, the
    // stem's band, the base surge's skirt; soft, and the sky still lights what lies in it -------------------------------
    if (stage != 1u && !sky && have && a > 0.3 && L.y > 0.02 && frame.mod_params[3].w < 0.5) {
        let T = pl_shadow(rel, L, a, Cb, ign(in.position.xy));
        col = col * (1.0 - 0.72 * (1.0 - T) * sun_up * k * fade);
    }

    // ---- the trail: a cord of lumpy smoke hung along its path, pale and thin high up, dark grey-brown and dense along
    // the dive, lit orange by the flame just behind the head; as it ages it swells, pales, breaks into beads and puffs,
    // frays and thins away over twenty seconds or so, drifting with the wind ------------------------------------------
    // (the join: the half-size stage's smoke over the picture, where the trail's would go)
    if (stage == 2u) {
        col = col * up.a + up.rgb;
    }
    if (stage != 2u && have && time > PL_SEEN) {
        let n = pl_n();
        let t0 = pl_w(1u);
        let dt = pl_w(2u);
        let thead = min(time, PL_HIT);
        let last = min(i32(floor((thead - t0) / dt)), n - 1);
        var tau = 0.0;
        var tc = vec3<f32>(0.0);
        var glow = vec3<f32>(0.0);
        let sd = vec3<f32>(f32(seed % 97u) * 3.1, f32(seed % 89u) * 1.7, 0.0);
        // (the trail's points, the head's the one past the last laid)
        var pa = pl_trail_pt(0, last, thead, time, seed) + C;
        var pv = pa;                      // the point before pa (pa itself before the first)
        var have_pv = true;
        var pc = pa;                      // the point after pa, when it is known already
        var have_pc = false;
        for (var i = 0; i <= last; i = i + 1) {
            // (eight pieces at a time looked at as one ball round them first: most rays pass well clear of it)
            if (i % 8 == 0 && i + 8 <= last) {
                let pg = pl_trail_pt(i + 8, last, thead, time, seed) + C;
                let cg = 0.5 * (pa + pg);
                let ag = max(time - (t0 + dt * f32(i)), 0.0);
                let tg = max(dot(cg, rd), 0.0);
                let rg = 0.65 * length(pg - pa) + 3.4 * (6.0 + 4.8 * sqrt(ag) + tg * px_a) + 4.0;
                if (length(cg - rd * tg) > rg || tg - rg > scene_len) {
                    pa = pg;
                    have_pv = false;
                    have_pc = false;
                    i = i + 7;
                    continue;
                }
            }
            if (!have_pv) {
                pv = pl_trail_pt(i - 1, last, thead, time, seed) + C;
            }
            var pb = pc;
            if (!have_pc) {
                pb = pl_trail_pt(i + 1, last, thead, time, seed) + C;
            }
            var pn = pb + (pb - pa);
            if (i < last) {
                pn = pl_trail_pt(i + 2, last, thead, time, seed) + C;
            }
            pc = pn;
            have_pc = true;
            let pa_ = pa;
            let pv_ = pv;
            pv = pa;
            have_pv = true;
            pa = pb;
            // (each piece is the smoke between two planes across the trail, through its two ends and halfway round
            // the bend at each, so that the pieces fit together with no seam, gap or overlap at any angle it is seen
            // from; the ray's way through each is counted, not one point on it. The whole's first end capped a little
            // past its first point, its last carried on past the head.)
            let ab = pb - pa_;
            let len_ab = max(length(ab), 1.0e-4);
            let da = ab / len_ab;
            let te_a = t0 + dt * f32(i);
            let age_a = max(time - te_a, 0.0);
            var na = da;
            var oa = pa_;
            if (i == 0) {
                oa = pa_ - da * (2.0 + 2.0 * sqrt(age_a));
            } else {
                na = normalize(da + normalize(pa_ - pv_ + vec3<f32>(0.0, 1.0e-5, 0.0)));
            }
            var nb = da;
            var ob = pb;
            if (i < last) {
                nb = normalize(da + normalize(pn - pb + vec3<f32>(0.0, 1.0e-5, 0.0)));
            } else {
                // (on into the ground, where it struck: not cut off square across it over the ground)
                ob = pb + da * (12.0 + 8.0 * sqrt(max(time - thead, 0.0))) * step(PL_HIT, time);
            }
            let ia = pl_half(rd, oa, na);
            let ib = pl_half(rd, ob, -nb);
            let t1 = max(max(ia.x, ib.x), 0.0);
            let t2 = min(min(ia.y, ib.y), scene_len);
            if (t2 <= t1) {
                continue;
            }
            let h = pl_ray_seg(rd, pa_, pb, -1.0e4, 1.0e4);
            let tn = clamp(h.y, t1, t2);
            let sz = clamp(dot(rd * tn - pa_, da) / len_ab, 0.0, 1.0);
            // (the lumps looked up on the sheet through the trail's axis that faces the eye: how far along this piece
            // the ray's way through it lies, and how far across the ray passes. Not where the ray meets the piece's
            // end, which a ray seen glancing along it would smear into streaks.)
            let cp = pa_ + ab * sz + (rd * h.y - (pa_ + ab * h.z));
            let te = clamp(te_a + dt * sz, t0, thead);
            let age = max(time - te, 0.0);
            // (the nuke's: laid white-hot in the re-entry, a thick lumpy trail of ablated smoke and the ionised air
            // glowing behind it; once it has shed its heat a pale vapour trail, thickening as it dives faster)
            let heat = 1.0 - smoothstep(PL_COOL - 0.6, PL_COOL + 1.0, te);
            let gone = 0.0;
            let dv = smoothstep(PL_DIVE - 1.0, PL_HIT, te);
            let dive = 0.0;
            // (smoke rather than vapour: from a second or two after it shows, as in the third clip, where the whole
            // hook it draws is the same grey-brown smoke)
            let smk = 0.0;
            // (its core's radius: thin and tight where it is laid, swelling with age; the outer fray to twice that)
            // (never thinner than a pixel, its density spread over the width it is drawn at)
            let rad0 = mix(1.2 + 3.0 * dv, 5.5, heat) + mix(1.5 + 1.5 * dv, 4.5, heat) * sqrt(age);
            let rad = max(rad0, tn * px_a * 0.9);
            let thin = rad0 / rad;
            if (h.x < rad * 3.4 && gone < 1.0) {
                // (the smoke's own lumps, carried with it as it drifts and rises, churning slowly: looked up where the
                // smoke was laid (fixed, so they never slide along it) and across it in its own width (so they swell
                // with it, about its axis). Their size along it cannot follow the width without sliding, so they are
                // looked up at the two fixed sizes either side of it, a doubling apart, and faded from one to the
                // next as it swells.)
                let sw = 2.2 * rad + 3.0;
                let la = pa_ - pl_trail_drift(i, age_a, seed);
                var lb = pb;
                if (i < last) {
                    lb = pb - pl_trail_drift(i + 1, max(time - (te_a + dt), 0.0), seed);
                }
                let laid = mix(la, lb, sz) - C;
                let across = (cp - (pa_ + ab * sz)) / sw + sd;
                let lv = log2(sw / 8.0);
                let lk = floor(lv);
                let lf = lv - lk;
                let sA = 8.0 * exp2(lk);
                let qa = laid / sA + across + vec3<f32>(lk * 17.3, lk * 5.1, 0.0);
                let qb = laid / (2.0 * sA) + across + vec3<f32>((lk + 1.0) * 17.3, (lk + 1.0) * 5.1, 0.0);
                // (two lookups faded together are evener than one: their spread put back)
                let lsp = 1.0 / sqrt(lf * lf + (1.0 - lf) * (1.0 - lf));
                // (the lumps are looked up once, where the ray passes nearest its axis: they are painted on a sheet
                // through it, facing the eye. Where the trail runs away from the eye that sheet is squeezed along the
                // trail and its lumps drawn out across it into streaks; but there the ray goes a long way through the
                // smoke along it and would see many lumps one behind another, evened out. So each size of lump lets go
                // towards its mean as the stretch of trail the ray passes through (or a pixel spans) grows past it.)
                let sn = max(length(cross(rd, da)), 0.08);
                let qs = 1.0 / (2.2 * rad + 3.0);
                let along = tn * px_a / sn * qs;
                let thru = 2.0 * sqrt(max(2.1 * rad * rad - h.x * h.x, 0.0)) * abs(dot(rd, da)) / sn * qs + 1.0e-3;
                let w1 = min(saturate(2.0 * sqrt(1.0 / thru)), saturate(2.0 - 10.0 * along));
                let w2 = min(saturate(2.0 * sqrt(0.385 / thru)), saturate(2.0 - 10.0 * along * 2.6));
                let w3 = min(saturate(2.0 * sqrt(0.164 / thru)), saturate(2.0 - 10.0 * along * 6.1));
                // (each looked up only where it shows)
                var n1 = 0.5;
                var n2 = 0.5;
                var n3 = 0.5;
                if (w1 > 0.0) {
                    let o = vec3<f32>(0.0, 0.0, 0.06 * age);
                    n1 = 0.5 + (mix(gnoise3(qa + o), gnoise3(qb + o), lf) - 0.5) * lsp;
                }
                if (w2 > 0.0) {
                    let o = vec3<f32>(4.0, 0.08 * age, 1.0);
                    n2 = 0.5 + (mix(gnoise3(qa * 2.6 + o), gnoise3(qb * 2.6 + o), lf) - 0.5) * lsp;
                }
                if (w3 > 0.0) {
                    let o = vec3<f32>(1.0, 7.0, 0.15 * age);
                    n3 = 0.5 + (mix(gnoise3(qa * 6.1 + o), gnoise3(qb * 6.1 + o), lf) - 0.5) * lsp;
                }
                let puff = 0.5 + 0.62 * w1 * (n1 - 0.5) + 0.3 * w2 * (n2 - 0.5) + 0.08 * w3 * (n3 - 0.5);
                // (a soft profile across it, its edge pushed in and out by the lumps: ragged, no rim)
                let rw = rad * (0.45 + 1.0 * puff);
                let rr = h.x / rw;
                // (and let go to nothing before the edge it is looked for within, not cut off there: the let-go
                // itself pushed in and out by the lumps, or where the smoke is dense its edge would be the let-go's,
                // smooth and straight)
                let prof = exp(-rr * rr * 1.4) * smoothstep(2.3, 1.5, rr);
                // (how much of the profile along the ray lies in this piece, and how much longer the ray's way through
                // it is than straight across)
                let ka = 1.183 * sn / rw;
                let gin = 0.5 * (pl_erf((t2 - h.y) * ka) - pl_erf((t1 - h.y) * ka)) / max(sn, 0.5);
                // (broken into beads and puffs as it ages, the gaps opening; the vapour high up breaks sooner. Where
                // the lumps are evened out, what they would have let through on the whole: the gaps' and the beads'
                // mean, not the mean lump's, which the gaps would swallow)
                let thr = mix(0.32, 0.12, smk) - 0.1 * heat + 0.38 * smoothstep(1.5, 18.0, age);
                let m = (puff - thr) * 3.2 + 0.3 * exp(-age / 0.8);
                let sl = 3.2 * 0.14 * sqrt(0.384 * (1.0 - w1 * w1) + 0.09 * (1.0 - w2 * w2) + 0.0064 * (1.0 - w3 * w3)) + 1.0e-3;
                let dens = saturate(sl * log(1.0 + exp(clamp(m / sl, -30.0, 30.0))));
                // (dense where it is laid, thinning over the next twenty seconds; the vapour fainter)
                let sig = mix(0.45 + 0.35 * dv, 0.8, heat) * exp(-age / mix(9.0, 16.0, heat)) * exp(-max(time - PL_HIT, 0.0) / 2.5) * fade * thin * (1.0 - gone);
                let dtau = sig * prof * dens * 1.6 * rad * gin;
                // (lit on its sunward side and on its lumps' tops, darker in its creases)
                let axis = pa_ + ab * sz;
                let nrm = normalize(cp - axis - rd * (0.6 * rad) + vec3<f32>(0.0, 1.0e-4, 0.0));
                let ln = 0.5 + w1 * (n1 - 0.5);
                let lit = (0.35 + 0.65 * saturate(dot(nrm, L) * 0.5 + 0.5)) * (0.6 + 0.8 * ln * ln);
                // (grey-brown smoke, paler as it spreads thin; the vapour high up a pale grey)
                var alb = mix(mix(mix(vec3<f32>(0.5, 0.5, 0.52), vec3<f32>(0.72, 0.72, 0.74), dv), vec3<f32>(0.74, 0.71, 0.66), heat), vec3<f32>(0.17, 0.145, 0.125), smk);
                alb = mix(alb, alb * 1.35 + vec3<f32>(0.03), smoothstep(4.0, 20.0, age));
                var c = alb * (sunc * lit * 0.85 + amb * (0.6 + 0.4 * ln));
                // (just behind the head it is lit by the flame: orange, dying back within a second)
                c = c + vec3<f32>(1.9, 0.75, 0.22) * exp(-age / 0.12) * dive * step(time, PL_HIT + 0.3) * (0.4 + 0.6 * ln);
                // (in the re-entry, lit from within by the glowing air just behind the head)
                c = c + vec3<f32>(2.2, 0.9, 0.35) * exp(-age / 0.35) * heat * (0.5 + 0.5 * ln);
                // (farther, the air between greys it to the sky)
                c = mix(c, haze_c, (1.0 - exp(-tn / 3000.0)) * 0.75);
                tc = tc + c * dtau;
                tau = tau + dtau;
                // (the flame tail just behind the head, in the dive)
                // (how far off its axis the ray passes within this piece: where it is nearest, or at the piece's end
                // it leaves by, so the glow runs on smoothly from piece to piece)
                let gx = length(rd * tn - axis);
                let chord = 2.0 * sqrt(max(rad * rad - gx * gx, 0.0));
                let fl = dive * exp(-age / 0.13) * step(time, PL_HIT + 0.05);
                // (soft-edged, a teardrop narrowing back from the head, white-yellow at its root, orange back along it)
                let fw = rad * (0.75 - 0.35 * saturate(age / 0.3));
                let fprof = exp(-pow(gx / max(fw, 0.5), 2.0) * 1.6) * min(fw * 0.5, 1.0);
                glow = max(glow, mix(vec3<f32>(3.2, 1.0, 0.18), vec3<f32>(4.0, 2.6, 1.0), exp(-age / 0.06)) * fl * 1.6 * fprof);
                // (high up, the hot streak of air it leaves glowing behind it, white, cooling within a second)
                // (the re-entry's: the ionised air it leaves glowing behind it, white-yellow cooling through orange to a
                // dull pink within a second, a core narrower than the smoke)
                let fh = max(heat, 0.1 * dv * dv) * exp(-age / mix(0.45, 0.25, dv)) * step(time, PL_HIT);
                let gr = rad * 0.5;
                let gch = sqrt(max(1.0 - gx * gx / (gr * gr), 0.0));
                let gcol = mix(mix(vec3<f32>(1.3, 0.35, 0.3), vec3<f32>(2.6, 0.95, 0.3), exp(-age / 0.4)), vec3<f32>(3.4, 3.0, 2.3), exp(-age / 0.1));
                glow = max(glow, gcol * fh * gch * 1.4);
            }
        }
        if (tau > 0.0) {
            let al = 1.0 - exp(-tau);
            if (stage == 0u) {
                col = mix(col, tc / tau, al * k);
            } else {
                pl_over(&hc, tc / tau, al * k);
            }
        }
        if (stage == 0u) {
            col = col + glow * k;
        } else {
            hc = vec4<f32>(hc.rgb + glow * k, hc.a);
        }
    }

    // ---- the pieces it sheds coming in: glowing chunks flung off to the side, falling away behind it, burning out
    // over a second or three, each trailing its own thin smoke; in the last seconds a spray of sparks off the fireball --
    if (have && time > PL_SEEN && time < PL_HIT + 7.0) {
        let nf = min(i32(pl_w(7u) + 0.5), 32);
        var ftau = 0.0;
        var ftc = vec3<f32>(0.0);
        var fglow = vec3<f32>(0.0);
        for (var f = 0; f < nf; f = f + 1) {
            let b = PL_FR + PL_FW * u32(f);
            let t0 = pl_w(b);
            let s = time - t0;
            let life = pl_w(b + 1u);
            // (gone, glow and smoke, three and a half seconds after it burns out: nothing more looked up for it)
            if (s <= 0.0 || s > life + 3.6) {
                continue;
            }
            let size = pl_w(b + 2u);
            let spark = pl_w(b + 3u) > 0.5;
            let kd = max(pl_w(b + 4u), 0.05);
            let p0 = vec3<f32>(pl_w(b + 5u), pl_w(b + 6u), pl_w(b + 7u)) + C;
            let v0 = vec3<f32>(pl_w(b + 8u), pl_w(b + 9u), pl_w(b + 10u));
            if (stage != 1u && s < life) {
                // (the glowing piece, smeared over the last few hundredths of a second it moved: a short streak)
                let pa = pl_frag(p0, v0, kd, s);
                let pb = pl_frag(p0, v0, kd, max(s - select(0.03, 0.05, spark), 0.0));
                let h = ray_seg(rd, pa, pb);
                // (in the join, hidden behind the column, which the half-size stage drew)
                if (h.y < select(scene_len + 2.0, min(scene_len + 2.0, up_t), stage == 2u)) {
                    let w = max(size, h.y * px_a * 0.8);
                    let e = min(size / w, 1.0);
                    let u = s / life;
                    let hot = select(mix(vec3<f32>(4.0, 2.3, 1.0), vec3<f32>(2.6, 0.75, 0.12), u), vec3<f32>(4.0, 3.2, 1.8), spark);
                    let fl = 0.75 + 0.25 * sin(time * 41.0 + f32(f) * 2.3);
                    fglow = fglow + hot * (exp(-pow(h.x / w, 2.0)) * 3.0 + 0.25 * exp(-h.x / (w * 4.0))) * e * e * (1.0 - u * u) * fl;
                }
            }
            if (stage != 2u && !spark) {
                // (its smoke: laid where it was while it burned, swelling and thinning after)
                let s_hi = min(s, life);
                let s_lo = max(s - 3.5, 0.0);
                let qe = pl_frag(p0, v0, kd, s_hi);
                let qs = pl_frag(p0, v0, kd, s_lo);
                let cq = 0.5 * (qs + qe);
                let rq = 0.75 * length(qe - qs) + 2.0 * size * (0.6 + 1.1 * sqrt(s - s_lo)) + 3.0;
                let tq = max(dot(cq, rd), 0.0);
                if (s_hi > s_lo && length(cq - rd * tq) < rq && tq - rq < scene_len) {
                    var qa = qs;
                    for (var j = 1; j <= 8; j = j + 1) {
                        let sj = s_lo + (s_hi - s_lo) * f32(j) / 8.0;
                        let qb = pl_frag(p0, v0, kd, sj);
                        let h = ray_seg(rd, qa, qb);
                        let age = s - (sj - (s_hi - s_lo) / 8.0 * (1.0 - h.z));
                        let rad = size * (0.6 + 1.1 * sqrt(age));
                        if (h.x < rad * 2.0 && h.y < scene_len + rad && (h.z < 0.9999 || j == 8)) {
                            let cp = rd * h.y;
                            // (from the target, not the world's origin: see the trail's lumps)
                            let nb = gnoise3((cp - C) / (2.5 * rad + 1.0) + vec3<f32>(f32(f) * 7.1, 0.0, 0.1 * age));
                            let prof = exp(-pow(h.x / (rad * (0.5 + nb)), 2.0) * 1.4);
                            let dens = saturate((nb - 0.18 - 0.25 * smoothstep(0.5, 3.5, age)) * 3.0);
                            let dtau = 0.5 * exp(-age / 1.8) * prof * dens * 1.6 * rad * fade;
                            var c = vec3<f32>(0.45, 0.43, 0.4) * (sunc * 0.75 + amb * 0.8);
                            c = c + vec3<f32>(1.6, 0.6, 0.15) * exp(-age / 0.1) * step(s, life);
                            c = mix(c, haze_c, (1.0 - exp(-h.y / 3000.0)) * 0.75);
                            ftc = ftc + c * dtau;
                            ftau = ftau + dtau;
                        }
                        qa = qb;
                    }
                }
            }
        }
        if (ftau > 0.0) {
            if (stage == 0u) {
                col = mix(col, ftc / ftau, (1.0 - exp(-ftau)) * k);
            } else {
                pl_over(&hc, ftc / ftau, (1.0 - exp(-ftau)) * k);
            }
        }
        col = col + fglow * k * fade;
    }

    // (how far off the cloud stands along this ray, where it is mostly opaque: the dust and debris behind it hidden)
    var col_t = select(1.0e9, up_t, stage == 2u);
    // (the cloud stands on the ground under the burst, Cb: its C)
    {
    let C = Cb;
    // ---- the mushroom cloud: raymarched, self-shadowed towards the sun, glowing from inside --------------------------
    // (the fireball's heat: white-hot for a moment, orange for seconds, a dull red glow dying over tens of seconds)
    let heat = exp(-a / 0.6);
    // (as filmed (Plumbbob Fizeau): a blazing orange ball for some five seconds, then going out fast; by eight or nine
    // seconds a dark sooty roll with a little red deep in it)
    let glow = 1.0 * (1.0 - smoothstep(4.5, 9.0, a)) + 0.12 * exp(-a / 10.0);
    if (stage != 2u && have && a > 0.0) {
        var cl = pl_column(a, C);
        // (first a cheap bound: a fat stick from under the land up to the cap's core circle, leaning with the wind, as
        // wide as the cap's rim and its lumps; its rounded top holds the dome. Its top at the core's height, not over
        // the cap: from a point higher up the rim's lumps lie further off than the rim's radius, and were cut off)
        let ctop = C + vec3<f32>(0.0, cl.hc, 0.0) + pl_wind() * a;
        let cbound = pl_ray_seg(rd, C - vec3<f32>(0.0, 20.0, 0.0), ctop, 0.0, 1.0);
        let crad = max(cl.Rt + cl.rt, max(cl.surge.x + cl.surge.y, 0.8 * cl.rt + 0.15 * cl.rt)) + PL_DM + 30.0 + 0.2 * length(pl_wind()) * a;
        let tb = pl_box(rd, cl.lo, cl.hi);
        let t1 = min(tb.y, scene_len);
        if (cbound.x < crad && t1 > tb.x) {
            var t = tb.x;
            var tr = 1.0;
            var acc = vec3<f32>(0.0);
            let j = ign(in.position.xy + vec2<f32>(fract(time * 7.0) * 37.0, 0.0));
            let ph = 0.8 + (0.5 + 1.6 * warm) * pow(saturate(dot(rd, L)), 5.0);
            let soft = smoothstep(PL_SOFT0, PL_SOFT1, a);
            let thin = exp(-max(a - PL_SOFT0 - 12.0, 0.0) / 7.0);
            var tmid = 0.0;
            var wmid = 0.0;
            var nl = 0;
            var lc_face = 0.0;
            var lc_bulk = 1.0;
            var sky_occ = 0.0;
            // (how far up a lump where the ray first meets the smoke: its glow and its soot are the surface's, not each
            // step's deeper in, whose lumps cut in slices would show as rings)
            var em_y = 0.5;
            var em_k = 0.0;
            // (dark brown as the fire goes out, by eight or nine seconds; lifting to Fizeau's grey-brown by twenty, paler on)
            let sootc = mix(mix(vec3<f32>(0.2, 0.14, 0.1), vec3<f32>(0.44, 0.37, 0.31), smoothstep(9.0, 20.0, a)), vec3<f32>(0.56, 0.51, 0.46), smoothstep(20.0, 45.0, a));
            for (var i = 0; i < 128; i = i + 1) {
                if (t > t1 || tr < 0.03) {
                    break;
                }
                let p = rd * t;
                let b2 = pl_col_base2(&cl, p);
                let d0 = b2.x;
                let dr = b2.y;
                let db = min(d0, dr);
                // (far from it, a long step: the body's distance is up to 1.6 times too long under the cap's roll)
                if (db > PL_DM + 14.0) {
                    t = t + (db - PL_DM - 4.0) * 0.52;
                    continue;
                }
                let st = max(5.0, t * 0.009) * (0.75 + 0.5 * j);
                var den = 0.0;
                var ringw = 0.0;
                var sd = vec4<f32>(d0, 0.5, 4.0, 0.5);
                // (deep inside, past where any lump could reach, it is smoke whatever the lumps: none looked up)
                if (d0 < -PL_DM - 6.0) {
                    sd = vec4<f32>(d0, 0.45, 4.0, 0.5);
                    den = thin;
                } else if (d0 < PL_DM + 4.0) {
                    sd = pl_col_sdf(&cl, p, d0, true);
                    let ramp = saturate(-sd.x / (sd.z + 40.0 * soft));
                    den = ramp * mix(saturate(0.15 + 1.7 * sd.w), 1.0, ramp * ramp) * thin;
                }
                // (the ring: thin and white, its edge soft)
                if (dr < 12.0) {
                    // (wispy: torn into strands and gaps by two sizes of noise, soft through its whole depth)
                    let rn = gnoise3((p + cam) * (1.0 / 7.0) + vec3<f32>(0.0, 0.0, 0.15 * a));
                    let rb = gnoise3((p + cam) * vec3<f32>(1.0 / 40.0, 1.0 / 14.0, 1.0 / 40.0) + vec3<f32>(3.0, 0.0, 0.05 * a));
                    let rd0 = saturate((-dr + 12.0 * (rn - 0.5)) / 14.0) * smoothstep(0.3, 0.7, rb) * cl.ring.z * 0.12;
                    ringw = rd0 / max(rd0 + den, 1.0e-4);
                    den = den + rd0;
                }
                // (the base surge's dust thinner than the cloud's smoke: the land shows through it in places)
                let sw = (1.0 - smoothstep(25.0, 70.0, p.y - C.y)) * smoothstep(0.8 * cl.sr.x, 1.6 * cl.sr.x, length((p - C).xz));
                den = den * (1.0 - 0.7 * sw);
                if (soft > 0.0 && den > 0.002) {
                    let mt = gnoise3((p + cam) * (1.0 / 20.0) - pl_wind() * (a * 0.09) + vec3<f32>(0.0, -0.05 * a, 0.0));
                    den = den * mix(1.0, saturate(0.2 + 1.6 * mt), soft);
                }
                if (den > 0.002) {
                    if (nl == 0) {
                        em_y = sd.y;
                        // (soot in broken patches over the creases between its lumps, carried with the cloud: not rings)
                        let qs = p - C - pl_lean(&cl, p.y - C.y);
                        em_k = smoothstep(0.42, 0.68, gnoise3(qs * (1.0 / 48.0) + vec3<f32>(2.3, -0.03 * a, 5.1)));
                    }
                    if (tr > 0.25 || nl == 0) {
                        let fp = p + L * 9.0;
                        lc_face = pl_col_sdf(&cl, fp, pl_col_base2(&cl, fp).x, false).x - sd.x;
                        let s1 = saturate((10.0 - pl_col_base(&cl, p + L * 20.0)) / 34.0);
                        let s2 = saturate((10.0 - pl_col_base(&cl, p + L * 55.0)) / 46.0);
                        let s3 = saturate((8.0 - pl_col_base(&cl, p + L * 120.0)) / 60.0);
                        lc_bulk = exp(-(s1 * 10.0 + s2 * 18.0 + s3 * 22.0) * 0.3);
                        // (the sky's light shut out from under the cap and deep in it: what lies under more of it
                        // darker, its tops lit)
                        sky_occ = saturate((12.0 - pl_col_base(&cl, p + vec3<f32>(0.0, 80.0, 0.0))) / 70.0);
                    }
                    nl = nl + 1;
                    let lam = mix(saturate(0.25 + lc_face / 7.0), 0.65, soft);
                    // (the ring, out from under the cap's edge, catches more of the sun than the stem in its shadow)
                    // (under the cap, the stem, the surge and the ring in its shadow)
                    let capsh = pl_cap_shade(p, L, a, C, cl.hc - 0.3 * cl.rt, cl.Rt + cl.rt);
                    let tsun = max(mix(lc_bulk, 0.7, soft) * lam * capsh, 0.45 * ringw * capsh);
                    let hy = saturate((p.y - C.y) / max(cl.hc + cl.rt, 1.0));
                    let deep = saturate(-d0 / 70.0);
                    let ao = mix((0.55 + 0.45 * sd.y) * (1.0 - 0.6 * deep) * (1.0 - 0.6 * sky_occ), 0.75, soft);
                    let kb = em_k * saturate(1.5 - 1.6 * em_y);
                    let mv = (0.9 + 0.2 * (sd.w - 0.5) + 0.25 * (sd.y - 0.5)) * (1.0 - 0.35 * kb);
                    // (dusty brown low down, sooty grey-brown up in the cap, a little pink-tan as it ages)
                    var alb = mix(vec3<f32>(0.43, 0.38, 0.32), sootc, smoothstep(0.08, 0.45, hy)) * mv;
                    alb = mix(alb, vec3<f32>(0.85, 0.86, 0.88), ringw);
                    // (the surge's dust darker and browner than the cloud: earth, not smoke)
                    alb = alb * (1.0 - 0.3 * sw);
                    let skyg = mix(mix(skyl, vec3<f32>(dot(skyl, vec3<f32>(0.2126, 0.7152, 0.0722))), 0.45), fogl, 0.15) * (1.0 - 0.35 * warm);
                    // (lifted as the fire goes out: the smoke's light scattered about inside it, so its shadowed side is grey-brown,
                    // not charcoal; while it burns, its own glow is most of its light)
                    let lift = smoothstep(5.0, 10.0, a);
                    var c = alb * ((skyg * (mix(0.48, 0.75, lift) * ao * (0.35 + 0.65 * hy)) + mix(vec3<f32>(0.2, 0.17, 0.13), vec3<f32>(0.3, 0.26, 0.2), lift) * day * (1.0 - 0.6 * warm) * ao) * mix(0.55, 1.0, capsh) + sunc * vec3<f32>(0.95, 0.85, 0.72) * (1.05 * tsun * ph));
                    // (lit from inside: the fireball's heat in the cap's core and its underside, white-hot at first,
                    // orange, then a dull red fading over tens of seconds; the stem's top lit by it from above)
                    let capw = smoothstep(cl.hc - 1.8 * cl.rt, cl.hc - 0.6 * cl.rt, p.y - C.y);
                    // (the fireball's heat: the whole ball at first, then gathered in the ring's core as it rolls up)
                    let qg = p - C - pl_lean(&cl, p.y - C.y);
                    let gv = vec2<f32>(length(qg.xz) - cl.Rt, (qg.y - cl.hc) * 1.2);
                    let ringc = exp(-dot(gv, gv) / pow(0.55 * cl.rt, 2.0));
                    let core = mix(1.0 - exp(min(d0, 0.0) / (0.22 * cl.rt + 6.0)), ringc, smoothstep(2.0, 9.0, a));
                    let under = 1.0 - smoothstep(cl.hc - 0.6 * cl.rt, cl.hc + 0.5 * cl.rt, p.y - C.y);
                    let surf = 1.5 * (1.0 - smoothstep(4.5, 8.5, a)) + 0.6 * exp(-a / 1.2);
                    // (from its first second, the glow on its lumps' crowns, their creases sooty)
                    let e = (heat * 5.0 + surf + glow * (0.06 + 3.2 * core * core * (exp(-a / 6.0) + 0.12)) * (0.3 + 1.4 * under)) * capw * (1.0 - ringw) * mix(0.1 + 2.3 * (1.0 - sd.y) * (1.0 - sd.y), (0.05 + 0.75 * smoothstep(0.2, 1.0, em_y)) * (1.0 - 0.6 * kb), smoothstep(0.3, 1.3, a));
                    let tcol = mix(mix(vec3<f32>(0.9, 0.13, 0.03), vec3<f32>(2.8, 0.95, 0.16), saturate(glow * 1.3 + 0.15 * core)), vec3<f32>(3.4, 3.0, 2.4), heat);
                    // (and the land's glow, under it, on the stem and the surge, at first)
                    let lowlit = (1.0 - capw) * (heat * 2.0 + 0.6 * glow) * exp(-max(p.y - C.y, 0.0) / 90.0) * 0.4;
                    // (at night its own glow is most of what lights it, and shows for longer)
                    let en = e * (1.0 + 1.6 * (1.0 - day));
                    // (while it burns, the light on its sooty skin small beside its own: dark in its creases, not pale)
                    c = c * (1.0 - 0.6 * capw * (1.0 - smoothstep(4.0, 8.0, a))) * (1.0 - saturate(en * 1.2)) + tcol * (en * 0.6 + lowlit);
                    let ext = den * 0.32 * st;
                    let al = 1.0 - exp(-ext);
                    acc = acc + tr * al * c;
                    tmid = tmid + tr * al * t;
                    wmid = wmid + tr * al;
                    tr = tr * (1.0 - al);
                }
                t = t + select(st, max(0.55 * min(sd.x, dr), (0.12 * st + 0.25) * min(1.0 + 0.06 * f32(i), 2.5)), min(sd.x, dr) > 0.0);
            }
            if (tr < 0.999) {
                let dist = tmid / max(wmid, 1.0e-4);
                if (tr < 0.5) {
                    col_t = dist;
                }
                let ap = 1.0 - exp(-dist / 4000.0);
                // (the air's haze over it: thin over the burning ball, whose own light outshines it)
                let ccol = mix(acc / max(1.0 - tr, 1.0e-4), haze_c, ap * 0.75 * mix(0.25, 1.0, smoothstep(5.0, 9.0, a)));
                if (stage == 0u) {
                    col = mix(col, ccol, (1.0 - tr) * k * fade);
                } else {
                    pl_over(&hc, ccol, (1.0 - tr) * k * fade);
                }
            }
        }
    }
    }
    // ---- the bomb: a white-hot streak coming in from orbit, its plasma sheath and ionised wake; its heat shed, the
    // casing (an ogive nose, a long body, four fins at its tail, spinning faster as it dives, the sun glinting off it),
    // diving faster and faster, a collar of vapour round it, its nose glowing again; a pinprick of light the instant
    // before it bursts --------------------------------------------------------------------------------------------
    if (stage != 1u && have && time > PL_SEEN - 0.1 && time < PL_HIT + 0.03) {
        let tb = min(time, PL_HIT);
        let H0 = pl_head(tb);
        let Hp = H0 + C;
        let dh = length(Hp);
        let hn = Hp / dh;
        let cth = dot(rd, hn);
        let th = sqrt(max(2.0 * (1.0 - cth), 0.0));
        let hp = project_rel(Hp);
        var vis = 1.0;
        if (hp.z > 0.0 && all(hp.xy > vec2<f32>(0.0)) && all(hp.xy < vec2<f32>(1.0))) {
            let dd = depth_at(hp.xy);
            if (!is_sky(dd) && length(world_offset(hp.xy, dd)) < dh - 3.0) {
                vis = 0.0;
            }
        } else if (cth < 0.0) {
            vis = 0.0;
        }
        let show = smoothstep(PL_SEEN - 0.1, PL_SEEN + 0.35, time) * vis * k;
        // (its way, nose first; how hot it still is; how hard it is diving: its nose heating again, the vapour round it)
        let vd = normalize(H0 - pl_head(tb - 0.06) + vec3<f32>(0.0, -1.0e-4, 0.0));
        let heat = 1.0 - smoothstep(PL_COOL - 0.6, PL_COOL + 1.0, time);
        let dive = smoothstep(PL_DIVE, PL_HIT, time);
        let vc = smoothstep(PL_HIT - 2.2, PL_HIT - 0.3, time);
        // (the frame it is drawn in: y along it, nose first, coning a little, less as it gathers speed)
        let sw = vec2<f32>(sin(time * 1.7), cos(time * 1.3)) * mix(0.04, 0.012, dive);
        let e1 = normalize(cross(vd, select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(vd.y) > 0.9)));
        let e2 = cross(vd, e1);
        let ay = normalize(vd + e1 * sw.x + e2 * sw.y);
        let ax = normalize(cross(ay, e2));
        let az = cross(ax, ay);
        // (its fins spin it up as it dives: the glints come faster and faster)
        let sd8 = max(time - PL_COOL, 0.0);
        let spin = time * 2.3 + 0.32 * sd8 * sd8;
        // (marched in the frame, within a sphere round it)
        let reach = 13.0;
        let cen = Hp;
        let bq = dot(rd, cen);
        let disc = bq * bq - dot(cen, cen) + reach * reach;
        if (disc > 0.0 && show > 0.0) {
            let sq = sqrt(disc);
            var tt = max(bq - sq, 0.0);
            let t1 = min(bq + sq, scene_len);
            var best = 1.0e9;
            var bt = tt;
            var bm = 0.0;
            for (var i = 0; i < 56; i = i + 1) {
                if (tt > t1) {
                    break;
                }
                let pw = tt * px_a;
                let w = rd * tt - Hp;
                let r = nk_bomb(vec3<f32>(dot(w, ax), dot(w, ay), dot(w, az)), spin, vc);
                let rr = r.x / pw;
                if (rr < best) {
                    best = rr;
                    bt = tt;
                    bm = r.y;
                }
                if (r.x < 0.02 * pw) {
                    break;
                }
                tt = tt + max(r.x, 0.35 * pw);
            }
            var cov = saturate(0.6 - best) / 0.6;
            let pw = bt * px_a;
            if (cov > 0.0) {
                let w = rd * bt - Hp;
                let q = vec3<f32>(dot(w, ax), dot(w, ay), dot(w, az));
                let ep = max(0.05, 0.4 * pw);
                let ex = vec2<f32>(1.0, -1.0);
                let nl = normalize(ex.xyy * nk_bomb(q + ex.xyy * ep, spin, vc).x + ex.yyx * nk_bomb(q + ex.yyx * ep, spin, vc).x + ex.yxy * nk_bomb(q + ex.yxy * ep, spin, vc).x + ex.xxx * nk_bomb(q + ex.xxx * ep, spin, vc).x);
                var n = normalize(ax * nl.x + ay * nl.y + az * nl.z);
                var alb = vec3<f32>(0.4, 0.41, 0.42);
                var spec = 1.0;
                if (bm < 0.5) {
                    // (the body: a dull grey casing, a dark band round it, faint seams)
                    let yb = q.y / NK_BS;
                    alb = select(alb, vec3<f32>(0.07), abs(yb - 0.9) < 0.3);
                    alb = alb * (0.9 + 0.1 * step(0.06, abs(fract(yb / 2.2) - 0.5)));
                } else if (bm < 1.5) {
                    alb = vec3<f32>(0.12, 0.12, 0.13);
                } else if (bm < 2.5) {
                    alb = vec3<f32>(0.09, 0.085, 0.08);
                } else {
                    // (the vapour: a thin white veil, flickering, thinning to its trailing edge)
                    let fade_v = 1.0 - saturate((2.4 * NK_BS - q.y) / (9.0 * vc + 0.01));
                    alb = vec3<f32>(0.95, 0.96, 1.0);
                    spec = 0.0;
                    cov = cov * vc * 0.35 * fade_v * (0.75 + 0.25 * sin(time * 53.0 + q.y * 3.0));
                    if (dot(n, rd) > 0.0) {
                        n = -n;
                    }
                }
                let ndl = dot(n, L);
                // (the canopy lets the sun through: lit from behind as well)
                let dif = select(max(ndl, 0.0), 0.5 + 0.5 * abs(ndl), bm > 2.5);
                var c = alb * (sunc * dif * 0.95 + amb * (0.55 + 0.45 * n.y));
                c = c + sunc * spec * (pow(max(dot(reflect(rd, n), L), 0.0), 90.0) * 5.0 + pow(max(dot(reflect(rd, n), L), 0.0), 8.0) * 0.15);
                // (still hot from the re-entry: the nose glowing red, the body dull red behind it, cooling)
                // (and heating again in the dive: the nose dull red, then orange, its edges brightest)
                let warmb = max(smoothstep(PL_COOL + 2.2, PL_COOL - 0.4, time), 0.8 * dive * dive);
                let wn = select(0.35 * saturate((q.y / NK_BS + 3.0) / 6.0), 1.0, bm > 1.5 && bm < 2.5) * select(1.0, 0.0, bm > 2.5);
                c = c + mix(vec3<f32>(1.6, 0.28, 0.06), vec3<f32>(3.0, 1.6, 0.6), max(heat, 0.6 * dive * dive)) * warmb * warmb * wn;
                c = mix(c, haze_c, (1.0 - exp(-bt / 3000.0)) * 0.75);
                col = mix(col, c, cov * show);
            }
        }
        // (from far off, a speck at least: the casing never thinner than a pixel against the sky)
        let thc = max(4.0 / dh, px_a * 0.9);
        let far = smoothstep(1.2, 0.35, 16.0 / dh / px_a / 6.0) * (1.0 - heat);
        col = mix(col, vec3<f32>(0.05, 0.05, 0.055) + sunc * 0.05, exp(-pow(th / thc, 2.0)) * far * 0.85 * show);
        // (the re-entry: a white-hot point, its plasma sheath drawn out behind it in a teardrop, bloom, a lens streak)
        if (heat > 0.001) {
            let fl = 0.86 + 0.14 * sin(time * 41.0) * sin(time * 27.0 + 1.0);
            let tc0 = max(3.0 / dh, px_a * 0.9);
            let core = exp(-pow(th / tc0, 2.0)) * 16.0;
            let bloom = 1.1 / (1.0 + pow(th / (tc0 * 4.0 + 0.004), 2.0)) + 0.22 * exp(-th / 0.05);
            let lw = 16.0 + 100.0 * heat;
            let s = ray_seg(rd, Hp, Hp - vd * lw);
            let ww = mix(1.6, 6.0, sqrt(s.z));
            let wpx = max(ww, s.y * px_a * 0.8);
            let sheath = exp(-pow(s.x / wpx, 2.0)) * pow(1.0 - s.z, 1.6) * (ww / wpx) * 5.0;
            let sv = rd - hn * cth;
            let upv = normalize(cross(cross(hn, vec3<f32>(0.0, 1.0, 0.0)), hn) + vec3<f32>(0.0, 1.0e-5, 0.0));
            let streak = exp(-abs(dot(sv, upv)) / (px_a * 1.2)) * exp(-th / 0.035) * 0.3;
            let hot = vec3<f32>(1.0, 0.95, 0.88) * (core + bloom + streak) + mix(vec3<f32>(1.0, 0.9, 0.75), vec3<f32>(1.0, 0.42, 0.16), sqrt(s.z)) * sheath;
            col = col + hot * heat * fl * show;
        }
        // (the dive's heat: a small orange glow at its nose and a short hot wake, growing to the burst)
        if (dive > 0.001) {
            let s = ray_seg(rd, Hp + vd * 9.0, Hp - vd * (4.0 + 22.0 * dive));
            let ww = mix(0.8, 2.2, s.z);
            let wpx = max(ww, s.y * px_a * 0.8);
            let wake = exp(-pow(s.x / wpx, 2.0)) * pow(1.0 - s.z, 2.0) * (ww / wpx);
            let tc1 = max(2.0 / dh, px_a * 0.9);
            let nose = exp(-pow(th / tc1, 2.0)) * 1.2 + 0.15 / (1.0 + pow(th / (tc1 * 4.0 + 0.002), 2.0));
            col = col + vec3<f32>(2.4, 0.95, 0.3) * (nose + wake * 0.8) * dive * dive * show;
        }
        // (the sun glinting off its turning fins, now and then, from any distance)
        let gph = pow(0.5 + 0.5 * sin(spin * 2.0 + 0.7), 30.0) + 0.5 * pow(0.5 + 0.5 * sin(spin * 2.0 + 2.6), 40.0);
        let gtc = max(2.0 / dh, px_a * 1.0);
        let glint = (exp(-pow(th / (gtc * 0.6), 2.0)) * 2.5 + 0.1 / (1.0 + pow(th / (gtc * 3.0), 2.0))) * gph * sun_up;
        // (and at night a strobe on its tail, so it can be followed down, blinking faster as it nears)
        let blink = step(fract(time * 1.1 + 0.25 * sd8 * sd8), 0.14) * (1.0 - day) * 0.8;
        let red = exp(-pow(th / max(px_a * 1.2, 0.8 / dh), 2.0)) * 2.0 + 0.2 / (1.0 + pow(th / (px_a * 5.0), 2.0));
        col = col + (sunc * glint * (1.0 + dive) + vec3<f32>(2.4, 0.12, 0.05) * red * blink) * (1.0 - heat) * show;
        // (the instant before: a pinprick of white at it, swelling)
        let pin = pow(saturate((time - (PL_HIT - 0.22)) / 0.22), 3.0);
        if (pin > 0.0) {
            let pc = max(2.0 / dh, px_a * 0.9);
            col = col + vec3<f32>(1.0, 0.98, 0.95) * (exp(-pow(th / pc, 2.0)) * 30.0 + 2.5 / (1.0 + pow(th / (0.012 * pin + 0.002), 2.0))) * pin * show;
        }
    }

    // ---- the dust: marched along the view ray where it crosses the shell behind the front, more sparsely inside ------
    if (stage != 2u && a > 0.0 && a < 45.0) {
        let rf = PL_V * a;
        // (the slab the dust stays in: over the land's lowest and highest ground, where the heightfield is in)
        var ylo = min(C.y, me.y) - 6.0;
        var yhi = max(C.y, me.y) + 90.0;
        if (pl_w(PL_HF) > 1.0) {
            ylo = min(ylo, C.y + pl_w(PL_HF + 2u) - 6.0);
            yhi = max(yhi, C.y + pl_w(PL_HF + 3u) + 90.0);
        }
        // (where this pixel's ray meets the land, its own height: the dust right there sits on it, in a hollow
        // smaller than the heightfield's cells or on a rise; a treetop or a wall counts only a little)
        var loc = vec4<f32>(0.0, 0.0, 0.0, 1.0);
        if (!sky) {
            let sq = rel - C;
            let off = sq.y - pl_land(sq.xz, pl_gref(length(sq.xz), me, C, dme)).x;
            let stp = 2.0 * max(pl_w(PL_HF + 1u), 260.0) / 95.0;
            loc = vec4<f32>(sq.xz, clamp(off, -30.0, 2.5 + 0.1 * max(off - 2.5, 0.0)), stp * stp * 0.6);
        }
        var t0 = 0.0;
        var t1 = min(min(scene_len, col_t), 3200.0);
        if (abs(rd.y) > 1.0e-5) {
            let ya = ylo / rd.y;
            let yb = yhi / rd.y;
            t0 = max(t0, min(ya, yb));
            t1 = min(t1, max(ya, yb));
        } else if (ylo > 0.0 || yhi < 0.0) {
            t1 = -1.0;
        }
        // (the ray across the discs out to the front and out to where the wall thins: the shell between)
        let a2 = max(dot(rd.xz, rd.xz), 1.0e-8);
        let bb = -dot(rd.xz, C.xz);
        let cc = dot(C.xz, C.xz);
        let Ro = rf + 20.0;
        let Ri = max(rf - 110.0, 0.0);
        let dout = bb * bb - a2 * (cc - Ro * Ro);
        let din = bb * bb - a2 * (cc - Ri * Ri);
        if (t1 > t0 && dout > 0.0) {
            let oa = (-bb - sqrt(dout)) / a2;
            let ob = (-bb + sqrt(dout)) / a2;
            var seg = array<vec2<f32>, 3>(vec2<f32>(oa, ob), vec2<f32>(0.0, -1.0), vec2<f32>(0.0, -1.0));
            var ns = array<i32, 3>(16, 0, 0);
            if (din > 0.0 && Ri > 0.0) {
                let ia = (-bb - sqrt(din)) / a2;
                let ib = (-bb + sqrt(din)) / a2;
                seg[0] = vec2<f32>(oa, ia);
                seg[1] = vec2<f32>(ib, ob);
                seg[2] = vec2<f32>(ia, ib);
                ns = array<i32, 3>(12, 10, 6);
            }
            // (how square the ray crosses the ring: along it, at the ring's sides from far off, it would pile up)
            let mid_t = clamp(-bb / a2, t0, t1);
            let pm = rd * mid_t - C;
            let side = saturate(abs(dot(normalize(rd.xz), pm.xz / max(length(pm.xz), 1.0))) * 1.6);
            var tr = 1.0;
            var acc = vec3<f32>(0.0);
            let j = ign(in.position.xy + vec2<f32>(0.0, fract(time * 5.0) * 53.0));
            // (the cap over it, for its shadow on the dust)
            let dcl = pl_column(max(a, 0.01), Cb);
            // (the near crossing, the haze inside, then the far crossing: in the order the ray meets them)
            var order = array<i32, 3>(0, 2, 1);
            for (var si = 0; si < 3; si = si + 1) {
                let k2 = order[si];
                let sa = max(seg[k2].x, t0);
                let sb = min(seg[k2].y, t1);
                let n = ns[k2];
                if (n == 0 || sb <= sa || tr < 0.02) {
                    continue;
                }
                // (closer together near the eye)
                for (var i = 0; i < n; i = i + 1) {
                    let u0 = (f32(i) + j) / f32(n);
                    let u1 = (f32(i) + j + 1.0) / f32(n);
                    let t = sa + (sb - sa) * u0 * u0;
                    let dt = (sb - sa) * (u1 * u1 - u0 * u0);
                    let p = rd * t;
                    let dh = pl_dust(p, C, a, me, dme, side, loc);
                    // (thin right round the eye: the front passing over it would otherwise fill the whole picture with
                    // dust, the sky too; the lens and the air at the eye show it there instead)
                    let den = dh.x * smoothstep(2.0, 30.0, t);
                    if (den <= 0.001) {
                        continue;
                    }
                    let al = 1.0 - exp(-den * dt * 0.3);
                    let h = dh.y;
                    // (its billows lit on top, darker under them and low down)
                    let wq = p + cam;
                    let bl = gnoise3(wq * vec3<f32>(1.0 / 9.0, 1.0 / 6.0, 1.0 / 9.0) + vec3<f32>(0.0, -1.2 * a + 0.5, 0.0));
                    let lo = (0.45 + 0.55 * saturate(h / 8.0)) * (0.55 + 0.7 * bl);
                    let dc = vec3<f32>(0.56, 0.49, 0.37) * (sunc * 0.75 * lo * pl_cap_shade(p, L, a, C, dcl.hc - 0.3 * dcl.rt, dcl.Rt + dcl.rt) + amb * 0.6);
                    acc = acc + tr * al * dc;
                    tr = tr * (1.0 - al);
                    if (tr < 0.02) {
                        break;
                    }
                }
            }
            if (stage == 0u) {
                col = mix(col, col * tr + acc, k * fade);
            } else {
                let kf = k * fade;
                hc = vec4<f32>(hc.rgb * (1.0 - kf + kf * tr) + acc * kf, hc.a * (1.0 - kf + kf * tr));
            }
        }
    }

    // ---- the debris: dark chunks and specks of earth, tumbling as they fly and fall, the big ones trailing smoke ----
    if (stage == 1u) {
        // (whether a piece of the debris still in the air passes near here, a few pixels wider than the join looks for
        // them: the join looks only near those that are; most of the picture has none near it)
        var near = 0.0;
        var near_hi = 0.0;
        if (a > 0.0 && a < 24.0 && pl_w(8u) > 0.5) {
            var low = min(C.y, me.y) - 4.0;
            if (pl_w(PL_HF) > 1.0) {
                low = min(low, C.y + pl_w(PL_HF + 2u) - 4.0);
            }
            let fpx = frame.resolution.y / (2.0 * tan(frame.view_params.w * 0.5));
            let wpx = 1.0 / fpx;
            let eka = exp(-0.06 * a);
            // (the middle of the two by two this pixel stands for, in the picture's pixels)
            let pxy = (floor(in.position.xy) * 2.0 + 1.0);
            for (var i = 0; i < PL_DEBRIS; i = i + 1) {
                let ch = pl_chunk(i, a, eka, C);
                if (ch.live <= 0.0 || ch.p.y < low) {
                    continue;
                }
                let dist = length(ch.p);
                let off = length(ch.p - rd * dot(ch.p, rd));
                if (dist < 1.0 || off > ch.s * 4.5 + length(ch.v) * 0.8 + 1.5 + 9.0 * dist * wpx) {
                    continue;
                }
                // (as the join looks for it on the screen, three pixels wider)
                let s0 = project_rel(ch.p);
                if (s0.z < 0.0) {
                    continue;
                }
                let rad = max(ch.s * fpx / dist, 0.55);
                let reach = select(rad * 1.4 + length(ch.v) * 0.03 * fpx / dist + 2.0, rad * 3.0 + length(ch.v) * 0.6 * fpx / dist + 4.0, smoothstep(0.45, 0.8, ch.s) > 0.0);
                if (length(pxy - s0.xy * frame.resolution.xy) > reach + 3.0) {
                    continue;
                }
                if (pl_chunk_up(ch, C, me, dme) > 0.0) {
                    // (the first and the last near it: the join looks through those only)
                    near = select(near, f32(i + 1), near == 0.0);
                    near_hi = f32(i + 1);
                }
            }
        }
        // (how far its ray went, and the column's distance, for the join to match its pixels against and hide what lies
        // behind the column; both kept within a half float)
        return PlOut(hc, vec4<f32>(min(scene_len, 6.0e4), min(col_t, 6.0e4), near, near_hi));
    }
    if ((stage == 0u || up_e.y > 0.0) && a > 0.0 && a < 24.0 && pl_w(8u) > 0.5) {
        let i_lo = select(0, i32(up_e.y + 0.5) - 1, stage == 2u);
        let i_hi = select(PL_DEBRIS, i32(up_e.z + 0.5), stage == 2u);
        let fpx = frame.resolution.y / (2.0 * tan(frame.view_params.w * 0.5));
        let pxy = in.position.xy;
        let lim = min(scene_len, col_t);
        var cov = 0.0;
        var smk = 0.0;
        // (below the lowest of the land, a chunk is down: no need to look for the land under it)
        var low = min(C.y, me.y) - 4.0;
        if (pl_w(PL_HF) > 1.0) {
            low = min(low, C.y + pl_w(PL_HF + 2u) - 4.0);
        }
        let wpx = 1.0 / fpx;
        let eka = exp(-0.06 * a);
        for (var i = i_lo; i < i_hi; i = i + 1) {
            var ch = pl_chunk(i, a, eka, C);
            if (ch.live <= 0.0 || ch.p.y < low) {
                continue;
            }
            let dist = length(ch.p);
            if (dist > lim || dist < 1.0) {
                continue;
            }
            // (first a cheap look at how far off this pixel's ray it is, in the world: most are well clear)
            let off = length(ch.p - rd * dot(ch.p, rd));
            let reach_w = ch.s * 4.5 + length(ch.v) * 0.8 + 1.5 + 6.0 * dist * wpx;
            if (off > reach_w) {
                continue;
            }
            ch.live = pl_chunk_up(ch, C, me, dme);
            if (ch.live <= 0.0) {
                continue;
            }
            let s0 = project_rel(ch.p);
            if (s0.z < 0.0) {
                continue;
            }
            let q0 = s0.xy * frame.resolution.xy;
            let rad = max(ch.s * fpx / dist, 0.55);
            let bigc = smoothstep(0.45, 0.8, ch.s);
            // (the smoke a big one trails: a fading wisp along where it flew the last half second)
            let reach = select(rad * 1.4 + length(ch.v) * 0.03 * fpx / dist + 2.0, rad * 3.0 + length(ch.v) * 0.6 * fpx / dist + 4.0, bigc > 0.0);
            if (length(pxy - q0) > reach) {
                continue;
            }
            let s1 = project_rel(ch.p - ch.v * 0.03);
            let q1 = s1.xy * frame.resolution.xy;
            // (a tumbling lump: a capsule along its blur, its outline turning)
            let ab = q1 - q0;
            let w = saturate(dot(pxy - q0, ab) / max(dot(ab, ab), 1.0e-4));
            let e = length(pxy - (q0 + ab * w));
            let spin = a * pl_w(PL_DB + PL_DW * u32(i) + 8u);
            let th = atan2(pxy.y - q0.y, pxy.x - q0.x);
            let lump = 1.0 + 0.28 * sin(th * 3.0 + f32(i) + spin) + 0.12 * sin(th * 5.0 - spin * 1.3);
            let c = saturate(rad * lump + 0.5 - e) * ch.live * saturate(rad / max(length(ab) * 0.5, rad));
            cov = max(cov, c);
            if (bigc > 0.0) {
                let s2 = project_rel(ch.p - ch.v * 0.6 + vec3<f32>(0.0, 1.2, 0.0));
                let q2 = s2.xy * frame.resolution.xy;
                let tb = q2 - q0;
                let u = saturate(dot(pxy - q0, tb) / max(dot(tb, tb), 1.0e-4));
                let wd = rad * (0.6 + 1.6 * u) + 0.5;
                let et = length(pxy - (q0 + tb * u));
                smk = max(smk, saturate(1.0 - et / wd) * (1.0 - u) * 0.45 * bigc * ch.live * step(0.5, s2.z));
            }
        }
        let dirt = vec3<f32>(0.035, 0.03, 0.026) * (amb * 1.5 + sunc * 0.3);
        let smoke = vec3<f32>(0.28, 0.29, 0.31) * (amb * 0.8 + sunc * 0.25);
        col = mix(col, smoke, smk * k * fade);
        col = mix(col, dirt, cov * k * fade);
    }

    // ---- the dust at the eye: as the front washes over the camera, the picture greyed and flattened by the dust in the
    // air, clearing as it settles, and muck thrown on the lens -------------------------------------------------------
    if (a > 0.0 && a < 40.0) {
        let rc = length(C.xz);
        let tau = a - rc / PL_V;                               // since the front reached the eye
        if (tau > -0.1 && rc > 100.0) {
            let land = pl_land(-C.xz, pl_gref(rc, me, C, dme));
            let hc = -C.y - land.x;                            // the eye over the ground
            let E = smoothstep(-0.08, 0.05, tau) * (0.6 * exp(-tau / 0.8) + 0.4 * exp(-tau / 3.5))
                * smoothstep(60.0, 10.0, hc) * smoothstep(6000.0, 2500.0, rc) * smoothstep(100.0, 200.0, rc)
                * (1.0 - 0.55 * land.y) * fade * k;
            if (E > 0.002) {
                let dust_c = vec3<f32>(0.5, 0.46, 0.4) * (sunc * 0.55 + amb * 0.8);
                // (the air thick with it: contrast lost, greyed and a little warmed)
                let lum = dot(col, vec3<f32>(0.2126, 0.7152, 0.0722));
                col = mix(col, mix(vec3<f32>(lum), dust_c, 0.5), 0.22 * E);
                col = col * mix(vec3<f32>(1.0), vec3<f32>(1.03, 0.99, 0.93), E);
                // (a faint film of it on the lens, in soft blotches, fixed to the screen)
                let pxy = pl_px;
                let res = frame.resolution.xy;
                // (as out of focus as the drops: broad, soft-edged, no fine grain)
                let film = gnoise3(vec3<f32>(pxy / (0.15 * res.y), 3.1)) * 0.8 + gnoise3(vec3<f32>(pxy / (0.07 * res.y), 7.7)) * 0.2;
                col = mix(col, dust_c, 0.12 * E * smoothstep(0.35, 0.95, film));
            }
            // (muck thrown on the lens as the front passes, far out of focus, as the second clip shows it: drops near
            // round but each its own, a few drawn out into soft streaks, 2 to 7% of the picture's height across, blurred
            // discs a touch denser towards the rim, feathered over their outer half with no outline, faintly mottled and
            // faintly lit on the side the light comes from; some faint, some strong (letting through 55 to 90% of the light),
            // grey; often with a smaller drop or two beside them; nearly all high on the screen; landing over the second
            // after the front, staying a long while)
            let vis = smoothstep(60.0, 10.0, hc) * smoothstep(6000.0, 2500.0, rc) * smoothstep(120.0, 260.0, rc) * (1.0 - 0.5 * land.y) * k;
            if (vis > 0.0 && tau > 0.2) {
                let pxy = pl_px;
                let res = frame.resolution.xy;
                var keep = 1.0;
                var shine = 0.0;
                for (var i = 0u; i < 14u; i = i + 1u) {
                    let t0 = 0.25 + 1.4 * mh(i, seed, 0x3d0u);
                    let age = tau - t0;
                    if (age <= 0.0) {
                        continue;
                    }
                    let c = vec2<f32>(0.03 + 0.94 * mh(i, seed, 0x3d1u), 0.02 + 0.4 * pow(mh(i, seed, 0x3d2u), 1.3)) * res;
                    let sz = mh(i, seed, 0x3d3u);
                    let r = (0.011 + 0.026 * pow(sz, 0.8)) * res.y;
                    let d0 = pxy - c;
                    if (dot(d0, d0) > 16.0 * r * r) {
                        continue;
                    }
                    let life = smoothstep(0.0, 0.08, age) * (1.0 - smoothstep(6.0, 16.0, age + 4.0 * mh(i, seed, 0x3d4u)));
                    // (the drop and up to three smaller ones round it, each its own size, stretch, turn and strength)
                    for (var j = 0u; j < 4u; j = j + 1u) {
                        let hj = mh(i * 7u + j, seed, 0x3e0u);
                        if (j > 0u && hj > 0.3) {
                            continue;
                        }
                        let k2 = i * 7u + j;
                        let rj = select(r * (0.22 + 0.3 * mh(k2, seed, 0x3e1u)), r, j == 0u);
                        let ang = TAU * mh(k2, seed, 0x3e2u);
                        let cj = select(c + vec2<f32>(cos(ang), sin(ang)) * r * (1.4 + 0.9 * mh(k2, seed, 0x3e3u)), c, j == 0u);
                        let dj = pxy - cj;
                        // (stretched along its own turn: the big ones hardly, the small ones up to twice as long)
                        let rot = TAU * mh(k2, seed, 0x3e4u);
                        let cr = cos(rot);
                        let sr = sin(rot);
                        let stretch = 1.0 + mix(0.4, 0.06, smoothstep(0.012, 0.03, rj / res.y)) * 2.0 * mh(k2, seed, 0x3e5u);
                        let e = vec2<f32>((dj.x * cr + dj.y * sr) / stretch, -dj.x * sr + dj.y * cr);
                        let th = atan2(e.y, e.x);
                        let ph = TAU * mh(k2, seed, 0x3e6u);
                        // (an edge a little uneven)
                        let q = length(e) / rj * (1.0 + 0.05 * sin(3.0 * th + ph) + 0.035 * sin(5.0 * th - 2.0 * ph));
                        if (q >= 1.4) {
                            continue;
                        }
                        // (a defocused disc: feathered from under half its radius out past its edge, a little denser
                        // towards the rim, its mottling blurred to a faint unevenness)
                        let body = 1.0 - smoothstep(0.3, 1.38, q);
                        let ring = body * mix(0.9, 1.15, smoothstep(0.1, 0.8, q));
                        let mott = 0.94 + 0.12 * gnoise3(vec3<f32>(e / (0.8 * rj), f32(k2 % 97u)));
                        let op = (0.14 + 0.34 * pow(mh(k2, seed, 0x3e7u), 0.7)) * select(0.85, 1.0, j == 0u);
                        keep = keep * (1.0 - ring * mott * op * life);
                        // (and the light caught in it, faintly, on its upper side)
                        shine = shine + body * smoothstep(0.3, -0.9, dj.y / rj) * op * life;
                    }
                }
                // (muck, not shade: the drops scatter the light as well as stopping it, a dusty grey-brown veil)
                let muck = vec3<f32>(0.42, 0.38, 0.33) * (sunc * 0.45 + amb * 0.9);
                col = mix(col, col * keep + muck * (1.0 - keep) * 0.7, vis * fade) + muck * 0.4 * min(shine, 1.0) * vis * fade;
            }
        }
    }

    // ---- the white-out: for a moment the whole picture is the flash, then it lets go, overexposed for a second ----
    if (stage != 1u && a > -0.02 && a < 4.0) {
        // (as filmed: the whole frame a pinkish white, then washed orange for a second or so, then the exposure drops
        // dark for a moment before the sky comes back)
        // (short and hard: the picture back within half a second, so the fireball's first boiling is seen)
        let wo = saturate(1.6 * exp(-max(a, 0.0) / 0.11)) * smoothstep(-0.02, 0.02, a);
        col = col * (1.0 + 0.4 * exp(-max(a, 0.0) / 0.22));
        let ow = smoothstep(0.04, 0.14, a) * (1.0 - smoothstep(0.3, 0.6, a));
        col = mix(col, col * vec3<f32>(1.5, 0.8, 0.35) + vec3<f32>(0.38, 0.14, 0.02), ow * k * 0.7);
        col = col * (1.0 - 0.18 * exp(-pow((a - 0.75) / 0.25, 2.0)) * k);
        col = mix(col, vec3<f32>(1.4, 1.24, 1.32), wo * k);
    }
    let srgb = linear_to_srgb(max(col, vec3<f32>(0.0)));
    if (capture() > 2.5) {
        let sp = floor(pl_px);
        let chk = fract((sp.x + sp.y) * 0.5);
        let ycc_y = srgb.g * 0.5 + (srgb.r + srgb.b) * 0.25;
        let ycc_co = srgb.r - srgb.b;
        let ycc_cg = srgb.g - (srgb.r + srgb.b) * 0.5;
        return PlOut(vec4<f32>(ycc_y, select(ycc_cg, ycc_co, chk < 0.25) * 0.5 + 0.5, 0.0, 1.0), vec4<f32>(0.0));
    }
    return PlOut(vec4<f32>(srgb, 1.0), vec4<f32>(0.0));
}


// ---- the jolt on the picture: the game's camera shake (nuke.rs's nk_jolt) tops out at a few degrees, so as the
// shockwave reaches the player the picture itself is knocked about too: a hard hit, ringing out fast, then a heavy
// shudder dying away over some eight seconds; hardest within a few hundred blocks, a tremor a couple of kilometres off.
// Shifted and turned a little (never more than a degree or so) and zoomed in just enough that no edge shows. The
// lens's own marks stay put (pl_px). -----------------------------------------------------------------------------
var<private> pl_px: vec2<f32>;
fn pl_jolt(in: StageIn) -> StageIn {
    pl_px = in.position.xy;
    let tgt = vec3<f32>(anchor_xz().x, block_y() + 1.0 + PL_BURST, anchor_xz().y);
    let me = vec3<f32>(frame.mod_params[3].x, frame.mod_params[3].y, frame.mod_params[3].z);
    let dist = length(me - tgt);
    let s = now() - PL_HIT - dist / PL_V;                  // since the front reached the player
    if (s <= 0.0 || s > 10.0 || intensity_v() <= 0.0) {
        return in;
    }
    let g = clamp(1.7 / (1.0 + dist / 450.0), 0.2, 1.0);
    // (the hit: a slam, then swinging hard and fast, three or four times, dying in under a second)
    let hit = 0.03 * g * exp(-s / 0.3) * smoothstep(0.0, 0.02, s);
    let ring = vec2<f32>(
        0.65 * sin(s * 47.0 + 0.6) + 0.35 * sin(s * 83.0 + 2.1),
        0.65 * cos(s * 41.0 + 1.3) + 0.35 * sin(s * 71.0 + 0.4)
    );
    // (the shudder: heavier and slower, the ground still heaving under the player, fading over seconds)
    let shud = 0.0065 * g * exp(-s / 2.6) * smoothstep(0.1, 0.5, s);
    let sh = vec2<f32>(
        0.55 * sin(s * 17.0 + 0.3) + 0.3 * sin(s * 29.0 + 1.9) + 0.15 * sin(s * 53.0),
        0.55 * cos(s * 15.0 + 2.2) + 0.3 * sin(s * 31.0 + 0.7) + 0.15 * cos(s * 59.0)
    );
    let off = ring * hit + sh * shud;
    // (and a turn: up to about a degree in the hit, a fraction of one in the shudder)
    let roll = 0.018 * g * exp(-s / 0.4) * sin(s * 37.0 + 0.9) + 0.003 * g * exp(-s / 2.6) * sin(s * 11.0);
    let res = frame.resolution.xy;
    let asp = res.x / res.y;
    let zoom = 1.0 + 2.2 * (hit + shud) + 1.1 * abs(roll) * asp;
    // (in picture heights about the middle, so the turn is round)
    var q = (in.uv - 0.5) * vec2<f32>(asp, 1.0) / zoom;
    q = vec2<f32>(q.x * cos(roll) - q.y * sin(roll), q.x * sin(roll) + q.y * cos(roll)) + off;
    var o = in;
    o.uv = clamp(q / vec2<f32>(asp, 1.0) + 0.5, vec2<f32>(0.0), vec2<f32>(1.0));
    o.position = vec4<f32>(o.uv * res, in.position.zw);
    return o;
}
@fragment
fn fs_main(in0: StageIn) -> @location(0) vec4<f32> {
    let in = pl_jolt(in0);
    return nuke(in, 0u, vec4<f32>(0.0), vec3<f32>(1.0e9, 1.0, 0.0)).c;
}


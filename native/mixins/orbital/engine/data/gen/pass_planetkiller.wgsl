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


// Orbital Laser's post pass for the Planet Killer (laser 6). Like the Downfall's, the mod builds it from
// shaders/strike.wgsl up to its fs_main (the helpers: the noise, ray_seg, bolt_line, lava_ramp, project_rel, mh) less the
// other lasers' own functions, followed by this file, and sets it for a planet killer strike only, so its size costs the
// other lasers nothing. Validate with tools/check-shader.sh.

// ---- laser 6: the planet killer -----------------------------------------------------------------------------------
// Seven towers grind up out of the land far out round the horizon, one after another, dark against a sky going dark:
// each one's ground heaves and splits, light leaking up through it; the tower breaks the surface and struggles there,
// straining, catching, shuddering, leaning, then bursts up out of it in a surge of dust, a column of earth climbing with
// it. Each crown crackles and fires a bolt of lightning at a ring of light forming high over the target: it feels its
// way out in steps, branching, then runs the rest of the way and strikes the ring, lighting the land and the sky, and
// holds the jagged path it took, trembling, struck again now and then. The ring lights up from where each bolt strikes
// it, round to the next, until it is whole, a band of plasma with lightning crawling over it; it shudders, tightens and
// fills with light, and they fuse: a flash, a ring of light tearing out through the sky, the sky cracking and the clouds
// blown open. A bolt feels its way down to the target, streamers reaching up to meet it, and the beam pours down it.
// The land under it domes up, cracking with light, and bursts: a fireball, a column of ejecta, a shock running out
// through the land and a wall of dust, debris spiralling up round the beam, the crater molten and fissures running out
// from it pulsing with light. Then the bolts stutter out and the towers go dark and sink; the ring crushes in to a
// point, drops into the crater and bursts again, and a mushroom cloud climbs over the crater as the daylight comes back.
// strike.rs times the same strike, digs the same crater and opens the same fissures (pk_crack): keep the PK_* and pk_*
// in step.

const PK_N: i32 = 7;               // the towers
const PK_H: f32 = 300.0;           // the ring their beams feed, its middle this high over the target,
const PK_RING_R: f32 = 220.0;      // this wide, tightening to PK_RING_T as they fuse,
const PK_RING_T: f32 = 150.0;
const PK_RING_TILT: f32 = 0.22;    // its face tipped this far towards the player, so it reads from the ground,
const PK_RING_V: f32 = 2.6;        // and lit round from each beam at this many radians a second
const PK_SRC_R: f32 = 1100.0;      // how far out the towers stand
const PK_TOWER_H: f32 = 420.0;     // how tall they stand, and how wide at the foot
const PK_TOWER_R: f32 = 62.0;
const PK_BULGE: f32 = 0.7;         // the ground over a tower heaves and splits for this long,
const PK_STRUGGLE: f32 = 1.1;      // then it breaks the surface and struggles there (straining, catching, shuddering),
const PK_THRUST: f32 = 0.8;        // then bursts up out of it, risen this long after,
const PK_RAISE: f32 = 2.25;        // and settled, and fires, this long after it broke the surface:
const PK_IGN0: f32 = 3.05;         // the first (its ground starting to heave as the strike starts), the last by PK_IGN1
const PK_IGN1: f32 = 5.45;
const PK_CREEP: f32 = 1.0;         // its bolt feels its way out from its crown for this long, then runs the rest of the
const PK_SHOOT: f32 = 1.14;        // way, striking the ring this long after it fires
const PK_SHAKE: f32 = 6.9;         // the ring shudders and tightens from here
const PK_MERGE: f32 = 7.6;         // keep in step with strike.rs: PK_IGN*, PK_BULGE, PK_STRUGGLE, PK_THRUST, PK_RAISE, PK_SHOOT,
const PK_DROP: f32 = 8.4;          // PK_MERGE, PK_DROP, PK_HIT, PK_BURST, PK_CUT, PK_POP, the crater's and the cracks'
const PK_HIT: f32 = 8.5;           // a bolt feels its way down from the ring to the target, the beam pours down it and lands,
const PK_BURST: f32 = 9.0;         // the ground domes up, and bursts
const PK_CUT: f32 = 17.65;         // the towers cut out
const PK_DRAIN: f32 = 0.4;         // their bolts dying over this long, all gone before the ring falls
const PK_FALL: f32 = 18.15;        // it drops into the crater,
const PK_POP: f32 = 18.55;         // and bursts there
const PK_END: f32 = 28.15;         // the daylight is back (the strike runs 30.5 s)
const PK_BLAST: f32 = 340.0;       // the land flattened out to here, PK_ABOVE up
const PK_ABOVE: f32 = 24.0;
const PK_BOWL: f32 = 240.0;        // the crater (strike.rs's pk_depth0): PK_BOWL round, its walls dropping PK_WALL_D from
const PK_FLOOR: f32 = 145.0;       // its edge in to PK_FLOOR, its floor sagging PK_SAG more in to the open shaft, PK_SHAFT
const PK_WALL_D: f32 = 60.0;       // round, down to bedrock (PK_SHAFT_D under a target at sea level)
const PK_SAG: f32 = 20.0;
const PK_SHAFT: f32 = 40.0;
const PK_SHAFT_D: f32 = 123.0;
const PK_CORE: f32 = 64.0;         // dug from PK_DIG0 after the burst at PK_RATE blocks a second, from the middle out: the
const PK_DIG0: f32 = 2.0;          // core (with the land over it), then the land over the rest out to PK_LAND, then the rest
const PK_RATE: f32 = 1500000.0;    // (pk_dig_t)
const PK_LAND: f32 = 268.0;
const PK_CRACKS: i32 = 12;         // the fissures: from PK_RIM out, PK_SEG-block segments, opening at PK_CRACK_V blocks a
const PK_RIM: f32 = 236.0;         // second from PK_CRACK_T after the burst
const PK_SEG: f32 = 12.0;
const PK_CRACK_V: f32 = 90.0;
const PK_CRACK_T: f32 = 0.9;
// The beams' light: a searing white core in an electric blue, a deep cobalt glow round it.
const PK_WHITE: vec3<f32> = vec3<f32>(7.0, 8.0, 10.0);
const PK_HOT: vec3<f32> = vec3<f32>(0.9, 2.2, 6.0);
const PK_DEEP: vec3<f32> = vec3<f32>(0.08, 0.22, 1.8);
const PK_ARC: vec3<f32> = vec3<f32>(0.55, 0.75, 2.4);       // the glow round the bolts, bluer and more violet

// Tower i: where its foot stands (xyz) and when it fires (w). The first fires beyond the target as the player faces it,
// the rest alternately to its right and left, round towards the player; each a little off its place and its time.
fn pk_emitter(i: i32, seed: f32) -> vec4<f32> {
    let s = u32(seed);
    let side = select(-1.0, 1.0, i % 2 == 1);
    let a = wing_a() + 3.14159265 + side * f32((i + 1) / 2) * TAU / f32(PK_N) + (mh(u32(i), s, 31u) - 0.5) * 0.5;
    let r = PK_SRC_R * (0.8 + 0.4 * mh(u32(i), s, 32u));
    let t = PK_IGN0 + (PK_IGN1 - PK_IGN0) * f32(i) / f32(PK_N - 1) + (mh(u32(i), s, 33u) - 0.5) * 0.12;
    let tgt = target_pos();
    return vec4<f32>(tgt.x + cos(a) * r, tgt.y - 2.0, tgt.z + sin(a) * r, t);
}

// Fissure i: x its heading out from the target, y how long it runs past PK_RIM. Its line wanders off that heading by
// pk_crack_off at each PK_SEG.
fn pk_crack(i: i32, seed: f32) -> vec2<f32> {
    let s = u32(seed);
    let a = (f32(i) + 0.7 * mh(u32(i), s, 21u)) * TAU / f32(PK_CRACKS) + mh(99u, s, 22u) * TAU;
    return vec2<f32>(a, 110.0 + 50.0 * mh(u32(i), s, 23u));
}
fn pk_crack_off(i: i32, j: i32, seed: f32) -> f32 {
    return select((mh(u32(i * 32 + j), u32(seed), 24u) - 0.5) * 0.12, 0.0, j == 0);
}

// How deep the crater is `r` out from its middle, smoothly (strike.rs's pk_depth0), and the ground dug out of it within
// `r` (pk_vol).
fn pk_depth0(r: f32) -> f32 {
    if (r < PK_SHAFT) {
        return PK_SHAFT_D;
    }
    if (r < PK_FLOOR) {
        return PK_WALL_D + PK_SAG * (PK_FLOOR - r) / (PK_FLOOR - PK_SHAFT);
    }
    let u = saturate((r - PK_FLOOR) / (PK_BOWL - PK_FLOOR));
    return PK_WALL_D * (1.0 - u * u);
}
fn pk_vol(r: f32) -> f32 {
    let w = PK_BOWL - PK_FLOOR;
    let rs = min(r, PK_SHAFT);
    var v = 3.14159265 * rs * rs * PK_SHAFT_D;
    if (r > PK_SHAFT) {
        let rf = min(r, PK_FLOOR);
        let k = PK_SAG / (PK_FLOOR - PK_SHAFT);
        v = v + TAU * ((PK_WALL_D + k * PK_FLOOR) * (rf * rf - PK_SHAFT * PK_SHAFT) * 0.5 - k * (rf * rf * rf - PK_SHAFT * PK_SHAFT * PK_SHAFT) / 3.0);
    }
    if (r > PK_FLOOR) {
        let u = min((r - PK_FLOOR) / w, 1.0);
        v = v + TAU * PK_WALL_D * w * (PK_FLOOR * (u - u * u * u / 3.0) + w * (u * u * 0.5 - u * u * u * u * 0.25));
    }
    return v;
}
// When the crater `r` out is dug (strike.rs's pk_dig_t): the core with the land over it, then, once the land over the rest
// is cleared, the rest, from the middle out.
fn pk_dig_t(r: f32) -> f32 {
    let rc = min(r, PK_CORE);
    let core = PK_BURST + PK_DIG0 + (3.14159265 * rc * rc * PK_ABOVE + pk_vol(rc)) / PK_RATE;
    if (r <= PK_CORE) {
        return core;
    }
    return core + 3.14159265 * (PK_LAND * PK_LAND - PK_CORE * PK_CORE) * PK_ABOVE / PK_RATE + (pk_vol(r) - pk_vol(PK_CORE)) / PK_RATE;
}

// How far the land at `rel2` (from the target, `r` out) has really been opened by `time`: the crater as strike.rs digs
// it, from the middle out (pk_dig_t), its edge wandering round it as pk_depth's does and a little ragged, soft. Nothing
// over the land not dug yet.
fn pk_open(rel2: vec2<f32>, r: f32, time: f32, seed: f32) -> f32 {
    let ang = atan2(rel2.y, rel2.x);
    let w = gnoise2(vec2<f32>(cos(ang), sin(ang)) * 4.4 + vec2<f32>(seed * 0.37, 11.0)) - 0.5;
    let rag = gnoise2(rel2 * 0.06 + vec2<f32>(seed, 3.0)) - 0.5;
    let edge = PK_BOWL * (1.0 + 0.14 * w) + 10.0 * rag;
    let inside = 1.0 - smoothstep(edge - 8.0, edge + 2.0, r);
    let front = time - pk_dig_t(max(r + 14.0 * rag, 0.0));
    return inside * smoothstep(0.0, 0.8, front);
}

// How far the blast's shock front has run out `t` after the land burst, and the second one `t` after the nexus burst:
// fast out, slowing as it spreads.
fn pk_shock_r(t: f32) -> f32 {
    return 90.0 + 820.0 * (1.0 - exp(-t * 0.55));
}
fn pk_pop_r(t: f32) -> f32 {
    return 30.0 + 540.0 * (1.0 - exp(-t * 0.6));
}
// How far a fissure's split has run out past PK_RIM `t` after the burst (strike.rs's pk_crack_time turned round): in
// jerks, four a second, each a lurch forward that eases to a stop, keeping to PK_CRACK_V on the whole.
fn pk_crack_front(t: f32) -> f32 {
    let q = max(t - PK_CRACK_T, 0.0) * 4.0;
    return (floor(q) + smoothstep(0.0, 0.35, fract(q))) / 4.0 * PK_CRACK_V;
}

// How much of a light `t` along the view ray shows: all of it in front of the scene or against the sky, some through a
// cloud, none behind the land.
fn pk_occ(t: f32, scene_len: f32, sky: bool, cloud: bool) -> f32 {
    return select(select(0.0, 0.5, cloud), 1.0, sky || t < scene_len);
}

// A ring of radius R round C (camera-relative) in the plane of e1 and e2: x how close the view ray passes to it, y how
// far along the ray, z where round it (radians). Where the ray crosses its plane, its nearest point is straight out from
// the middle; where the ray runs along the plane, from the ray's closest point to the middle.
fn pk_ring(rd: vec3<f32>, C: vec3<f32>, e1: vec3<f32>, e2: vec3<f32>, R: f32) -> vec3<f32> {
    let n = cross(e1, e2);
    var X = rd * max(dot(C, rd), 0.0) - C;
    let dn = dot(rd, n);
    if (abs(dn) > 0.08) {
        let tp = dot(C, n) / dn;
        if (tp > 0.0) {
            X = rd * tp - C;
        }
    }
    let a = atan2(dot(X, e2), dot(X, e1));
    let P = C + (e1 * cos(a) + e2 * sin(a)) * R;
    let tq = max(dot(P, rd), 0.0);
    return vec3<f32>(length(P - rd * tq), tq, a);
}

// The colour of the beams' and the ring's light by how hot it is (0 to 1 and over): a deep blue haze, an electric
// blue, cyan, then white.
fn pk_heat(h: f32) -> vec3<f32> {
    var c = mix(vec3<f32>(0.02, 0.05, 0.45), vec3<f32>(0.12, 0.45, 3.0), smoothstep(0.0, 0.35, h));
    c = mix(c, vec3<f32>(0.7, 2.8, 5.2), smoothstep(0.3, 0.7, h));
    return mix(c, vec3<f32>(6.5, 7.8, 9.5), smoothstep(0.65, 1.0, h));
}

// A band of light round C (camera-relative) at radius R in the plane with normal n, `w` blocks wide (at least a pixel
// or so): met where the view ray crosses the plane, widened as the plane turns edge on so it never thins to nothing.
// x how bright, y how far along the ray, z where round it (radians, from e1 towards e2).
fn pk_band(rd: vec3<f32>, C: vec3<f32>, e1: vec3<f32>, e2: vec3<f32>, R: f32, w: f32) -> vec3<f32> {
    let n = cross(e1, e2);
    let dn = dot(rd, n);
    let tp = dot(C, n) / select(dn, 1.0e-4, abs(dn) < 1.0e-4);
    if (tp <= 0.0) {
        return vec3<f32>(0.0);
    }
    let X = rd * tp - C;
    let ww = max(w, tp * 0.0013) / max(abs(dn), 0.12);
    return vec3<f32>(exp(-pow((length(X) - R) / ww, 2.0)) * (w / max(w, tp * 0.0013)), tp, atan2(dot(X, e2), dot(X, e1)));
}

// A tower, in its own frame (y up from its bottom, PK_TOWER_H tall): a stepped hexagonal plinth splayed into the ground,
// three buttresses flying up off its corners, a shaft in six tiers narrowing up it with a heavy collar under each joint
// and ribs up its corners, a neck, a ring plate round it, and four claws curling up round the emitter at its crown under
// a spire. Its distance (a little under, so marching it never oversteps), and what it is made of there: 0 the hull,
// 1 a collar or a rib, 2 the crown, 3 a buttress, 5 the emitter.
const PK_T0: f32 = 64.0;            // the shaft, from the plinth's top
const PK_T1: f32 = 336.0;           // to the neck,
const PK_TIER: f32 = 45.333;        // in six tiers
const PK_TB: f32 = 136.0;           // and all of it (and the broken ground heaped round its foot) within this of its axis
const PK_CORE_Y: f32 = 397.0;       // where the emitter is

// A hexagon's distance, `a` from its middle to the middle of a side (its corners on +-x).
fn pk_hex(p: vec2<f32>, a: f32) -> f32 {
    let k = vec3<f32>(-0.8660254, 0.5, 0.57735027);
    var q = abs(p);
    q = q - 2.0 * min(dot(k.xy, q), 0.0) * k.xy;
    q = q - vec2<f32>(clamp(q.x, -k.z * a, k.z * a), a);
    return length(q) * sign(q.y);
}
// p turned into the first of n sectors round the axis (the first centred `off` round from +x).
fn pk_fold(p: vec2<f32>, n: f32, off: f32) -> vec2<f32> {
    let s = TAU / n;
    let a = atan2(p.y, p.x) - off;
    let b = a - s * floor(a / s + 0.5);
    return vec2<f32>(cos(b), sin(b)) * length(p);
}
fn pk_cone(p: vec3<f32>, a: vec3<f32>, b: vec3<f32>, ra: f32, rb: f32) -> f32 {
    let pa = p - a;
    let ba = b - a;
    let h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h) - mix(ra, rb, h);
}
// The shaft's half-width at height y, before its tiers.
fn pk_shaft_a(y: f32) -> f32 {
    let u = saturate((y - PK_T0) / (PK_T1 - PK_T0));
    return mix(46.0, 19.0, u * (0.55 + 0.45 * u));
}
// How far the tower being marched has risen, and how high the broken ground is heaped round its foot (0 to 1).
var<private> pk_lift_g: f32;
var<private> pk_heap_g: f32;
fn pk_tsdf(p: vec3<f32>) -> vec2<f32> {
    let y = p.y;
    // the plinth, in three steps, run down into the ground
    let pa = mix(76.0, 60.0, saturate(y / PK_T0)) - 7.0 * smoothstep(20.0, 22.0, y) - 6.0 * smoothstep(42.0, 44.0, y);
    var d = max(pk_hex(p.xz, pa) * 0.9, max(-60.0 - y, y - PK_T0));
    var m = 0.0;
    // the shaft, each tier narrowing up its height
    let ti = clamp(floor((y - PK_T0) / PK_TIER), 0.0, 5.0);
    let tt = (y - PK_T0) / PK_TIER - ti;
    let a = pk_shaft_a(y) * (1.04 - 0.08 * tt);
    // (every other tier turned a twelfth of the way round, so its corners stand over the faces under it)
    let tw = select(0.0, 0.5235988, ti - 2.0 * floor(ti * 0.5) > 0.5);
    let pr = vec2<f32>(cos(tw) * p.x + sin(tw) * p.z, -sin(tw) * p.x + cos(tw) * p.z);
    d = min(d, max(pk_hex(pr, a), max(PK_T0 - 2.0 - y, y - PK_T1)));
    // a collar under each joint
    let yj = PK_T0 + clamp(round((y - PK_T0) / PK_TIER), 1.0, 5.0) * PK_TIER;
    let dc = max(length(p.xz) - pk_shaft_a(yj) * 1.12 - 5.0, abs(y - yj + 1.0) - 3.5);
    if (dc < d) {
        d = dc;
        m = 1.0;
    }
    // ribs up its corners
    let q6 = pk_fold(pr, 6.0, 0.0);
    let dr = max(max(abs(q6.y) - 1.8, q6.x - a * 1.1547 - 3.5), max(PK_T0 - y, y - PK_T1 + 30.0));
    if (dr < d) {
        d = dr;
        m = 1.0;
    }
    // the three buttresses off the plinth's corners
    let q3 = pk_fold(p.xz, 3.0, 0.0);
    let df = max(max(abs(q3.y) - 4.5, (q3.x + 0.38 * y - 104.0) * 0.935), max(-60.0 - y, y - 236.0));
    if (df < d) {
        d = df;
        m = 3.0;
    }
    // the ground round its foot, broken and heaped up round it as it burst out (not risen with it)
    if (pk_heap_g > 0.0) {
        let rr = length(p.xz);
        let yg = y - PK_TOWER_H + pk_lift_g;
        let hh = pk_heap_g * (16.0 * exp(-pow((rr - 82.0) / 26.0, 2.0)) + 7.0 * exp(-pow((rr - 112.0) / 14.0, 2.0)))
            * (0.6 + 0.8 * gnoise2(p.xz * 0.09)) - 2.0;
        let dm = max((yg - hh) * 0.45, rr - PK_TB + 2.0);
        if (dm < d) {
            d = dm;
            m = 6.0;
        }
    }
    // the crown
    if (y > PK_T1 - 24.0) {
        let dn = max(pk_hex(p.xz, 14.0), max(PK_T1 - 4.0 - y, y - 360.0));
        let dh = max(abs(y - 352.0) - 2.2, abs(length(p.xz) - 31.0) - 9.0);
        let q4 = pk_fold(p.xz, 4.0, 0.7853982);
        let qc = vec3<f32>(q4.x, y, q4.y);
        let dk = min(pk_cone(qc, vec3<f32>(15.0, 346.0, 0.0), vec3<f32>(37.0, 380.0, 0.0), 6.0, 4.0),
            pk_cone(qc, vec3<f32>(37.0, 380.0, 0.0), vec3<f32>(13.0, 416.0, 0.0), 4.0, 1.2));
        let dsp = pk_cone(p, vec3<f32>(0.0, 352.0, 0.0), vec3<f32>(0.0, 420.0, 0.0), 5.0, 0.8);
        let dcr = min(min(dn, dh), min(dk, dsp));
        if (dcr < d) {
            d = dcr;
            m = 2.0;
        }
        let de = length(p - vec3<f32>(0.0, PK_CORE_Y, 0.0)) - 8.5;
        if (de < d) {
            d = de;
            m = 5.0;
        }
    }
    return vec2<f32>(d, m);
}
// A point (camera-relative) in the frame of the tower whose foot is at S (camera-relative, on the ground), risen `lift`
// out of the land, leaning by `lean` (sheared about the ground), turned `rot` about its axis.
fn pk_tlocal(X: vec3<f32>, S: vec3<f32>, lift: f32, lean: vec2<f32>, rot: f32) -> vec3<f32> {
    let rel = X - S;
    let xz = rel.xz - lean * rel.y;
    let c = cos(rot);
    let s = sin(rot);
    return vec3<f32>(c * xz.x - s * xz.y, rel.y + PK_TOWER_H - lift, s * xz.x + c * xz.y);
}
// The view ray against the tower (S, lift, lean, rot as pk_tlocal), up to `tmax`: x how far along it (under 0 if it
// misses), y what it is made of there. Marched from where the ray enters the upright cylinder round it.
fn pk_tower(S: vec3<f32>, lift: f32, lean: vec2<f32>, rot: f32, rd: vec3<f32>, tmax: f32) -> vec2<f32> {
    let o = -S.xz + lean * S.y;
    let v = rd.xz - lean * rd.y;
    let a = max(dot(v, v), 1.0e-8);
    let b = dot(o, v);
    let disc = b * b - a * (dot(o, o) - PK_TB * PK_TB);
    if (disc <= 0.0) {
        return vec2<f32>(-1.0);
    }
    var t0 = (-b - sqrt(disc)) / a;
    var t1 = (-b + sqrt(disc)) / a;
    // (from a little under its foot, the ground there not always level, to its tip)
    let ylo = S.y - 30.0;
    let yhi = S.y + lift + 2.0;
    if (abs(rd.y) > 1.0e-5) {
        t0 = max(t0, min(ylo / rd.y, yhi / rd.y));
        t1 = min(t1, max(ylo / rd.y, yhi / rd.y));
    }
    t0 = max(t0, 0.0);
    t1 = min(t1, tmax);
    if (t1 <= t0) {
        return vec2<f32>(-1.0);
    }
    var t = t0;
    for (var k = 0; k < 80; k = k + 1) {
        let h = pk_tsdf(pk_tlocal(rd * t, S, lift, lean, rot));
        if (h.x < max(0.05, t * 0.0009)) {
            return vec2<f32>(t, h.y);
        }
        t = t + h.x * 0.8;
        if (t > t1) {
            break;
        }
    }
    return vec2<f32>(-1.0);
}
// The tower's surface's normal at q (in its frame).
fn pk_tnormal(q: vec3<f32>, e: f32) -> vec3<f32> {
    let k = vec2<f32>(1.0, -1.0);
    return normalize(k.xyy * pk_tsdf(q + k.xyy * e).x + k.yyx * pk_tsdf(q + k.yyx * e).x + k.yxy * pk_tsdf(q + k.yxy * e).x
        + k.xxx * pk_tsdf(q + k.xxx * e).x);
}

fn pk_ease(a: f32, b: f32, x: f32) -> f32 {
    let y = 1.0 - saturate(x);
    return mix(a, b, 1.0 - y * y);
}
fn pk_jolt(s: f32, at: f32, k: f32) -> f32 {
    return select(0.0, exp(-(s - at) * k), s > at);
}
// A tower `s` seconds after it breaks the surface: x how far it has risen (of its height), y how hard it shudders
// (blocks). It punches through, strains against the ground barely moving, gives a little and catches, grinds on, gives
// again and catches, gathers itself, shaking harder and harder, then bursts up out of it, carried a little past its
// height, and settles.
fn pk_rise(s: f32) -> vec2<f32> {
    if (s <= 0.0) {
        return vec2<f32>(0.0);
    }
    var h = 0.162;
    if (s < 0.12) {
        h = pk_ease(0.0, 0.055, s / 0.12);
    } else if (s < 0.38) {
        h = mix(0.055, 0.066, (s - 0.12) / 0.26);
    } else if (s < 0.45) {
        h = pk_ease(0.066, 0.104, (s - 0.38) / 0.07);
    } else if (s < 0.52) {
        h = mix(0.104, 0.097, smoothstep(0.45, 0.52, s));
    } else if (s < 0.76) {
        h = mix(0.097, 0.118, (s - 0.52) / 0.24);
    } else if (s < 0.82) {
        h = pk_ease(0.118, 0.17, (s - 0.76) / 0.06);
    } else if (s < 0.9) {
        h = mix(0.17, 0.162, smoothstep(0.82, 0.9, s));
    } else if (s >= PK_STRUGGLE) {
        let x = (s - PK_STRUGGLE) / PK_THRUST;
        if (x < 1.0) {
            h = mix(0.162, 1.035, 1.0 - pow(1.0 - x, 2.4));
        } else {
            let y = saturate((x - 1.0) * PK_THRUST / (PK_RAISE - PK_STRUGGLE - PK_THRUST));
            h = mix(1.035, 1.0, y) + 0.008 * sin(y * 9.0) * (1.0 - y);
        }
    }
    let strain = smoothstep(0.88, PK_STRUGGLE, s) * f32(s < PK_STRUGGLE);
    let sh = 0.35 * f32(s < PK_STRUGGLE) + 2.2 * pk_jolt(s, 0.0, 8.0) + 1.4 * pk_jolt(s, 0.38, 10.0) + 1.6 * pk_jolt(s, 0.45, 9.0)
        + 1.8 * pk_jolt(s, 0.76, 10.0) + 1.5 * pk_jolt(s, 0.82, 9.0) + 1.6 * strain + 3.2 * pk_jolt(s, PK_STRUGGLE, 2.6);
    return vec2<f32>(h, sh);
}

// The leader of a bolt `et` seconds after it sets out: how far it has reached (of the way). It feels its way out in
// steps, slowly, stalling, for PK_CREEP, then suddenly runs the rest of the way.
fn pk_lead(et: f32, fi: f32) -> f32 {
    if (et <= 0.0) {
        return 0.0;
    }
    if (et < PK_CREEP) {
        let q = et / PK_CREEP;
        let w = q + 0.035 * sin(q * 11.0 + fi * 2.3);
        let st = (floor(w * 14.0) + smoothstep(0.0, 0.3, fract(w * 14.0))) / 14.0;
        return 0.36 * pow(saturate(st), 1.35);
    }
    let x = saturate((et - PK_CREEP) / (PK_SHOOT - PK_CREEP));
    return 0.36 + 0.64 * x * (0.7 + 0.3 * x);
}

// A bolt's jagged line: straight runs between random kinks, x of them along it; seeded by `so`.
fn pk_jg(x: f32, so: u32) -> f32 {
    let i = u32(i32(floor(x)) + 4096);
    return mix(f32(pcg(i ^ so)), f32(pcg((i + 1u) ^ so)), fract(x)) * (2.0 / 4294967296.0) - 1.0;
}

// A bolt of lightning from A to B (camera-relative), seeded by `s`, drawn out to `head` of the way along, `n` segments;
// `amp` how far it wanders off its line (of its length), `jit` how hard it crackles (its line trembling, a new tremble
// every frame of film, its shape kept), `rc` its channel's radius. Each kink is the same from frame to frame, so it keeps
// the path it took. x its core, y the glow round it, z how far along it the nearest point is.
fn pk_bolt(rd: vec3<f32>, A: vec3<f32>, B: vec3<f32>, head: f32, s: u32, n: i32, amp: f32, jit: f32, rc: f32, time: f32,
           scene_len: f32, sky: bool, cloud: bool) -> vec3<f32> {
    let AB = B - A;
    let L = max(length(AB), 1.0e-3);
    let D = AB / L;
    let qc = ray_seg(rd, A, A + AB * head);
    let wc = max(rc, qc.y * 0.0013);
    let margin = L * amp * 0.13 + wc * 30.0;
    if (head <= 0.0 || qc.x > margin) {
        return vec3<f32>(0.0);
    }
    let e1 = normalize(cross(D, select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(D.y) > 0.9)));
    let e2 = cross(D, e1);
    let s1 = pcg(s ^ 0x9e3779b9u);
    let s2 = pcg(s1);
    let s3 = pcg(s2);
    let s4 = pcg(s3);
    let s5 = pcg(s4);
    let s6 = pcg(s5);
    let s7 = pcg(s6);
    let s8 = pcg(s7);
    let sj = pcg(s ^ u32(i32(time * 24.0)));
    let fn_ = f32(n);
    // (in two passes: the line's broad bends first, four segments at a time, and only where the ray passes near one of
    // those its kinks; the broad bends kink on those four-segment knots, so the coarse line is exactly theirs)
    let nc = (n + 3) / 4;
    let fnc = f32(n) / 4.0;
    let fine = L * amp * 0.05;
    var cprev = A;
    var prev = A;
    var best = 1.0e9;
    var bt = 0.0;
    var bu = 0.0;
    for (var c = 1; c <= nc; c = c + 1) {
        let j0 = (c - 1) * 4;
        let j1 = min(c * 4, n);
        let cu0 = f32(j0) / fn_;
        if (cu0 >= head) {
            break;
        }
        let cu = f32(j1) / fn_;
        let cenv = sqrt(max(sin(cu * 3.14159265), 0.0));
        let co = vec2<f32>(pk_jg(cu * fnc * 0.5, s1), pk_jg(cu * fnc * 0.5, s2)) * 0.065 + vec2<f32>(pk_jg(cu * fnc, s3), pk_jg(cu * fnc, s4)) * 0.035;
        let CP = A + AB * cu + (e1 * co.x + e2 * co.y) * (L * amp * cenv);
        let cq = ray_seg(rd, cprev, CP);
        cprev = CP;
        if (cq.x > fine + max(rc, cq.y * 0.0013) * 40.0) {
            // (too far from it to matter: carry on from where its kinked line ends)
            if (cu > head) {
                break;
            }
            let x = cu * fn_;
            var o = co + vec2<f32>(pk_jg(x * 0.5, s5), pk_jg(x * 0.5, s6)) * 0.018 + vec2<f32>(pk_jg(x, s7), pk_jg(x, s8)) * 0.009;
            o = o + vec2<f32>(pk_jg(x, sj), pk_jg(x, sj ^ 0x55u)) * 0.0035 * jit;
            prev = A + AB * cu + (e1 * o.x + e2 * o.y) * (L * amp * cenv);
            continue;
        }
        for (var j = j0 + 1; j <= j1; j = j + 1) {
            let u0 = f32(j - 1) / fn_;
            if (u0 >= head) {
                break;
            }
            let u = f32(j) / fn_;
            let env = sqrt(max(sin(u * 3.14159265), 0.0));
            let x = u * fn_;
            var o = vec2<f32>(pk_jg(u * fnc * 0.5, s1), pk_jg(u * fnc * 0.5, s2)) * 0.065 + vec2<f32>(pk_jg(u * fnc, s3), pk_jg(u * fnc, s4)) * 0.035
                + vec2<f32>(pk_jg(x * 0.5, s5), pk_jg(x * 0.5, s6)) * 0.018 + vec2<f32>(pk_jg(x, s7), pk_jg(x, s8)) * 0.009;
            o = o + vec2<f32>(pk_jg(x, sj), pk_jg(x, sj ^ 0x55u)) * 0.0035 * jit;
            var P = A + AB * u + (e1 * o.x + e2 * o.y) * (L * amp * env);
            if (u > head) {
                P = mix(prev, P, (head - u0) * fn_);
            }
            let q = ray_seg(rd, prev, P);
            if (q.x < best) {
                best = q.x;
                bt = q.y;
                bu = mix(u0, min(u, head), q.z);
            }
            prev = P;
        }
    }
    if (best > 1.0e8) {
        return vec3<f32>(0.0);
    }
    let w = max(rc, bt * 0.0013);
    let en = rc / w;
    let occ = pk_occ(bt, scene_len, sky, cloud);
    let core = exp(-pow(best / (w * 0.6), 2.0)) * en;
    let glow = (exp(-best / (w * 3.5)) * 0.55 + exp(-best / (w * 14.0)) * 0.12) * en * (1.0 - smoothstep(0.4, 1.0, qc.x / margin));
    return vec3<f32>(core * occ, glow * occ, bu);
}

// The point `u` along a bolt's path (pk_bolt's, with no crackle): where a branch leaves it.
fn pk_bolt_at(A: vec3<f32>, B: vec3<f32>, u: f32, s: u32, n: i32, amp: f32) -> vec3<f32> {
    let AB = B - A;
    let L = max(length(AB), 1.0e-3);
    let D = AB / L;
    let e1 = normalize(cross(D, select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(D.y) > 0.9)));
    let e2 = cross(D, e1);
    let s1 = pcg(s ^ 0x9e3779b9u);
    let s2 = pcg(s1);
    let s3 = pcg(s2);
    let s4 = pcg(s3);
    let s5 = pcg(s4);
    let s6 = pcg(s5);
    let s7 = pcg(s6);
    let s8 = pcg(s7);
    let x = u * f32(n);
    let fnc = f32(n) / 4.0;
    let env = sqrt(max(sin(u * 3.14159265), 0.0));
    let o = vec2<f32>(pk_jg(u * fnc * 0.5, s1), pk_jg(u * fnc * 0.5, s2)) * 0.065 + vec2<f32>(pk_jg(u * fnc, s3), pk_jg(u * fnc, s4)) * 0.035
        + vec2<f32>(pk_jg(x * 0.5, s5), pk_jg(x * 0.5, s6)) * 0.018 + vec2<f32>(pk_jg(x, s7), pk_jg(x, s8)) * 0.009;
    return A + AB * u + (e1 * o.x + e2 * o.y) * (L * amp * env);
}

// How bright tower i's bolt is `et` after it set out: faint while it feels its way, a blinding stroke as it strikes the
// ring, then a held arc, flickering, struck again now and then, stuttering out when the towers cut out.
fn pk_bolt_light(et: f32, i: i32, seed: f32, time: f32) -> f32 {
    if (et <= 0.0) {
        return 0.0;
    }
    let tc = et - PK_SHOOT;
    if (tc < 0.0) {
        return 0.12 + 0.25 * smoothstep(PK_CREEP - 0.05, PK_SHOOT, et);
    }
    let s = u32(seed) + u32(i) * 977u;
    let fl = 0.72 + 0.28 * mh(u32(time * 30.0), s, 51u);
    let b = floor(time * 4.0);
    let rs = select(0.0, exp(-fract(time * 4.0) * 7.0) * 2.2, mh(u32(b), s, 52u) > 0.72 && tc > 0.6);
    let ct = time - PK_CUT - 0.08 * mh(u32(i), u32(seed), 34u);
    let end = select(1.0, step(0.45, mh(u32(time * 22.0), s, 53u)) * (1.0 + 1.5 * exp(-ct * 12.0)) * (1.0 - smoothstep(0.05, PK_DRAIN, ct)), ct > 0.0);
    return (fl + rs + 7.0 * exp(-tc * 9.0)) * end;
}

// The dust and earth tower i throws up, on the view ray up to `tmax`, its foot at F (camera-relative), `s` after it
// broke the surface: puffs of it vented round its foot each time it catches; then, as it bursts up, the bulk of the
// ground round it blown out in a surge rolling out over the land, a column of earth climbing with it and falling off it,
// and a cloud left hanging round its foot. Marched through in ten steps, lit by the day from above (its tops lit, its
// depths dark) and by `glow` near the tower. xyz the light it gives, w how much of what is behind shows through.
fn pk_dust(rd: vec3<f32>, F: vec3<f32>, s: f32, sb: f32, fi: f32, seed: f32, tmax: f32, px: vec2<f32>, amb: vec3<f32>,
           glow: vec3<f32>, time: f32) -> vec4<f32> {
    let tb = s - PK_STRUGGLE;                                   // since it burst up
    let up = tb > 0.0;
    // its foot's cloud: a little dust as the ground heaves, each catch venting more, then the bulk of it as it bursts
    let vent = 0.6 * (pk_jolt(s, 0.0, 2.0) + pk_jolt(s, 0.45, 2.5) + pk_jolt(s, 0.82, 2.5));
    let Rf = select(14.0 + 40.0 * sb + 50.0 * saturate(s / PK_STRUGGLE), 90.0 + 120.0 * (1.0 - exp(-tb * 0.5)), up);
    let Hf = select(10.0 + 14.0 * sb + 36.0 * saturate(s / PK_STRUGGLE), 80.0 + 90.0 * (1.0 - exp(-tb * 0.55)), up);
    let af = select(0.3 * sb + 0.45 * saturate(s * 2.0) + vent, 1.15 - 0.5 * smoothstep(2.0, 14.0, tb), up)
        * (1.0 - smoothstep(PK_CUT + 4.0, PK_END, time));
    // the surge rolling out, and the column of earth climbing with it
    let Rs = 60.0 + 340.0 * (1.0 - exp(-tb * 0.9));
    let aS = 26.0 + 75.0 * (1.0 - exp(-tb * 0.7));
    let as_ = select(0.0, exp(-tb / 3.5), up);
    let as2 = as_ * smoothstep(0.04, 0.12, as_);
    let Hc = 40.0 + 430.0 * (1.0 - exp(-tb * 1.4));
    let ac = select(0.0, 1.2 * exp(-max(tb - 0.8, 0.0) / 1.8), up);
    let ac2 = ac * smoothstep(0.04, 0.12, ac);
    let Rb = max(Rf * 1.05, max(select(0.0, Rs + aS * 1.4, as_ > 0.04), select(0.0, 120.0 + Hc * 0.3, ac > 0.04)));
    let Hb = max(Hf * 1.1, max(select(0.0, aS * 2.0, as_ > 0.04), select(0.0, Hc, ac > 0.04)));
    if (af + as_ + ac < 0.02) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    // where the ray is inside its bounds: an upright cylinder round its foot
    let v = rd.xz;
    let a = max(dot(v, v), 1.0e-8);
    let b = -dot(v, F.xz);
    let c = dot(F.xz, F.xz) - Rb * Rb;
    let disc = b * b - a * c;
    if (disc <= 0.0) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    var t0 = (-b - sqrt(disc)) / a;
    var t1 = (-b + sqrt(disc)) / a;
    if (abs(rd.y) > 1.0e-5) {
        let ya = (F.y - 2.0) / rd.y;
        let yb = (F.y + Hb) / rd.y;
        t0 = max(t0, min(ya, yb));
        t1 = min(t1, max(ya, yb));
    }
    t0 = max(t0, 0.0);
    t1 = min(t1, tmax);
    if (t1 <= t0) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let N = 9;
    let dt = (t1 - t0) / f32(N);
    var T = 1.0;
    var acc = vec3<f32>(0.0);
    let jit = ign(px);
    for (var k = 0; k < N; k = k + 1) {
        let q = rd * (t0 + (f32(k) + jit) * dt) - F;
        let r = length(q.xz);
        let y = max(q.y, 0.0);
        var d = af * smoothstep(1.0, 0.1, length(vec2<f32>(r / Rf, y / Hf)));
        if (up) {
            if (abs(r - Rs) < aS * 1.5 && as2 > 0.0) {
                let lump = 0.55 + 0.9 * gnoise2(vec2<f32>(atan2(q.z, q.x) * 5.0 + fi * 3.0, tb * 0.3));
                let aL = aS * lump;
                d = d + as2 * smoothstep(1.0, 0.1, length(vec2<f32>(r - Rs, y - aL * 0.55)) / aL) * smoothstep(Rs * 0.2, Rs * 0.75, r);
            }
            let Rc = 80.0 + 0.35 * y + 60.0 * (1.0 - exp(-tb * 1.2));
            d = d + ac2 * smoothstep(1.0, 0.2, r / Rc) * smoothstep(Hc, Hc * 0.5, y) * (0.6 + 0.4 * smoothstep(Hc * 0.25, 0.0, y));
        }
        // (none of it here, however the noise falls: no need to work it out)
        if (d < 0.135) {
            continue;
        }
        // (billowing: it churns and rolls out, climbing where it climbs; its edges eaten into billows, the noise only
        // taking away)
        let nq = q * 0.022 + vec3<f32>(fi * 17.0 + seed, -time * 0.3, fi * 5.0) - vec3<f32>(q.x, 0.0, q.z) * (0.005 / max(r, 1.0)) * time * 6.0;
        let n = gfbm3(nq, 2);
        d = smoothstep(0.0, 1.0, saturate((d * (0.4 + 2.2 * n) - 0.35) * 2.0));
        if (d > 0.002) {
            let al = 1.0 - exp(-d * 0.07 * dt);
            // (lit from above: its tops bright, its depths and underside dark; the tower's light on it close to it)
            let lit = amb * (0.3 + 1.0 * smoothstep(0.4, 0.8, n)) * (0.55 + 0.45 * saturate(y / max(Hf, 20.0)))
                + glow * exp(-r / 70.0);
            acc = acc + T * al * lit;
            T = T * (1.0 - al);
            if (T < 0.02) {
                break;
            }
        }
    }
    return vec4<f32>(acc, T);
}

// The mushroom of smoke over the crater `mt` after the nexus burst in it (C its foot, camera-relative), on the view ray
// up to `tmax`: a stem boiling up out of the crater into a cap that rolls over on itself as it climbs and spreads, glowing
// from under where the fire is still in it, cooling. Marched through in twelve steps. xyz the light it gives, w how much
// of what is behind shows through.
fn pk_mushroom(rd: vec3<f32>, C: vec3<f32>, mt: f32, seed: f32, tmax: f32, px: vec2<f32>, amb: vec3<f32>, time: f32) -> vec4<f32> {
    let hc = 90.0 + 640.0 * (1.0 - exp(-mt * 0.2));             // its cap's height,
    let rx = 90.0 + 340.0 * (1.0 - exp(-mt * 0.28));            // how wide,
    let ry = rx * 0.42;                                         // how deep
    let Rb = rx * 1.25;
    let Hb = hc + ry * 1.3;
    let v = rd.xz;
    let a = max(dot(v, v), 1.0e-8);
    let b = -dot(v, C.xz);
    let c = dot(C.xz, C.xz) - Rb * Rb;
    let disc = b * b - a * c;
    if (disc <= 0.0) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    var t0 = (-b - sqrt(disc)) / a;
    var t1 = (-b + sqrt(disc)) / a;
    if (abs(rd.y) > 1.0e-5) {
        let ya = (C.y - 2.0) / rd.y;
        let yb = (C.y + Hb) / rd.y;
        t0 = max(t0, min(ya, yb));
        t1 = min(t1, max(ya, yb));
    }
    t0 = max(t0, 0.0);
    t1 = min(t1, tmax);
    if (t1 <= t0) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }
    let N = 12;
    let dt = (t1 - t0) / f32(N);
    var T = 1.0;
    var acc = vec3<f32>(0.0);
    let jit = ign(px);
    let fresh = exp(-mt / 6.0);
    // (lightning flickering inside it now and then, as in a volcano's plume)
    let fb = floor(time * 9.0);
    let flick = step(0.8, fh21(vec2<f32>(fb, seed))) * exp(-mt / 8.0);
    let fq = vec3<f32>((fh21(vec2<f32>(fb, 3.0)) - 0.5) * rx, hc - ry * 0.3 + (fh21(vec2<f32>(fb, 5.0)) - 0.5) * ry, (fh21(vec2<f32>(fb, 7.0)) - 0.5) * rx);
    for (var k = 0; k < N; k = k + 1) {
        let q = rd * (t0 + (f32(k) + jit) * dt) - C;
        let r = length(q.xz);
        let y = q.y;
        // the cap: a ring rolling over on itself round a dome; the stem, wider at its foot and where it meets the cap
        let ring = length(vec2<f32>((r - rx * 0.55) / (rx * 0.5), (y - hc) / ry));
        let dome = length(vec2<f32>(r / (rx * 0.75), (y - hc - ry * 0.2) / (ry * 1.1)));
        var d = smoothstep(1.0, 0.25, min(ring, dome));
        let Rs = (36.0 + 4.5 * mt) * (1.0 + 0.7 * exp(-y / 25.0) + 0.8 * smoothstep(hc - ry * 2.5, hc - ry * 0.5, y));
        d = max(d, smoothstep(1.0, 0.3, r / Rs) * smoothstep(hc + ry * 0.2, hc - ry * 0.6, y) * 0.9);
        if (d < 0.13) {
            continue;
        }
        // (billowing: the cap rolling over, the stem climbing)
        let roll = vec3<f32>(q.x, 0.0, q.z) / max(r, 1.0);
        let nq = q * (0.9 / rx) + vec3<f32>(seed, -mt * 0.35, seed * 0.7) + roll * mt * 0.15;
        let n = gfbm3(nq * 3.0, 3);
        d = smoothstep(0.0, 1.0, saturate((d * (0.4 + 2.2 * n) - 0.35) * 2.0));
        if (d > 0.002) {
            let al = 1.0 - exp(-d * (2.4 / rx) * dt);
            // (lit from above, its depths dark; from under by the fire still in it, low in the stem and under the cap)
            let under = smoothstep(hc + ry * 0.3, hc - ry * 0.8, y) * smoothstep(0.35, 0.75, 1.0 - n);
            let glow = lava_ramp(0.35 + 0.35 * (1.0 - n)) * (exp(-max(y, 0.0) / 40.0) * 1.4 + under * 0.5) * fresh;
            let lit = amb * (0.3 + 1.0 * smoothstep(0.45, 0.85, n)) * (0.6 + 0.4 * saturate((y - hc + ry) / (2.0 * ry))) + glow
                + PK_ARC * flick * exp(-length(q - fq) / (rx * 0.35)) * 0.6;
            acc = acc + T * al * lit;
            T = T * (1.0 - al);
            if (T < 0.02) {
                break;
            }
        }
    }
    return vec4<f32>(acc, T);
}

fn planet_killer(in: StageIn) -> vec4<f32> {
    let uv = in.uv;
    let aspect = frame.resolution.x / frame.resolution.y;
    let time = now();
    let cam = frame.camera_position.xyz;
    let tgt = target_pos();
    let crel = tgt - cam;
    let k = intensity_v();
    let seed = seed_v();

    // ---- timeline -------------------------------------------------------------
    // the daylight draining away as the towers rise, back once it is over
    let dark = smoothstep(0.0, 1.5, time) * (1.0 - smoothstep(PK_POP + 1.5, PK_END, time));
    let charge = smoothstep(PK_IGN0 + PK_SHOOT, PK_MERGE, time) * f32(time < PK_FALL);
    let unstable = smoothstep(PK_SHAKE, PK_MERGE, time) * f32(time < PK_MERGE);
    let merge_t = time - PK_MERGE;
    let merged = merge_t > 0.0;
    let burn = smoothstep(PK_DROP, PK_DROP + 0.05, time) * (1.0 - smoothstep(PK_CUT + PK_DRAIN, PK_CUT + PK_DRAIN + 0.4, time));
    let hit_t = time - PK_HIT;
    let bt = time - PK_BURST;                                   // since the land burst
    let burst = bt > 0.0;
    let mt = time - PK_POP;                                     // since the nexus burst in the crater
    let popped = mt > 0.0;
    // (the screen flashes as the land bursts and as the nexus does, a little as they fuse)
    let flash = select(0.0, exp(-bt * 5.0), burst) + select(0.0, exp(-merge_t * 9.0) * 0.3, merged)
        + select(0.0, exp(-mt * 9.0) * 0.4, popped) + select(0.0, exp(-hit_t * 12.0) * 0.25, hit_t > 0.0);
    let after = 1.0 - smoothstep(PK_END - 0.5, PK_END + 2.0, time);
    // the towers' power: rising with them, full while they fire, gone once they cut out
    let power = 1.0 - smoothstep(PK_CUT, PK_CUT + 0.8, time);

    // the ring's frame: its underside turned towards the player, and two directions across it (angles round it run from re1
    // towards re2)
    let tw = wing_dirs().xy;
    let rn = normalize(vec3<f32>(-tw.x * PK_RING_TILT, 1.0, -tw.y * PK_RING_TILT));
    let re1 = normalize(cross(rn, vec3<f32>(0.0, 0.0, 1.0)));
    let re2 = cross(rn, re1);
    // the towers, and how many beams are feeding the ring
    var em: array<vec4<f32>, 7>;
    var fa: array<f32, 7>;                                      // where round the ring each beam feeds it
    var fed = 0.0;
    var lock = 0.0;                                             // a jolt of light as each bolt strikes it
    var blt: array<f32, 7>;                                     // how bright each bolt is
    var strike_fl = 0.0;                                        // the flash of the bolts striking, all together
    for (var i = 0; i < PK_N; i = i + 1) {
        em[i] = pk_emitter(i, seed);
        blt[i] = pk_bolt_light(time - em[i].w, i, seed, time) * power;
        strike_fl = strike_fl + max(blt[i] - 1.0, 0.0);
        let fv = em[i].xyz - tgt;
        fa[i] = atan2(dot(fv, re2), dot(fv, re1));
        let lt = time - em[i].w - PK_SHOOT;
        fed = fed + smoothstep(-0.1, 0.2, lt);
        lock = lock + select(0.0, exp(-lt * 7.0), lt > 0.0 && time < PK_CUT);
    }
    // the ring: round the point over the target, tipped towards the player; it tightens as they fuse, holds while it
    // feeds the beam, and crushes in to a point as they drain, which falls into the crater
    let tight = smoothstep(PK_SHAKE, PK_MERGE, time);
    let crush = saturate((time - PK_CUT - 0.1) / (PK_FALL - PK_CUT - 0.1));
    let RR = mix(PK_RING_R, PK_RING_T, tight * tight) * (1.0 + 0.015 * sin(time * 9.0) * burn) * (1.0 - crush * crush);
    let fall = saturate((time - PK_FALL) / (PK_POP - PK_FALL));
    let NX0 = crel + vec3<f32>(0.0, PK_H, 0.0) + vec3<f32>(sin(time * 41.0), sin(time * 37.0 + 1.0), cos(time * 43.0)) * 2.5 * unstable;
    let NX = NX0 - vec3<f32>(0.0, (PK_H - 6.0) * fall * fall, 0.0);       // (falling, faster and faster)
    // its middle: nothing until they fuse; then the white-hot heart the beam is fired from, and at the end the ring
    // crushed into it
    let fuse = smoothstep(PK_MERGE - 0.4, PK_MERGE, time);
    let Rn = (fuse * (6.0 + 8.0 * select(0.0, exp(-merge_t * 3.0), merged)) * (1.0 - crush) + 14.0 * crush * crush + 2.0 * lock * fuse)
        * (0.94 + 0.06 * sin(time * 31.0) + 0.04 * sin(time * 53.0)) * f32(!popped);
    // how much of it is lit and how hard: the light it throws on the land and the clouds
    let glow_n = saturate(fed / 7.0) * (0.5 + 0.7 * charge + 0.6 * burn) * (1.0 - crush) * f32(!popped);
    // energy racing round it, faster and faster as it charges, and while it burns
    let spin = time * 1.5 + 9.0 * charge * charge * charge * max(time - PK_IGN0 - PK_SHOOT, 0.0) + 6.0 * burn * max(time - PK_DROP, 0.0);

    // ---- the light and the sky ------------------------------------------------
    let sun = frame.sun.xyz;
    let day = saturate(sun.y * 2.5 + 0.35);
    let pT = project_rel(crel);
    let pN = project_rel(NX);

    // ---- what bends the light: the ring, and the shock rings running out through the land -------------------------
    let d0 = depth_at(uv);
    let sky0 = is_sky(d0);
    let p0 = cam + world_offset(uv, select(d0, 0.5, sky0));
    var off = vec2<f32>(0.0);
    if (pN.z > 0.0 && glow_n > 0.01) {
        // what is seen through the ring bent towards its middle and turned with it, harder as it charges and as it
        // shudders; a shimmer of heat in it
        let r0d = normalize(world_offset(uv, 0.5));
        let dn0 = dot(r0d, rn);
        let tp0 = dot(NX0, rn) / select(dn0, 1.0e-4, abs(dn0) < 1.0e-4);
        if (tp0 > 0.0) {
            let in_ = saturate(1.0 - length(r0d * tp0 - NX0) / max(RR, 1.0));
            let dv = uv - pN.xy;
            let tw_ = in_ * in_ * (0.04 + 0.08 * charge + 0.1 * unstable) * glow_n;
            off = off - dv * in_ * in_ * (0.05 + 0.08 * charge + 0.1 * unstable) * glow_n + vec2<f32>(-dv.y, dv.x) * tw_
                + (vec2<f32>(gnoise2(uv * 90.0 + vec2<f32>(0.0, time * 3.0)), gnoise2(uv * 90.0 + vec2<f32>(17.0, time * 2.5))) - 0.5) * 0.004 * in_ * glow_n;
            off = off * k;
        }
    }
    if (pT.z > 0.0 && !sky0) {
        let r0 = length(p0.xz - tgt.xz);
        if (burst) {
            // the land rippling as the shock runs out through it, rings of it behind the front
            let rs = pk_shock_r(bt);
            let m = (exp(-pow((r0 - rs) / 7.0, 2.0)) + 0.5 * exp(-pow((r0 - rs * 0.8) / 5.0, 2.0)) * sin(r0 * 0.15 - bt * 20.0))
                * exp(-bt * 0.4);
            off = off + normalize(uv - pT.xy + vec2<f32>(1.0e-5)) * m * 0.03 * k;
        }
        if (popped) {
            let rs = pk_pop_r(mt);
            off = off + normalize(uv - pT.xy + vec2<f32>(1.0e-5)) * exp(-pow((r0 - rs) / 6.0, 2.0)) * exp(-mt * 0.6) * 0.02 * k;
        }
    }
    for (var i = 0; i < PK_N; i = i + 1) {
        // the land rippling out from each tower as it bursts up out of it
        let rt = time - (em[i].w - PK_RAISE + PK_STRUGGLE);
        if (rt > 0.0 && rt < 2.0 && !sky0) {
            let pb_ = project_rel(em[i].xyz - cam);
            let rr = length(p0.xz - em[i].xz);
            let rs = 260.0 * sqrt(rt);
            if (pb_.z > 0.0) {
                off = off + normalize(uv - pb_.xy + vec2<f32>(1.0e-5)) * exp(-pow((rr - rs) / 14.0, 2.0)) * exp(-rt * 1.8) * 0.012 * k;
            }
        }
    }
    if (burn > 0.001 && pT.z > 0.0) {
        // the air boiling round the beam's foot
        let m = exp(-length((uv - pT.xy) * vec2<f32>(aspect, 1.0)) / 0.1);
        let hw = vec2<f32>(gnoise2(uv * vec2<f32>(120.0, 45.0) + vec2<f32>(0.0, -time * 8.0)), gnoise2(uv * vec2<f32>(120.0, 45.0) + vec2<f32>(31.0, -time * 7.0))) - 0.5;
        off = off + hw * 0.006 * m * burn * k;
    }
    let uv2 = clamp(uv + off, vec2<f32>(0.002), vec2<f32>(0.998));

    // ---- the scene ------------------------------------------------------------
    let d = depth_at(uv2);
    var sky = is_sky(d);
    var solid = false;                                          // (a tower is what is seen here)
    let rel = world_offset(uv2, select(d, 0.5, sky));
    var scene_len = select(1.0e9, length(rel), !sky);
    let rd = normalize(world_offset(uv2, 0.5));
    let rdb = normalize(world_offset(uv, 0.5));                // not bent
    let P = cam + rel;
    var cloud = !sky && abs(P.y - CLOUD_Y - 2.0) < 6.0;
    let ca = flash * 0.015 * k;
    let ca_dir = (uv2 - vec2<f32>(0.5)) * ca;
    var col = srgb_to_linear(vec3<f32>(
        textureSampleLevel(scene_color, linear_sampler, uv2 + ca_dir, 0.0).r,
        textureSampleLevel(scene_color, linear_sampler, uv2, 0.0).g,
        textureSampleLevel(scene_color, linear_sampler, uv2 - ca_dir, 0.0).b));
    // the sky goes to a deep night blue, a band of light along the horizon while the towers fire; the land dark
    let night = vec3<f32>(0.004, 0.007, 0.022) + vec3<f32>(0.03, 0.05, 0.16) * exp(-abs(rd.y) / 0.06) * power * saturate(time - PK_IGN0);
    if (sky) {
        col = mix(col, night, 0.88 * dark * k);
    } else {
        col = col * (1.0 - 0.62 * dark * k);
    }
    // the clouds blown open from under the ring as they fuse, a rim of light running out round the hole
    if (cloud && merged) {
        let dcl = length(P.xz - (NX + cam).xz);
        let Rh = 1100.0 * (1.0 - exp(-merge_t * 0.9));
        col = mix(col, night * dark + vec3<f32>(0.2, 0.3, 0.5) * (1.0 - dark), smoothstep(Rh, Rh - 90.0, dcl) * 0.95 * k);
        col = col + PK_HOT * exp(-pow((dcl - Rh) / 45.0, 2.0)) * 0.5 * exp(-merge_t * 0.5) * k;
    }
    var add = vec3<f32>(0.0);

    // ---- the towers: the ground over each heaving and splitting, light leaking up through the cracks; the tower
    //      breaking the surface and struggling there, straining, catching, shuddering, leaning, puffs of dust venting
    //      round it; then bursting up out of it, the ground round it blown out in a surge of dust and a column of earth
    //      climbing with it, rock flung out; dark armoured metal, tiered, buttressed, power running up its seams, its
    //      crown's emitter crackling before it fires. Solid: the nearest of them (or of their heaving ground) is drawn
    //      over what is behind it, and hides it, and anything nearer (the land, the dust) hides it.
    var tS: array<vec4<f32>, 7>;                                // where each stands (shaking) and how far it has risen
    var tst: array<vec4<f32>, 7>;                               // s, its ground's heave, its power, its seams waking
    var near_t = scene_len;
    var near_col = vec3<f32>(0.0);
    var near_add = vec3<f32>(0.0);
    var near_a = 0.0;
    let hazec = srgb_to_linear(frame.fog_color.rgb) * (0.3 + 0.7 * day) * (1.0 - 0.8 * dark);
    let amb_t = mix(vec3<f32>(0.012, 0.018, 0.045), vec3<f32>(0.2, 0.24, 0.32), day) * (1.0 - 0.7 * dark);
    let sun_c = vec3<f32>(1.6, 1.5, 1.35) * day * (1.0 - 0.85 * dark);
    for (var i = 0; i < PK_N; i = i + 1) {
        let e = em[i];
        let fi = f32(i);
        let r0 = e.w - PK_RAISE;                                // when it breaks the surface
        let bt0 = time - (r0 - PK_BULGE);                       // since its ground began to heave
        tS[i] = vec4<f32>(e.xyz - cam, 0.0);
        tst[i] = vec4<f32>(-99.0, 0.0, 0.0, 0.0);
        if (bt0 <= 0.0) {
            continue;
        }
        let s = time - r0;
        let tb = s - PK_STRUGGLE;                               // since it burst up
        let rz = pk_rise(s);
        let S0 = e.xyz - cam;
        let ds = length(S0);
        let sdir = S0 / ds;
        let et = time - e.w;
        let c = 1.0 - dot(rd, sdir);
        let sb = smoothstep(0.0, PK_BULGE, bt0);
        // it shudders, the ground under it trembling as it heaves; it leans as it struggles, and straightens as it
        // bursts up; once it has cut out it sinks back, slowly at first
        let shk = rz.y + 0.5 * sb * f32(s < 0.0);
        let S = S0 + vec3<f32>(sin(time * 43.0 + fi * 1.3) + 0.5 * sin(time * 71.0 + fi), 0.0, sin(time * 37.0 + fi * 2.1) + 0.5 * sin(time * 67.0 + fi * 0.7)) * shk * 0.6;
        let la = mh(u32(i), u32(seed), 35u) * TAU;
        let lean = vec2<f32>(cos(la), sin(la)) * ((0.05 + 0.02 * mh(u32(i), u32(seed), 36u)) * (1.0 - smoothstep(PK_STRUGGLE, PK_STRUGGLE + 0.6, s)) + 0.004 * shk) * f32(s > 0.0);
        let sk = saturate((time - PK_CUT - 1.5) / 3.5);
        let lift = PK_TOWER_H * rz.x * (1.0 - sk * sk) + sin(time * 31.0) * shk * 0.3 * f32(s > 0.0);
        let lit = smoothstep(-0.5, 0.15, et) * power;
        let wake = smoothstep(0.0, 0.5, tb) * power;              // (its seams waking as it bursts up)
        let fire_ = select(0.0, exp(-(et - PK_SHOOT) * 2.2), et > PK_SHOOT);
        tS[i] = vec4<f32>(S, lift);
        tst[i] = vec4<f32>(s, sb, lit, wake);
        // (the horizon round it lit by its crown, a little, along the horizon more than above it)
        let low = exp(-abs(rd.y - sdir.y - 0.05) / 0.07);
        add = add + PK_ARC * (exp(-c / 0.004) * 0.6 + exp(-c / 0.02) * 0.08) * low * (0.5 * fire_ + 0.08 * lit) * select(0.15, 1.0, sky || scene_len > ds * 0.6) * k;
        // (only near it)
        if (ray_seg(rd, S0, S0 + vec3<f32>(0.0, PK_TOWER_H + 30.0, 0.0)).x > PK_TB * 1.5 + 60.0) {
            continue;
        }
        let haze = 1.0 - exp(-ds / 6000.0);
        // its ground heaving up before it breaks, split by cracks with light leaking up through them, then broken open
        // round it while it struggles, until it bursts out
        if (tb < 0.3) {
            let Rd = 150.0;
            let Cd = S0 + vec3<f32>(0.0, (34.0 * sb * sb + 8.0 * saturate(s / PK_STRUGGLE)) - Rd, 0.0);
            let tcd = dot(Cd, rd);
            let dc2 = dot(Cd, Cd) - tcd * tcd;
            if (tcd > 0.0 && dc2 < Rd * Rd) {
                let td = tcd - sqrt(Rd * Rd - dc2);
                let pd = rd * td - Cd;
                if (pd.y + Cd.y - S0.y > -0.5 && (sky || td < scene_len + 6.0) && td < near_t) {
                    let nd = pd / Rd;
                    let ang = atan2(nd.z, nd.x);
                    // (the land itself lifted, shaded by its slope; split by cracks no thinner than a pixel, the ground
                    // round them torn up dark, light leaking up out of them)
                    let pw = td * 0.0013 / 5.0;
                    let w1 = max(0.007, pw * 0.7);
                    let w2 = max(0.005, pw * 0.5);
                    let cn = abs(gnoise2(vec2<f32>(ang * 9.0, nd.y * 30.0) + vec2<f32>(fi * 5.0)) - 0.5);
                    let cn2 = abs(gnoise2(vec2<f32>(ang * 23.0, nd.y * 70.0) + vec2<f32>(fi * 3.0, 9.0)) - 0.5);
                    let open = sb * (1.0 - smoothstep(0.0, 0.3, tb));
                    let cracks = (exp(-cn / w1) * pow(0.007 / w1, 1.5) + 0.5 * exp(-cn2 / w2) * pow(0.005 / w2, 1.5) * saturate(s * 2.0)) * open;
                    let torn = (exp(-cn / (w1 * 6.0)) * 0.7 + smoothstep(0.985, 0.995, nd.y) * saturate(s * 3.0)) * open;
                    let slope = 0.55 + 0.6 * saturate(dot(nd, normalize(vec3<f32>(0.3, 1.0, 0.2))));
                    let land = vec3<f32>(0.12, 0.15, 0.08) * (0.25 + 0.75 * day) * (1.0 - 0.55 * dark) * slope;
                    let dome = mix(land, vec3<f32>(0.06, 0.048, 0.038) * (0.3 + 0.6 * day) * (1.0 - 0.5 * dark), saturate(torn));
                    near_t = td;
                    // (as hazy with distance as the land round it: it is the land)
                    near_col = mix(dome, col, saturate(td / 2500.0) * 0.85);
                    near_add = pk_heat(0.45 + 0.35 * saturate(cracks)) * cracks * (0.4 + 1.2 * saturate(s)) * k;
                    near_a = open;
                }
            }
        }
        if (lift > 1.0) {
            let rot = fi * 0.9 + mh(u32(i), u32(seed), 37u) * 1.0;
            pk_lift_g = lift;
            pk_heap_g = smoothstep(0.0, 0.4, tb) * (1.0 - smoothstep(PK_CUT + 2.0, PK_CUT + 6.0, time));
            let th = pk_tower(S, lift, lean, rot, rd, near_t);
            if (th.x > 0.0) {
                let X = rd * th.x;
                let q = pk_tlocal(X, S, lift, lean, rot);
                let nl = pk_tnormal(q, max(0.4, th.x * 0.0008));
                let cr = cos(rot);
                let sr = sin(rot);
                let n = normalize(vec3<f32>(cr * nl.x + sr * nl.z, nl.y, -sr * nl.x + cr * nl.z));
                let m = th.y;
                let yp = q.y;
                // (the panels of its hull: on each face of the six, plates in courses, each a little different, the
                // joints between them dark; their face-local place)
                let qf = pk_fold(q.xz, 6.0, 0.5235988);
                let course = floor(yp / 17.0);
                let pu = qf.y / 13.0 + 0.5 * (course - 2.0 * floor(course / 2.0));
                let groove = max(smoothstep(0.45, 0.49, abs(fract(pu) - 0.5)), smoothstep(0.46, 0.49, abs(fract(yp / 17.0) - 0.5))) * f32(m < 0.5 || m > 2.5);
                let plate = fh21(vec2<f32>(floor(pu) + floor(atan2(q.z, q.x) * 0.955) * 17.0, course + fi * 31.0));
                // (some plates inset, darker, a slit of light across them)
                let inset = step(0.8, plate) * f32(m < 0.5) * step(PK_T0, yp);
                var alb = vec3<f32>(0.042, 0.046, 0.056) * (0.7 + 0.6 * plate) * (1.0 - 0.6 * groove) * (1.0 - 0.5 * inset);
                if (m > 0.5 && m < 1.5) {
                    alb = vec3<f32>(0.065, 0.066, 0.072);                  // collars and ribs: heavier, brighter metal
                } else if (m > 1.5 && m < 2.5) {
                    alb = vec3<f32>(0.06, 0.062, 0.075);                   // the crown
                } else if (m > 2.5 && m < 3.5) {
                    alb = vec3<f32>(0.038, 0.04, 0.05) * (0.85 + 0.3 * plate); // the buttresses
                } else if (m > 5.5) {
                    alb = vec3<f32>(0.075, 0.062, 0.05) * (0.6 + 0.6 * gnoise2(q.xz * 0.3));   // the broken ground
                }
                // lit by the sky, the sun, the ring, the beam, and its own emitter; its hollows shadowed
                let ao = 0.3 + 0.7 * saturate(pk_tsdf(q + nl * 6.0).x / 6.0);
                let L = frame.sun.xyz;
                let Lr = normalize(NX - X);
                let Lb = normalize(crel - X);
                let qe = vec3<f32>(0.0, PK_CORE_Y, 0.0) - q;
                let de2 = dot(qe, qe);
                let emi = (0.3 * lit + 3.0 * fire_ + 0.1 * wake) * 900.0 / (900.0 + de2) * max(dot(nl, qe * inverseSqrt(de2)), 0.0);
                let ringc = pk_heat(0.55) * glow_n * 0.4 + vec3<f32>(0.5, 0.7, 1.2) * burn * 0.3;
                let diff = amb_t * (0.35 + 0.65 * n.y) + sun_c * max(dot(n, L), 0.0) + pk_heat(0.55) * glow_n * 0.22 * max(dot(n, Lr), 0.0)
                    + vec3<f32>(0.5, 0.7, 1.2) * burn * 0.3 * max(dot(n, Lb), 0.0) + PK_HOT * emi;
                let spec = sun_c * pow(max(dot(n, normalize(L - rd)), 0.0), 48.0) * 0.35 + ringc * pow(max(dot(n, normalize(Lr - rd)), 0.0), 24.0) * 0.6;
                let rim = pow(1.0 - max(dot(n, -rd), 0.0), 5.0) * select(1.0, 0.15, m > 5.5);
                var tc = alb * diff * ao * (0.6 + 0.4 * smoothstep(0.0, 200.0, yp)) + spec * ao * (1.0 - 0.6 * groove) + (amb_t * 1.5 + PK_DEEP * 0.12 * (0.2 + lit)) * rim * ao;
                // power: in the seams over the joints, up the middle of some of the hull's plates in runs, along the
                // buttresses' edges, round the ring plate, surging; the emitter blazing as it fires
                let yj = PK_T0 + clamp(round((yp - PK_T0) / PK_TIER), 1.0, 5.0) * PK_TIER;
                let surge = 0.3 + pow(0.5 + 0.5 * sin(yp * 0.03 - time * 10.0 + fi), 6.0) * 1.8;
                let run = step(0.55, fh21(vec2<f32>(floor(yp / 23.0) + floor(atan2(q.z, q.x) * 0.955) * 7.0, fi + seed)));
                var glow = 0.0;
                if (m < 0.5) {
                    glow = exp(-pow((yp - yj - 3.6) / 0.8, 2.0)) * 0.7 + exp(-pow(qf.y / 0.7, 2.0)) * run * step(PK_T0, yp) * 0.6
                        + inset * exp(-pow((fract(yp / 17.0) - 0.5) / 0.04, 2.0)) * 0.5;
                } else if (m > 2.5 && m < 3.5) {
                    let q3 = pk_fold(q.xz, 3.0, 0.0);
                    glow = exp(-pow((104.0 - 0.38 * yp - q3.x) / 1.2, 2.0)) * smoothstep(0.0, 20.0, yp) * 0.9;
                } else if (m > 1.5 && m < 2.5) {
                    glow = exp(-pow((length(q.xz) - 37.0) / 1.0, 2.0)) * smoothstep(356.0, 350.0, yp) * 1.2 + exp(-pow((length(q.xz) - 25.0) / 1.0, 2.0)) * smoothstep(356.0, 350.0, yp) * 0.6;
                }
                if (m > 5.5) {
                    let cn = abs(gnoise2(q.xz * 0.12 + vec2<f32>(fi * 7.0)) - 0.5);
                    glow = exp(-cn / 0.015) * 0.35 * (1.0 - smoothstep(0.0, 6.0, tb));
                }
                var em_ = PK_HOT * glow * surge * (0.12 * wake + lit) * 0.9;
                if (m > 4.5 && m < 5.5) {
                    em_ = PK_WHITE * (0.15 * wake + 0.8 * lit + 2.5 * fire_) + PK_HOT * (0.3 * wake + lit) * (0.6 + 0.4 * rim);
                    tc = vec3<f32>(0.02, 0.03, 0.06);
                }
                // (caked in earth where it came up through the ground as it struggled, the earth falling away in streaks
                // once it has burst up)
                let crust_top = PK_TOWER_H - 0.17 * PK_TOWER_H;
                let streak = gnoise2(vec2<f32>(atan2(q.z, q.x) * 11.0, yp * 0.012 + fi));
                let earth = saturate(smoothstep(crust_top - 30.0, crust_top + 10.0, yp) * select(1.0, saturate(1.0 - tb * 0.35 - (1.0 - streak) * 0.7), tb > 0.0)
                    + smoothstep(90.0, 0.0, yp) * 0.7) * 0.9 * f32(m < 5.5);
                tc = mix(tc, vec3<f32>(0.07, 0.056, 0.042) * (0.6 + 0.5 * streak) * (0.3 + 0.6 * day) * (1.0 - 0.4 * dark) * (0.5 + 0.5 * ao), earth);
                em_ = em_ * (1.0 - earth);
                near_t = th.x;
                near_col = mix(tc, hazec, haze);
                near_add = em_ * (1.0 - haze * 0.7) * k;
                near_a = 1.0;
            }
        }
    }
    if (near_a > 0.0) {
        col = mix(col, near_col, near_a);
        add = add * (1.0 - near_a) + near_add;
        scene_len = near_t;
        if (near_a > 0.5) {
            sky = false;
            cloud = false;
            solid = true;
        }
    }
    // what each throws up, and its crown, the furthest first, each cut by what is in front of it
    var order: array<i32, 7>;
    for (var i = 0; i < PK_N; i = i + 1) {
        order[i] = i;
    }
    for (var i = 0; i < PK_N; i = i + 1) {
        for (var j = i + 1; j < PK_N; j = j + 1) {
            if (dot(tS[order[j]].xyz, tS[order[j]].xyz) > dot(tS[order[i]].xyz, tS[order[i]].xyz)) {
                let o = order[i];
                order[i] = order[j];
                order[j] = o;
            }
        }
    }
    for (var oi = 0; oi < PK_N; oi = oi + 1) {
        let i = order[oi];
        let st = tst[i];
        let s = st.x;
        if (s < -PK_BULGE - 0.5) {
            continue;
        }
        let fi = f32(i);
        let S0 = em[i].xyz - cam;
        let S = tS[i].xyz;
        let lift = tS[i].w;
        let sb = st.y;
        let lit = st.z;
        let wake = st.w;
        let tb = s - PK_STRUGGLE;
        let et = time - em[i].w;
        let fire_ = select(0.0, exp(-(et - PK_SHOOT) * 2.2), et > PK_SHOOT);
        // (only near it: what it throws up climbs some 600 blocks and spreads 400 round it)
        if (ray_seg(rd, S0, S0 + vec3<f32>(0.0, 650.0, 0.0)).x > 480.0) {
            continue;
        }
        // the dust it throws up (cut by the land and by the towers)
        let amb = vec3<f32>(0.4, 0.36, 0.31) * (0.15 + 0.85 * day) * (1.0 - 0.6 * dark) + PK_DEEP * 0.03 * lit;
        let dg = PK_HOT * (0.05 * lit + 0.06 * wake * exp(-max(tb, 0.0))) + lava_ramp(0.4) * 0.05 * f32(s > 0.0) * exp(-max(s, 0.0) * 0.8);
        let du = pk_dust(rd, S0, s, sb, fi, seed, select(scene_len, 1.0e9, sky), in.position.xy, amb, dg, time);
        col = col * du.w + du.xyz * k + col * (1.0 - k) * (1.0 - du.w);
        add = add * mix(1.0, du.w, 0.85);
        // rock flung up and out as it bursts through, falling back (dark against the sky)
        if (tb > 0.0 && tb < 6.0 && ray_seg(rd, S0, S0 + vec3<f32>(0.0, 130.0 * tb, 0.0)).x < 100.0 * tb + 60.0) {
            for (var j = 0; j < 14; j = j + 1) {
                let hv = vec3<f32>(pcg3d(vec3<u32>(u32(j), u32(i), u32(seed)))) * (1.0 / 4294967295.0);
                let az = hv.x * TAU;
                let vh = 25.0 + 70.0 * hv.y;
                let vy = 45.0 + 85.0 * hv.z * hv.z;
                let s3 = S0 + vec3<f32>(cos(az) * 40.0, 6.0, sin(az) * 40.0);
                let a1 = max(tb - 0.05, 0.0);
                let pa = s3 + vec3<f32>(cos(az) * vh * tb, vy * tb - 16.0 * tb * tb, sin(az) * vh * tb);
                let pb = s3 + vec3<f32>(cos(az) * vh * a1, vy * a1 - 16.0 * a1 * a1, sin(az) * vh * a1);
                if (pa.y < S0.y - 2.0) {
                    continue;
                }
                let qj = ray_seg(rd, pa, pb);
                let wj = 2.0 + 4.5 * hv.y;
                let cov = smoothstep(1.0, 0.5, qj.x / max(wj, qj.y * 0.0013)) * (wj / max(wj, qj.y * 0.0013));
                let vj = select(1.0, 1.0 - smoothstep(scene_len - 1.0, scene_len + 1.0, qj.y), !sky);
                col = mix(col, vec3<f32>(0.035, 0.03, 0.026) * (0.4 + 0.6 * day), cov * vj);
                add = add * (1.0 - cov * vj * 0.8);
            }
        }
        // its emitter: blazing as it fires, and before it fires the charge crawling over its crown, crackling
        let tip = S + vec3<f32>(0.0, lift - PK_TOWER_H + PK_CORE_Y, 0.0);
        let ct = 1.0 - dot(rd, normalize(tip));
        add = add + (PK_WHITE * exp(-ct / 3.0e-6) * 0.6 + PK_HOT * exp(-ct / 6.0e-5) * 0.4) * (lit + 2.0 * fire_)
            * pk_occ(length(tip) - 12.0, scene_len, sky, cloud) * k;
        let corona = smoothstep(-0.7, -0.1, et) * (1.0 - smoothstep(PK_SHOOT, PK_SHOOT + 0.5, et)) * power;
        if (corona > 0.01) {
            for (var j = 0; j < 2; j = j + 1) {
                let sj = pcg(u32(seed) + u32(i) * 131u + u32(j) * 7u + u32(time * 16.0) * 1009u);
                let hv = vec3<f32>(pcg3d(vec3<u32>(sj, 3u, 5u))) * (1.0 / 4294967295.0);
                let a0 = tip + vec3<f32>(0.0, 6.0 * hv.x, 0.0);
                let dir = normalize(vec3<f32>(cos(hv.y * TAU), 0.6 * hv.z - 0.1, sin(hv.y * TAU)));
                let bo = pk_bolt(rd, a0, a0 + dir * (30.0 + 30.0 * hv.z), 1.0, sj, 6, 1.6, 0.0, 0.5, time, scene_len, sky, cloud);
                add = add + (PK_WHITE * bo.x * 0.8 + PK_HOT * bo.y) * corona * k;
            }
        }
    }

    // ---- on the land: lit by the ring and the beam, the shock rings, the crater and the fissures molten ----------
    let rel2 = P.xz - tgt.xz;
    let r = length(rel2);
    let dy = P.y - tgt.y;
    if (!sky && !solid) {
        let on_ground = 1.0 - smoothstep(25.0, 40.0, dy);
        // the ring lights the land under it, a ring of blue light on it, falling off from its nearest point
        let pr = P - cam - NX0;
        let pp = pr - rn * dot(pr, rn);
        let ql = pr - pp / max(length(pp), 1.0e-3) * RR;
        col = col + col * vec3<f32>(0.45, 0.6, 0.95) * glow_n * 50000.0 / (dot(ql, ql) + 60000.0) * k;
        // the bolts lighting the land under them, blinding as each strikes
        for (var i = 0; i < PK_N; i = i + 1) {
            if (blt[i] > 0.01) {
                let A = em[i].xyz - cam + vec3<f32>(0.0, PK_TOWER_H, 0.0);
                let F = NX0 + (re1 * cos(fa[i]) + re2 * sin(fa[i])) * RR;
                let ab = F - A;
                let pa = P - cam - A;
                let dl = length(pa - ab * saturate(dot(pa, ab) / dot(ab, ab)));
                col = col + col * vec3<f32>(0.8, 0.85, 1.1) * blt[i] * 0.2 / (1.0 + dl * dl / 90000.0) * k;
            }
        }
        // the beam hard on the land round its foot
        col = col + col * vec3<f32>(1.6, 2.2, 3.6) * burn * 22000.0 / (r * r + dy * dy + 7500.0) * k;
        if (charge > 0.0 && hit_t < 0.5) {
            // charging: the ground under the ring glowing with the charge gathering in it, flickering
            let fade = 1.0 - smoothstep(0.0, 0.5, hit_t);
            let fl = 0.6 + 0.4 * mh(u32(time * 24.0), u32(seed), 61u);
            add = add + PK_ARC * exp(-r / 24.0) * charge * charge * 0.5 * fl * on_ground * fade * k;
        }
        if (burst) {
            // the shock ring racing out over the land, kicking up dust as it goes
            let rs = pk_shock_r(bt);
            // (a flash along it at first; then only the dust it lifts, pale on its leading edge)
            add = add + (PK_HOT * 0.6 + vec3<f32>(1.2, 1.0, 0.8)) * exp(-pow((r - rs) / 4.0, 2.0)) * exp(-bt * 3.0) * on_ground * k;
            col = mix(col, vec3<f32>(0.3, 0.27, 0.24) * (0.3 + 0.7 * day) * (1.0 - 0.5 * dark), exp(-pow((r - rs + 8.0) / 14.0, 2.0)) * 0.45 * exp(-bt * 0.35) * on_ground * k);
            let behind = smoothstep(rs, rs - 30.0, r) * smoothstep(rs - 160.0, rs - 50.0, r) * exp(-bt * 0.3);
            col = mix(col, vec3<f32>(0.16, 0.13, 0.11) * (0.3 + 0.7 * day) * (1.0 - 0.6 * dark), behind * 0.55 * on_ground * k);
        }
        if (popped) {
            let rs = pk_pop_r(mt);
            add = add + PK_HOT * exp(-pow((r - rs) / 3.0, 2.0)) * exp(-mt * 3.0) * 0.8 * on_ground * k;
            col = mix(col, vec3<f32>(0.3, 0.27, 0.24) * (0.3 + 0.7 * day) * (1.0 - 0.5 * dark), exp(-pow((r - rs + 6.0) / 10.0, 2.0)) * 0.35 * exp(-mt * 0.5) * on_ground * k);
        }
        if (burst && r < PK_BOWL * 1.12) {
            // the crater glowing where it has just been dug (each part of it as it is opened, from the middle out,
            // cooling), hotter the deeper; the magma strewn over its floor (more of it in towards the shaft) and over the
            // bedrock at the foot of the shaft glowing on in patches (strike.rs strews it so: no lake, only rock); round
            // the foot of the beam everything white-hot
            let deep = max(-dy, 0.0);
            let dug = time - pk_dig_t(r);
            let open = pk_open(rel2, r, time, seed);
            let fresh = exp(-max(dug, 0.0) / 7.0) * smoothstep(1.0, 3.0, deep) * open;
            let core = saturate((deep - 30.0) / 60.0) * open;
            let pn = gnoise2(rel2 * 0.11 + vec2<f32>(seed, 0.0));
            let hotf = saturate(1.0 - (r - PK_SHAFT) / (PK_BOWL - PK_SHAFT));
            let th = 0.66 - 0.22 * hotf * hotf;
            let mpatch = smoothstep(th, th + 0.1, pn) * smoothstep(PK_WALL_D * 0.6, PK_WALL_D, deep) * open;
            let bottom = smoothstep(PK_SHAFT_D - 16.0, PK_SHAFT_D - 4.0, deep) * smoothstep(0.42, 0.56, pn) * open;
            let heat = max(max(fresh * 0.85, core * 0.6), max(mpatch * 0.8, bottom * 0.9)) * (1.0 - smoothstep(PK_BOWL * 0.98, PK_BOWL * 1.1, r))
                + burn * exp(-r / 35.0);
            let n = gfbm2(rel2 * 0.06 + vec2<f32>(P.y * 0.2 + time * 0.05, seed));
            let veins = exp(-pow((n - 0.5) / 0.07, 2.0));
            let molten = mix(veins * 0.9, 1.0, saturate(heat * heat + max(mpatch, bottom)));
            let hh = heat * molten * (0.8 + 0.4 * gnoise2(rel2 * 0.15 + vec2<f32>(time * 0.3, P.y)));
            add = add + lava_ramp(hh) * smoothstep(0.03, 0.25, heat * molten) * on_ground * after * 2.6 * k;
        }
        // the fissures running out from the rim, opening as the shock reaches them, light pulsing out along them
        // (in from the rim too, across the land not dug yet, up to the crater's real edge)
        let unopened = 1.0 - pk_open(rel2, r, time, seed);
        if (burst && r > PK_SHAFT && r < PK_RIM + 170.0 && unopened > 0.01) {
            let ang = atan2(rel2.y, rel2.x);
            var crack = 0.0;
            var pulse = 0.0;
            // (each fissure keeps to its own twelfth of the way round, give or take, so only the three nearest are looked at)
            let base = mh(99u, u32(seed), 22u) * TAU;
            let x = (ang - base) / (TAU / f32(PK_CRACKS));
            let i0 = i32(floor(x - floor(x / f32(PK_CRACKS)) * f32(PK_CRACKS)));
            for (var di = -1; di <= 1; di = di + 1) {
                let i = (i0 + di + PK_CRACKS) % PK_CRACKS;
                let cr = pk_crack(i, seed);
                let u = max(r - PK_RIM, 0.0);
                if (u > cr.y) {
                    continue;
                }
                let j = i32(floor(u / PK_SEG));
                let f = fract(u / PK_SEG);
                let a = cr.x + mix(pk_crack_off(i, j, seed), pk_crack_off(i, j + 1, seed), f);
                var da = ang - a;
                da = da - TAU * floor(da / TAU + 0.5);
                let lat = abs(da) * r;
                let hw = 1.0 + 4.5 * (1.0 - u / cr.y);
                let open = saturate((pk_crack_front(bt) - u) / 6.0);
                let c1 = ((1.0 - smoothstep(hw - 0.4, hw + 0.8, lat)) + exp(-lat / (hw * 2.5)) * 0.35) * open;
                if (c1 > crack) {
                    crack = c1;
                    pulse = pow(0.5 + 0.5 * sin(u * 0.1 - time * 5.0 + f32(i)), 4.0);
                }
            }
            crack = crack * unopened;
            if (crack > 0.01) {
                let hh = (0.55 + 0.35 * exp(-bt / 14.0) + 0.25 * pulse * power) * (0.85 + 0.3 * gnoise2(rel2 * 0.3 + vec2<f32>(time * 0.3, 0.0)));
                add = add + (lava_ramp(hh) + PK_HOT * pulse * 0.4 * power) * crack * on_ground * after * 2.2 * k;
            }
        }
    }
    // the clouds lit from above by the ring, from below by the beam
    if (cloud) {
        let pr = P - cam - NX0;
        let pp = pr - rn * dot(pr, rn);
        let dn = length(pr - pp / max(length(pp), 1.0e-3) * RR);
        add = add + pk_heat(0.4) * (glow_n * 0.45 * exp(-dn / 140.0) + burn * 0.12 * exp(-length(rel2) / 80.0)) * k;
        for (var i = 0; i < PK_N; i = i + 1) {
            if (blt[i] > 0.01) {
                let A = em[i].xyz - cam + vec3<f32>(0.0, PK_TOWER_H, 0.0);
                let F = NX0 + (re1 * cos(fa[i]) + re2 * sin(fa[i])) * RR;
                let ab = F - A;
                let pa = P - cam - A;
                let dl = length(pa - ab * saturate(dot(pa, ab) / dot(ab, ab)));
                add = add + vec3<f32>(0.5, 0.6, 1.2) * blt[i] * 0.35 / (1.0 + dl * dl / 40000.0) * k;
            }
        }
    }

    // ---- the land doming up under the beam, cracking with the light inside it, before it bursts --------------------
    if (hit_t > 0.0 && !burst) {
        let s = pow(saturate(hit_t / (PK_BURST - PK_HIT)), 2.2);
        let Rd = 40.0 + 140.0 * s;
        let Cd = crel - vec3<f32>(0.0, Rd * 0.62, 0.0);
        let tcd = dot(Cd, rd);
        let dc2 = dot(Cd, Cd) - tcd * tcd;
        // (not from under it: the player standing on it would be lifted with it)
        if (tcd > 0.0 && dc2 < Rd * Rd && dot(Cd, Cd) > Rd * Rd) {
            let td = tcd - sqrt(Rd * Rd - dc2);
            let pd = rd * td - Cd;
            if (pd.y + Cd.y - crel.y > -1.0 && (sky || td < scene_len + 4.0)) {
                let nd = pd / Rd;
                let ang = atan2(nd.z, nd.x);
                // (the land itself heaved up, shaded by its slope, split by cracks no thinner than a pixel, white-hot
                // light inside them, the ground torn dark along them)
                let pw = td * 0.0013 / max(Rd / 6.0, 1.0);
                let w1 = max(0.012, pw * 0.7);
                let w2 = max(0.008, pw * 0.5);
                let cn = abs(gnoise2(vec2<f32>(ang * 4.0, nd.y * 6.0) + vec2<f32>(seed)) - 0.5);
                let cn2 = abs(gnoise2(vec2<f32>(ang * 11.0, nd.y * 15.0) + vec2<f32>(seed + 7.0)) - 0.5);
                let cracks = (exp(-cn / w1) * pow(0.012 / w1, 1.5) + 0.6 * exp(-cn2 / w2) * pow(0.008 / w2, 1.5)) * smoothstep(0.1, 0.8, s);
                let torn = exp(-cn / (w1 * 5.0)) * smoothstep(0.0, 0.6, s);
                let top = exp(-(1.0 - nd.y) * 14.0);
                let slope = 0.5 + 0.7 * saturate(dot(nd, normalize(vec3<f32>(0.3, 1.0, 0.2))));
                let land = vec3<f32>(0.12, 0.15, 0.08) * (0.25 + 0.75 * day) * (1.0 - 0.55 * dark) * slope * (1.0 + 1.2 * max(nd.y, 0.0) * glow_n);
                col = mix(land, vec3<f32>(0.05, 0.04, 0.035) * (0.3 + 0.6 * day), saturate(torn));
                add = (mix(lava_ramp(0.55 + 0.4 * saturate(cracks)), PK_WHITE * 0.15, 0.3) * cracks * 2.5 + PK_HOT * top * 1.5 * s) * k;
                scene_len = min(scene_len, td);
            }
        }
    }

    // ---- the wall of dust thrown out round it, racing over the land and climbing ------------------------------------
    if (burst && bt < 18.0) {
        let Rw = 120.0 + 520.0 * (1.0 - exp(-bt * 0.3));
        let Hw = 30.0 + 170.0 * (1.0 - exp(-bt * 0.45));
        let c2 = cam.xz - tgt.xz;
        let v2 = rd.xz;
        let a2 = dot(v2, v2);
        let b2 = dot(c2, v2);
        let disc = b2 * b2 - a2 * (dot(c2, c2) - Rw * Rw);
        if (a2 > 1.0e-6 && disc > 0.0) {
            let sq = sqrt(disc);
            var dust = 0.0;
            for (var s = 0; s < 2; s = s + 1) {
                let tw = (-b2 + select(-sq, sq, s == 1)) / a2;
                if (tw <= 0.0 || (!sky && tw > scene_len)) {
                    continue;
                }
                let pw = cam + rd * tw;
                let hy = pw.y - tgt.y;
                let aw = atan2(pw.z - tgt.z, pw.x - tgt.x);
                let n = gfbm2(vec2<f32>(aw * 7.0 + seed, hy * 0.03 - bt * 0.3));
                let top = Hw * (0.55 + 0.8 * n);
                dust = max(dust, smoothstep(top, top * 0.3, hy) * smoothstep(-6.0, 2.0, hy) * (0.5 + 0.6 * n));
            }
            let fade = exp(-bt / 4.0) * smoothstep(0.0, 0.3, bt);
            let lit = vec3<f32>(0.2, 0.18, 0.16) * (0.25 + 0.75 * day) * (1.0 - 0.6 * dark) + vec3<f32>(0.2, 0.28, 0.5) * burn * 0.6 * exp(-Rw / 500.0);
            col = mix(col, lit, saturate(dust * fade) * 0.85 * k);
            add = add * (1.0 - saturate(dust * fade) * 0.6);
        }
    }

    // ---- the column of ejecta thrown up round the beam as the land bursts, thinning out -------------------------
    if (burst && bt < 14.0) {
        let He = 60.0 + 460.0 * (1.0 - exp(-bt * 0.9));
        let Re = 45.0 + 70.0 * (1.0 - exp(-bt * 0.6));
        let q = ray_seg(rd, crel, crel + vec3<f32>(0.0, He, 0.0));
        if (q.x < Re * 1.6) {
            let X = rd * q.y - crel;
            let side = dot(X, normalize(cross(rd, vec3<f32>(0.0, 1.0, 0.0)) + vec3<f32>(1.0e-4, 0.0, 0.0)));
            let n = gfbm2(vec2<f32>(side / Re * 1.5 + seed, X.y / Re * 0.6 - bt * 0.8));
            // a ragged shell, densest at its edge, its top boiling out
            let shell = exp(-pow((q.x - Re * 0.6) / (Re * 0.5), 2.0)) * (0.4 + 0.9 * n) * smoothstep(He, He * 0.7, X.y);
            let dens = saturate(shell * 1.1) * exp(-max(bt - 5.0, 0.0) / 3.0) * (1.0 - smoothstep(11.0, 14.0, bt)) * smoothstep(Re * 1.2, Re * 2.6, length(crel.xz));
            let vis = select(1.0, 1.0 - smoothstep(scene_len - 1.0, scene_len + 1.0, q.y), !sky);
            let lit = vec3<f32>(0.09, 0.075, 0.065) * (0.3 + 0.7 * day) * (1.0 - 0.5 * dark) + PK_HOT * 0.02 * burn * (0.5 + n)
                + lava_ramp(0.55) * exp(-max(X.y, 0.0) / 25.0) * 0.15;
            col = mix(col, lit, dens * 0.9 * vis * k);
            add = add * (1.0 - dens * 0.5 * vis);
        }
    }

    // ---- the mushroom of smoke climbing over the crater once the nexus has burst there, lit from under ------------
    if (popped) {
        let amb = vec3<f32>(0.2, 0.19, 0.19) * (0.2 + 0.8 * day) * (1.0 - 0.5 * dark);
        let mu = pk_mushroom(rd, crel, mt, seed, select(scene_len, 1.0e9, sky), in.position.xy, amb, time);
        let f = after * smoothstep(0.0, 0.8, mt) * k;
        col = mix(col, col * mu.w + mu.xyz, f);
        add = add * mix(1.0, mu.w, 0.85 * f);
    }

    // ---- the towers' bolts: each feeling its way out from its crown towards the ring in steps, branching, slowly, then
    //      running the rest of the way and striking it, a blinding stroke that lights the land and the sky; then held,
    //      the same jagged path, trembling, flickering, struck again now and then; where it meets the ring, a crackling
    //      knot of light ---------------------------------------------------------------------------------------------
    for (var i = 0; i < PK_N; i = i + 1) {
        let e = em[i];
        let et = time - e.w;
        let Lb = blt[i];
        if (et <= 0.0 || Lb < 0.002) {
            continue;
        }
        let fi = f32(i);
        let A = e.xyz - cam + vec3<f32>(0.0, PK_CORE_Y + 9.0, 0.0);
        let F = NX0 + (re1 * cos(fa[i]) + re2 * sin(fa[i])) * RR;
        let head = pk_lead(et, fi);
        let si = pcg(u32(seed) * 31u + u32(i) * 7919u);
        let tc = et - PK_SHOOT;
        let held = tc > 0.0;
        let rc = select(1.0, 2.0 + 2.5 * exp(-tc * 6.0), held) * k;
        let bo = pk_bolt(rdb, A, F, head, si, 32, 1.0, select(0.0, 1.0, held), rc, time, scene_len, sky, cloud);
        // (its glow held back in the blinding moment it strikes: the core blazes, the air round it does not fog over)
        let gl = min(Lb, 2.0) / max(Lb, 1.0e-3);
        var c = PK_WHITE * bo.x * 1.1 + PK_ARC * bo.y * gl;
        // (the leader's tip, brightest where it is feeling its way)
        if (!held) {
            let hp = pk_bolt_at(A, F, head, si, 32, 1.0);
            let th = max(dot(hp, rdb), 0.0);
            let dh = length(hp - rdb * th);
            let wh = max(2.0, th * 0.0013);
            c = c + (PK_WHITE * exp(-pow(dh / (wh * 1.2), 2.0)) * 1.5 + PK_ARC * exp(-dh / (wh * 6.0)) * 0.5) * (2.0 / wh) * pk_occ(th, scene_len, sky, cloud) * 3.0;
        }
        // its branches, put out as it feels its way; they flash with the stroke and die
        let br = select(1.0, 0.5 * exp(-tc * 7.0), held);
        if (br > 0.01) {
            for (var j = 0; j < 4; j = j + 1) {
                let sbj = pcg(si + u32(j) * 0x2545u);
                let hv = vec3<f32>(pcg3d(vec3<u32>(sbj, 9u, 1u))) * (1.0 / 4294967295.0);
                let ub = 0.04 + 0.27 * hv.x;
                let bh = saturate((min(head, 0.36) - ub) / (0.07 + 0.08 * hv.y));
                if (bh <= 0.0) {
                    continue;
                }
                let O = pk_bolt_at(A, F, ub, si, 32, 1.0);
                let D = normalize(F - A);
                let e1 = normalize(cross(D, vec3<f32>(0.0, 1.0, 0.0)));
                let e2 = cross(D, e1);
                let ba = hv.z * TAU;
                let dir = normalize(D + (e1 * cos(ba) + e2 * sin(ba)) * (0.5 + 0.5 * hv.y));
                let lb = length(F - A) * (0.06 + 0.1 * hv.y);
                let bb = pk_bolt(rdb, O, O + dir * lb, bh, sbj, 8, 1.5, 0.0, rc * 0.6, time, scene_len, sky, cloud);
                c = c + (PK_WHITE * bb.x * 0.7 + PK_ARC * bb.y * 0.8 * gl) * br * (1.0 - 0.6 * bb.z);
            }
        }
        // (the air round it lit)
        let qa = ray_seg(rdb, A, A + (F - A) * head);
        c = c + vec3<f32>(0.5, 0.55, 1.0) * exp(-qa.x / max(50.0, qa.y * 0.03)) * 0.025 * gl * pk_occ(qa.y, scene_len, sky, cloud);
        // where it meets the ring: a white-hot knot, arcs crackling out of it over the ring (blazing as it strikes, but
        // not swelling into a ball of light)
        var ck = vec3<f32>(0.0);
        if (held) {
            let tf = max(dot(F, rdb), 0.0);
            let df = length(F - rdb * tf);
            let wf = max(5.0, tf * 0.0016);
            let ocf = pk_occ(tf, scene_len, sky, cloud);
            let fan = df / max(tf, 1.0);
            ck = ((PK_WHITE * exp(-pow(df / (wf * 1.1), 2.0)) * 1.4 + PK_ARC * exp(-df / (wf * 3.0)) * 0.6) * (5.0 / wf)
                + PK_ARC * exp(-fan / 0.006) * 0.12 * select(0.0, 1.0, tf > 0.0)) * ocf;
            for (var j = 0; j < 3; j = j + 1) {
                let sj = pcg(si + u32(j) * 0x3d1u + u32(time * 20.0) * 0x9e37u);
                let hv = vec3<f32>(pcg3d(vec3<u32>(sj, 4u, 2u))) * (1.0 / 4294967295.0);
                let ta = fa[i] + (hv.x - 0.5) * 0.9;
                let dir = normalize((re1 * cos(ta) + re2 * sin(ta)) * RR + rn * (hv.y - 0.5) * 60.0 - (F - NX0));
                let ma = pk_bolt(rdb, F, F + dir * (40.0 + 70.0 * hv.z), 1.0, sj, 7, 1.4, 0.0, 0.8 * k, time, scene_len, sky, cloud);
                ck = ck + (PK_WHITE * ma.x * 0.8 + PK_ARC * ma.y * 0.8) * (1.0 - ma.z * 0.7);
            }
        }
        add = add + (c * Lb + ck * min(Lb, 2.5)) * k;
    }

    // ---- the ring: lit round from where each beam feeds it until it closes, a band of light with a white-hot outer
    //      edge, a lit inner edge and a turbulent body, runes turning on it, energy racing round; filling with light as
    //      they fuse; met where the view ray crosses its plane, so it is a clean ellipse from anywhere ----------------
    let ring_vis = saturate(fed * 2.0) * (1.0 - smoothstep(PK_FALL - 0.05, PK_FALL + 0.05, time)) * f32(!popped);
    let tcn = dot(NX, rd);
    let lum_n = Rn / 14.0;
    if (ring_vis > 0.0 && RR > 1.0) {
        let dn = dot(rd, rn);
        let tpl = dot(NX0, rn) / select(dn, 1.0e-4, abs(dn) < 1.0e-4);
        if (tpl > 0.0) {
            let X = rd * tpl - NX0;
            let rr = length(X);
            let th = atan2(dot(X, re2), dot(X, re1));
            // (a pixel, in the ring's plane: every line is at least that wide, so nothing shimmers)
            let fp = max(tpl * 0.0013, 0.3) / max(abs(dn), 0.1);
            let rho = rr - RR;
            // (its width uneven round it, churning)
            let W = (24.0 + 10.0 * charge) * (0.7 + 0.6 * gnoise2(vec2<f32>(th * 4.0 + spin * 0.5, seed)));
            if (rho > -W - 40.0 - fp * 4.0 && rho < 90.0 + fp * 4.0) {
                // how much of it is lit at this angle: each beam's arc running on round from where it feeds, gathering
                // speed, a white-hot head leading it; each feed point flaring as its beam strikes
                var lit = 0.0;
                var lit_soft = 0.0;                             // (the same, its ends soft: for the haze round it)
                var lead = 0.0;
                for (var i = 0; i < PK_N; i = i + 1) {
                    let dt = time - (em[i].w + PK_SHOOT - 0.03);
                    if (dt <= 0.0) {
                        continue;
                    }
                    let reach = PK_RING_V * dt * (1.0 + 0.6 * dt);
                    var d = th - fa[i];
                    d = d - TAU * floor(d / TAU);
                    lit = max(lit, smoothstep(reach + 0.03, reach - 0.03, d));
                    let ds = select(d, d - TAU, d > TAU - 0.4);
                    lit_soft = max(lit_soft, smoothstep(-0.35, 0.0, ds) * smoothstep(reach + 0.35, reach - 0.05, ds));
                    lead = max(lead, exp(-pow((d - reach) / 0.05, 2.0)) * (1.0 - smoothstep(TAU * 0.6, TAU, reach)));
                    lead = max(lead, exp(-pow(min(d, TAU - d) / 0.04, 2.0)) * (0.35 + 1.5 * exp(-dt * 4.0)) * power);
                }
                let lw = max(2.2, fp);
                let edge = exp(-pow(rho / lw, 2.0)) * (2.2 / lw);
                let iw = max(1.4, fp);
                let inner = exp(-pow((rho + W) / iw, 2.0)) * (1.4 / iw);
                let body = smoothstep(-W - fp, -W + fp, rho) * smoothstep(fp, -fp, rho);
                // a band of plasma churning round, threads of lightning crawling over it (in stretches, a new path every
                // frame of film or so), its outer edge white-hot and uneven
                let flowr = gnoise2(vec2<f32>(th * RR * 0.03 - spin * 4.0, rho * 0.08 + seed));
                var arcs = 0.0;
                let fw = max(0.9, fp);
                for (var f = 0; f < 3; f = f + 1) {
                    let sf = pcg(u32(seed) + u32(f) * 0x51u + u32(time * 14.0 + f32(f) * 0.33) * 0x9e37u);
                    let x = th * RR / 16.0;
                    let y = -W * 0.5 + W * 0.45 * (pk_jg(x, sf) * 0.7 + pk_jg(x * 3.1, sf ^ 0x77u) * 0.3);
                    let on = smoothstep(0.1, 0.3, pk_jg(x * 0.09, sf ^ 0x1234u) * 0.5 + 0.5 - 0.2);
                    arcs = arcs + exp(-pow((rho - y) / fw, 2.0)) * (0.9 / fw) * on;
                }
                let haze = exp(-max(rho, 0.0) / 45.0) * exp(-max(-rho - W, 0.0) / 30.0);
                let level = (0.55 + 0.6 * charge + 0.5 * burn + 0.5 * unstable * (0.5 + 0.5 * sin(time * 47.0))) * ring_vis;
                var c = pk_heat(1.0) * edge * (0.35 + 1.0 * flowr * flowr) + pk_heat(0.75) * inner * 0.25
                    + pk_heat(0.25 + 0.35 * flowr) * body * (0.2 + 0.4 * flowr * flowr)
                    + (PK_WHITE * 0.4 + PK_ARC) * arcs * (0.5 + 0.8 * charge + 0.5 * burn + 1.5 * lock);
                c = c * lit + pk_heat(0.1) * haze * 0.35 * lit_soft + PK_WHITE * lead * (edge * 0.4 + body * 0.25) * 2.0
                    + pk_heat(0.2) * (1.0 - lit) * edge * 0.08 * saturate(fed);
                add = add + c * level * pk_occ(tpl, scene_len, sky, cloud) * k;
            }
            // as they fuse it fills with light, swirling in to its middle
            let fill = fuse * (0.9 * select(1.0, exp(-merge_t * 1.2), merged) + 0.22 * burn) * (1.0 - crush);
            if (fill > 0.001 && rho < -W) {
                let sw = gfbm2(vec2<f32>(th * 2.0 + rr * 0.02 - time * 1.4, rr * 0.03 - time * 0.9));
                let dsc = fill * (0.3 + 0.7 * sw) * (0.35 + 0.65 * saturate(1.0 - rr / RR)) * smoothstep(-W, -W - 15.0, rho);
                add = add + pk_heat(0.25 + 0.45 * sw * fill) * dsc * 0.5 * ring_vis * pk_occ(tpl, scene_len, sky, cloud) * k;
            }
        }
    }
    // ---- its middle: the white-hot heart the beam is fired from, and the ring crushed into it, falling ----------
    if (Rn > 0.01 && tcn > 0.0) {
        let dcn = length(NX - rd * tcn);
        let occ = pk_occ(tcn - Rn, scene_len, sky, cloud);
        let wpx = max(Rn, tcn * 0.0016);
        let en = Rn / wpx;
        let hx = normalize(cross(rd, vec3<f32>(0.0, 1.0, 0.0)) + vec3<f32>(1.0e-4, 0.0, 0.0));
        let hy = cross(hx, rd);
        let o = rd * tcn - NX;
        let ang = atan2(dot(o, hy), dot(o, hx));
        let surf = gfbm2(vec2<f32>(ang * 2.5 + seed, dcn / wpx * 1.5 - time * 3.0));
        // (a hard white core, a thin rim of blue fire round it, a little haze: a star, not a blur)
        let core = 1.0 - smoothstep(wpx * 0.9, wpx * 1.0, dcn * (0.94 + 0.12 * surf));
        let rim = exp(-pow((dcn - wpx) / (wpx * 0.12), 2.0));
        var star = pk_heat(1.0) * 0.9 * core + pk_heat(0.7) * rim * (0.6 + 0.5 * surf) * en
            + pk_heat(0.45) * exp(-max(dcn - wpx, 0.0) / (wpx * 0.35)) * (0.3 + 0.4 * surf) * en
            + pk_heat(0.1) * exp(-dcn / (wpx * 3.0)) * 0.5 * en;
        if (fall > 0.0) {
            // falling: its trail down the line of the beam
            let q = ray_seg(rd, NX, NX + vec3<f32>(0.0, 120.0 * fall, 0.0));
            let wq = max(2.0, q.y * 0.0013);
            star = star + pk_heat(0.6) * exp(-pow(q.x / wq, 2.0)) * (3.0 / wq) * (1.0 - q.z) * fall;
        }
        add = add + star * occ * k;
    }

    // ---- as they fuse: a ring of fire tearing out through the sky, and the sky cracking open from the nexus -------
    if (merged && merge_t < 6.0) {
        let tp = NX.y / select(rd.y, 1.0e-5, abs(rd.y) < 1.0e-5);
        if (tp > 0.0) {
            let pp = rd * tp;
            let rr = length(pp.xz - NX.xz);
            let ap = atan2(pp.z - NX.z, pp.x - NX.x);
            let R = 1400.0 * (1.0 - exp(-merge_t * 0.9));
            let th = 5.0 + 22.0 * merge_t;
            var ring = exp(-pow((rr - R) / th, 2.0)) * exp(-merge_t * 1.5) * saturate(0.2 + 1.1 * gfbm2(vec2<f32>(ap * 9.0, rr * 0.004 + seed)));
            // the cracks: one jagged line out of each of fourteen sectors, running out ahead of the ring
            let sec = floor(ap / (TAU / 14.0));
            let ac = (sec + 0.5 + 0.5 * (fh21(vec2<f32>(sec, seed)) - 0.5)) * TAU / 14.0;
            // (jagged: straight runs between kinks, every 90 blocks and every 25)
            let k1 = rr / 90.0;
            let k2 = rr / 25.0;
            let kink = mix(fh21(vec2<f32>(sec * 7.0 + floor(k1), seed)), fh21(vec2<f32>(sec * 7.0 + floor(k1) + 1.0, seed)), fract(k1)) * 60.0
                + mix(fh21(vec2<f32>(sec * 5.0 + floor(k2), seed + 3.0)), fh21(vec2<f32>(sec * 5.0 + floor(k2) + 1.0, seed + 3.0)), fract(k2)) * 14.0 - 37.0;
            let lat = abs((ap - ac) * rr - kink * smoothstep(40.0, 200.0, rr));
            let wc = 1.5 + rr * 0.002;
            let reach = 1600.0 * (1.0 - exp(-merge_t * 2.5));
            ring = ring + exp(-pow(lat / wc, 2.0)) * smoothstep(reach, reach - 200.0, rr) * smoothstep(RR * 0.9, RR * 1.3, rr) * exp(-merge_t * 1.8) * 1.6;
            let wfar = max(1.0, tp * 0.002);
            // (not edge on, where it would only be a line across the sky)
            add = add + (PK_ARC * 0.7 + PK_WHITE * 0.12) * ring * min(1.0, 30.0 / wfar) * smoothstep(0.03, 0.12, abs(rd.y)) * pk_occ(tp, scene_len, sky, cloud) * k;
        }
    }

    // ---- once they have fused, a bolt feeling its way down from the ring's middle to the target, branching, and
    //      streamers reaching up off the land to meet it; the beam pours down the path it opens ----------------------
    let dl_t = time - (PK_MERGE + 0.15);
    if (dl_t > 0.0 && time < PK_DROP + 0.3) {
        let G = crel - vec3<f32>(0.0, 1.0, 0.0);
        let dl = dl_t * PK_SHOOT / (PK_DROP - PK_MERGE - 0.15);
        let hd = pk_lead(dl, 3.0);
        let si = pcg(u32(seed) * 13u + 77u);
        let lv = select(0.3 + 0.4 * smoothstep(PK_CREEP, PK_SHOOT, dl), 3.0 * exp(-(time - PK_DROP) * 9.0), time > PK_DROP);
        let bo = pk_bolt(rdb, NX, G, hd, si, 24, 0.7, 0.0, 1.6 * k, time, scene_len, sky, cloud);
        var c = PK_WHITE * bo.x + PK_ARC * bo.y;
        if (time < PK_DROP) {
            let hp = pk_bolt_at(NX, G, hd, si, 24, 0.7);
            let th = max(dot(hp, rdb), 0.0);
            let dh = length(hp - rdb * th);
            let wh = max(2.0, th * 0.0013);
            c = c + (PK_WHITE * exp(-pow(dh / (wh * 1.2), 2.0)) * 1.5 + PK_ARC * exp(-dh / (wh * 6.0)) * 0.5) * (2.0 / wh) * pk_occ(th, scene_len, sky, cloud) * 3.0;
        }
        for (var j = 0; j < 3; j = j + 1) {
            let sbj = pcg(si + u32(j) * 0x2545u);
            let hv = vec3<f32>(pcg3d(vec3<u32>(sbj, 9u, 1u))) * (1.0 / 4294967295.0);
            let ub = 0.05 + 0.28 * hv.x;
            let bh = saturate((min(hd, 0.36) - ub) / (0.07 + 0.08 * hv.y));
            if (bh > 0.0) {
                let O = pk_bolt_at(NX, G, ub, si, 24, 0.7);
                let ba = hv.z * TAU;
                let dir = normalize(vec3<f32>(cos(ba) * (0.6 + 0.6 * hv.y), -1.0, sin(ba) * (0.6 + 0.6 * hv.y)));
                let bb = pk_bolt(rdb, O, O + dir * (40.0 + 70.0 * hv.y), bh, sbj, 8, 1.5, 0.0, 1.0 * k, time, scene_len, sky, cloud);
                c = c + (PK_WHITE * bb.x * 0.7 + PK_ARC * bb.y * 0.8) * (1.0 - 0.6 * bb.z);
            }
        }
        // (the streamers: thin sparks reaching up off the land round the target, flickering, in the last moments)
        let st = smoothstep(PK_DROP - 0.4, PK_DROP - 0.1, time) * (1.0 - smoothstep(PK_DROP, PK_DROP + 0.1, time));
        if (st > 0.0) {
            for (var j = 0; j < 4; j = j + 1) {
                let sj = pcg(u32(seed) * 7u + u32(j) * 0x61u);
                let hv = vec3<f32>(pcg3d(vec3<u32>(sj, 2u, 8u))) * (1.0 / 4294967295.0);
                let a0 = hv.x * TAU;
                let O = crel + vec3<f32>(cos(a0), 0.0, sin(a0)) * (6.0 + 30.0 * hv.y);
                let fl = step(0.3, mh(u32(time * 30.0), sj, 3u));
                let bb = pk_bolt(rdb, O, O + vec3<f32>((hv.z - 0.5) * 20.0, 20.0 + 35.0 * hv.z, (hv.y - 0.5) * 20.0), st, sj, 8, 2.2, 1.0, 0.3 * k, time, scene_len, sky, cloud);
                c = c + (PK_WHITE * bb.x * 0.5 + PK_ARC * bb.y * 0.6) * fl * (1.0 - 0.6 * bb.z);
            }
        }
        add = add + c * lv * k;
    }

    // ---- the beam: down from the ring's middle onto the target, a white core inside a blue sheath, strands wound round it ----
    if (burn > 0.001) {
        let G = crel - vec3<f32>(0.0, 14.0, 0.0);
        let xh = saturate((time - PK_DROP) / (PK_HIT - PK_DROP));
        let xt = saturate((time - PK_CUT - PK_DRAIN * 0.5) / 0.4);
        let u_head = xh * xh;
        let u_top = xt * xt;
        let A = NX + (G - NX) * u_top;
        let B = NX + (G - NX) * u_head;
        let q = ray_seg(rdb, A, B);
        let lenb = length(G - NX);
        let qz = mix(u_top, u_head, q.z);
        let along = qz * lenb;
        let hgt = NX.y + (G.y - NX.y) * qz - crel.y;
        var rc = (11.0 + 1.2 * sin(time * 23.0) + 0.9 * sin(time * 37.0 + 1.0)) * (1.0 + 0.6 * exp(-max(hit_t, 0.0) * 2.0));
        rc = rc * (1.0 + 0.5 * exp(-max(hgt, 0.0) / 12.0)) * k;
        let w = max(rc, q.y * 0.0013);
        let e = rc / w;
        let dd = q.x;
        if (dd < w * 40.0) {
            let vis = select(1.0, 1.0 - smoothstep(scene_len - 0.8, scene_len + 0.8, q.y), !sky);
            let vis_mix = mix(0.15, 1.0, vis);
            let bdir = (G - NX) / max(lenb, 1.0e-3);
            let e1 = normalize(cross(bdir, vec3<f32>(1.0, 0.0, 0.0)));
            let e2 = cross(bdir, e1);
            let ofs = rdb * q.y - (A + (B - A) * q.z);
            let ang = atan2(dot(ofs, e2), dot(ofs, e1));
            let n1 = gnoise2(vec2<f32>(ang * 1.6, along * 0.04 - time * 18.0));
            let n2 = gnoise2(vec2<f32>(ang * 2.3 + 7.0, along * 0.09 - time * 25.0));
            // surges racing down it, three strands wound round it
            let pulse = pow(0.5 + 0.5 * sin(along * 0.03 - time * 60.0), 6.0);
            let core = exp(-pow(dd / (w * 0.42), 2.0));
            let inner = exp(-pow(dd / (w * 1.2), 2.0)) * (0.6 + 0.8 * n1);
            let outer = exp(-pow(dd / (w * 2.6), 2.0)) * (0.4 + 0.9 * n2);
            let halo = (exp(-dd / (rc * 4.0)) + exp(-dd / max(q.y, 1.0) / 0.05) * 0.1) * (1.0 - smoothstep(w * 25.0, w * 40.0, dd));
            var strands = 0.0;
            let axis = A + (B - A) * q.z;
            // (lightning crawling over it: jagged arcs wound round it in stretches, a new one every frame of film or so)
            for (var s = 0; s < 4; s = s + 1) {
                let sk = pcg(u32(seed) * 3u + u32(s) * 0x9e1u + u32(time * 18.0 + f32(s) * 0.27) * 0x632bu);
                let hv = vec3<f32>(pcg3d(vec3<u32>(sk, 6u, 6u))) * (1.0 / 4294967295.0);
                let a0 = hv.x * lenb;
                let al = 50.0 + 130.0 * hv.y;
                let on = smoothstep(a0, a0 + 8.0, along) * smoothstep(a0 + al, a0 + al - 8.0, along);
                if (on <= 0.0) {
                    continue;
                }
                let ph = hv.z * TAU + along * 0.02 * select(-1.0, 1.0, hv.x > 0.5) + pk_jg(along / 9.0, sk) * 0.9;
                let hp = axis + (e1 * cos(ph) + e2 * sin(ph)) * rc * (1.35 + 0.45 * pk_jg(along / 6.0, sk ^ 0x5bu));
                let th = max(dot(hp, rdb), 0.0);
                let wh = max(rc * 0.1, th * 0.0012);
                strands = strands + exp(-pow(length(hp - rdb * th) / wh, 2.0)) * (rc * 0.1 / wh) * on * select(1.0, 1.0 - smoothstep(scene_len - 0.8, scene_len + 0.8, th), !sky);
            }
            var b = (PK_WHITE * core * (1.0 + 0.6 * pulse) + PK_HOT * inner * (0.28 + 0.6 * pulse) + PK_DEEP * outer * 0.4) * e;
            // the head of it, blazing, on its way down
            b = b + PK_WHITE * exp(-pow((q.z - 1.0) * (u_head - u_top) * lenb / 10.0, 2.0)) * core * 1.5 * (1.0 - step(1.0, u_head));
            // (its strands wind out of it below the ring, not round its heart)
            strands = strands * smoothstep(40.0, 110.0, along);
            add = add + (b * vis + halo * PK_DEEP * 0.12 * e * vis_mix + (PK_ARC * 0.8 + PK_WHITE * 0.45) * strands * 2.2) * burn * k;
        }
        // the fireball where the land burst, boiling; it settles round the foot of the beam
        if (burst) {
            let Rf = (70.0 + 130.0 * exp(-bt * 0.6) * (1.0 - exp(-bt * 6.0))) * (0.93 + 0.07 * sin(time * 13.0));
            let cf = crel + vec3<f32>(0.0, Rf * 0.25, 0.0);
            let tcp = dot(cf, rd);
            // (a dome, flattened against the land)
            let dc = length((rd * max(tcp, 0.0) - cf) * vec3<f32>(1.0, 1.7, 1.0));
            if (dc < Rf * 4.0 && tcp > 0.0) {
                let hx = normalize(cross(rd, vec3<f32>(0.0, 1.0, 0.0)) + vec3<f32>(1.0e-4, 0.0, 0.0));
                let hy = cross(hx, rd);
                let on = rd * tcp - cf;
                let ang = atan2(dot(on, hy), dot(on, hx));
                let nz = gfbm2(vec2<f32>(ang * 1.3 + seed, dc / Rf * 2.0 - time * 2.5));
                let fire = exp(-pow(dc / (Rf * (0.75 + 0.5 * nz)), 2.0));
                // plasma, white-hot at its heart, the land burning orange under it, a crust of smoke round its edge
                let heat = fire * (0.4 + 0.6 * exp(-dc / (Rf * 0.3)));
                let low = exp(-max((rd * max(tcp, 0.0) - crel).y, 0.0) / 12.0);
                // (seen from inside it, only its heart: it does not fog the whole view)
                let visf = select(1.0, smoothstep(tcp - Rf * 1.3, tcp - Rf * 0.2, scene_len), !sky) * mix(smoothstep(0.0, 0.5, heat), 1.0, smoothstep(Rf * 0.8, Rf * 1.8, length(cf)));
                col = mix(col, vec3<f32>(0.04, 0.04, 0.05), smoothstep(0.05, 0.5, fire) * (1.0 - heat) * 0.6 * visf * burn * k);
                add = add + (PK_WHITE * 0.25 * heat * heat + PK_HOT * 0.45 * heat * (1.0 + 0.6 * nz) + PK_DEEP * fire * 0.3
                    + lava_ramp(0.45 + 0.5 * heat) * fire * low * 1.4) * visf * burn * k;
                add = add + vec3<f32>(1.2, 1.2, 1.6) * exp(-dc / Rf) * 0.12 * (1.0 - smoothstep(Rf * 2.5, Rf * 4.0, dc)) * smoothstep(Rf, Rf * 3.0, length(cf)) * burn * visf * k;
            }
        }
    }

    // ---- the nexus bursting in the crater: a ball of fire and plasma swelling out of it, the mushroom climbing out of it --
    if (popped && mt < 5.0) {
        let Rp = (45.0 + 135.0 * (1.0 - exp(-mt * 3.0))) * (0.95 + 0.05 * sin(time * 17.0));
        let cf = crel + vec3<f32>(0.0, Rp * 0.3 + 40.0 * mt, 0.0);
        let tcp = dot(cf, rd);
        let dc = length((rd * max(tcp, 0.0) - cf) * vec3<f32>(1.0, 1.3, 1.0));
        if (dc < Rp * 2.0) {
            let hx = normalize(cross(rd, vec3<f32>(0.0, 1.0, 0.0)) + vec3<f32>(1.0e-4, 0.0, 0.0));
            let on = rd * tcp - cf;
            let nz = gfbm2(vec2<f32>(atan2(dot(on, cross(hx, rd)), dot(on, hx)) * 1.4 + seed, dc / Rp * 2.0 - time * 2.0));
            let fire = exp(-pow(dc / (Rp * (0.7 + 0.5 * nz)), 2.0)) * exp(-mt / 1.2) * (1.0 - smoothstep(3.5, 5.0, mt));
            let visf = select(1.0, smoothstep(tcp - Rp * 1.3, tcp - Rp * 0.2, scene_len), !sky) * select(0.0, 1.0, tcp > 0.0)
                * mix(smoothstep(0.3, 0.8, fire), 1.0, smoothstep(Rp * 0.8, Rp * 1.8, length(cf)));
            add = add + (lava_ramp(0.35 + 0.6 * fire) * fire * 2.4 + PK_HOT * fire * fire * 1.5 * exp(-mt * 2.0)) * visf * k
                * mix(0.35, 1.0, smoothstep(Rp * 0.8, Rp * 1.8, length(cf)));
        }
    }

    // ---- debris spiralling up round the beam, and molten rock thrown out of the crater, the crater still erupting ----
    let sp_q = ray_seg(rd, crel, crel + vec3<f32>(0.0, 300.0, 0.0));
    if (burst && sp_q.x < 340.0) {
        for (var j = 0; j < 30; j = j + 1) {
            // each one thrown again and again, a new way each time
            let fj = f32(j);
            let life = 2.2 + 1.6 * fract(fj * 0.618034);
            let ph = fract(fj * 0.754878) * life;
            let gen = floor((time + ph) / life);
            let tb = gen * life - ph;                               // when this one was thrown
            let a = time - tb;
            let erupting = tb > PK_CUT && fract(fj * 0.31) > 0.6;   // (after the beam, a few: the crater still erupting)
            if (tb < PK_BURST || (tb > PK_CUT && !erupting) || tb > PK_END - 4.0) {
                continue;
            }
            let hv = vec3<f32>(pcg3d(vec3<u32>(u32(j), u32(gen), u32(seed)))) * (1.0 / 4294967295.0);
            var pa = vec3<f32>(0.0);
            var pb = vec3<f32>(0.0);
            if (j % 2 == 0 && tb < PK_CUT) {
                // round the beam: orbiting it and climbing
                let rr = 30.0 + 50.0 * hv.x;
                let w0 = (1.2 + 1.5 * hv.y) * select(-1.0, 1.0, hv.z > 0.5);
                let vy = 35.0 + 50.0 * hv.z;
                let a1 = max(a - 0.08, 0.0);
                pa = crel + vec3<f32>(cos(hv.y * TAU + w0 * a) * rr, vy * a, sin(hv.y * TAU + w0 * a) * rr);
                pb = crel + vec3<f32>(cos(hv.y * TAU + w0 * a1) * rr, vy * a1, sin(hv.y * TAU + w0 * a1) * rr);
            } else {
                let az = hv.x * TAU;
                let vh = 25.0 + 60.0 * hv.y;
                let vy = 35.0 + 55.0 * hv.z;
                let s3 = crel + vec3<f32>(cos(az) * 20.0, 2.0, sin(az) * 20.0);
                let a1 = max(a - 0.07, 0.0);
                pa = s3 + vec3<f32>(cos(az) * vh * a, vy * a - 16.0 * a * a, sin(az) * vh * a);
                pb = s3 + vec3<f32>(cos(az) * vh * a1, vy * a1 - 16.0 * a1 * a1, sin(az) * vh * a1);
                if (pa.y + cam.y < tgt.y - 20.0) {
                    continue;
                }
            }
            let qj = ray_seg(rd, pa, pb);
            let vis = select(1.0, 1.0 - smoothstep(scene_len - 0.4, scene_len + 0.4, qj.y), !sky);
            if (j % 3 == 0) {
                // a chunk of the land, dark against the light
                let w = 0.8 + 1.2 * hv.y;
                col = mix(col, vec3<f32>(0.04, 0.035, 0.03), exp(-pow(qj.x / max(w, qj.y * 0.0012), 4.0)) * (w / max(w, qj.y * 0.0012)) * vis);
                add = add * (1.0 - exp(-pow(qj.x / max(w, qj.y * 0.0012), 4.0)) * vis * 0.8);
            } else {
                let w = max(0.4, qj.y * 0.0012);
                add = add + mix(vec3<f32>(4.0, 3.4, 2.6), vec3<f32>(2.6, 0.7, 0.12), saturate(a / life)) * exp(-pow(qj.x / w, 2.0)) * (0.4 / w) * (1.0 - a / life) * vis * k;
            }
        }
    }

    // ---- the shock dome: the blast front in the air, a shell bending the light, lit at its edge -----------------
    if (burst && bt < 5.0) {
        let Rs = pk_shock_r(bt);
        let tcs = dot(crel, rd);
        let ps = rd * max(tcs, 0.0) - crel;
        let dcs = length(ps);
        let th = 8.0 + 25.0 * bt;
        let wpx = max(th, max(tcs, 1.0) * 0.002);
        // (a faint pale shell, as a shock front is seen by the haze it condenses, soft and broken)
        let brk = 0.5 + 0.8 * gnoise2(vec2<f32>(atan2(ps.z, ps.x) * 6.0, ps.y * 0.02 + seed));
        let limb = exp(-pow((dcs - Rs) / wpx, 2.0)) * (th / wpx) * smoothstep(-5.0, 10.0, ps.y) * brk;
        add = add + vec3<f32>(0.4, 0.43, 0.5) * limb * 0.35 * exp(-bt * 1.6) * pk_occ(tcs, scene_len, sky, cloud) * k;
    }

    // ---- the lens: bloom round the ring's heart and the beam's foot, a long streak through the heart --------------
    if (pN.z > 0.0 && Rn > 0.01) {
        let dd = (uv - pN.xy) * vec2<f32>(aspect, 1.0);
        let l = lum_n * (0.6 + 0.5 * charge + 0.6 * burn) + select(0.0, exp(-merge_t * 4.0) * 1.5, merged) + lock * 0.8;
        add = add + PK_HOT * l / (1.0 + dot(dd, dd) * 600.0) * 0.25 * k;
    }
    if (pT.z > 0.0 && (burn > 0.001 || (popped && mt < 2.0))) {
        let dd = (uv - pT.xy) * vec2<f32>(aspect, 1.0);
        let l = burn + select(0.0, exp(-mt * 2.0) * 2.0, popped);
        add = add + vec3<f32>(1.2, 1.6, 2.6) * l / (1.0 + dot(dd, dd) * 400.0) * 0.25 * k;
    }
    add = add + vec3<f32>(2.2, 2.5, 3.2) * flash * flash * k;
    // (the sky lit up as the bolts strike)
    add = add + vec3<f32>(0.6, 0.65, 1.0) * min(strike_fl, 8.0) * 0.006 * select(0.5, 1.0, sky) * k;

    // ---- combine --------------------------------------------------------------
    var outc = col + add;
    let vg = length((uv - vec2<f32>(0.5)) * vec2<f32>(aspect, 1.0));
    outc = outc * (1.0 - smoothstep(0.3, 1.0, vg) * (0.2 + 0.3 * dark) * k);
    // (tone-mapped so the brightest light keeps its colour: the filmic curve on its brightness, half on each channel)
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
    return planet_killer(in);
}

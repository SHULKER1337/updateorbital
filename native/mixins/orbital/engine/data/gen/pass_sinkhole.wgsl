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


// Orbital Laser's post pass for the Sinkhole (laser 8). Like the Crystal Bloom's, the mod builds it from
// shaders/strike.wgsl up to its fs_main (the helpers: the noise, rot_axis, project_rel, mh, ign) less the other lasers'
// own functions, followed by this file, and sets it for a sinkhole strike only. Validate with tools/check-shader.sh.

// ---- laser 8: the sinkhole ----------------------------------------------------------------------------------------
// No beam, nothing from the sky. The land round the target trembles, birds go up off it, hairline cracks race out over
// it, radiating and branching; a patch in the middle gives (real blocks), the cracks round the slabs it will break into
// open; then it caves in from the middle out, ring by ring: each slab of land (grass over dirt over stone) strains,
// tilts and drops away into the pit, the dust boiling up out of it and rolling out low over the land, and the pit is
// left: dark, sheer, down to bedrock, water pouring over its edge where it cut a river or a lake.
// strike/sinkhole.rs cuts the same rings and slabs (ShGeo) and hands them over as the table below (sh_table); it digs
// each slab's land SH_DIG_AHEAD before it lets go, while this pass already draws the slab over it, so nothing is seen
// open before it falls: keep the SH_* and the table in step.
const SH_R: f32 = 112.0;           // the pit's mean radius at the top (the rim wanders, sh_rim)
const SH_GIVE: f32 = 6.0;          // the middle gives,
const SH_SAG: f32 = 7.3;           // sags,
const SH_C0: f32 = 8.6;            // and the collapse sets out from the middle (sh_front)
const SH_LEAD: f32 = 0.45;         // a slab drawn this long before it lets go, straining in place,
const SH_FALL: f32 = 3.2;          // and gone this long after, deep in the pit
const SH_DEEP0: f32 = 16.0;        // the pit dug on down to bedrock from here (until then it is 25 deep)
const SH_END: f32 = 34.0;          // the dust gone
const SH_LEN: f32 = 40.0;          // the strike's length (lasers.rs): the pit's dark fades out over its last SH_FADE
const SH_FADE: f32 = 9.0;
const SH_DIG: f32 = 0.1;           // a slab's land dug this long before it lets go (sinkhole.rs's SH_DIG_AHEAD)
const SH_SPURTS: i32 = 10;         // the cracks race out in spurts (sinkhole.rs's sh_spurts), each over SH_SPURT
const SH_SPURT: f32 = 0.2;
const SH_BIRDS: i32 = 28;

// ---- the table (strike/sinkhole.rs's sh_table): see SH_RG.. there ----------------------------------------------
const SH_RG: u32 = 8u;
const SH_RW: u32 = 5u;
const SH_WF: u32 = 64u;
const SH_SB: u32 = 96u;
const SH_SW: u32 = 24u;
const SH_MAT: u32 = 7936u;         // the materials (sh_land.rs's MATS), two words each
const SH_GRID: u32 = 8192u;        // the land's columns (sh_land.rs): SH_GW by SH_GW from the target's less SH_G
const SH_G: i32 = 134;
const SH_GW: i32 = 269;
fn sh_w(i: u32) -> f32 {
    if (i < arrayLength(&mod_data)) {
        return bitcast<f32>(mod_data[i]);
    }
    return 0.0;
}
fn sh_count() -> i32 {
    if (arrayLength(&mod_data) < SH_SB) {
        return 0;
    }
    return i32(sh_w(0u));
}
fn sh_rim(a: f32) -> f32 {
    return SH_R * (1.0 + 0.07 * sin(3.0 * a + sh_w(2u)) + 0.04 * sin(5.0 * a + sh_w(3u)) + 0.025 * sin(11.0 * a + sh_w(4u))
        + 0.012 * sin(23.0 * a + sh_w(5u)));
}
fn sh_ring_r(j: i32, a: f32, rim: f32) -> f32 {
    let nr = i32(sh_w(1u));
    if (j <= 0) {
        return 0.0;
    }
    if (j >= nr) {
        return rim;
    }
    let b = SH_RG + u32(j) * SH_RW;
    return sh_w(b) * rim / SH_R + 2.0 * sin(7.0 * a + sh_w(b + 1u));
}
// When the collapse reaches r out (sinkhole.rs's sh_front), and how far out it has reached at `t` (its inverse).
fn sh_front(r: f32) -> f32 {
    if (r < 30.0) {
        return SH_C0 + 0.9 * r / 30.0;
    }
    return SH_C0 + 2.0 + 4.4 * pow(clamp((r - 30.0) / (SH_R - 30.0), 0.0, 1.4), 0.75);
}
fn sh_reached(t: f32) -> f32 {
    if (t < SH_C0) {
        return 0.0;
    }
    if (t < SH_C0 + 0.9) {
        return 30.0 * (t - SH_C0) / 0.9;
    }
    if (t < SH_C0 + 2.0) {
        return 30.0;
    }
    return 30.0 + (SH_R - 30.0) * pow((t - SH_C0 - 2.0) / 4.4, 1.0 / 0.75);
}
// The slab the land at polar (r, a) from the middle is part of (-1 outside the rim), and the distances from it to its
// ring's edges and its sector's (in blocks): x the ring's slab index, y its edges' nearest, z when it lets go.
fn sh_slab_at(r: f32, a: f32, rim: f32, seed: u32) -> vec3<f32> {
    if (r >= rim) {
        return vec3<f32>(-1.0, r - rim, 0.0);
    }
    let nr = i32(sh_w(1u));
    var j = 0;
    loop {
        if (j + 1 >= nr || r < sh_ring_r(j + 1, a, rim)) {
            break;
        }
        j = j + 1;
    }
    let r0 = sh_ring_r(j, a, rim);
    let r1 = sh_ring_r(j + 1, a, rim);
    let b = SH_RG + u32(j) * SH_RW;
    let n = i32(sh_w(b + 2u));
    let th0 = sh_w(b + 3u);
    let off = i32(sh_w(b + 4u));
    let u = fract((a - th0) / TAU) * f32(n);
    let m0 = min(i32(floor(u)), n - 1);
    let jit0 = 0.35 * (mh(u32(m0 % n), seed, 0x710u + u32(j)) - 0.5);
    let jit1 = 0.35 * (mh(u32((m0 + 1) % n), seed, 0x710u + u32(j)) - 0.5);
    var m = m0;
    var e0 = f32(m0) + jit0;
    var e1 = f32(m0 + 1) + jit1;
    if (u < e0) {
        m = (m0 + n - 1) % n;
        e1 = e0;
        e0 = f32(m0 - 1) + 0.35 * (mh(u32((m0 + n - 1) % n), seed, 0x710u + u32(j)) - 0.5);
    } else if (u >= e1) {
        m = (m0 + 1) % n;
        e0 = e1;
        e1 = f32(m0 + 2) + 0.35 * (mh(u32((m0 + 2) % n), seed, 0x710u + u32(j)) - 0.5);
    }
    let side = min(u - e0, e1 - u) / f32(n) * TAU * r;
    let ring = select(min(r - r0, r1 - r), r1 - r, j == 0);
    let k = off + m;
    return vec3<f32>(f32(k), min(side, ring), sh_w(SH_SB + u32(k) * SH_SW + 6u));
}

// ---- a slab: a convex block of land (its corners' quad, grown to cover its curved edges; its ground's plane on top;
//      flat underneath), moving as it strains, tilts and falls -----------------------------------------------------------
struct ShPose {
    o: vec3<f32>,      // its ground's middle where it now is, relative to the camera
    pv: vec3<f32>,     // the edge it tips over, relative to the camera, before it moves
    er: vec3<f32>,     // out from the pit's middle, and along its ring
    et: vec3<f32>,
    phi: f32,          // how far it has tipped (its inner edge down), and turned about its own up
    psi: f32,
    drop: vec3<f32>,   // how far it has dropped and slid in
}
fn sh_corner(r: f32, th: f32) -> vec2<f32> {
    return vec2<f32>(cos(th), sin(th)) * max(r, 0.6);
}
// Slab k's pose `s` seconds after it lets go (s < 0: straining in place), C the pit's middle relative to the camera.
fn sh_pose(b: u32, k: i32, s: f32, C: vec3<f32>) -> ShPose {
    let c0 = sh_corner(sh_w(b + 2u), sh_w(b));
    let c1 = sh_corner(sh_w(b + 3u), sh_w(b + 1u));
    let c2 = sh_corner(sh_w(b + 5u), sh_w(b + 1u));
    let c3 = sh_corner(sh_w(b + 4u), sh_w(b));
    let m = (c0 + c1 + c2 + c3) * 0.25;
    let am = 0.5 * (sh_w(b) + sh_w(b + 1u));
    let er2 = vec2<f32>(cos(am), sin(am));
    var p: ShPose;
    p.er = vec3<f32>(er2.x, 0.0, er2.y);
    p.et = vec3<f32>(-er2.y, 0.0, er2.x);
    let ytop = sh_w(b + 7u);
    let thick = sh_w(b + 10u);
    let half_r = 0.5 * (0.5 * (sh_w(b + 4u) + sh_w(b + 5u)) - 0.5 * (sh_w(b + 2u) + sh_w(b + 3u)));
    let O = C + vec3<f32>(m.x, ytop, m.y);
    p.pv = O + p.er * half_r - vec3<f32>(0.0, thick, 0.0);
    let fk = f32(k);
    if (s < 0.0) {
        // dug out under it, still in place: exactly where the land it stands in for was (the hand-off unseen)
        p.phi = 0.0;
        p.psi = 0.0;
        p.drop = vec3<f32>(0.0);
    } else {
        // let go: a lurch, then tipping in over its outer edge faster and faster as it drops, sliding in, turning a
        // little
        let l = smoothstep(0.0, 0.3, s);
        p.phi = min(0.03 * l + 0.5 * sh_w(b + 12u) * s * s, 1.5);
        p.psi = sh_w(b + 13u) * s * s;
        p.drop = vec3<f32>(0.0, -0.45 * l - 0.5 * sh_w(b + 11u) * s * s, 0.0) - p.er * sh_w(b + 14u) * s * s;
    }
    p.o = O;
    return p;
}
// Into the slab's own frame (its ground's middle at the origin, along the world's axes as it lay): a point relative to
// the camera, and a direction.
fn sh_to(p: ShPose, x: vec3<f32>) -> vec3<f32> {
    let q = rot_axis(x - p.drop - p.pv, p.et, -p.phi) + p.pv - p.o;
    return rot_axis(q, vec3<f32>(0.0, 1.0, 0.0), -p.psi);
}
fn sh_from(p: ShPose, q: vec3<f32>) -> vec3<f32> {
    return rot_axis(rot_axis(q, vec3<f32>(0.0, 1.0, 0.0), p.psi) + p.o - p.pv, p.et, p.phi) + p.pv + p.drop;
}
fn sh_dir_to(p: ShPose, v: vec3<f32>) -> vec3<f32> {
    return rot_axis(rot_axis(v, p.et, -p.phi), vec3<f32>(0.0, 1.0, 0.0), -p.psi);
}
fn sh_dir_from(p: ShPose, v: vec3<f32>) -> vec3<f32> {
    return rot_axis(rot_axis(v, vec3<f32>(0.0, 1.0, 0.0), p.psi), p.et, p.phi);
}
// The view ray (o + t d, in the slab's frame) through slab b: x where it enters, y where it leaves, z which face it
// enters by (0 top, 1 bottom, 2.. the sides), w unused.
fn sh_hit(b: u32, o: vec3<f32>, d: vec3<f32>) -> vec3<f32> {
    let c = array<vec2<f32>, 4>(sh_corner(sh_w(b + 2u), sh_w(b)), sh_corner(sh_w(b + 3u), sh_w(b + 1u)),
        sh_corner(sh_w(b + 5u), sh_w(b + 1u)), sh_corner(sh_w(b + 4u), sh_w(b)));
    let m = (c[0] + c[1] + c[2] + c[3]) * 0.25;
    var t0 = -1.0e9;
    var t1 = 1.0e9;
    var face = -1.0;
    // the top: its ground's plane; the bottom: flat
    let sx = sh_w(b + 8u);
    let sz = sh_w(b + 9u);
    let nt = vec3<f32>(-sx, 1.0, -sz);
    let thick = sh_w(b + 10u);
    for (var i = 0; i < 6; i = i + 1) {
        var n = nt;
        var w = 0.0;
        if (i == 1) {
            n = vec3<f32>(0.0, -1.0, 0.0);
            w = thick;
        } else if (i >= 2) {
            let a = c[i - 2] - m;
            let e = c[(i - 1) % 4] - m - a;
            var n2 = normalize(vec2<f32>(e.y, -e.x) + vec2<f32>(1.0e-7));
            if (dot(n2, a) < 0.0) {
                n2 = -n2;
            }
            let grow = 1.0 + select(0.0, sh_w(b + 16u), i == 2) + select(0.0, sh_w(b + 17u), i == 4);
            n = vec3<f32>(n2.x, 0.0, n2.y);
            w = dot(n2, a) + grow;
        }
        let den = dot(n, d);
        let num = w - dot(n, o);
        if (abs(den) < 1.0e-7) {
            if (num < 0.0) {
                return vec3<f32>(1.0, 0.0, -1.0);
            }
            continue;
        }
        let tt = num / den;
        if (den < 0.0) {
            if (tt > t0) {
                t0 = tt;
                face = f32(i);
            }
        } else {
            t1 = min(t1, tt);
        }
    }
    return vec3<f32>(t0, t1, face);
}

// A column's top as the land's colours make it (sRGB, as lit at full light), and how high it is over its ground's top:
// the leaves over it where a tree stands, else its block's top, tinted, or snow.
fn sh_top_albedo(w: vec3<u32>) -> vec4<f32> {
    let leaf = (w.y >> 16u) & 63u;
    if (leaf > 0u) {
        var m = sh_mat(leaf);
        if (m.tint == 2u) {
            m.top = m.top * sh_565(w.z >> 16u, vec3<f32>(0.467, 0.671, 0.184));
        }
        return vec4<f32>(m.top * 0.82, f32((w.y >> 26u) & 15u));
    }
    return vec4<f32>(sh_ground_albedo(w), 0.0);
}
fn sh_ground_albedo(w: vec3<u32>) -> vec3<f32> {
    if (((w.x >> 30u) & 1u) == 1u) {
        return vec3<f32>(0.95, 0.98, 0.99);
    }
    var m = sh_mat((w.x >> 9u) & 63u);
    if (m.tint == 1u) {
        m.top = m.top * sh_565(w.z & 0xffffu, vec3<f32>(0.569, 0.741, 0.349));
    }
    return m.top;
}
// How the real land beside slab b is lit this frame, channel by channel (xyz: the scene's colour over the land's
// model of it; w: how many of its dozen columns were seen), from the tops of the columns just out past its outer edge
// (the next ring's, or past the rim: ground still standing, in the land read), each kept only where the scene shows
// that very top (its depth where it should be), and not under water.
fn sh_calib(b: u32, C: vec3<f32>, dy0: f32) -> vec4<f32> {
    let am = 0.5 * (sh_w(b) + sh_w(b + 1u));
    let span = sh_w(b + 1u) - sh_w(b);
    let ro = 0.5 * (sh_w(b + 4u) + sh_w(b + 5u));
    var acc = vec3<f32>(0.0);
    var n = 0.0;
    for (var j = 0; j < 16; j = j + 1) {
        let a = am + (f32(j % 4) / 3.0 - 0.5) * span * 1.1;
        let r = ro + 2.5 + 3.0 * f32(j / 4);
        let ci = i32(floor(r * cos(a) + 0.5)) + SH_G;
        let ck = i32(floor(r * sin(a) + 0.5)) + SH_G;
        let w = sh_colw(ci, ck);
        if (w.x >> 31u == 0u || ((w.y >> 30u) & 1u) == 1u) {
            continue;
        }
        let alb = sh_top_albedo(w);
        let top = C + vec3<f32>(f32(ci - SH_G), f32(sh_col_h(w)) - dy0 + alb.w, f32(ck - SH_G));
        let P = project_rel(top);
        if (P.z < 0.0 || P.x < 0.0 || P.y < 0.0 || P.x > 1.0 || P.y > 1.0) {
            continue;
        }
        let d = depth_at(P.xy);
        if (is_sky(d)) {
            continue;
        }
        let seen = world_offset(P.xy, d);
        if (length(seen - top) > 1.0 + 0.008 * length(top)) {
            continue;
        }
        let sc = textureSampleLevel(scene_color, linear_sampler, P.xy, 0.0).rgb;
        acc = acc + clamp(sc / max(alb.xyz, vec3<f32>(0.03)), vec3<f32>(0.0), vec3<f32>(1.6));
        n = n + 1.0;
    }
    return vec4<f32>(acc / max(n, 1.0), n);
}

// The view ray (o + t d, in slab b's frame) through the blocks of the land it carries (slab k's columns of the land's
// square, `off` taking its frame into the square's), from tn to tf: x the distance to the block it hits (1e9 none),
// yzw the face's normal in its frame; and the block's colour (sRGB) and the pixel's size there for `pw0` a pixel's
// angle.
struct ShVox {
    t: f32,
    n: vec3<f32>,
    c: vec3<f32>,
}
fn sh_vox(b: u32, k: i32, o: vec3<f32>, d: vec3<f32>, off: vec3<f32>, t_max: f32, px_a: f32) -> ShVox {
    var v: ShVox;
    v.t = 1.0e9;
    let lo = vec3<f32>(sh_w(b + 18u), sh_w(b + 22u), sh_w(b + 19u));
    let hi = vec3<f32>(sh_w(b + 20u) + 1.0, sh_w(b + 23u), sh_w(b + 21u) + 1.0);
    let P = o + off;
    let inv = 1.0 / select(d, vec3<f32>(1.0e-7), abs(d) < vec3<f32>(1.0e-7));
    let ta = (lo - P) * inv;
    let tb = (hi - P) * inv;
    let tn3 = min(ta, tb);
    let tf3 = max(ta, tb);
    let tn = max(max(tn3.x, tn3.y), max(tn3.z, 0.0));
    let tf = min(min(tf3.x, tf3.y), min(tf3.z, t_max));
    if (tf <= tn) {
        return v;
    }
    let ylo = sh_w(b + 22u);
    var t = tn + 1.0e-4;
    let p0 = P + d * t;
    var cell = floor(p0);
    let stp = sign(d);
    let tdel = abs(inv);
    var tnext = (cell + max(stp, vec3<f32>(0.0)) - P) * inv;
    // (which axis it last stepped along: the face it enters by; at the start, the box's face it came in by)
    var axis = 1;
    if (tn3.x >= tn3.y && tn3.x >= tn3.z) {
        axis = 0;
    } else if (tn3.z >= tn3.y) {
        axis = 2;
    }
    var lastc = vec2<i32>(-99999);
    var w = vec3<u32>(0u);
    for (var i = 0; i < 160; i = i + 1) {
        if (t > tf) {
            break;
        }
        let cc = vec2<i32>(i32(cell.x), i32(cell.z));
        if (any(cc != lastc)) {
            w = sh_colw(cc.x, cc.y);
            lastc = cc;
        }
        if (w.x != 0u) {
            let blk = sh_cell(w, k, cell, ylo);
            if (blk.x != 0u) {
                var n = vec3<f32>(0.0);
                if (axis == 0) {
                    n.x = -stp.x;
                } else if (axis == 1) {
                    n.y = -stp.y;
                } else {
                    n.z = -stp.z;
                }
                v.t = t;
                v.n = n;
                let f = P + d * t - cell;
                v.c = sh_block_col(blk, w, cell, n, clamp(f, vec3<f32>(0.0), vec3<f32>(0.9999)), t * px_a);
                return v;
            }
        }
        // (on to the next cell)
        if (tnext.x < tnext.y && tnext.x < tnext.z) {
            t = tnext.x;
            tnext.x = tnext.x + tdel.x;
            cell.x = cell.x + stp.x;
            axis = 0;
        } else if (tnext.y < tnext.z) {
            t = tnext.y;
            tnext.y = tnext.y + tdel.y;
            cell.y = cell.y + stp.y;
            axis = 1;
        } else {
            t = tnext.z;
            tnext.z = tnext.z + tdel.z;
            cell.z = cell.z + stp.z;
            axis = 2;
        }
    }
    return v;
}

// The land's colours, a block at a time: grass, its side, dirt, stone in strata, deepslate deep down, broken rock under.
fn sh_block_tint(q: vec3<f32>, k: f32) -> f32 {
    return 0.86 + 0.28 * fh31(floor(q) + vec3<f32>(k * 17.0, 0.0, 0.0));
}
fn sh_earth(dtop: f32, face: f32, q: vec3<f32>, k: f32, day: f32) -> vec3<f32> {
    let bt = sh_block_tint(q, k);
    if (face < 0.5) {
        let g = vec3<f32>(0.17, 0.31, 0.11) * (0.85 + 0.3 * fvnoise(q.xz * 0.25 + vec2<f32>(k)));
        return g * bt;
    }
    if (face > 0.5 && face < 1.5) {
        return vec3<f32>(0.11, 0.10, 0.095) * bt;
    }
    if (dtop < 0.9) {
        return select(vec3<f32>(0.25, 0.18, 0.12), vec3<f32>(0.19, 0.3, 0.1), dtop < 0.3 + 0.25 * fh21(floor(q.xz))) * bt;
    }
    if (dtop < 4.0 + 1.5 * fh21(floor(q.xz) + vec2<f32>(k))) {
        return vec3<f32>(0.27, 0.19, 0.13) * bt;
    }
    // stone, in bands (andesite, tuff, granite now and then), deepslate under it
    let band = floor((dtop + 0.7 * fvnoise(q.xz * 0.2)) / 3.0);
    let hb = fh21(vec2<f32>(band, k * 0.37));
    var st = vec3<f32>(0.40, 0.395, 0.385);
    if (hb > 0.82) {
        st = vec3<f32>(0.46, 0.33, 0.28);
    } else if (hb > 0.66) {
        st = vec3<f32>(0.33, 0.34, 0.31);
    } else if (hb < 0.15) {
        st = vec3<f32>(0.5, 0.5, 0.49);
    }
    let ore = step(0.985, fh31(floor(q) + vec3<f32>(3.0, k, 1.0)));
    st = mix(st, vec3<f32>(0.08, 0.08, 0.08), ore);
    return mix(st, vec3<f32>(0.2, 0.2, 0.22), smoothstep(10.0, 16.0, dtop)) * bt;
}

// ---- the cracks: a network racing out over the land from the middle, branching, and the slabs' outlines opening up
//      before they go (a Voronoi of cells stretched out along the radius, so most run out from the middle) ------------
fn sh_net(q: vec2<f32>, er: vec2<f32>) -> vec2<f32> {
    // in a frame along the radius and across it, cells longer along it
    let u = vec2<f32>(dot(q, er), dot(q, vec2<f32>(-er.y, er.x))) * vec2<f32>(0.075, 0.14);
    let w = u + 0.35 * vec2<f32>(fvnoise(u * 1.7 + vec2<f32>(3.1, 1.2)), fvnoise(u * 1.7 + vec2<f32>(7.4, 5.3)));
    let i = floor(w);
    let f = w - i;
    var d1 = 9.0;
    var d2 = 9.0;
    for (var y = -1; y <= 1; y = y + 1) {
        for (var x = -1; x <= 1; x = x + 1) {
            let g = vec2<f32>(f32(x), f32(y));
            let h = vec2<f32>(fh21(i + g), fh21(i + g + vec2<f32>(19.7, 4.1)));
            let d = length(g + h - f);
            if (d < d1) {
                d2 = d1;
                d1 = d;
            } else if (d < d2) {
                d2 = d;
            }
        }
    }
    // (the distance to the nearest edge, in blocks, roughly; and a value along it)
    return vec2<f32>((d2 - d1) * 6.0, fh21(i));
}

// ---- the land as it really is (sh_land.rs): each column's ground, the blocks on it, under it and deeper, the snow on
//      it, the trunk and leaves of a tree standing on it, and the slab it is part of ------------------------------------
// Column (ci, ck) of the land's square: its three words (0s: not read, or outside it).
fn sh_colw(ci: i32, ck: i32) -> vec3<u32> {
    if (ci < 0 || ck < 0 || ci >= SH_GW || ck >= SH_GW) {
        return vec3<u32>(0u);
    }
    let i = SH_GRID + 3u * u32(ck * SH_GW + ci);
    if (i + 2u >= arrayLength(&mod_data)) {
        return vec3<u32>(0u);
    }
    return vec3<u32>(mod_data[i], mod_data[i + 1u], mod_data[i + 2u]);
}
// A 5-6-5 colour (sRGB), or `def` for 0 (not known).
fn sh_565(c: u32, def: vec3<f32>) -> vec3<f32> {
    if (c == 0u) {
        return def;
    }
    return vec3<f32>(f32((c >> 11u) & 31u) / 31.0, f32((c >> 5u) & 63u) / 63.0, f32(c & 31u) / 31.0);
}
// Its ground's top, from the target's ground (one above its highest ground block).
fn sh_col_h(w: vec3<u32>) -> i32 {
    return i32(w.x & 511u) - 256;
}
// A material's colours (sRGB): x its top's, y its sides'; and its kind (0 plain, 1 leaves, 2 log, 3 water, 4 grassy) and
// how much each block of it varies.
struct ShMat {
    top: vec3<f32>,
    side: vec3<f32>,
    kind: u32,
    tint: u32,
    var_: f32,
}
fn sh_mat(m: u32) -> ShMat {
    var o: ShMat;
    let i = SH_MAT + 2u * m;
    var a = 0x00646e7au;
    var b = 0x2e646e7au;
    if (i + 1u < arrayLength(&mod_data)) {
        a = mod_data[i];
        b = mod_data[i + 1u];
    }
    o.top = vec3<f32>(f32(a & 255u), f32((a >> 8u) & 255u), f32((a >> 16u) & 255u)) / 255.0;
    o.side = vec3<f32>(f32(b & 255u), f32((b >> 8u) & 255u), f32((b >> 16u) & 255u)) / 255.0;
    o.kind = (a >> 24u) & 7u;
    o.tint = (a >> 27u) & 3u;
    o.var_ = f32(b >> 24u) / 255.0;
    return o;
}
// What block of slab k is at cell c of the land's square (y from the target's ground), given its column's words and its
// underside `ylo`: 0 none; else 1 + the material, the second the cell's part (0 ground's top block, 1 deeper ground,
// 2 trunk, 3 leaves).
fn sh_cell(w: vec3<u32>, k: i32, c: vec3<f32>, ylo: f32) -> vec2<u32> {
    if (w.x >> 31u == 0u || i32((w.x >> 21u) & 511u) != k + 1) {
        return vec2<u32>(0u);
    }
    let y = i32(c.y);
    let g = sh_col_h(w) - 1;
    // (its underside broken, a block or two either way)
    let lo = i32(ylo) + i32(fh21(c.xz) * 2.5);
    if (y < lo) {
        return vec2<u32>(0u);
    }
    if (y <= g) {
        let dd = g - y;
        if (dd == 0) {
            return vec2<u32>(1u + ((w.x >> 9u) & 63u), 0u);
        }
        if (dd <= 3) {
            return vec2<u32>(1u + ((w.x >> 15u) & 63u), 1u);
        }
        if (dd <= 7) {
            return vec2<u32>(1u + (w.y & 63u), 1u);
        }
        // (deeper: stone, deepslate deeper still)
        return vec2<u32>(select(13u, 19u, dd > 16 + i32(fh21(c.xz + vec2<f32>(5.0)) * 4.0)), 1u);
    }
    let up = y - g;
    let log = (w.y >> 6u) & 63u;
    if (log > 0u && up <= i32((w.y >> 12u) & 15u)) {
        return vec2<u32>(1u + log, 2u);
    }
    let leaf = (w.y >> 16u) & 63u;
    if (leaf > 0u && up >= i32((w.y >> 22u) & 15u) && up <= i32((w.y >> 26u) & 15u)) {
        // (leaves, ragged: a few gaps in them)
        if (fh31(c + vec3<f32>(0.0, 31.0, 0.0)) < 0.16) {
            return vec2<u32>(0u);
        }
        return vec2<u32>(1u + leaf, 3u);
    }
    return vec2<u32>(0u);
}
// A block's colour on face `fn` (its normal, along an axis) at `f` within it (0..1 each way), at cell `c`, as the game's
// own blocks look: the material's colour varying a little block to block and texel to texel (the texels fading out
// once they are smaller than a pixel: `pw` a pixel's size, in blocks), the grass's fringe on the sides of its block,
// snow on it, bark streaks and log rings. sRGB.
fn sh_block_col(cell: vec2<u32>, w: vec3<u32>, c: vec3<f32>, fnrm: vec3<f32>, f: vec3<f32>, pw: f32) -> vec3<f32> {
    var m = sh_mat(cell.x - 1u);
    // (tinted as the game tints it there: grass by the biome's grass colour, leaves by its foliage colour)
    if (m.tint == 1u) {
        m.top = m.top * sh_565(w.z & 0xffffu, vec3<f32>(0.569, 0.741, 0.349));
    } else if (m.tint == 2u) {
        m.top = m.top * sh_565(w.z >> 16u, vec3<f32>(0.467, 0.671, 0.184));
        m.side = m.top;
    }
    let topf = fnrm.y > 0.5;
    var col = select(m.side, m.top, topf || fnrm.y < -0.5);
    // (the texel it is in on that face)
    var uv = f.xz;
    if (abs(fnrm.x) > 0.5) {
        uv = f.zy;
    } else if (abs(fnrm.z) > 0.5) {
        uv = f.xy;
    }
    let tx = floor(uv * 16.0);
    let tex = fh31(vec3<f32>(tx, 7.0) + c * vec3<f32>(1.31, 2.17, 0.73)) - 0.5;
    let texk = 1.0 - smoothstep(0.03, 0.09, pw);
    if (m.kind == 4u && cell.y == 0u && !topf && fnrm.y > -0.5) {
        // (grassy: its sides the dirt, with the grass's fringe hanging over the top)
        let fringe = 0.82 - 0.12 * step(0.5, fh21(vec2<f32>(tx.x, c.x + c.z * 3.0)));
        if (uv.y > fringe) {
            col = m.top;
        }
    }
    if (m.kind == 2u && !(topf || fnrm.y < -0.5)) {
        // (bark: streaks up the log)
        col = col * (0.85 + 0.3 * fh21(vec2<f32>(tx.x, c.x * 7.0 + c.z)) * texk + 0.15 * (1.0 - texk));
    }
    if (cell.y == 0u && (w.x >> 30u & 1u) == 1u) {
        // (snow lying on it: its top white, a rim of white down its sides)
        if (topf || uv.y > 0.86) {
            col = vec3<f32>(0.95, 0.98, 0.99);
        }
    }
    let blockv = (fh31(c) - 0.5) * m.var_;
    let leafk = select(1.0, 1.8, m.kind == 1u);
    // (leaves: the darker inside of the tree showing through their gaps)
    let leafd = select(1.0, 0.82, m.kind == 1u);
    return col * leafd * (1.0 + blockv + tex * m.var_ * 0.9 * leafk * texk);
}

// ---- the cracks: they race out from the middle in spurts (sinkhole.rs's sh_spurts), along the lines the slabs will
//      break on, thin at first, widening into dark gaps as the slab each side is about to go ----------------------------
fn sh_spurt_t(i: i32, seed: u32) -> f32 {
    return 1.0 + 6.4 * (f32(i) + 0.15 + 0.7 * mh(u32(i), seed, 0x7c0u)) / f32(SH_SPURTS);
}
fn sh_spurt_r(i: i32) -> f32 {
    return SH_R * 1.3 * pow(f32(i + 1) / f32(SH_SPURTS), 0.85);
}
// When the cracks reach `rr` out (the radius over the lag at that angle): in the spurt that runs over it, slowing as it
// stops.
fn sh_crack_at(rr: f32, seed: u32) -> f32 {
    let u = pow(clamp(rr / (SH_R * 1.3), 0.0, 1.0), 1.0 / 0.85) * f32(SH_SPURTS);
    let i = clamp(i32(ceil(u)) - 1, 0, SH_SPURTS - 1);
    let r0 = select(0.0, sh_spurt_r(i - 1), i > 0);
    let f = saturate((rr - r0) / max(sh_spurt_r(i) - r0, 1.0e-3));
    return sh_spurt_t(i, seed) + SH_SPURT * (1.0 - sqrt(1.0 - f));
}
// The nearest edge of the slab at polar (r, a), as sh_slab_at finds it: x the slab (-1 outside the rim), y the distance
// to the edge, z which side of the edge its slab is (1: the side that drops first), w along the edge (in blocks); and
// the edge's normal (xz).
struct ShEdge {
    k: f32,
    d: f32,
    first: f32,
    along: f32,
    n: vec2<f32>,
    t: f32,
}
fn sh_edge(r: f32, a: f32, rim: f32, seed: u32) -> ShEdge {
    var e: ShEdge;
    e.k = -1.0;
    if (r >= rim) {
        return e;
    }
    let nr = i32(sh_w(1u));
    var j = 0;
    loop {
        if (j + 1 >= nr || r < sh_ring_r(j + 1, a, rim)) {
            break;
        }
        j = j + 1;
    }
    let r0 = sh_ring_r(j, a, rim);
    let r1 = sh_ring_r(j + 1, a, rim);
    let b = SH_RG + u32(j) * SH_RW;
    let n = i32(sh_w(b + 2u));
    let th0 = sh_w(b + 3u);
    let off = i32(sh_w(b + 4u));
    let u = fract((a - th0) / TAU) * f32(n);
    let m0 = min(i32(floor(u)), n - 1);
    let jit0 = 0.35 * (mh(u32(m0 % n), seed, 0x710u + u32(j)) - 0.5);
    let jit1 = 0.35 * (mh(u32((m0 + 1) % n), seed, 0x710u + u32(j)) - 0.5);
    var m = m0;
    var e0 = f32(m0) + jit0;
    var e1 = f32(m0 + 1) + jit1;
    if (u < e0) {
        m = (m0 + n - 1) % n;
        e1 = e0;
        e0 = f32(m0 - 1) + 0.35 * (mh(u32((m0 + n - 1) % n), seed, 0x710u + u32(j)) - 0.5);
    } else if (u >= e1) {
        m = (m0 + 1) % n;
        e0 = e1;
        e1 = f32(m0 + 2) + 0.35 * (mh(u32((m0 + 2) % n), seed, 0x710u + u32(j)) - 0.5);
    }
    let ds0 = (u - e0) / f32(n) * TAU * r;
    let ds1 = (e1 - u) / f32(n) * TAU * r;
    let din = select(1.0e4, r - r0, j > 0);
    let dout = r1 - r;
    let k = off + m;
    e.k = f32(k);
    e.t = sh_w(SH_SB + u32(k) * SH_SW + 6u);
    let er = vec2<f32>(cos(a), sin(a));
    let et = vec2<f32>(-er.y, er.x);
    e.d = min(min(ds0, ds1), min(din, dout));
    if (e.d == dout) {
        // (its outer edge: the slab inside goes first)
        e.n = er;
        e.first = 1.0;
        e.along = a * r1;
    } else if (e.d == din) {
        e.n = er;
        e.first = 0.0;
        e.along = a * r0;
    } else {
        // (a side: which side drops first, the edge's own)
        let edge = select(m + 1, m, ds0 < ds1);
        let lead = step(0.5, mh(u32(edge % n), seed, 0x7c5u + u32(j)));
        e.n = et;
        e.first = select(1.0 - lead, lead, ds0 < ds1);
        e.along = r + 37.0 * f32(edge);
    }
    return e;
}

// ---- dust: what the collapse throws up out of the pit and rolls out low over the land, and the puff of the give --
fn sh_dust(p: vec3<f32>, time: f32, rimm: f32) -> f32 {
    let r = length(p.xz);
    var d = 0.0;
    // the give's puff, then the sag's
    let tg = time - SH_GIVE;
    if (tg > 0.0 && tg < 6.0) {
        let rr = 14.0 + 10.0 * (1.0 - exp(-tg * 1.5));
        d = d + exp(-tg * 0.7) * smoothstep(rr, rr * 0.5, r) * smoothstep(10.0 + 6.0 * tg, 0.0, p.y + 4.0) * 0.9;
    }
    let tc = time - SH_C0;
    if (tc > 0.0) {
        let env = smoothstep(0.0, 1.5, tc) * (1.0 - smoothstep(12.0, SH_END - SH_C0, tc));
        // out of the pit: boiling up where the land has gone, higher and higher, thinning as it climbs
        let reach = min(sh_reached(time), SH_R * 1.12) + 6.0;
        let H = 18.0 + 75.0 * (1.0 - exp(-tc / 6.0));
        let plume = smoothstep(reach, reach - 25.0, r) * smoothstep(H, H * 0.3, p.y) * smoothstep(-70.0, -20.0, p.y);
        // rolling out over the land, low, from the rim
        let out = rimm + 90.0 * (1.0 - exp(-max(time - (SH_C0 + 3.0), 0.0) / 6.0));
        let hk = 5.0 + 7.0 * smoothstep(rimm, out, r);
        let skirt = smoothstep(rimm - 20.0, rimm, r) * smoothstep(out, out - 40.0, r) * smoothstep(hk, 0.0, p.y) * step(-2.0, p.y) * (1.0 - 0.6 * smoothstep(rimm, out, r));
        let late = 1.0 - smoothstep(4.0, 14.0, tc) * smoothstep(-10.0, 30.0, p.y) * 0.7;
        d = d + env * late * (plume * 1.0 + skirt * 0.6);
    }
    if (d < 0.003) {
        return 0.0;
    }
    let q = p * 0.045 + vec3<f32>(0.0, -time * 0.18, 0.0) + vec3<f32>(time * 0.05, 0.0, 0.0);
    let n = 0.62 * fvnoise3(q) + 0.38 * fvnoise3(q * 2.3 + vec3<f32>(5.1, 1.3 - time * 0.2, 7.7));
    return d * smoothstep(0.32, 0.8, n) * 2.0;
}

fn sinkhole(in: StageIn) -> vec4<f32> {
    let uv = in.uv;
    let time = now();
    let cam = frame.camera_position.xyz;
    let k = intensity_v();
    let seed = u32(seed_v());
    let px_a = frame.view_params.w / frame.resolution.y;      // (the angle a pixel spans)
    let anc = anchor_xz();
    let gy = target_y();
    let C = vec3<f32>(anc.x, gy, anc.y) - cam;              // the pit's middle, on the target's ground
    let n_slabs = sh_count();
    let sun = frame.sun.xyz;
    let day = saturate(sun.y * 2.5 + 0.35);

    let d = depth_at(uv);
    let sky = is_sky(d);
    let rel = world_offset(uv, select(d, 0.5, sky));
    var scene_len = select(1.0e9, length(rel), !sky);
    let rd = normalize(world_offset(uv, 0.5));
    let scene = srgb_to_linear(textureSampleLevel(scene_color, linear_sampler, uv, 0.0).rgb);
    var col = scene;
    let Q = rel - C;                                          // the scene's point from the pit's middle
    let rq = length(Q.xz);
    let aq = atan2(Q.z, Q.x);
    let rimq = sh_rim(aq);
    let Ls = normalize(select(vec3<f32>(0.3, 1.0, 0.2), sun, sun.y > 0.05));
    let amb = mix(vec3<f32>(0.03, 0.035, 0.05), vec3<f32>(0.32, 0.36, 0.44), day);
    let sunc = vec3<f32>(1.25, 1.18, 1.05) * day;

    // (a pixel's footprint on the land, from the derivatives of where it is: here, in uniform control flow)
    let dQx = dpdx(Q);
    let dQy = dpdy(Q);
    // (the surface's normal there, from them, towards the eye)
    var nQ = normalize(cross(dQx, dQy) + vec3<f32>(0.0, 1.0e-9, 0.0));
    if (dot(nQ, rel) > 0.0) {
        nQ = -nQ;
    }
    let dy0 = gy - (block_y() + 1.0);                         // the target's ground over its block's top
    let fade = 1.0 - smoothstep(SH_LEN - SH_FADE, SH_LEN, time);
    let fade_e = fade * fade * (3.0 - 2.0 * fade);

    // ---- on the land: the cracks, and the pit's darkness where it has been dug -----------------------------------
    if (!sky && n_slabs > 0 && rq < SH_R * 1.4) {
        let pw = scene_len * px_a;
        // (the land's column here, looked up a little inside the block the pixel is on, so a pixel on a block's face
        // never flips between the columns either side of it; is this its ground's top? With a tolerance that grows
        // with the distance, as the depth's precision falls, and softly, so nothing flickers; only on top faces, and
        // never across water)
        let Qs = Q - nQ * 0.08;
        let cw = sh_colw(i32(floor(Qs.x + 0.5)) + SH_G, i32(floor(Qs.z + 0.5)) + SH_G);
        var gw = 1.0 - smoothstep(2.5, 3.5, abs(Q.y));
        if (cw.x >> 31u == 1u) {
            let hy = f32(sh_col_h(cw)) - dy0;
            let tol = 0.15 + scene_len * 0.004;
            gw = (1.0 - smoothstep(hy + tol, hy + 2.0 * tol + 0.1, Qs.y)) * smoothstep(hy - 1.1 - tol, hy - 0.95, Qs.y)
                * select(1.0, 0.0, ((cw.y >> 30u) & 1u) == 1u);
        }
        gw = gw * smoothstep(0.5, 0.8, nQ.y);
        let on_ground = gw > 0.01;
        // the cracks, along the slabs' edges, from 1 s, racing out in spurts, the fingers running ahead here and
        // lagging there; thin at first, widening, then gaping as the slabs each side are about to go
        if (time > 0.9 && on_ground && time < sh_front(rq) + 0.2) {
            let e = sh_edge(rq, aq, rimq, seed);
            let lag = 0.8 + 0.45 * fvnoise(vec2<f32>(cos(aq), sin(aq)) * 2.3 + vec2<f32>(f32(seed % 97u) * 0.37));
            let age = time - sh_crack_at(rq / lag, seed);
            if (e.k >= 0.0 && age > 0.0 && time < e.t - SH_DIG + 0.02) {
                let o = smoothstep(e.t - 1.9, e.t - 0.1, time);
                var w = 0.06 + 0.42 * pow(saturate(age / 2.2), 0.7) + 0.2 * smoothstep(SH_GIVE - 0.5, SH_GIVE + 1.5, time) + 0.8 * o * o;
                // (the footprint across the crack, from the derivatives; at a silhouette it is huge, and it fades out)
                let n3 = vec3<f32>(e.n.x, 0.0, e.n.y);
                let fp = max(length(vec2<f32>(dot(dQx, n3), dot(dQy, n3))), pw * 0.35);
                // (its edges broken and wandering, less so where a pixel is wider than the wander)
                let wq = Q.xz + vec2<f32>(f32(seed % 61u) * 7.3, 0.0);
                let jag = (fvnoise(wq * 0.42) - 0.5) * (0.5 + 0.9 * w) + (fvnoise(wq * 1.6 + vec2<f32>(4.1, 9.3)) - 0.5) * (0.25 + 0.5 * w) * saturate(1.5 - fp * 1.5);
                let d = e.d + jag;
                // (never thinner on screen than most of a pixel: drawn wider and fainter instead, so it neither
                // breaks up nor shimmers; and faded out far off)
                let wd = max(w, 0.7 * fp);
                let cov = saturate((wd - d) / fp + 0.5) * sqrt(w / wd) * (1.0 - smoothstep(1.5, 4.0, fp)) * (1.0 - smoothstep(380.0, 650.0, scene_len));
                // (the side that drops first stepped down a little, in shadow beside the gap)
                let drop = (0.25 + 0.7 * o) * e.first;
                let band = saturate((w + drop - d) / fp + 0.5) * (1.0 - cov) * step(0.01, drop) * (1.0 - smoothstep(1.5, 4.0, fp));
                // (dust puffing up out of it as it opens, a second or so)
                let puff = exp(-age * 1.6) * saturate((w * 2.5 + 1.5 - e.d) / 1.5);
                col = mix(col, vec3<f32>(0.22, 0.19, 0.16) * (amb + sunc * 0.5), 0.35 * puff * k * gw);
                col = col * (1.0 - 0.45 * band * k * gw);
                col = mix(col, vec3<f32>(0.006, 0.005, 0.005), 0.94 * cov * k * gw);
            }
        }
        // and round the rim once it has gone: the land there torn along it
        let sl = sh_slab_at(rq, aq, rimq, seed);
        if (sl.x < 0.0 && time > sh_front(rimq) && sl.y < 14.0 && on_ground) {
            let wq = Q.xz * 0.08;
            let wob = (fvnoise(wq + vec2<f32>(3.0)) - 0.5) * 5.0;
            let dd = abs(fract((sl.y + wob) / 4.6 + 0.3) - 0.5) * 4.6;
            let w = 0.12 * fvnoise(Q.xz * 0.15 + vec2<f32>(9.0)) * smoothstep(14.0, 4.0, sl.y);
            let fp = max(length(vec2<f32>(length(dQx.xz), length(dQy.xz))) * 0.7, pw * 0.35);
            let wd = max(w, 0.7 * fp);
            let crack = saturate((wd - dd) / fp + 0.5) * (w / max(wd, 1.0e-4)) * (1.0 - smoothstep(1.5, 4.0, fp));
            col = col * (1.0 - 0.88 * crack * k * fade_e * gw);
        }
        // the pit, where it has been dug: dark, darker the deeper, a cold haze down in it; and, until it is dug on down,
        // its floor 25 down hidden in murk; fading slowly away over the strike's last seconds (the real pit's walls
        // darken with depth on their own)
        let into = rimq + 7.0 - rq;
        if (into > 0.0 && Q.y < -2.5 && time > sh_front(rq) - SH_DIG) {
            let dep = -Q.y;
            var dark = pow(smoothstep(2.0, 108.0, dep), 0.7);
            dark = max(dark, smoothstep(13.0, 24.0, dep) * 0.93 * (1.0 - smoothstep(SH_DEEP0 + 2.0, SH_DEEP0 + 7.0, time)));
            let haze = mix(vec3<f32>(0.012, 0.012, 0.014), vec3<f32>(0.05, 0.05, 0.055), day);
            col = mix(col, haze, dark * 0.97 * k * fade_e);
        }
    }

    // ---- the slabs: solid, the nearest drawn, hidden by anything nearer; each from the moment its land is dug, in its
    //      place, as the land it stands in for was (the land's own blocks, when it was read), then letting go ---------
    var hit_t = 1.0e9;
    var hit_c = vec3<f32>(0.0);
    var hit_b = 0u;
    var hit_base = vec3<f32>(0.0);
    var hit_below = 0.0;
    if (n_slabs > 0 && time > SH_C0 - SH_DIG - 0.1 && time < 16.6 + SH_FALL) {
        for (var i = 0; i < n_slabs; i = i + 1) {
            let b = SH_SB + u32(i) * SH_SW;
            let s = time - sh_w(b + 6u);
            if (s < -SH_DIG || s > SH_FALL) {
                continue;
            }
            let ps = sh_pose(b, i, s, C);
            let real = sh_w(b + 15u) > 0.5;
            // (a sphere round it first: round the land it carries, or round its block of ground)
            var cc = ps.o + ps.drop;
            var rad = 0.5 * length(vec2<f32>(sh_w(b + 5u) - sh_w(b + 2u), (sh_w(b + 1u) - sh_w(b)) * sh_w(b + 5u))) + sh_w(b + 10u) + 4.0;
            // (its frame into the land's square)
            let mq = (sh_corner(sh_w(b + 2u), sh_w(b)) + sh_corner(sh_w(b + 3u), sh_w(b + 1u)) + sh_corner(sh_w(b + 5u), sh_w(b + 1u))
                + sh_corner(sh_w(b + 4u), sh_w(b))) * 0.25;
            let off = vec3<f32>(mq.x + 0.5 + f32(SH_G), sh_w(b + 7u) + dy0, mq.y + 0.5 + f32(SH_G));
            if (real) {
                let lo = vec3<f32>(sh_w(b + 18u), sh_w(b + 22u), sh_w(b + 19u));
                let hi = vec3<f32>(sh_w(b + 20u) + 1.0, sh_w(b + 23u), sh_w(b + 21u) + 1.0);
                cc = sh_from(ps, 0.5 * (lo + hi) - off);
                rad = 0.5 * length(hi - lo) + 1.0;
            }
            let tc = dot(cc, rd);
            if (dot(cc, cc) - tc * tc > rad * rad || tc + rad < 0.0 || tc - rad > min(hit_t, scene_len + 1.0)) {
                continue;
            }
            let o = sh_to(ps, vec3<f32>(0.0));
            let dl = sh_dir_to(ps, rd);
            var t_hit = 1.0e9;
            var nl = vec3<f32>(0.0, 1.0, 0.0);
            var base = vec3<f32>(0.0);
            if (real) {
                let vx = sh_vox(b, i, o, dl, off, min(hit_t, scene_len + 0.3), px_a);
                if (vx.t >= 1.0e8) {
                    continue;
                }
                t_hit = vx.t;
                nl = vx.n;
                base = vx.c;
            } else {
                // (its land not read: a block of ground, grass over dirt over stone, its top its ground's plane)
                let h = sh_hit(b, o, dl);
                if (h.y <= h.x || h.x <= 0.0 || h.x >= hit_t || h.x > scene_len + 0.7) {
                    continue;
                }
                t_hit = h.x;
                let q = o + dl * h.x;
                let sx = sh_w(b + 8u);
                let sz = sh_w(b + 9u);
                let dtop = sx * q.x + sz * q.z - q.y;
                nl = normalize(vec3<f32>(-sx, 1.0, -sz));
                if (h.z > 0.5 && h.z < 1.5) {
                    nl = vec3<f32>(0.0, -1.0, 0.0);
                } else if (h.z > 1.5) {
                    let c = array<vec2<f32>, 4>(sh_corner(sh_w(b + 2u), sh_w(b)), sh_corner(sh_w(b + 3u), sh_w(b + 1u)),
                        sh_corner(sh_w(b + 5u), sh_w(b + 1u)), sh_corner(sh_w(b + 4u), sh_w(b)));
                    let fi = i32(h.z) - 2;
                    let e = c[(fi + 1) % 4] - c[fi];
                    var n2 = normalize(vec2<f32>(e.y, -e.x) + vec2<f32>(1.0e-7));
                    let m = (c[0] + c[1] + c[2] + c[3]) * 0.25;
                    if (dot(n2, c[fi] - m) < 0.0) {
                        n2 = -n2;
                    }
                    nl = vec3<f32>(n2.x, 0.0, n2.y);
                }
                base = linear_to_srgb(sh_earth(dtop, h.z, q + ps.o + cam, f32(i), day));
            }
            hit_t = t_hit;
            // (lit as the game lights its blocks: by the face, the top brightest, the sides less, the underside least,
            // turning with the slab; and by the time of day)
            let nw = sh_dir_from(ps, nl);
            let shade = 0.6 * nw.x * nw.x + 0.8 * nw.z * nw.z + select(0.5, 1.0, nw.y > 0.0) * nw.y * nw.y;
            // (the sky's light by the time of day, as the game darkens it towards night: 0.25 is noon)
            hit_b = b;
            hit_base = base * shade;
            hit_below = (gy + sh_w(b + 7u)) - (cam + rd * t_hit).y;
        }
    }
    if (hit_t < 1.0e8) {
        // lit as the real land round it is lit, this frame: the scene's own colour of the tops of a dozen columns of
        // untouched ground beside where the slab lay (in the land read, seen, and where they are expected), over what
        // the land's colours make of them, channel by channel; whatever the hour, the weather, the brightness
        // setting or a torch near. Where none is seen, by the sky's light for the time of day (0.25 noon).
        let cal = sh_calib(hit_b, C, dy0);
        let skyk = saturate(cos((frame.time.y - 0.25) * TAU) * 2.0 + 0.5);
        let light = mix(vec3<f32>(mix(0.2, 1.0, skyk)), cal.xyz, smoothstep(1.0, 4.0, cal.w));
        var c = srgb_to_linear(saturate(hit_base * light));
        // (lit as the land round it while it tips and is still at the rim; into the pit's shadow only as it sinks
        // below where its ground was, and its dark deeper still, by how deep, eased)
        let shadow = smoothstep(3.0, 22.0, hit_below);
        c = mix(c, c * 0.3, shadow * shadow * (3.0 - 2.0 * shadow) * 0.7);
        let pit = smoothstep(12.0, 75.0, hit_below);
        c = mix(c, vec3<f32>(0.012, 0.012, 0.014), pit * pit * (3.0 - 2.0 * pit) * 0.95);
        hit_c = c;
        col = mix(col, hit_c, k);
        scene_len = hit_t;
    }

    // ---- water pouring over the rim where the pit cut a river or a lake: from the water's own surface, over the
    //      rim as it wanders, curving over a lip and falling faster and faster, a little out from the wall; in strands
    //      of the water's own blue (the biome's tint) with darker gaps between, breaking up into white lower down, mist
    //      where it goes into the dark ---------------------------------------------------------------------------------
    let nwf = i32(sh_w(SH_WF));
    if (n_slabs > 0 && nwf > 0) {
        let wt = SH_WF + 1u < arrayLength(&mod_data);
        var tint = vec3<f32>(0.247, 0.463, 0.894);
        if (wt && mod_data[SH_WF + 1u] != 0u) {
            let c = mod_data[SH_WF + 1u];
            tint = vec3<f32>(f32((c >> 16u) & 255u), f32((c >> 8u) & 255u), f32(c & 255u)) / 255.0;
        }
        // (the game's water: its grey texture tinted, darker for the depth showing through)
        let blue = srgb_to_linear(tint * 0.62);
        for (var w = 0; w < min(nwf, 6); w = w + 1) {
            let b = SH_WF + 4u + u32(w) * 4u;
            let ac = sh_w(b);
            let hw = sh_w(b + 1u);
            let ytop = sh_w(b + 2u) - 0.12;
            let s = time - sh_w(b + 3u);
            if (s < 0.0) {
                continue;
            }
            // (its front falling, faster and faster)
            let fall = min(0.5 * 30.0 * s * s, 160.0);
            // the sheet: r = the rim there, less how far it has come out from the wall by the depth it has fallen
            // (a lip over the edge, then a slight outward arc); met by a few steps from where the ray meets the
            // cylinder through the rim at its middle, on both sides of it
            let R0 = sh_rim(ac) - 0.8;
            let a2 = max(dot(rd.xz, rd.xz), 1.0e-8);
            let bb = -dot(rd.xz, C.xz);
            let cc2 = dot(C.xz, C.xz) - R0 * R0;
            let disc = bb * bb - a2 * cc2;
            if (disc <= 0.0) {
                continue;
            }
            for (var side = 0; side < 2; side = side + 1) {
                var t = (-bb + select(-1.0, 1.0, side == 1) * sqrt(disc)) / a2;
                if (t <= 0.0) {
                    continue;
                }
                for (var it = 0; it < 4; it = it + 1) {
                    let X = rd * t - C;
                    let d = max(ytop - X.y, 0.0);
                    let rr = sh_rim(atan2(X.z, X.x)) + 0.35 - 0.9 * sqrt(d) - 0.04 * d;
                    let f = length(X.xz) - rr;
                    // (the ray's rate across the sheet, roughly: along the radius)
                    let dr = dot(normalize(X.xz), rd.xz);
                    t = t - f / select(dr, sign(dr) * 0.05, abs(dr) < 0.05);
                }
                if (t <= 0.0 || t > scene_len + 0.2) {
                    continue;
                }
                let X = rd * t - C;
                let a = atan2(X.z, X.x);
                let da = abs(atan2(sin(a - ac), cos(a - ac)));
                let d = ytop - X.y;
                let along = (a - ac) * sh_rim(ac);
                let edge = hw * (0.85 + 0.2 * fvnoise(vec2<f32>(d * 0.08, f32(w) * 3.0)) + 0.25 * (fvnoise(vec2<f32>(d * 0.5 - time * 3.0, f32(w) * 7.0 + sign(a - ac))) - 0.5));
                if (da > edge || d < -0.05 || d > fall) {
                    continue;
                }
                // (strands of different widths, sliding down faster as it falls; their gaps darker, showing through)
                let q = 4.0 * sqrt(max(d, 0.0)) - time * 5.5;
                let pwf = t * px_a;
                let st1 = fvnoise(vec2<f32>(along * 0.9, q * 0.35));
                let st2 = fvnoise(vec2<f32>(along * 2.6 + 7.0, q * 0.9));
                let st3 = fvnoise(vec2<f32>(along * 6.0 + 3.0, q * 2.2)) * saturate(1.5 - pwf * 3.0);
                let strand = 0.5 * st1 + 0.32 * st2 + 0.18 * (st3 + 0.5 * (1.0 - saturate(1.5 - pwf * 3.0)));
                let body = smoothstep(0.28, 0.62, strand);
                // (white where it breaks up, lower down, and on the strands' crests; mist lower still)
                let foam = smoothstep(6.0, 40.0, d) * smoothstep(0.55, 0.8, strand) + 0.35 * smoothstep(0.7, 0.9, st3) * smoothstep(1.0, 8.0, d);
                let lip = 1.0 - smoothstep(0.0, 1.2, d);
                let shade = mix(0.75, 1.0, lip);
                var wc = mix(blue * shade, vec3<f32>(0.85, 0.88, 0.9) * 0.9, saturate(foam)) * (amb * 1.4 + sunc * 0.75);
                // (into the pit's dark, and spray where it goes)
                let deep = pow(smoothstep(4.0, 110.0, d), 0.7);
                wc = mix(wc, vec3<f32>(0.03, 0.035, 0.04), deep * 0.85 * fade_e);
                var alpha = mix(0.35, 0.85, body) * smoothstep(edge, edge * 0.6, da);
                // (its front ragged as it first pours, and mist where it thins out deep down)
                alpha = alpha * smoothstep(fall, fall - 6.0 - 4.0 * st1, d) * (1.0 - 0.5 * smoothstep(60.0, 140.0, d));
                col = mix(col, wc, saturate(alpha) * k * fade_e);
                let mist = smoothstep(30.0, 120.0, d) * 0.25 * (0.5 + st2);
                col = mix(col, vec3<f32>(0.5, 0.52, 0.55) * (amb + sunc * 0.3), mist * k * fade_e * smoothstep(edge * 1.3, edge * 0.5, da));
            }
        }
    }

    // ---- the birds going up off the land as it starts to shake, scattering away from it ------------------------------
    if (time > 0.8 && time < 10.0) {
        for (var i = 0; i < SH_BIRDS; i = i + 1) {
            let h = vec3<f32>(mh(u32(i), seed, 0x7b0u), mh(u32(i), seed, 0x7b1u), mh(u32(i), seed, 0x7b2u));
            let t0 = 1.0 + 1.6 * h.x + 0.6 * h.z;
            let s = time - t0;
            if (s < 0.0) {
                continue;
            }
            let a = h.y * TAU;
            let dir = vec3<f32>(cos(a), 0.0, sin(a));
            let start = C + dir * (25.0 + 110.0 * h.z) + vec3<f32>(0.0, 4.0 + 6.0 * h.x, 0.0);
            let pos = start + dir * (9.0 * s) + vec3<f32>(0.0, 6.0 * s - 0.25 * s * s + 1.5 * sin(s * 2.0 + h.x * 6.0), 0.0);
            let dist = length(pos);
            if (dist > scene_len) {
                continue;
            }
            let P = project_rel(pos);
            if (P.z < 0.0) {
                continue;
            }
            let span = max(0.45 / (dist * px_a), 1.2);
            let pxl = (uv - P.xy) * frame.resolution.xy;
            let flap = sin(time * (13.0 + 4.0 * h.x) + h.z * 20.0);
            let wx = abs(pxl.x) / span;
            let yv = pxl.y / span + (0.35 + 0.35 * flap) * (1.0 - wx) - 0.2;
            let m = step(wx, 1.0) * saturate(1.0 - abs(yv) * 1.8 / max(0.25, 1.0 / span));
            // (one passing close to the eye left out: it would be a black scrawl across the view)
            col = mix(col, vec3<f32>(0.03, 0.03, 0.035), m * 0.9 * k * (1.0 - smoothstep(7.0, 10.0, time)) * smoothstep(12.0, 30.0, dist));
        }
    }

    // ---- the dust, marched along the view ray through where it can be -------------------------------------------
    if (time > SH_GIVE && time < SH_END) {
        let Rb = SH_R * 1.15 + 95.0;
        let a2 = max(dot(rd.xz, rd.xz), 1.0e-8);
        let bb = -dot(rd.xz, C.xz);
        let cc2 = dot(C.xz, C.xz) - Rb * Rb;
        let disc = bb * bb - a2 * cc2;
        if (disc > 0.0) {
            var t0 = (-bb - sqrt(disc)) / a2;
            var t1 = (-bb + sqrt(disc)) / a2;
            let y0 = -70.0;
            let y1 = 100.0;
            if (abs(rd.y) > 1.0e-5) {
                let ya = (C.y + y0) / rd.y;
                let yb = (C.y + y1) / rd.y;
                t0 = max(t0, min(ya, yb));
                t1 = min(t1, max(ya, yb));
            }
            t0 = max(t0, 0.0);
            t1 = min(t1, scene_len);
            if (t1 > t0) {
                let N = 22;
                let dt = (t1 - t0) / f32(N);
                var tr = 1.0;
                var acc = vec3<f32>(0.0);
                let j = ign(in.position.xy + vec2<f32>(fract(time * 7.0) * 61.0, 0.0));
                let rimm = SH_R;
                for (var i = 0; i < N; i = i + 1) {
                    let t = t0 + dt * (f32(i) + j);
                    let p = rd * t - C;
                    let den = sh_dust(p, time, rimm);
                    if (den <= 0.0) {
                        continue;
                    }
                    let a = 1.0 - exp(-den * dt * 0.025);
                    // (lit from above, darker low down and deep in the pit)
                    let up = smoothstep(-40.0, 40.0, p.y);
                    let dc = mix(vec3<f32>(0.05, 0.043, 0.036), vec3<f32>(0.5, 0.44, 0.36), up) * (amb * 1.3 + sunc * 0.55 * up);
                    acc = acc + tr * a * dc;
                    tr = tr * (1.0 - a);
                    if (tr < 0.02) {
                        break;
                    }
                }
                col = mix(col, col * tr + acc, k);
            }
        }
    }

    // ---- a faint dimming of the light while the dust is up -------------------------------------------------------
    let murk = smoothstep(SH_C0, SH_C0 + 3.0, time) * (1.0 - smoothstep(20.0, SH_END, time)) * fade_e;
    col = col * (1.0 - 0.12 * murk * k);
    let srgb = linear_to_srgb(max(col, vec3<f32>(0.0)));
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
    return sinkhole(in);
}

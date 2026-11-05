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


// Orbital Laser's post pass for the Supercell (laser 12). Like the Payload's, the mod builds it from shaders/strike.wgsl
// up to its fs_main (the helpers: the noise, project_rel, bolt_line, mh, ign) less the other lasers' own functions,
// followed by this file, and sets it for a supercell strike only. Validate with tools/check-shader.sh.

// ---- laser 12: the supercell --------------------------------------------------------------------------------------
// No beam. The sky darkens; a storm cloud boils up over the target and spreads: a broad, low, dark deck, a slowly
// turning wall cloud hanging under its middle with ragged scud round it, a tower climbing out of it into an anvil that
// spreads downwind. Rain falls out of it in streaked grey curtains (the world's weather is left alone). Then the storm: lightning strikes all over the land under it,
// faster and faster, each bolt a branching channel from the cloud's base to the ground, re-striking a few times, the
// cloud lit from inside round its root and the land round its foot lit bright; flickers inside the cloud between. A few
// thin funnels come down out of the wall cloud, touch, wander over the land in a swirl of dust and lift back up (the
// vortex section). Then the finale: a rapid run of bolts snapping down closer and closer onto the target, in time with
// its sound's cracks, some arcing in out of the ring round the wall cloud; a hush, the light gone out but for the
// leader racing down; then one colossal strike on the target, a single blinding channel, the ring of bolts round the
// wall cloud snapping into it in the same instant, held, a shockwave over the land and a jolt. Then the storm dies away.
// strike/storm.rs hands the bolts, the funnels' tracks and the flickers to the pass in its table (sc_table,
// render.set-data): keep the SC_* and VX_* in step.
const SC_FORMED: f32 = 6.5;        // the cloud is formed,
const SC_STORM0: f32 = 4.0;        // the flurry's lone small bolts strike from here,
const SC_WAVES: f32 = 15.0;        // more and more at once from here,
const SC_CONV: f32 = 24.0;         // drawn in onto the target from here
const SC_STORM1: f32 = 27.85;      // to here, then the finale's run-in (storm.rs's FIN_RUN)
const SC_FINALE: f32 = 29.0;       // collapsing into the colossal strike,
const SC_CLEAR: f32 = 32.5;        // the storm dying away from here,
const SC_LEN: f32 = 42.0;          // and gone by the strike's end (lasers.rs's length)
const SC_B: u32 = 16u;             // the table: the bolts from SC_B, SC_BW words each (t, x, z off the middle, ground),
const SC_BW: u32 = 4u;             // in the order they strike
const SC_NB: u32 = 140u;           // (room for this many)
const SC_F: u32 = 576u;            // the funnels from SC_F, VX_W words each (vortex.rs's vx_words)
const VX_W: u32 = 148u;
const VX_DT: f32 = 0.5;
const VX_DOWN: f32 = 3.5;
const SC_K: u32 = 1024u;           // the flickers in the cloud from SC_K (t, x, z)
const SC_I: u32 = 1192u;           // for each whole second, the first bolt still seen then (a u32)
const SC_NI: u32 = 64u;
// The cloud's heights over the target's ground: the deck's base, the wall cloud's (lower, under its middle), the
// deck's top, the tower's, and the anvil's underside and top.
const SC_BASE: f32 = 80.0;
const SC_WALL: f32 = 46.0;
const SC_TOP: f32 = 150.0;
const SC_TOWER: f32 = 315.0;
const SC_ANV0: f32 = 270.0;
const SC_ANV1: f32 = 335.0;

fn sc_w(i: u32) -> f32 {
    if (i >= arrayLength(&mod_data)) {
        return 0.0;
    }
    return bitcast<f32>(mod_data[i]);
}
fn sc_have() -> bool {
    return arrayLength(&mod_data) > SC_K;
}

// ---- helpers (as payload.wgsl's) ------------------------------------------------------------------------------------
fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}
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
// Cauliflower lumps (payload.wgsl's pl_dome): about 1 on a dome's crown, 0 in a crease.
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
    return mat3x3<f32>(-0.6616, 0.1124, 0.7414, -0.4826, -0.8205, -0.3063, 0.5739, -0.5605, 0.5971) * p;
}
fn rot2(v: vec2<f32>, a: f32) -> vec2<f32> {
    let c = cos(a);
    let s = sin(a);
    return vec2<f32>(c * v.x - s * v.y, s * v.x + c * v.y);
}

// ---- the storm's life ---------------------------------------------------------------------------------------------
// How far it has formed (0 to 1 over the build-up), and how much of it is left as it dies away.
fn sc_form(t: f32) -> f32 {
    return smoothstep(0.0, SC_FORMED, t);
}
fn sc_fade(t: f32) -> f32 {
    return 1.0 - smoothstep(SC_CLEAR, SC_LEN - 1.0, t);
}
// How far out the deck reaches, and the anvil.
fn sc_deck_r(t: f32) -> f32 {
    return 70.0 + 230.0 * smoothstep(0.2, SC_FORMED + 1.5, t);
}
fn sc_anvil_r(t: f32) -> f32 {
    return -40.0 + 340.0 * smoothstep(3.5, SC_FORMED + 6.5, t);
}
// How heavily it rains (0 to 1).
fn sc_rain(t: f32) -> f32 {
    return smoothstep(3.5, 8.0, t) * (1.0 - smoothstep(SC_CLEAR - 1.0, SC_CLEAR + 3.0, t));
}
// The deck's base over the ground at r out (the wall cloud hangs lower under its middle).
fn sc_base(r: f32) -> f32 {
    return mix(SC_BASE, SC_WALL, 1.0 - smoothstep(28.0, 70.0, r));
}

// ---- the cloud ------------------------------------------------------------------------------------------------------
// The cloud's smooth body at q (off the target's ground): positive inside, about one per dozen blocks in.
fn sc_shape(q: vec3<f32>, t: f32) -> f32 {
    let r = length(q.xz);
    let form = sc_form(t);
    let base = sc_base(r) + 14.0 * (1.0 - form);
    // (it builds up from a dark, flat layer: its top climbing, the tower last)
    let tower = 1.0 - smoothstep(80.0, 175.0, r);
    let full = mix(SC_TOP, SC_TOWER, tower * smoothstep(1.0, 6.2, t));
    let top = base + (full - base) * (0.3 + 0.7 * smoothstep(0.0, 4.4, t));
    let deck = min(min(q.y - base, top - q.y) / 14.0, (sc_deck_r(t) - r) / 45.0);
    // (the anvil: flat, spreading downwind of the tower, thinning out at its edge, its underside sagging to its middle)
    let qa = q.xz - vec2<f32>(80.0 * form, 10.0 * form);
    let ra = length(qa * vec2<f32>(0.8, 1.0));
    let ar = sc_anvil_r(t);
    let sag = 18.0 * (1.0 - smoothstep(0.0, ar, ra));
    let anv = min(min(q.y - (SC_ANV0 + 12.0 * smoothstep(0.3, 1.0, ra / ar) - sag), SC_ANV1 - 14.0 * smoothstep(0.4, 1.0, ra / ar) - q.y) / 12.0, (ar - ra) / 60.0) - 3.0 * (1.0 - smoothstep(3.5, 5.8, t));
    // (and as it dies away it is eaten away from its edges in, thinning to nothing, not just fading)
    return max(deck, anv) - 1.8 * (1.0 - smoothstep(0.0, 3.0, t)) - 9.0 * pow(1.0 - sc_fade(t), 1.3);
}
// The cloud's density at q (0 to 1), its lumps turning with the storm (faster in close, where the wall cloud turns),
// boiling up the tower; and in .y how far up its lumps lie (0 in a crease, 1 on a crown).
fn sc_den(q: vec3<f32>, t: f32, fine: bool) -> vec2<f32> {
    let sh = sc_shape(q, t);
    if (sh < -2.6) {
        return vec2<f32>(0.0, 0.0);
    }
    let r = length(q.xz);
    let low = 1.0 - smoothstep(SC_TOP, SC_ANV0, q.y);
    let ang = 0.12 * t * 60.0 / (60.0 + r) * low;
    let qr = vec3<f32>(rot2(q.xz, -ang), q.y).xzy;
    let boil = vec3<f32>(0.0, -0.9 * t, 0.0);
    let n1 = gnoise3(pl_rot(0, qr * (1.0 / 75.0)) + boil * (1.0 / 75.0));
    let n2 = gnoise3(pl_rot(1, qr * (1.0 / 27.0)) + vec3<f32>(3.1, -0.03 * t, 7.7));
    var d = sh + (n1 - 0.5) * 2.6 + (n2 - 0.5) * 1.2;
    var crown = 0.5;
    // (the tower's and the anvil's edges in cauliflower lumps, boiling)
    let tw = (1.0 - smoothstep(80.0, 180.0, r)) * smoothstep(SC_TOP - 20.0, SC_TOP + 20.0, q.y);
    if (fine && d > -1.2 && d < 1.0) {
        if (tw > 0.01) {
            crown = pl_dome(pl_rot(0, (qr + boil * 1.3) * (1.0 / 24.0)));
            d = d + (crown - 0.45) * 1.8 * tw;
        }
        let n3 = gnoise3(qr * (1.0 / 8.0) + vec3<f32>(0.0, -0.12 * t, 0.0));
        d = d + (n3 - 0.5) * 0.7;
    }
    // (ragged scud under the base round the wall cloud: wisps hanging lower, turning faster)
    let base = sc_base(r);
    let scud = (1.0 - smoothstep(30.0, 110.0, r)) * smoothstep(base - 26.0, base - 4.0, q.y) * (1.0 - smoothstep(base - 4.0, base + 4.0, q.y));
    if (scud > 0.01) {
        let qs = vec3<f32>(rot2(q.xz, -0.3 * t * 50.0 / (50.0 + r)), q.y).xzy;
        let ns = gnoise3(qs * (1.0 / 14.0) + vec3<f32>(5.0, 0.0, 1.0));
        d = max(d, (ns - 0.62) * 6.0 * scud * sc_form(t));
    }
    return vec2<f32>(saturate(d * 0.9) * sc_fade(t), crown);
}

// A flash lighting the cloud (camera-relative point, how bright).
struct ScFlash {
    p: array<vec4<f32>, 3>,
}

// ---- the bolts ------------------------------------------------------------------------------------------------------
// As lightning is: a faint stepped leader, a dim branching tree, creeping down from the cloud in a few frames
// (SC_LEAD); then the return stroke lighting the whole channel at once at full brightness; then two to four re-strokes
// flickering down the same channel over a few tenths of a second, each lasting several frames at 60 fps; a brief
// afterglow. The channel is tortuous: kinked every few blocks at every scale (piecewise-linear noise, so it bends
// sharply, never smoothly), forking downward in branches that taper and fade; a thin white-violet core in a wide bloom.
const SC_LEAD: f32 = 0.09;
// The return stroke and re-strokes of bolt `n` (its hash) `a` seconds after the return stroke: 1 at a stroke's peak.
fn sc_stroke(a: f32, n: u32) -> f32 {
    if (a < 0.0 || a > 1.0) {
        return 0.0;
    }
    let count = 2u + n % 3u;
    var s = 0.0;
    var ts = 0.0;
    for (var k = 0u; k <= count; k = k + 1u) {
        let h = f32(pcg(n * 13u + k) & 1023u) / 1023.0;
        let dk = select(0.05 + 0.1 * h, 0.0, k == 0u);
        ts = ts + dk;
        s = s + select(0.55 + 0.35 * h, 1.0, k == 0u) * exp(-max(a - ts, 0.0) / 0.045) * step(ts, a);
    }
    // (the channel glowing on faintly between the strokes, and after)
    return s + 0.1 * exp(-a / 0.35);
}
// The finale's run-in (storm.rs's FIN_RUN): the bolts struck after SC_STORM1, each on a crack of the finale's sound's
// run-in. Lightning as the eye sees it: no leader to see, the channel there at once at full brightness, gone in a few
// frames, a brief afterglow (a quarter of them re-striking once); and all of it out in the hush before the crack
// (`sc_hushcut`).
fn sc_snap(a: f32, n: u32) -> f32 {
    if (a < 0.0 || a > 0.5) {
        return 0.0;
    }
    let re = select(0.0, 0.5, (n & 3u) == 0u) * exp(-max(a - 0.055, 0.0) / 0.025) * step(0.055, a);
    return exp(-a / 0.03) + re + 0.12 * exp(-a / 0.1);
}
fn sc_is_run(t: f32) -> bool {
    return t > SC_STORM1;
}
// The hush before the crack (SC_SUCK, storm.rs's FIN_SUCK, in the strike's time): 1 in it, the light held back.
fn sc_hush(t: f32) -> f32 {
    let tf = t - SC_FINALE;
    return select(0.0, smoothstep(-SC_SUCK, -SC_SUCK + 0.03, tf), tf < 0.0);
}
// How much of the run-in's bolts is still seen at `t`: none from the hush on.
fn sc_hushcut(t: f32) -> f32 {
    return 1.0 - smoothstep(SC_FINALE - SC_SUCK, SC_FINALE - SC_SUCK + 0.03, t);
}
// Whether run-in bolt i arcs in out of the ring round the wall cloud (its root out in the ring, its channel running in
// under the cloud's base before it drops onto its foot), and if so its root and the bend where it turns down.
fn sc_arc(i: u32, seed: u32) -> bool {
    return mh(i, seed, 0x7au) < 0.4;
}
fn sc_arc_root(f: vec3<f32>, i: u32, seed: u32) -> vec3<f32> {
    let a = atan2(f.z, f.x) + 0.8 * (mh(i, seed, 0x7bu) - 0.5);
    let rr = 50.0 + 35.0 * mh(i, seed, 0x7cu);
    return vec3<f32>(cos(a) * rr, sc_base(rr) + 2.0, sin(a) * rr);
}
fn sc_arc_bend(f: vec3<f32>, root: vec3<f32>, i: u32, seed: u32) -> vec3<f32> {
    let k = 0.3 + 0.2 * mh(i, seed, 0x7du);
    return vec3<f32>(mix(f.x, root.x, k), mix(f.y, root.y, 0.7 + 0.15 * mh(i, seed, 0x7eu)), mix(f.z, root.z, k));
}
// The leader: how far down the cloud's branching tree has crept by `a` seconds after the return stroke (negative a).
fn sc_leader(a: f32) -> f32 {
    return saturate((a + SC_LEAD) / SC_LEAD);
}
// Bolt i: its foot (off the middle, on the ground) and when its return stroke is.
fn sc_bolt(i: u32) -> vec4<f32> {
    let o = SC_B + SC_BW * i;
    return vec4<f32>(sc_w(o + 1u), sc_w(o + 3u), sc_w(o + 2u), sc_w(o));
}
// The first bolt that can still be seen at `t` (the table's per-second index: the bolts are in the order they strike,
// so the pass looks only from it on, while they are due, never at the whole storm's).
fn sc_first(t: f32) -> u32 {
    let s = u32(clamp(floor(t), 0.0, f32(SC_NI - 1u)));
    if (SC_I + s >= arrayLength(&mod_data)) {
        return 0u;
    }
    return mod_data[SC_I + s];
}
// How big a bolt struck at `t` is: the flurry's small and thin, full size once the waves come, a little more as they
// draw in.
fn sc_size(t: f32) -> f32 {
    return mix(0.45, 1.0, smoothstep(SC_STORM0, SC_WAVES, t)) * (1.0 + 0.2 * smoothstep(SC_CONV, SC_FINALE, t));
}
// How far the bolts are drawn in at `t` (0 to 1): their roots to the wall cloud's middle, their feet onto the target.
fn sc_conv(t: f32) -> f32 {
    return smoothstep(SC_CONV, SC_FINALE, t);
}
// Whether bolt i is a positive bolt: a rarer, brighter one out of the anvil, from high and far off.
fn sc_positive(i: u32, seed: u32) -> bool {
    return mh(i, seed, 0x5au) < 0.08;
}
// Where a bolt's channel leaves the cloud over its foot f (off the middle): out of the base a little off to one side,
// or for a positive bolt out of the anvil's underside, high and further out.
// As the bolts draw in (`sc_conv` of when it struck, `t`) its root slides in under the wall cloud's middle, so the last
// waves spray down out of one knot of the cloud onto the land round the target.
fn sc_root(f: vec3<f32>, i: u32, seed: u32, t: f32) -> vec3<f32> {
    let a = TAU * mh(i, seed, 0x51u);
    let r = length(f.xz);
    var root = vec3<f32>(f.x + 22.0 * cos(a) * mh(i, seed, 0x52u), sc_base(r) + 4.0, f.z + 22.0 * sin(a) * mh(i, seed, 0x52u));
    if (sc_positive(i, seed)) {
        let out = f.xz / max(r, 1.0);
        root = vec3<f32>(f.x + out.x * 45.0, SC_ANV0 - 8.0, f.z + out.y * 45.0);
    }
    let knot = vec3<f32>(9.0 * cos(a), SC_WALL + 8.0, 9.0 * sin(a));
    return mix(root, knot, 0.9 * pow(sc_conv(t), 1.2));
}
// Piecewise-linear noise in [-1, 1]: sharp kinks, no smooth curves.
fn sc_lin(x: f32, s: f32) -> f32 {
    let i = floor(x);
    let f = x - i;
    return mix(fh21(vec2<f32>(i, s)), fh21(vec2<f32>(i + 1.0, s)), f) * 2.0 - 1.0;
}
// The channel's sideways kink at u of its way (0 its root, 1 its end), in its lengths: four scales of kinks, the
// finest every couple of blocks on a bolt of a hundred.
// (`fq`: how many times longer than a hundred blocks it is: a long bolt kinks as often along its length)
fn sc_kink(u: f32, s: f32, fq: f32) -> f32 {
    let v = u * fq;
    return (0.11 * sc_lin(v * 4.0, s) + 0.05 * sc_lin(v * 11.0, s + 1.7) + 0.024 * sc_lin(v * 29.0, s + 3.1) + 0.011 * sc_lin(v * 70.0, s + 5.3)) / sqrt(fq);
}
// One kinked channel on the picture from sa to sb (pixels), `w` its core's half-width there: x its core, y its bloom,
// z how far along it the nearest point is. The kink is pinned at the end (`pin`: the foot on the ground).
fn sc_channel(px: vec2<f32>, sa: vec2<f32>, sb: vec2<f32>, s: f32, w: f32, pin: bool, fq: f32) -> vec3<f32> {
    let ab = sb - sa;
    let L = max(length(ab), 1.0);
    let dir = ab / L;
    let nrm = vec2<f32>(-dir.y, dir.x);
    let ap = px - sa;
    let u = clamp(dot(ap, dir) / L, 0.0, 1.0);
    let env = select(1.0, sqrt(max(1.0 - u, 0.0)) * 1.15, pin) * smoothstep(0.0, 0.04, u);
    let k0 = sc_kink(u, s, fq) * env;
    let k1 = sc_kink(u + 0.002, s, fq) * env;
    let slope = (k1 - k0) / 0.002;
    let off = (dot(ap, nrm) - k0 * L) / sqrt(1.0 + slope * slope);
    let along = dot(ap, dir) - u * L;
    let d = length(vec2<f32>(off, along));
    let core = exp(-pow(d / w, 2.0));
    let g = 1.0 / (1.0 + pow(d / (w * 9.0), 2.0));
    return vec3<f32>(core, g * g, u);
}
// A bolt from root a to foot b (camera-relative), drawn on the picture: its channel and five forks (each kinked, branching
// down and out, tapering and fading), hidden by what stands in front of it. `lead`: how far down the leader has crept
// (1: the whole channel). x: the hot core, y: the bloom.
fn sc_draw_bolt(px: vec2<f32>, a: vec3<f32>, b: vec3<f32>, seed: f32, wmul: f32, lead: f32, scene_len: f32) -> vec2<f32> {
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
    let dist = length(0.5 * (a + b));
    let focal = res.y / (2.0 * tan(frame.view_params.w * 0.5));
    let w = clamp(0.35 * focal / dist, 0.7, 4.0) * wmul;
    // (far from it on the picture: nothing to draw)
    let u0 = saturate(dot(px - sa, ab) / (L * L));
    if (length(px - (sa + ab * u0)) > 0.45 * L + 40.0 * w) {
        return vec2<f32>(0.0);
    }
    let la = length(a);
    let lb = length(b);
    let fq = max(length(a - b) / 100.0, 1.0);
    let m = sc_channel(px, sa, sb, seed, w, true, fq);
    let seen = select(0.0, 1.0, scene_len > mix(la, lb, m.z) - 3.0) * smoothstep(lead + 0.01, lead - 0.01, m.z);
    var core = m.x * seen;
    var glow = m.y * seen;
    let dir = ab / L;
    let nrm = vec2<f32>(-dir.y, dir.x);
    for (var j = 0; j < 5; j = j + 1) {
        let fj = f32(j);
        let hu = fract(seed * 0.618 + fj * 0.377);
        let u = 0.1 + 0.62 * fract(hu + fj * 0.21);
        if (u > lead) {
            continue;
        }
        let root = sa + ab * u + nrm * sc_kink(u, seed, fq) * sqrt(1.0 - u) * 1.15 * L;
        let side = select(-1.0, 1.0, fract(seed * 0.71 + fj * 0.53) > 0.5);
        let bdir = normalize(dir + nrm * side * (0.55 + 0.6 * fract(seed * 1.3 + fj * 0.7)));
        let len = L * (0.12 + 0.22 * fract(seed * 0.9 + fj * 0.77)) * (1.0 - 0.5 * u);
        let f = sc_channel(px, root, root + bdir * len, seed + 7.0 + fj * 3.3, w * 0.55, false, fq);
        // (it creeps out as the leader passes it, and fades and thins along its length)
        let grown = smoothstep(f.z - 0.02, f.z + 0.02, (lead - u) * 3.0);
        let fade = pow(1.0 - f.z, 1.6);
        let fs = select(0.0, 1.0, scene_len > mix(la, lb, u + f.z * 0.25) - 3.0) * grown * fade;
        core = core + f.x * fs;
        glow = glow + f.y * fs * 0.7;
    }
    return vec2<f32>(core, glow);
}

// ---- the vortex: a funnel let down out of the cloud (vortex.rs) --------------------------------------------------
// A condensation funnel hanging from the wall cloud: wide where it leaves the cloud's base, tapering smoothly to a
// narrow cone or rope at the ground, leaning a little the way it travels and bending in a slow sinuous curve; its edge
// fairly sharp, wound with striations that spiral round it and up it as it turns, fastest near the ground. At its foot,
// once it nears the land, a squat debris cloud whirls up, wider than the funnel and dust-coloured, with pieces flung
// round it and out. It forms by lowering out of the cloud (the debris kicking up before it touches), matures, then
// ropes out (thinning to a twisted, sinuous rope) and lifts back up as it dies. Lit as the storm is: darker on its side
// away from the light, silhouetted against what is brighter behind it.
// A full tornado scales it: VX_RT (the cone's width at the cloud) and the foot's width with the funnel's touch radius
// (vortex.rs's `touch_r`), the debris cloud with it, the march's bound (vx_bound) with both.
const VX_ROPE: f32 = 4.0;          // it ropes out over this long before it is gone, lifting off over the last 1.6 (vortex.rs's VX_LIFT)
const VX_RT: f32 = 11.0;           // the cone's radius where it leaves the cloud's base
struct VxFunnel {
    foot: vec3<f32>,       // camera-relative, on the land (vortex.rs smooths the land under it)
    top: vec3<f32>,
    vel: vec2<f32>,        // its foot's way over the land, blocks a second
    low: f32,              // the share of it from the ground up not (yet, or any more) drawn
    touch: f32,            // how much it is on the land
    debris: f32,           // how much dust is whirled up round its foot
    rope: f32,             // how far it has roped out (0 mature, 1 a thin rope)
    r: f32,                // its touch radius
    spin: f32,
}
fn vx_at(k: u32, t: f32, C: vec3<f32>) -> VxFunnel {
    var f: VxFunnel;
    let o = SC_F + VX_W * k;
    let t0 = sc_w(o);
    let t1 = sc_w(o + 1u);
    let n = max(i32(sc_w(o + 2u) + 0.5), 1);
    let u = clamp((t - t0) / VX_DT, 0.0, f32(n - 1));
    let i = min(i32(floor(u)), max(n - 2, 0));
    let fr = u - f32(i);
    let a = o + 4u + 3u * u32(i);
    let b = o + 4u + 3u * u32(min(i + 1, n - 1));
    let pa = vec3<f32>(sc_w(a), sc_w(a + 2u), sc_w(a + 1u));
    let pb = vec3<f32>(sc_w(b), sc_w(b + 2u), sc_w(b + 1u));
    let p = mix(pa, pb, fr);
    f.foot = C + p;
    f.vel = (pb.xz - pa.xz) / VX_DT;
    // (its top in the wall cloud's base, drawn in towards the middle and ahead of its foot: it leans the way it goes)
    let top_xz = p.xz * 0.85 + f.vel * 1.2;
    f.top = C + vec3<f32>(top_xz.x, sc_base(length(top_xz)) + 3.0, top_xz.y);
    let down = smoothstep(t0, t0 + VX_DOWN, t);
    let lift = smoothstep(t1 - 1.6, t1, t);
    f.low = max(1.0 - down, lift);
    f.touch = smoothstep(t0 + 0.8 * VX_DOWN, t0 + VX_DOWN, t) * (1.0 - smoothstep(t1 - 1.8, t1 - 1.2, t));
    f.debris = smoothstep(t0 + 0.45 * VX_DOWN, t0 + VX_DOWN, t) * (1.0 - smoothstep(t1 - 2.0, t1 - 0.6, t));
    f.rope = smoothstep(t1 - VX_ROPE, t1 - 1.2, t);
    f.r = sc_w(o + 3u);
    f.spin = f32(k) * 2.1;
    if (t < t0 || t > t1) {
        f.low = 1.0;
        f.debris = 0.0;
    }
    return f;
}
// The funnel's radius at s of its way up (0 its foot, 1 the cloud's base): a narrow foot, flaring into the wide cone it
// hangs from; thinned to a rope as it dies.
fn vx_radius(f: VxFunnel, s: f32) -> f32 {
    let foot = (1.0 + 0.4 * f.r) * mix(1.0, 0.55, f.rope);
    let cone = mix(VX_RT, VX_RT * 0.35, f.rope);
    // (and as it lowers, its tip a narrowing point)
    let tip = smoothstep(f.low - 0.02, f.low + 0.3, s);
    return mix(foot, cone, pow(s, mix(3.5, 5.0, f.rope))) * mix(0.25, 1.0, tip);
}
// The funnel's axis at s of its way up: from its foot to its top, bending in a slow S that writhes as it turns, more
// as it ropes out.
fn vx_axis(f: VxFunnel, s: f32, t: f32) -> vec3<f32> {
    let along = mix(f.foot, f.top, s);
    let side = normalize(vec3<f32>(-(f.top - f.foot).z, 0.0, (f.top - f.foot).x) + vec3<f32>(1.0e-3, 0.0, 0.0));
    let amp = mix(3.0, 10.0, f.rope) * sin(3.14159 * s) * (1.0 - 0.7 * f.low);
    let w1 = sin(s * 5.0 - t * 0.9 + f.spin) * amp;
    let w2 = cos(s * 3.0 - t * 0.6 + f.spin * 1.3) * amp * 0.6;
    return along + side * w1 + vec3<f32>(side.z, 0.0, -side.x) * w2;
}
// How far round the funnel reaches from its axis (the march's bound): the cone, the debris cloud.
fn vx_bound(f: VxFunnel) -> f32 {
    return VX_RT + 14.0 + 3.0 * f.r;
}
// The funnel at camera-relative p: x its density, y its dust's, z how far it lies out on the funnel's surface (0 at the
// axis, 1 at its edge: the shading's side), w the striation there.
fn vx_den(f: VxFunnel, p: vec3<f32>, t: f32) -> vec4<f32> {
    let H = max(f.top.y - f.foot.y, 10.0);
    let s = saturate((p.y - f.foot.y) / H);
    let ax = vx_axis(f, s, t);
    let e = (p - ax).xz;
    let d = length(e);
    let th = atan2(e.y, e.x);
    // (it turns, fastest near the ground; its striations spiral round it and climb as it turns)
    let w = mix(9.0, 2.5, s);
    let thr = th - w * t - f.spin;
    let stri = 0.5 + 0.5 * sin(6.0 * thr + p.y * 0.55);
    let n = gnoise3(vec3<f32>(cos(thr) * 2.0, sin(thr) * 2.0, p.y * 0.09 - t * 1.4) + vec3<f32>(f.spin));
    let rs = vx_radius(f, s) * (0.9 + 0.12 * stri + 0.18 * (n - 0.5));
    let vis = smoothstep(f.low - 0.03, f.low + 0.03, s);
    let fun = smoothstep(rs, rs * 0.8, d) * (0.75 + 0.25 * stri) * vis;
    // (the debris cloud whirled round its foot: squat, ragged, dust-coloured, turning fast, wider than the funnel)
    var dust = 0.0;
    let hy = p.y - f.foot.y;
    if (f.debris > 0.01 && hy < 26.0) {
        let dd = length((p - f.foot).xz);
        let thd = atan2((p - f.foot).z, (p - f.foot).x) - 7.0 * t - f.spin;
        let rd0 = (5.0 + 2.6 * f.r) * (0.8 + 0.45 * gnoise3(vec3<f32>(cos(thd) * 1.8, sin(thd) * 1.8, hy * 0.12 - t * 0.6 + f.spin)));
        let top = 7.0 + 14.0 * smoothstep(rd0, 0.0, dd);
        dust = smoothstep(rd0, rd0 * 0.45, dd) * smoothstep(top, top * 0.3, hy) * smoothstep(-1.5, 1.0, hy) * f.debris;
        dust = dust * (0.55 + 0.45 * sin(3.0 * thd + hy * 0.4)) * 1.7;
    }
    return vec4<f32>(fun, dust, saturate(d / max(rs, 0.5)), stri);
}
// The pieces flung round a funnel's foot (a few dozen, each a tumbling dark speck orbiting and climbing, some thrown
// out), on the picture: how much of this pixel they cover.
fn vx_pieces(px: vec2<f32>, f: VxFunnel, t: f32, scene_len: f32) -> f32 {
    if (f.debris < 0.02) {
        return 0.0;
    }
    let res = frame.resolution.xy;
    let focal = res.y / (2.0 * tan(frame.view_params.w * 0.5));
    var cover = 0.0;
    for (var i = 0u; i < 16u; i = i + 1u) {
        let h = vec3<f32>(f32(pcg(i * 3u + 1u) & 1023u), f32(pcg(i * 3u + 2u) & 1023u), f32(pcg(i * 3u + 3u) & 1023u)) / 1023.0;
        let life = fract(t * (0.25 + 0.2 * h.x) + h.y);
        let r = (4.0 + 2.5 * f.r) * (0.7 + 0.6 * h.z) + 10.0 * life * life * step(0.7, h.x);
        let a = TAU * h.x + t * (5.0 - 2.5 * h.z) + f.spin;
        let y = 1.0 + 26.0 * life * (0.4 + 0.6 * h.y) - 30.0 * max(life - 0.75, 0.0);
        let q = f.foot + vec3<f32>(cos(a) * r, y, sin(a) * r);
        let pq = project_rel(q);
        if (pq.z < 0.0) {
            continue;
        }
        let dq = length(q);
        let sz = max(0.28 * focal / dq * (0.4 + 0.8 * h.z), 0.5);
        let dpx = length(px - pq.xy * res);
        cover = max(cover, smoothstep(sz + 0.7, sz - 0.3, dpx) * select(0.0, 1.0, scene_len > dq) * f.debris * smoothstep(0.0, 0.08, life) * (1.0 - smoothstep(0.9, 1.0, life)));
    }
    return cover;
}

// What the volumetric part has gathered: colour (premultiplied), transmittance, and its distance.
// Rain in the world: drops falling along lines in the way they fall (`vel`, blocks a second: down, and blown), the
// lines' feet on a grid across that way, a jittered line a cell, the drops strung along each its own (length, speed,
// spacing, brightness, whether it is there: a hash a cell). Five layers out from the camera (`cq`, off the middle),
// each a coarser grid than the last: near drops big, fast and few, far ones fine and many. Only the cells the ray
// crosses in each layer are tried, so no direction is special: looking along the rain (straight up or down) the drops
// come end on, as dots, never converging on a point; nothing repeats on the picture. Hidden past `near`.
fn sc_rain_lines(rd: vec3<f32>, cq: vec3<f32>, vel: vec3<f32>, near: f32, time: f32) -> f32 {
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
    for (var k = 0; k < 5; k = k + 1) {
        let fk = f32(k);
        let cell = 0.45 * pow(1.9, fk);
        let ta = 1.3 * pow(1.9, fk);
        let tb = min(ta * 1.9, near);
        if (ta >= tb) {
            break;
        }
        let pa = c2 + r2 * ta;
        let pb = c2 + r2 * tb;
        var last = vec2<f32>(1.0e9);
        for (var n = 0; n < 6; n = n + 1) {
            let g = floor(mix(pa, pb, (f32(n) + 0.5) / 6.0) / cell);
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

struct ScVol {
    c: vec4<f32>,
    t: f32,
}
fn sc_over(h: ptr<function, vec4<f32>>, c: vec3<f32>, x: f32) {
    *h = vec4<f32>((*h).rgb * (1.0 - x) + c * x, (*h).a * (1.0 - x));
}

// How the flashes light a point of the cloud.
fn sc_flash_at(fl: ScFlash, p: vec3<f32>) -> f32 {
    var e = 0.0;
    for (var j = 0; j < 3; j = j + 1) {
        let f = fl.p[j];
        if (f.w > 0.001) {
            let d = p - f.xyz;
            e = e + f.w / (1.0 + dot(d, d) * (1.0 / 3200.0));
        }
    }
    return e;
}

// The cloud, the rain and the funnels along the ray rd (camera-relative), as far as `scene_len`.
fn sc_volume(rd: vec3<f32>, scene_len: f32, C: vec3<f32>, time: f32, j: f32, fl: ScFlash, L: vec3<f32>, amb: vec3<f32>, sunc: vec3<f32>, fine: bool) -> ScVol {
    var acc = vec4<f32>(0.0, 0.0, 0.0, 1.0);
    var tmid = 0.0;
    var wmid = 0.0;
    let fc = vec3<f32>(0.75, 0.8, 1.15);
    let form = sc_form(time);
    let fade = sc_fade(time);
    // ---- the cloud: marched between its lowest base and the anvil's top, inside its widest reach -------------------
    let reach = max(sc_deck_r(time), sc_anvil_r(time) + 110.0) + 40.0;
    let ylo = C.y + SC_WALL - 30.0;
    let yhi = C.y + SC_ANV1 + 15.0;
    var t0 = 0.0;
    var t1 = scene_len;
    if (abs(rd.y) > 1.0e-5) {
        let ta = (ylo - 0.0) / rd.y;
        let tb = (yhi - 0.0) / rd.y;
        t0 = max(t0, min(ta, tb));
        t1 = min(t1, max(ta, tb));
    } else if (0.0 < ylo || 0.0 > yhi) {
        t1 = -1.0;
    }
    // (and the cylinder of its reach)
    let oc = -C.xz;
    let dxz = rd.xz;
    let qa = dot(dxz, dxz);
    let qb = dot(oc, dxz);
    let qc = dot(oc, oc) - reach * reach;
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
    if (t1 > t0 && form * fade > 0.001) {
        let n = select(36, 56, fine);
        let span = t1 - t0;
        // (short steps in the cloud, at most 96 of them: a long ray through it is only seen through so far)
        let dt0 = clamp(span / f32(n), 2.5, 7.0);
        var dt = dt0;
        var t = t0 + dt * j;
        let ph = 0.75 + 0.6 * pow(saturate(dot(rd, L)), 6.0);
        for (var i = 0; i < 96; i = i + 1) {
            if (t > t1 || acc.a < 0.03) {
                break;
            }
            let p = rd * t;
            let q = p - C;
            let sh = sc_shape(q, time);
            if (sh < -3.0) {
                // (empty air: leap on, short of where the lumps could reach)
                t = t + max(dt, (-sh - 2.6) * 11.0);
                continue;
            }
            // (thinned round the eye: from inside it, or flying through its scud, the storm round about still shows)
            let dn = sc_den(q, time, fine) * vec2<f32>(smoothstep(12.0, 70.0, t), 1.0);
            if (dn.x > 0.003) {
                let r = length(q.xz);
                let base = sc_base(r);
                let tower = 1.0 - smoothstep(80.0, 175.0, r);
                let top = mix(SC_TOP, SC_TOWER, tower);
                let h01 = saturate((q.y - base) / max(top - base, 1.0));
                // (lit from above: deep in it, and its underside, dark; a look towards the sun for its own lumps)
                var sun_t = exp(-min(max(top - q.y, 0.0), 110.0) * 0.022);
                if (fine) {
                    let q2 = q + L * 16.0;
                    sun_t = sun_t * exp(-saturate(sc_shape(q2, time) + 0.5) * 1.4);
                }
                let anvil = smoothstep(SC_ANV0 - 30.0, SC_ANV0 + 10.0, q.y);
                sun_t = max(sun_t, anvil * 0.7);
                // (storm-grey, its base green-black, the tower's tops pale)
                let alb = mix(mix(vec3<f32>(0.1, 0.14, 0.11), vec3<f32>(0.3, 0.33, 0.31), smoothstep(0.0, 0.35, h01)), vec3<f32>(0.6, 0.61, 0.63), smoothstep(0.35, 1.0, h01)) * (0.85 + 0.3 * dn.y);
                let e = sc_flash_at(fl, p);
                let ambg = mix(amb, vec3<f32>(dot(amb, vec3<f32>(0.2126, 0.7152, 0.0722))), 0.65);
                let c = alb * (ambg * (0.45 + 0.55 * h01) * (2.0 - fade) + sunc * mix(0.6, sun_t, fade) * 0.85 * ph) + fc * e * (0.5 + 0.5 * alb);
                let ext = dn.x * 0.07 * dt * (0.35 + 0.65 * fade);
                let al = 1.0 - exp(-ext);
                sc_over(&acc, c, al);
                tmid = tmid + acc.a * al * t;
                wmid = wmid + acc.a * al;
            }
            dt = dt0 * (0.8 + 0.4 * fract(j + f32(i) * 0.618)) * select(1.0, 2.0, dn.x < 0.003 && sh < -1.0);
            t = t + dt;
        }
    }
    // ---- the rain: grey veils falling out of the base, streaked, heaviest under the forward part of the storm ----
    let rk = sc_rain(time) * fade;
    if (rk > 0.001) {
        let rr = sc_deck_r(time) * 0.78;
        let yb = C.y + SC_BASE;
        var r0 = 0.0;
        var r1 = scene_len;
        if (abs(rd.y) > 1.0e-5) {
            let ta = (C.y - 4.0) / rd.y;
            let tb = yb / rd.y;
            r0 = max(r0, min(ta, tb));
            r1 = min(r1, max(ta, tb));
        }
        let qc2 = dot(oc, oc) - rr * rr;
        let disc2 = qb * qb - qa * qc2;
        if (disc2 > 0.0 && qa > 1.0e-8) {
            let sq = sqrt(disc2);
            r0 = max(r0, (-qb - sq) / qa);
            r1 = min(r1, (-qb + sq) / qa);
        } else if (qc2 > 0.0) {
            r1 = -1.0;
        }
        r1 = min(r1, r0 + 700.0);
        if (r1 > r0) {
            let nr = 10;
            let dtr = (r1 - r0) / f32(nr);
            var tr = 1.0;
            var cr = vec3<f32>(0.0);
            for (var i = 0; i < nr; i = i + 1) {
                let t = r0 + (f32(i) + j) * dtr;
                let p = rd * t;
                let q = p - C;
                let r = length(q.xz);
                // (the curtains: broad shafts hanging from the base, leaning and drifting with the wind, streaked by the rain
                // falling through them: its streaks drawn down fast; the wall cloud's middle drier)
                let sx = q.xz + vec2<f32>(0.3 * q.y + 3.0 * time, 0.0);
                let curtain = gnoise3(vec3<f32>(sx * (1.0 / 26.0), time * 0.06));
                let fall = gnoise3(vec3<f32>(sx.x * (1.0 / 3.0), (q.y + 32.0 * time) * (1.0 / 22.0), sx.y * (1.0 / 3.0)));
                // (streaked in long vertical bands that read as rain from far off)
                let bands = gnoise3(vec3<f32>(sx.x * (1.0 / 7.0), (q.y + 20.0 * time) * (1.0 / 90.0), sx.y * (1.0 / 7.0)));
                var den = rk * smoothstep(0.46, 0.64, curtain) * smoothstep(0.38, 0.62, bands) * (0.55 + 0.9 * smoothstep(0.45, 0.75, fall)) * (1.0 - smoothstep(rr * 0.6, rr, r)) * smoothstep(18.0, 50.0, length(q.xz - vec2<f32>(-20.0, 0.0)));
                den = den * smoothstep(-4.0, 6.0, q.y) * (1.0 - smoothstep(sc_base(r) - 10.0, sc_base(r), q.y));
                // (none close round the eye: the curtains are seen across the land, never a wall in front of the view)
                den = den * smoothstep(40.0, 140.0, t);
                if (den > 0.001) {
                    let e = sc_flash_at(fl, p);
                    let c = vec3<f32>(0.36, 0.39, 0.42) * (amb * 0.8 + sunc * 0.15) + fc * e * 0.35;
                    let al = 1.0 - exp(-den * 0.05 * dtr);
                    cr = cr + tr * al * c;
                    tr = tr * (1.0 - al);
                }
            }
            // (the rain is under the cloud: in front of what the cloud gathered, for an eye under it; never so thick that
            // the storm behind it, its bolts and its funnels, does not show through: at most 45% of it hidden)
            let keep = max(tr, 0.55);
            cr = cr * (1.0 - keep) / max(1.0 - tr, 1.0e-4);
            acc = vec4<f32>(cr + keep * acc.rgb, keep * acc.a);
            if (tr < 0.98 && wmid < 1.0e-3) {
                tmid = 0.5 * (r0 + r1);
                wmid = 1.0;
            }
        }
    }
    // ---- the funnels ---------------------------------------------------------------------------------------------------
    if (sc_have()) {
        let nf = u32(sc_w(2u) + 0.5);
        for (var k = 0u; k < min(nf, 4u); k = k + 1u) {
            let f = vx_at(k, time, C);
            if (f.low >= 0.999) {
                continue;
            }
            let bnd = vx_bound(f);
            let sg = pl_ray_seg(rd, f.foot, f.top, 0.0, 1.0);
            if (sg.x > bnd || sg.y - bnd > scene_len) {
                continue;
            }
            // (marched only across it: its width where the ray passes nearest, and the dust's round its foot)
            let half = vx_radius(f, sg.z) * 1.3 + 4.0 + select(0.0, 6.0 + 3.0 * f.r, sg.z < 0.4);
            let ft0 = max(sg.y - half, 0.0);
            let ft1 = min(sg.y + half, scene_len);
            let nn = select(18, 26, fine);
            let fdt = (ft1 - ft0) / f32(nn);
            var fa = vec4<f32>(0.0, 0.0, 0.0, 1.0);
            var ftm = 0.0;
            for (var i = 0; i < nn; i = i + 1) {
                let t = ft0 + (f32(i) + j) * fdt;
                let p = rd * t;
                // (only under the cloud's base: inside it the cloud hides it, and its cone merges into the base)
                let qb = p - C;
                let v4 = vx_den(f, p, time);
                // (inside the cloud the cloud hides it: where the cloud's smooth body begins, it is gone)
                let dd = v4.xy * smoothstep(0.4, -0.6, sc_shape(qb, time)) * smoothstep(sc_base(length(qb.xz)) + 1.0, sc_base(length(qb.xz)) - 6.0, qb.y);
                let den = dd.x + dd.y;
                if (den > 0.002) {
                    let e = sc_flash_at(fl, p);
                    let s01 = saturate((p.y - f.foot.y) / max(f.top.y - f.foot.y, 1.0));
                    // (lit as the storm is: the side towards the light and the sky paler, the far side and the cone
                    // under the cloud darker, the striations' grooves a little darker)
                    let ax = vx_axis(f, s01, time);
                    let nrm = normalize(vec3<f32>((p - ax).x, 0.0, (p - ax).z) + vec3<f32>(0.0, 1.0e-3, 0.0));
                    let lit = 0.55 + 0.45 * dot(nrm, normalize(vec3<f32>(L.x, 0.0, L.z) + vec3<f32>(1.0e-3, 0.0, 0.0)));
                    let rim = smoothstep(0.55, 1.0, v4.z);
                    let fcol = mix(vec3<f32>(0.16, 0.18, 0.18), vec3<f32>(0.27, 0.29, 0.3), s01 * 0.5 + 0.5 * rim) * (0.8 + 0.25 * v4.w) * (1.0 - 0.4 * smoothstep(0.7, 1.0, s01));
                    let dcol = vec3<f32>(0.36, 0.3, 0.22);
                    let alb = (fcol * dd.x + dcol * dd.y) / den;
                    let c = alb * (amb * (0.75 + 0.6 * lit) + sunc * 0.15 * lit) + fc * e * 0.5 * alb;
                    let al = 1.0 - exp(-den * 0.9 * fdt);
                    sc_over(&fa, c, al);
                    ftm = ftm + t * al;
                    if (fa.a < 0.03) {
                        break;
                    }
                }
            }
            if (fa.a < 0.999) {
                // (under the cloud: in front of what the cloud gathered, unless the eye looks down through it)
                let ftd = ftm / max(1.0 - fa.a, 1.0e-3);
                let mid = tmid / max(wmid, 1.0e-4);
                if (wmid < 1.0e-3 || ftd < mid) {
                    acc = vec4<f32>(fa.rgb + fa.a * acc.rgb, fa.a * acc.a);
                } else {
                    acc = vec4<f32>(acc.rgb + acc.a * fa.rgb, fa.a * acc.a);
                }
                tmid = tmid + ftd * (1.0 - fa.a) * 4.0;
                wmid = wmid + (1.0 - fa.a) * 4.0;
            }
        }
    }
    var o: ScVol;
    o.c = acc;
    o.t = select(1.0e9, tmid / max(wmid, 1.0e-4), wmid > 1.0e-4);
    return o;
}

struct PlOut {
    c: vec4<f32>,
    e: vec4<f32>,
}

// The pass, in one of three stages: 0 the whole of it at full size (fs_main); 1 the half-size stage (fs_half: the
// cloud, the rain and the funnels, over a two by two of the picture's pixels), as premultiplied colour and
// transmittance; 2 the join (fs_join: the rest, sharp, at full size, with the half-size stage's `up` laid over).
fn supercell(in: StageIn, stage: u32, up: vec4<f32>) -> PlOut {
    var uv = in.uv;
    let time = now();
    let k = intensity_v();
    let seed = u32(seed_v());
    let anc = anchor_xz();
    let cam = frame.camera_position.xyz;
    let gy = block_y() + 1.0;
    let C = vec3<f32>(anc.x, gy, anc.y) - cam;
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
    let form = sc_form(time) * sc_fade(time);
    let have = sc_have();

    // (the light, matched to the scene's: its sky, the sun's or the moon's)
    var skyl = srgb_to_linear(frame.sky_color.rgb);
    let amb0 = mix(vec3<f32>(0.02, 0.025, 0.035), skyl * 0.55 + vec3<f32>(0.03), day);
    let amb = amb0 * mix(1.0, 0.55, form);
    let sunc = (mix(vec3<f32>(1.25, 1.18, 1.05), vec3<f32>(1.4, 0.62, 0.3), warm) * sun_up + vec3<f32>(0.05, 0.07, 0.11) * moon) * mix(1.0, 0.6, form);

    // ---- the flashes: the bolts striking now and the flickers in the cloud, the three brightest kept for the cloud ---
    var fl: ScFlash;
    fl.p[0] = vec4<f32>(0.0);
    fl.p[1] = vec4<f32>(0.0);
    fl.p[2] = vec4<f32>(0.0);
    // (and the brightest bolt's own light on the land)
    var gflash = vec3<f32>(0.0);
    var sky_flash = 0.0;
    let tf = time - SC_FINALE;
    if (have) {
        let nb = min(u32(sc_w(0u) + 0.5), SC_NB);
        for (var i = sc_first(time); i < nb; i = i + 1u) {
            let b = sc_bolt(i);
            let a = time - b.w;
            if (a < 0.0) {
                break;
            }
            if (a > 1.0) {
                continue;
            }
            let run = sc_is_run(b.w);
            var I = sc_stroke(a, pcg(i ^ seed)) * select(1.0, 1.6, sc_positive(i, seed)) * sc_size(b.w);
            var root = C + sc_root(b.xyz, i, seed, b.w);
            if (run) {
                I = sc_snap(a, pcg(i ^ seed)) * sc_hushcut(time) * sc_size(b.w) * 1.1;
                if (sc_arc(i, seed)) {
                    root = C + sc_arc_root(b.xyz, i, seed);
                }
            }
            let foot = C + b.xyz;
            let fp = vec4<f32>(root + vec3<f32>(0.0, 20.0, 0.0), I * 2.5);
            // (kept if brighter than the dimmest held)
            var lo = 0;
            if (fl.p[1].w < fl.p[lo].w) { lo = 1; }
            if (fl.p[2].w < fl.p[lo].w) { lo = 2; }
            if (fp.w > fl.p[lo].w) { fl.p[lo] = fp; }
            if (stage != 1u && !sky) {
                let dl = length(rel - foot);
                gflash = gflash + vec3<f32>(0.8, 0.85, 1.1) * I * 5.0 / (1.0 + dl * dl / 300.0);
            }
            sky_flash = sky_flash + I * 0.5 / (1.0 + length(foot) / 300.0);
        }
        let nk = u32(sc_w(3u) + 0.5);
        for (var i = 0u; i < min(nk, 64u); i = i + 1u) {
            let o = SC_K + 3u * i;
            let a = time - sc_w(o);
            if (a < 0.0 || a > 0.7) {
                continue;
            }
            // (a flicker: two or three quick pulses)
            let I = (exp(-a / 0.06) + 0.7 * exp(-max(a - 0.14, 0.0) / 0.05) * step(0.14, a) + 0.5 * exp(-max(a - 0.33, 0.0) / 0.06) * step(0.33, a)) * 1.6 * (1.0 - sc_hush(time));
            let p = C + vec3<f32>(sc_w(o + 1u), SC_BASE + 40.0 + 60.0 * mh(i, seed, 0x61u), sc_w(o + 2u));
            let fp = vec4<f32>(p, I);
            var lo = 0;
            if (fl.p[1].w < fl.p[lo].w) { lo = 1; }
            if (fl.p[2].w < fl.p[lo].w) { lo = 2; }
            if (fp.w > fl.p[lo].w) { fl.p[lo] = fp; }
            sky_flash = sky_flash + I * 0.12 / (1.0 + length(p) / 300.0);
        }
    }
    // (the finale's: a knot of bolts on the target, blinding, lighting the cloud over it hard)
    var fin = 0.0;
    if (tf > 0.0 && tf < 3.0) {
        // (held: the channel burning on for two seconds, re-struck again and again)
        fin = 0.4 * (1.0 - smoothstep(1.6, 2.4, tf)) * (0.75 + 0.25 * sin(tf * 41.0));
        for (var n = 0; n < 7; n = n + 1) {
            let ts = array<f32, 7>(0.0, 0.12, 0.3, 0.52, 0.8, 1.12, 1.5)[n];
            fin = fin + (1.0 - 0.09 * f32(n)) * exp(-max(tf - ts, 0.0) / 0.08) * step(ts, tf);
        }
        fl.p[0] = vec4<f32>(C + vec3<f32>(0.0, SC_WALL + 14.0, 0.0), fin * 2.2);
        if (stage != 1u && !sky) {
            let dl = length(rel - C);
            gflash = gflash + vec3<f32>(0.85, 0.88, 1.1) * fin * 18.0 / (1.0 + dl * dl / 2500.0);
        }
        sky_flash = sky_flash + fin * 0.6 / (1.0 + length(C) / 400.0);
    }

    // ---- the land in the storm's gloom: darker and a little green under the cloud, and lit by the bolts --------------
    if (stage != 1u) {
        if (!sky) {
            let rr = length((rel - C).xz);
            let cover = form * (1.0 - smoothstep(sc_deck_r(time) * 0.75, sc_deck_r(time) * 1.05, rr));
            // (and wet where the rain falls: darker, a little cooler)
            let wet = sc_rain(time) * sc_fade(time) * (1.0 - smoothstep(sc_deck_r(time) * 0.55, sc_deck_r(time) * 0.8, rr));
            // (the storm's shadow reaching on past its deck, under the anvil and the murk round it: the land round a
            // player watching from a few hundred blocks off dims too, not just what lies under the cloud)
            let shade = form * (1.0 - smoothstep(sc_deck_r(time), sc_deck_r(time) * 1.9, rr));
            col = col * (1.0 - 0.3 * form - 0.42 * cover) * (1.0 - 0.3 * shade * (1.0 - cover)) * mix(vec3<f32>(1.0), vec3<f32>(0.9, 1.0, 0.94), max(cover, 0.6 * shade)) * mix(vec3<f32>(1.0), vec3<f32>(0.84, 0.86, 0.9), wet);
            col = col + scene * gflash * k;
            // (the finale's shockwave: a bright ring racing out over the land at 140 blocks a second, as its edits go,
            // a wall of dust and smoke rising behind it, settling into a haze)
            if (tf > 0.0 && tf < 5.0) {
                let front = 140.0 * tf;
                let e = rr - front;
                let ring = exp(-pow(e / 6.0, 2.0)) * exp(-tf / 1.6);
                let behind = smoothstep(4.0, -30.0, e) * exp(-tf / 2.2) * smoothstep(0.0, 25.0, rr);
                col = col + (scene * 2.2 + vec3<f32>(0.25, 0.22, 0.18)) * ring * k;
                col = mix(col, vec3<f32>(0.2, 0.18, 0.16) * (amb0 * 2.0 + vec3<f32>(0.08)), 0.45 * behind * k);
                // (the crater glowing where the strike fused it, cooling)
                col = col + vec3<f32>(2.6, 0.9, 0.25) * exp(-max(rr - 6.0, 0.0) / 9.0) * exp(-tf / 1.8) * k;
            }
        } else {
            let lum = dot(col, vec3<f32>(0.2126, 0.7152, 0.0722));
            col = mix(col, vec3<f32>(lum) * vec3<f32>(0.92, 1.0, 0.95), 0.6 * form) * (1.0 - 0.62 * form);
        }
        // (everything flickering brighter with the flashes, the sky most)
        col = col + (scene * 0.5 + amb0 * 0.4 + vec3<f32>(0.01)) * vec3<f32>(0.8, 0.85, 1.1) * min(sky_flash, 2.5) * select(0.5, 1.0, sky) * k;
    }

    // ---- the cloud, the rain and the funnels -------------------------------------------------------------------------
    var vol_t = 1.0e9;
    var vol_a = 1.0;
    if (stage == 2u) {
        col = col * up.a + up.rgb;
        vol_a = up.a;
    } else if (time < SC_LEN) {
        let j = ign(in.position.xy + vec2<f32>(fract(time * 7.0) * 37.0, 0.0));
        let v = sc_volume(rd, scene_len, C, time, j, fl, L, amb, sunc, true);
        vol_t = v.t;
        vol_a = v.c.a;
        if (stage == 0u) {
            let kk = k;
            col = col * mix(1.0, v.c.a, kk) + v.c.rgb * kk;
        } else {
            let srgb_h = v.c;
            return PlOut(vec4<f32>(srgb_h.rgb * k, mix(1.0, srgb_h.a, k)), vec4<f32>(min(scene_len, 6.0e4), select(1.0e9, v.t, v.t < 1.0e8), 0.0, 0.0));
        }
    }

    // ---- the bolts, over it all (hidden by the cloud only for an eye above it) ----------------------------------------
    let cam_above = smoothstep(C.y + SC_TOP - 20.0, C.y + SC_TOP + 20.0, 0.0);
    let behind = mix(1.0, vol_a, cam_above);
    // (the hush before the crack: the light held back, the land and the cloud a breath darker)
    let hush = sc_hush(time);
    col = col * (1.0 - 0.32 * hush * k);
    // (the pieces flung round the funnels' feet: dark specks against the dust and the sky)
    if (have) {
        let nf = u32(sc_w(2u) + 0.5);
        for (var kf = 0u; kf < min(nf, 4u); kf = kf + 1u) {
            let f = vx_at(kf, time, C);
            if (f.debris < 0.02) {
                continue;
            }
            let sg = pl_ray_seg(rd, f.foot, f.foot + vec3<f32>(0.0, 30.0, 0.0), 0.0, 1.0);
            if (sg.x < 14.0 + 3.0 * f.r) {
                let cv = vx_pieces(in.position.xy, f, time, scene_len);
                col = mix(col, vec3<f32>(0.07, 0.06, 0.05) * (amb0 + vec3<f32>(0.05)), cv * k);
            }
        }
    }
    if (have) {
        let px = in.position.xy;
        let nb = min(u32(sc_w(0u) + 0.5), SC_NB);
        var core = 0.0;
        var glow = 0.0;
        for (var i = sc_first(time); i < nb; i = i + 1u) {
            let b = sc_bolt(i);
            let a = time - b.w;
            if (a < -SC_LEAD) {
                break;
            }
            if (a > 1.0) {
                continue;
            }
            let pos = sc_positive(i, seed);
            let root = C + sc_root(b.xyz, i, seed, b.w);
            let foot = C + b.xyz;
            let sd = f32(pcg(i * 7u + seed) % 1000u) * 0.13 + 3.0;
            let sz = sc_size(b.w);
            if (sc_is_run(b.w)) {
                // (the run-in's: there at once, no leader; an arcing one in two legs, in under the cloud's base from the
                // ring and then down)
                let I = sc_snap(a, pcg(i ^ seed)) * sc_hushcut(time) * 1.3;
                if (I < 0.004) {
                    continue;
                }
                if (sc_arc(i, seed)) {
                    let ra = C + sc_arc_root(b.xyz, i, seed);
                    let bend = C + sc_arc_bend(b.xyz, ra - C, i, seed);
                    let m0 = sc_draw_bolt(px, ra, bend, sd + 1.9, 0.9 * sz, 1.0, scene_len);
                    let m1 = sc_draw_bolt(px, bend, foot, sd, 1.15 * sz, 1.0, scene_len);
                    core = core + (m0.x + m1.x) * I;
                    glow = glow + (m0.y + m1.y) * I;
                } else {
                    let m = sc_draw_bolt(px, root, foot, sd, 1.15 * sz, 1.0, scene_len);
                    core = core + m.x * I;
                    glow = glow + m.y * I;
                }
                continue;
            }
            if (a < 0.0) {
                // (the stepped leader: a dim branching tree creeping down)
                let m = sc_draw_bolt(px, root, foot, sd, 0.6 * sz, sc_leader(a), scene_len);
                core = core + m.x * 0.12;
                glow = glow + m.y * 0.1;
                continue;
            }
            let I = sc_stroke(a, pcg(i ^ seed)) * select(1.0, 1.5, pos) * mix(0.6, 1.0, sz);
            let m = sc_draw_bolt(px, root, foot, sd, select(1.0, 1.6, pos) * sz, 1.0, scene_len);
            core = core + m.x * I;
            glow = glow + m.y * I;
        }
        // (spider lightning: some of the flickers crawl along the cloud's base in branching channels)
        let nk = u32(sc_w(3u) + 0.5);
        for (var i = 0u; i < min(nk, 64u); i = i + 1u) {
            if (mh(i, seed, 0x62u) > 0.5) {
                continue;
            }
            let o = SC_K + 3u * i;
            let a = time - sc_w(o);
            if (a < 0.0 || a > 0.5) {
                continue;
            }
            let p0 = vec3<f32>(sc_w(o + 1u), 0.0, sc_w(o + 2u));
            let ang = TAU * mh(i, seed, 0x63u);
            let len = 60.0 + 80.0 * mh(i, seed, 0x64u);
            let p1 = p0 + vec3<f32>(cos(ang) * len, 0.0, sin(ang) * len);
            let ra = C + vec3<f32>(p0.x, sc_base(length(p0.xz)) - 2.0, p0.z);
            let rb = C + vec3<f32>(p1.x, sc_base(length(p1.xz)) - 2.0, p1.z);
            let I = (exp(-a / 0.07) + 0.6 * exp(-max(a - 0.15, 0.0) / 0.06) * step(0.15, a)) * 0.6 * (1.0 - hush);
            let m = sc_draw_bolt(px, ra, rb, f32(i) * 3.7 + 11.0, 0.7, saturate(a / 0.12), scene_len);
            core = core + m.x * I;
            glow = glow + m.y * I;
        }
        // (in the hush, the one channel's leader racing down out of the wall cloud onto the target, faint, its tearing
        // what is heard then; the return stroke lights the same path)
        let main_root = C + vec3<f32>(0.0, SC_WALL + 6.0, 0.0);
        let main_sd = f32(seed % 13u);
        if (tf > -SC_SUCK && tf < 0.0) {
            let lead = pow(saturate((tf + SC_SUCK) / SC_SUCK), 1.5);
            let m = sc_draw_bolt(px, main_root, C, main_sd, 1.2, lead, scene_len);
            core = core + m.x * 0.14;
            glow = glow + m.y * 0.08;
        }
        if (fin > 0.0) {
            // (the one channel, blinding, held and re-struck)
            let m = sc_draw_bolt(px, main_root, C, main_sd, 6.5, 1.0, scene_len);
            core = core + m.x * fin;
            glow = glow + m.y * fin;
            // (and in the same instant the ring of bolts round the wall cloud snapping into it, from all round, each
            // striking its channel part way down; gone in a few frames, into it, as the whiteout clears)
            let sp = exp(-tf / 0.08) * step(tf, 0.4);
            if (sp > 0.01) {
                for (var i = 0u; i < 9u; i = i + 1u) {
                    let a = TAU * (f32(i) + 0.4 * mh(i, seed, 0x71u)) / 9.0 + f32(seed % 7u);
                    let rr = 50.0 + 35.0 * mh(i, seed, 0x72u);
                    let root = C + vec3<f32>(cos(a) * rr, sc_base(rr) + 2.0, sin(a) * rr);
                    let hit = C + vec3<f32>(0.0, 12.0 + 28.0 * mh(i, seed, 0x73u), 0.0);
                    let m = sc_draw_bolt(px, root, hit, f32(i) * 23.1 + 5.0 + f32(seed % 11u), 2.2, 1.0, scene_len);
                    core = core + m.x * sp * 1.6;
                    glow = glow + m.y * sp * 1.4;
                }
            }
        }
        col = col + (vec3<f32>(2.4, 2.4, 3.2) * min(core, 3.0) * 2.4 + vec3<f32>(0.42, 0.4, 1.0) * glow * 1.2) * behind * k;
    }
    // (the finale: the picture whited out for an instant, fading as the eye recovers, less from far off)
    if (tf > 0.0 && tf < 1.5) {
        let near = 1.0 / (1.0 + length(C) / 350.0);
        let wo = (0.65 * exp(-tf / 0.08) + 0.2 * exp(-tf / 0.6)) * near * k;
        col = mix(col, vec3<f32>(1.3, 1.32, 1.45), saturate(wo));
    }

    // ---- the rain close by, for an eye under the storm: drops in the world round the camera (`sc_rain_lines`, as the
    // Hurricane's: the same at any pitch, looking straight up or down), slanted a little by the wind, more of them
    // out at the edges of the picture than across its middle, hidden by what stands in front, only under the base
    let rk = sc_rain(time) * sc_fade(time);
    if (rk > 0.01 && stage != 1u) {
        let res = frame.resolution.xy;
        let edge = mix(0.3, 1.0, smoothstep(0.12, 0.48, length((uv - 0.5) * vec2<f32>(res.x / res.y, 1.0))));
        let cq = -C;
        let under = (1.0 - smoothstep(sc_deck_r(time) * 0.6, sc_deck_r(time) * 0.8, length(cq.xz))) * (1.0 - smoothstep(sc_base(length(cq.xz)) - 20.0, sc_base(length(cq.xz)), cq.y));
        let streak = sc_rain_lines(rd, cq, vec3<f32>(2.2, -16.0, 0.8), scene_len, time) * under * 0.8;
        col = col + vec3<f32>(0.62, 0.66, 0.72) * streak * rk * edge * (amb0 * 0.7 + vec3<f32>(0.02) + vec3<f32>(0.7) * min(sky_flash, 2.0)) * k;
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

// ---- the finale's jolt: the picture slammed and shaken as its crack reaches the player, as hard as the Rod's (rod.wgsl's
// pl_jolt): a slam swinging hard three or four times in half a second, a shudder fading over a couple of seconds ----
// How long before its crack reaches the player the finale's hush falls (storm.rs's FIN_SUCK: the beds cut, the run-in
// fallen away, only the leader's tearing rising into it; the pass holds its light back then, `sc_hush`).
const SC_SUCK: f32 = 0.16;
// Seconds since the finale's crack reached the player (negative before), and how much of it reaches them.
fn sc_heard() -> vec2<f32> {
    let C = vec3<f32>(anchor_xz().x, block_y() + 1.0, anchor_xz().y);
    let me = vec3<f32>(frame.mod_params[3].x, frame.mod_params[3].y, frame.mod_params[3].z);
    let dist = length(me - C);
    return vec2<f32>(now() - SC_FINALE - 0.05 - dist / 343.0, clamp(1.5 / (1.0 + dist / 350.0), 0.2, 1.0));
}
fn sc_jolt(in: StageIn) -> StageIn {
    let h = sc_heard();
    let s = h.x;
    if (s <= 0.0 || s > 6.0 || intensity_v() <= 0.0) {
        return in;
    }
    let g = h.y;
    let hit = 0.034 * g * exp(-s / 0.22) * smoothstep(0.0, 0.015, s);
    let ring = vec2<f32>(0.65 * sin(s * 53.0 + 0.6) + 0.35 * sin(s * 89.0 + 2.1), 0.65 * cos(s * 47.0 + 1.3) + 0.35 * sin(s * 77.0 + 0.4));
    let shud = 0.005 * g * exp(-s / 1.8) * smoothstep(0.08, 0.4, s);
    let sh = vec2<f32>(0.55 * sin(s * 17.0 + 0.3) + 0.3 * sin(s * 29.0 + 1.9) + 0.15 * sin(s * 53.0),
                       0.55 * cos(s * 15.0 + 2.2) + 0.3 * sin(s * 31.0 + 0.7) + 0.15 * cos(s * 59.0));
    let off = ring * hit + sh * shud;
    let roll = 0.018 * g * exp(-s / 0.3) * sin(s * 41.0 + 0.9) + 0.0025 * g * exp(-s / 1.8) * sin(s * 11.0);
    let res = frame.resolution.xy;
    let asp = res.x / res.y;
    let zoom = 1.0 + 2.2 * (hit + shud) + 1.1 * abs(roll) * asp;
    var q = (in.uv - 0.5) * vec2<f32>(asp, 1.0) / zoom;
    q = vec2<f32>(q.x * cos(roll) - q.y * sin(roll), q.x * sin(roll) + q.y * cos(roll)) + off;
    var o = in;
    o.uv = clamp(q / vec2<f32>(asp, 1.0) + 0.5, vec2<f32>(0.0), vec2<f32>(1.0));
    o.position = vec4<f32>(o.uv * res, in.position.zw);
    return o;
}
// The pressure of it on the picture, with the sound: in the hush before the crack the picture drawn in (the edges
// darkening, the colour draining a little), then as it hits a hard punch of light, the air shoved (a pale flash
// that blows out the picture's middle tones, gone in a third of a second) and a dusty haze settling after.
fn sc_press(c: vec3<f32>, uv: vec2<f32>) -> vec3<f32> {
    let h = sc_heard();
    let s = h.x;
    if (s < -SC_SUCK - 0.05 || s > 3.0 || intensity_v() <= 0.0) {
        return c;
    }
    let g = h.y;
    let res = frame.resolution.xy;
    let r = length((uv - 0.5) * vec2<f32>(res.x / res.y, 1.0));
    var o = c;
    // (the hush: drawn in)
    let suck = smoothstep(-SC_SUCK - 0.05, -0.02, s) * (1.0 - smoothstep(0.0, 0.03, s));
    let lum = dot(o, vec3<f32>(0.2126, 0.7152, 0.0722));
    o = mix(o, vec3<f32>(lum), 0.35 * suck * g) * (1.0 - 0.55 * suck * g * smoothstep(0.25, 0.85, r));
    // (the punch: the picture blown out pale, the middle first)
    let punch = g * smoothstep(0.0, 0.012, s) * exp(-max(s, 0.0) / 0.09);
    o = o + (vec3<f32>(0.95, 0.97, 1.05) - o * 0.3) * punch * (1.0 - 0.45 * smoothstep(0.1, 0.9, r));
    // (the dust it shoves along after: a warm grey haze settling over two seconds)
    let haze = g * smoothstep(0.03, 0.25, s) * exp(-max(s - 0.25, 0.0) / 1.2);
    o = mix(o, vec3<f32>(0.42, 0.4, 0.37) * (0.6 + 0.4 * lum), 0.22 * haze);
    return max(o, vec3<f32>(0.0));
}

@fragment
fn fs_main(in0: StageIn) -> @location(0) vec4<f32> {
    let o = supercell(sc_jolt(in0), 0u, vec4<f32>(0.0)).c;
    return vec4<f32>(sc_press(o.rgb, in0.uv), o.a);
}


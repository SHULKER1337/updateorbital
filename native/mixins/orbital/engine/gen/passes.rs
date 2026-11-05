/// The other lasers' pass, then the downfall's, the planet killer's, the crystal bloom's and the sinkhole's.
const PASS_OWN: [&str; 5] = [include_str!("../data/shaders/strike.wgsl"), include_str!("../data/gen/pass_downfall.wgsl"), include_str!("../data/gen/pass_planetkiller.wgsl"), include_str!("../data/gen/pass_crystalbloom.wgsl"), include_str!("../data/gen/pass_sinkhole.wgsl")];
/// The Payload's at QUALITY FULL and FAST.
const PASS_PAYLOAD: [&str; 2] = [include_str!("../data/gen/pass_payload_false.wgsl"), include_str!("../data/gen/pass_payload_true.wgsl")];
/// The Nuke's at QUALITY FULL and FAST.
const PASS_NUKE: [&str; 2] = [include_str!("../data/gen/pass_nuke_false.wgsl"), include_str!("../data/gen/pass_nuke_true.wgsl")];
/// The Rod from God's at QUALITY FULL and FAST.
const PASS_ROD: [&str; 2] = [include_str!("../data/gen/pass_rod_false.wgsl"), include_str!("../data/gen/pass_rod_true.wgsl")];
/// The Supercell's at QUALITY FULL and FAST.
const PASS_SUPERCELL: [&str; 2] = [include_str!("../data/gen/pass_supercell_false.wgsl"), include_str!("../data/gen/pass_supercell_true.wgsl")];
/// The Hurricane's at QUALITY FULL and FAST.
const PASS_HURRICANE: [&str; 2] = [include_str!("../data/gen/pass_hurricane_false.wgsl"), include_str!("../data/gen/pass_hurricane_true.wgsl")];

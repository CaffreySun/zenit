//! Fault controls and ownership counters compile out of production builds.
pub const enabled = @import("builtin").is_test or @import("build_options").test_mode;

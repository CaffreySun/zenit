const builtin = @import("builtin");

pub const TitlebarStyle = enum {
    default,
    /// Application content extends into the caption. Native window controls
    /// remain owned by the platform; the application draws its caption body.
    custom_inset,
};

pub const WindowChrome = @import("system_sdk").window_chrome.Config;

pub const WindowConfig = struct {
    min_width: u32 = 0,
    min_height: u32 = 0,
    width: if (builtin.os.tag == .windows) u32 else u16 = 800,
    height: if (builtin.os.tag == .windows) u32 else u16 = 600,
    title: [:0]const u8 = if (builtin.os.tag == .windows) "Zenit" else "zenit",
    /// New API takes precedence. Null translates the legacy titlebar settings.
    chrome: ?WindowChrome = null,
    titlebar: TitlebarStyle = .default,
    titlebar_height: f32 = 52,
    titlebar_drag_right_inset: f32 = 0,
    /// Experimental AppKit host prototype; other backends reject visible policies.
    /// Final host preference/fallback contract is not frozen yet.
    fullscreen_header: @import("system_sdk").window_chrome.HeaderVisibility = .hidden,
};

pub fn requestedChrome(config: WindowConfig) WindowChrome {
    return config.chrome orelse switch (config.titlebar) {
        .default => .native,
        // Legacy custom_inset was a no-op on Linux; opt in through chrome.
        .custom_inset => if (builtin.os.tag == .linux) .native else .{ .custom = .{} },
    };
}

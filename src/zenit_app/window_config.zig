const builtin = @import("builtin");

pub const TitlebarStyle = enum {
    default,
    /// Application content extends into the caption. Native window controls
    /// remain owned by the platform; the application draws its caption body.
    custom_inset,
};

pub const WindowConfig = struct {
    width: if (builtin.os.tag == .windows) u32 else u16 = 800,
    height: if (builtin.os.tag == .windows) u32 else u16 = 600,
    title: [:0]const u8 = if (builtin.os.tag == .windows) "Zenit" else "zenit",
    titlebar: TitlebarStyle = .default,
    titlebar_height: f32 = 52,
    titlebar_drag_right_inset: f32 = 0,
};

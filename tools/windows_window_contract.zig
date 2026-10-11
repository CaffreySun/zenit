//! Owned HWND titlebar hit-test contract; never activates or moves the desktop.
const std = @import("std");
const App = @import("zenit_app").App;
const ui = @import("ui");
const Point = extern struct { x: i32, y: i32 };
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
extern "user32" fn ClientToScreen(*anyopaque, *Point) callconv(.winapi) c_int;
extern "user32" fn SendMessageW(*anyopaque, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern "user32" fn GetWindowRect(*anyopaque, *Rect) callconv(.winapi) c_int;
extern fn zenit_win_titlebar_region(*anyopaque, f32, f32) c_int;
extern fn zenit_win_window_drag(*anyopaque) c_int;
extern fn zenit_win_custom_frame(*anyopaque, c_int, f32, f32) c_int;
extern "dwmapi" fn DwmGetWindowAttribute(*anyopaque, u32, *Rect, u32) callconv(.winapi) i32;
extern "user32" fn ScreenToClient(*anyopaque, *Point) callconv(.winapi) c_int;
fn require(ok: bool) !void {
    if (!ok) return error.WindowContractFailed;
}
fn hit(app: *App, x: f32, y: f32) !isize {
    const scale = app.win.getScaleFactor();
    var point = Point{ .x = @intFromFloat(x * scale), .y = @intFromFloat(y * scale) };
    const hwnd = app.win.getNativeSurfaceHandle();
    try require(ClientToScreen(hwnd, &point) != 0);
    const packed_point = @as(u32, @as(u16, @truncate(@as(u32, @bitCast(point.x))))) | (@as(u32, @as(u16, @truncate(@as(u32, @bitCast(point.y))))) << 16);
    return SendMessageW(hwnd, 0x84, 0, @as(isize, @as(i32, @bitCast(packed_point))));
}
const HitContext = struct {
    blocked: bool = true,
    calls: usize = 0,
    x: f32 = 0,
    y: f32 = 0,
    fn callback(raw: ?*anyopaque, x: f32, y: f32) callconv(.c) c_int {
        const self: *HitContext = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.x = x;
        self.y = y;
        return @intFromBool(self.blocked);
    }
};
pub fn run(app: *App) !void {
    const foreground = GetForegroundWindow();
    defer {
        app.win.setTitlebarHitCallback(null, null);
        app.win.setTitlebarDragHeight(0);
        app.win.setTitlebarDragRightInset(0);
    }
    try require(try hit(app, 40, 10) == 1); // HTCLIENT by default.
    app.win.setTitlebarDragHeight(32);
    try require(try hit(app, 40, 10) == 2); // HTCAPTION only inside the declared band.
    try require(try hit(app, 40, 40) == 1);
    app.win.setTitlebarDragRightInset(64);
    const size = app.win.getSize();
    try require(try hit(app, @as(f32, @floatFromInt(size[0])) - 10, 10) == 1);
    var context = HitContext{};
    app.win.setTitlebarHitCallback(HitContext.callback, &context);
    try require(try hit(app, 40, 10) == 1);
    try require(context.calls == 1 and @abs(context.x - 40) < 1 and @abs(context.y - 10) < 1);
    context.blocked = false;
    try require(try hit(app, 40, 10) == 2);
    app.win.setTitlebarHitCallback(null, null);
    try require(zenit_win_titlebar_region(app.win.getNativeSurfaceHandle(), std.math.nan(f32), 0) == 0);
    try require(zenit_win_titlebar_region(app.win.getNativeSurfaceHandle(), -1, 0) == 0);
    try require(try hit(app, 40, 10) == 2); // Rejection preserves the old band.
    const ForeignThread = struct {
        fn check(hwnd: *anyopaque, result: *c_int) void {
            result.* = zenit_win_titlebar_region(hwnd, 1, 0);
        }
    };
    var foreign_result: c_int = -1;
    const thread = try std.Thread.spawn(.{}, ForeignThread.check, .{ app.win.getNativeSurfaceHandle(), &foreign_result });
    thread.join();
    try require(foreign_result == 0 and try hit(app, 40, 10) == 2);
    app.win.setTitlebarDragHeight(0);
    try require(try hit(app, 40, 10) == 1);
    if (foreground != app.win.getNativeSurfaceHandle()) {
        var before: Rect = undefined;
        var after: Rect = undefined;
        try require(GetWindowRect(app.win.getNativeSurfaceHandle(), &before) != 0);
        try require(zenit_win_window_drag(app.win.getNativeSurfaceHandle()) == 0);
        try require(GetWindowRect(app.win.getNativeSurfaceHandle(), &after) != 0);
        try require(std.meta.eql(before, after));
    }
    try require(GetForegroundWindow() == foreground);
}

/// Uses a separate owned App; no system move loop, activation or clicks.
pub fn runCustom(io: std.Io) !void {
    const foreground = GetForegroundWindow();
    const before = @FieldType(App, "win").liveWindowCount();
    {
        const app = try App.init(std.heap.page_allocator, .{ .io = io, .window = .{ .width = 401, .height = 301, .title = "Zenit custom caption contract", .titlebar = .custom_inset, .titlebar_height = 52, .titlebar_drag_right_inset = 160 } });
        defer app.deinit();
        const hwnd = app.win.getNativeSurfaceHandle();
        try require(app.win.getTitlebarHeight() == 52);
        try require(std.meta.eql(app.win.getSize(), [2]u32{ 401, 301 }));
        var outer: Rect = undefined;
        var origin = Point{ .x = 0, .y = 0 };
        try require(GetWindowRect(hwnd, &outer) != 0 and ClientToScreen(hwnd, &origin) != 0);
        try require(origin.y == outer.top); // No second native caption above UI.
        try require(origin.x > outer.left); // Native side resize border retained.
        const button = try ui.box(app.cx, .{ .width = .{ .px = 70 }, .height = .{ .px = 32 }, .position = .absolute, .background = ui.Color.WHITE }, .{});
        const ext = try button.style.ensureExtFallible(app.allocator);
        ext.inset = .{ .left = .{ .px = 100 }, .top = .{ .px = 8 } };
        var clicks: usize = 0;
        button.behavior.events.on_click = ui.Cx.simpleHandler(struct {
            fn clicked(raw: *anyopaque) void {
                const count: *usize = @ptrCast(@alignCast(raw));
                count.* += 1;
            }
        }.clicked, &clicks);
        app.cx.root = try ui.box(app.cx, .{ .width = .{ .grow = .{} }, .height = .{ .grow = .{} } }, .{button});
        try app.frame();
        try require(try hit(app, 40, 20) == 2);
        try require(try hit(app, 120, 20) == 1); // App callback excludes interactive UI.
        try require(try hit(app, 245, 20) == 1); // Declared right-hand exclusion.
        try require(try hit(app, 40, 60) == 1);
        try require(try hit(app, 40, 1) == 12); // HTTOP retained over the custom caption.
        var controls: Rect = undefined;
        try require(DwmGetWindowAttribute(hwnd, 5, &controls, @sizeOf(Rect)) >= 0);
        try require(controls.right > controls.left and controls.bottom > controls.top);
        var reserved: Rect = undefined;
        try require(zenit_win_caption_button_rect(hwnd, &reserved) == 1);
        try require(reserved.left == controls.left + outer.left - origin.x and
            reserved.top == controls.top + outer.top - origin.y and
            reserved.right == controls.right + outer.left - origin.x and
            reserved.bottom == controls.bottom + outer.top - origin.y);
        try require(zenit_win_caption_button_rect(hwnd, null) == -1);
        const third = @divTrunc(controls.right - controls.left, 3);
        for ([_]isize{ 8, 9, 20 }, 0..) |expected, index| {
            var point = Point{ .x = outer.left + controls.left + third * @as(i32, @intCast(index)) + @divTrunc(third, 2), .y = outer.top + @divTrunc(controls.top + controls.bottom, 2) };
            try require(ScreenToClient(hwnd, &point) != 0);
            const scale = app.win.getScaleFactor();
            const actual = try hit(app, @as(f32, @floatFromInt(point.x)) / scale, @as(f32, @floatFromInt(point.y)) / scale);
            if (actual != expected) std.log.err("custom caption control {d}: hit={d}, expected={d}, bounds={any}", .{ index, actual, expected, controls });
            try require(actual == expected);
        }
        try require(zenit_win_custom_frame(hwnd, 1, std.math.nan(f32), 0) == 0);
        try require(zenit_win_custom_frame(hwnd, 1, -1, 0) == 0);
        try require(app.win.getTitlebarHeight() == 52 and GetForegroundWindow() == foreground and clicks == 0);
        _ = ShowWindow(hwnd, 7); // SW_SHOWMINNOACTIVE, owned contract App only.
        try require(IsIconic(hwnd) != 0 and zenit_win_caption_button_rect(hwnd, &reserved) == 0);
        app.cx.needs_redraw = true;
        try app.frame(); // DWM caption bounds are undefined while minimized.
        _ = ShowWindow(hwnd, 4); // Restore without activating.
        try require(IsIconic(hwnd) == 0 and GetForegroundWindow() == foreground);
        try require(app.win.setSizeChecked(503, 307));
        try app.frame();
        try require(std.meta.eql(app.win.getSize(), [2]u32{ 503, 307 }));
        try require(zenit_win_custom_frame(hwnd, 0, 52, 0) != 0);
        try require(app.win.setSizeChecked(401, 301));
        try require(app.win.getTitlebarHeight() == 0);
        try require(zenit_win_caption_button_rect(hwnd, &reserved) == 0);
        origin = .{ .x = 0, .y = 0 };
        try require(GetWindowRect(hwnd, &outer) != 0 and ClientToScreen(hwnd, &origin) != 0 and origin.y > outer.top);
        try require(GetForegroundWindow() == foreground);
    }
    try require(@FieldType(App, "win").liveWindowCount() == before);
    std.log.info("Windows custom caption contract: App config, client sizing, UI exclusion, DWM controls and restore PASS", .{});
}

extern "user32" fn SetWindowPos(*anyopaque, ?*anyopaque, c_int, c_int, c_int, c_int, u32) callconv(.winapi) c_int;
extern fn zenit_win_caption_button_rect(*anyopaque, ?*Rect) c_int;
extern "user32" fn ShowWindow(*anyopaque, c_int) callconv(.winapi) c_int;
extern "user32" fn IsIconic(*anyopaque) callconv(.winapi) c_int;
extern fn zenit_win_contract_refresh_source(*anyopaque, u32, u32) void;

pub fn runRefresh(app: *App) !void {
    const hwnd = app.win.getNativeSurfaceHandle();
    const foreground = GetForegroundWindow();
    const actual = app.win.getDisplayRefreshRate();
    try require(std.math.isFinite(actual) and actual > 1);
    defer {
        zenit_win_contract_refresh_source(app.win.native, 0, 0);
        _ = SendMessageW(hwnd, 0x7e, 0, 0); // WM_DISPLAYCHANGE invalidates cache.
        _ = SendMessageW(hwnd, 0xf, 0, 0);
    }
    zenit_win_contract_refresh_source(app.win.native, 60000, 1001);
    // Changing the source alone must not bypass the per-monitor cache.
    try require(app.win.getDisplayRefreshRate() == actual);
    _ = SendMessageW(hwnd, 0x7e, 0, 0);
    _ = SendMessageW(hwnd, 0xf, 0, 0);
    try require(@abs(app.win.getDisplayRefreshRate() - 59.94006) < 0.001);
    try require(@abs(app.cx.display_refresh_hz - 59.94006) < 0.001);
    zenit_win_contract_refresh_source(app.win.native, 120000, 1001);
    _ = SendMessageW(hwnd, 0x7e, 0, 0);
    _ = SendMessageW(hwnd, 0xf, 0, 0);
    try require(@abs(app.cx.display_refresh_hz - 119.88012) < 0.001);
    // Invalid/default frequencies restore the real driver source, not zero Hz.
    zenit_win_contract_refresh_source(app.win.native, 1, 0);
    _ = SendMessageW(hwnd, 0x7e, 0, 0);
    _ = SendMessageW(hwnd, 0xf, 0, 0);
    try require(app.cx.display_refresh_hz == actual);
    try require(GetForegroundWindow() == foreground);
    std.log.info("Windows display refresh contract actual={d:.3} fractional=59.940/119.880", .{actual});
}

pub fn runPaint(app: *App) !void {
    const hwnd = app.win.getNativeSurfaceHandle();
    const foreground = GetForegroundWindow();
    var before: Rect = undefined;
    try require(GetWindowRect(hwnd, &before) != 0);
    const original = app.win.getSize();
    try require(!app.win.isInLiveResize() and !app.native_frame_active);
    defer {
        app.native_frame_active = false;
        _ = SendMessageW(hwnd, 0x232, 0, 0);
        _ = SetWindowPos(hwnd, null, 0, 0, before.right - before.left, before.bottom - before.top, 0x16);
        _ = SendMessageW(hwnd, 0xf, 0, 0);
    }
    _ = SendMessageW(hwnd, 0x231, 0, 0);
    try require(app.win.isInLiveResize());
    app.win.setSize(original[0] - 80, original[1] - 60);
    const size = app.win.getSize();
    // No SDK pump or App.frame here: the native WM_PAINT callback must update
    // viewport/layout while Win32 owns its nested move/size loop.
    _ = SendMessageW(hwnd, 0xf, 0, 0);
    try require(app.width == size[0] and app.height == size[1]);
    try require(app.cx.viewport.width == @as(f32, @floatFromInt(size[0])));
    try require(app.cx.viewport.height == @as(f32, @floatFromInt(size[1])));
    const root = app.cx.root orelse return error.WindowContractFailed;
    try require(@abs(root.globalRect().w - app.cx.viewport.width) < 0.1);
    const frames = app.cx.frame_count;
    _ = SendMessageW(hwnd, 0x113, 0x5a4e0001, 0);
    try require(app.cx.frame_count > frames); // Timer keeps animation ticking.
    app.native_frame_active = true;
    app.native_redraw_pending = false;
    const stable_frames = app.cx.frame_count;
    _ = SendMessageW(hwnd, 0xf, 0, 0);
    try require(app.native_redraw_pending and app.cx.frame_count == stable_frames);
    app.native_frame_active = false;
    _ = SendMessageW(hwnd, 0x232, 0, 0);
    try require(!app.win.isInLiveResize());
    const ended_frames = app.cx.frame_count;
    _ = SendMessageW(hwnd, 0x113, 0x5a4e0001, 0);
    try require(app.cx.frame_count == ended_frames); // A stale timer cannot render.
    try require(GetForegroundWindow() == foreground);
}

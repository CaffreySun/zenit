//! DPI-aware client sizing on an owned background HWND, without activation.
const std = @import("std");
const App = @import("zenit_app").App;
const Window = @FieldType(App, "win");
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
extern "user32" fn GetWindowRect(*anyopaque, *Rect) callconv(.winapi) c_int;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern "user32" fn GetDpiForWindow(*anyopaque) callconv(.winapi) u32;
const WindowLong = if (@import("builtin").cpu.arch == .x86) struct {
    extern "user32" fn GetWindowLongW(*anyopaque, c_int) callconv(.winapi) i32;
    extern "user32" fn SetWindowLongW(*anyopaque, c_int, i32) callconv(.winapi) i32;
    const get = GetWindowLongW;
    const set = SetWindowLongW;
} else struct {
    extern "user32" fn GetWindowLongPtrW(*anyopaque, c_int) callconv(.winapi) isize;
    extern "user32" fn SetWindowLongPtrW(*anyopaque, c_int, isize) callconv(.winapi) isize;
    const get = GetWindowLongPtrW;
    const set = SetWindowLongPtrW;
};
extern "user32" fn SetWindowPos(*anyopaque, ?*anyopaque, c_int, c_int, c_int, c_int, u32) callconv(.winapi) c_int;
extern "user32" fn SendMessageW(*anyopaque, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn CreateMenu() callconv(.winapi) ?*anyopaque;
extern "user32" fn AppendMenuW(*anyopaque, u32, usize, [*:0]const u16) callconv(.winapi) c_int;
extern "user32" fn GetMenu(*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn SetMenu(*anyopaque, ?*anyopaque) callconv(.winapi) c_int;
extern "user32" fn DestroyMenu(*anyopaque) callconv(.winapi) c_int;
extern "user32" fn DrawMenuBar(*anyopaque) callconv(.winapi) c_int;
fn require(ok: bool) !void {
    if (!ok) return error.WindowSizeContractFailed;
}
fn sized(app: *App, width: u32, height: u32) !void {
    try require(app.win.setSizeChecked(width, height));
    const actual = app.win.getSize();
    const pixels = app.win.getDrawableSize();
    const dpi = GetDpiForWindow(app.win.getNativeSurfaceHandle());
    std.log.info("Windows size contract requested={d}x{d} actual={d}x{d} physical={d}x{d} dpi={d}", .{ width, height, actual[0], actual[1], pixels[0], pixels[1], dpi });
    try require(actual[0] == width and actual[1] == height);
    try require(pixels[0] == (@as(u64, width) * dpi + 95) / 96);
    try require(pixels[1] == (@as(u64, height) * dpi + 95) / 96);
    _ = SendMessageW(app.win.getNativeSurfaceHandle(), 0xf, 0, 0);
    try require(app.width == width and app.height == height);
}
pub fn run(app: *App) !void {
    const hwnd = app.win.getNativeSurfaceHandle();
    const foreground = GetForegroundWindow();
    const old_style = WindowLong.get(hwnd, -16);
    const old_ex_style = WindowLong.get(hwnd, -20);
    const old_menu = GetMenu(hwnd);
    var before: Rect = undefined;
    try require(GetWindowRect(hwnd, &before) != 0);
    const menu = CreateMenu() orelse return error.WindowSizeContractFailed;
    defer {
        _ = SetMenu(hwnd, old_menu);
        _ = WindowLong.set(hwnd, -16, old_style);
        _ = WindowLong.set(hwnd, -20, old_ex_style);
        _ = SetWindowPos(hwnd, null, 0, 0, before.right - before.left, before.bottom - before.top, 0x36);
        _ = DrawMenuBar(hwnd);
        _ = DestroyMenu(menu);
        _ = SendMessageW(hwnd, 0xf, 0, 0);
    }
    try sized(app, 801, 601);
    try sized(app, 1150, 850);
    try require(AppendMenuW(menu, 0, 1, std.unicode.utf8ToUtf16LeStringLiteral("Sizing 菜单")) != 0);
    try require(SetMenu(hwnd, menu) != 0);
    _ = DrawMenuBar(hwnd);
    try sized(app, 803, 603);
    var single_row: Rect = undefined;
    try require(GetWindowRect(hwnd, &single_row) != 0);
    for (2..10) |id| {
        try require(AppendMenuW(menu, 0, id, std.unicode.utf8ToUtf16LeStringLiteral("Extended sizing menu 菜单")) != 0);
    }
    _ = DrawMenuBar(hwnd);
    try sized(app, 803, 603); // Multiple menu rows must not steal client height.
    var wrapped: Rect = undefined;
    try require(GetWindowRect(hwnd, &wrapped) != 0);
    try require(wrapped.bottom - wrapped.top > single_row.bottom - single_row.top);
    std.log.info("Windows wrapped menu outer height {d}->{d}, client height stays 603", .{ single_row.bottom - single_row.top, wrapped.bottom - wrapped.top });
    _ = WindowLong.set(hwnd, -16, old_style & ~@as(isize, 0x40000)); // No WS_THICKFRAME.
    _ = WindowLong.set(hwnd, -20, old_ex_style | 0x200); // WS_EX_CLIENTEDGE.
    _ = SetWindowPos(hwnd, null, 0, 0, 0, 0, 0x37);
    try require(WindowLong.get(hwnd, -16) == old_style & ~@as(isize, 0x40000));
    try require(WindowLong.get(hwnd, -20) == old_ex_style | 0x200);
    try sized(app, 805, 605);
    _ = WindowLong.set(hwnd, -16, (old_style & ~@as(isize, 0x40000)) | 0x300000); // Native scrollbars.
    _ = SetWindowPos(hwnd, null, 0, 0, 0, 0, 0x37);
    try sized(app, 807, 607);
    var stable: Rect = undefined;
    try require(GetWindowRect(hwnd, &stable) != 0);
    const cached = .{ app.win.width, app.win.height };
    for ([_][2]u32{ .{ 0, 600 }, .{ 800, 0 }, .{ std.math.maxInt(u32), 600 }, .{ 800, std.math.maxInt(u32) } }) |size| {
        try require(!app.win.setSizeChecked(size[0], size[1]));
        var after: Rect = undefined;
        try require(GetWindowRect(hwnd, &after) != 0 and std.meta.eql(stable, after));
        try require(app.win.width == cached[0] and app.win.height == cached[1]);
        const count = Window.liveWindowCount();
        if (Window.init(size[0], size[1], "Invalid sizing contract")) |created| {
            var owned = created;
            owned.deinit();
            return error.WindowSizeContractFailed;
        } else |err| try require(err == error.WindowCreationFailed);
        try require(Window.liveWindowCount() == count);
    }
    var accepted = true;
    const thread = try std.Thread.spawn(.{}, struct {
        fn worker(win: *Window, result: *bool) void {
            result.* = win.setSizeChecked(807, 607);
        }
    }.worker, .{ &app.win, &accepted });
    thread.join();
    try require(!accepted and GetForegroundWindow() == foreground);
    var final: Rect = undefined;
    try require(GetWindowRect(hwnd, &final) != 0 and std.meta.eql(stable, final));
}

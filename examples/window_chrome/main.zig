//! A different Header is compiled for each window backend. GPU choice is irrelevant.
const std = @import("std");
const ui = @import("ui");
const app = @import("zenit_app");
const v = ui.view;
const W = ui.widgets;
var test_window: ?*app.App = null;
var test_search: ?*ui.Signal([]const u8) = null;
fn testRoute(path: []const u8, _: []const u8, out: []u8) ?[]const u8 {
    const window = test_window orelse return null;
    if (std.mem.eql(u8, path, "/chrome-input")) {
        var writer = std.Io.Writer.fixed(out);
        std.json.Stringify.value(if (test_search) |value| value.peek() else "", .{}, &writer) catch return null;
        return writer.buffered();
    }
    if (std.mem.eql(u8, path, "/chrome-double-maximize")) {
        window.toggleMaximize() catch return null;
        window.toggleMaximize() catch return null;
    } else if (std.mem.eql(u8, path, "/chrome-fullscreen-cancel")) {
        window.setFullscreen(true) catch return null;
        window.setFullscreen(false) catch return null;
    } else if (!std.mem.eql(u8, path, "/chrome-state")) return null;
    const s = window.chromeState();
    return std.fmt.bufPrint(out, "{{\"requested\":\"{s}\",\"effective\":\"{s}\",\"owner\":\"{s}\",\"fallback\":\"{s}\",\"maximized\":{},\"fullscreen\":{},\"transitioning\":{},\"active\":{},\"width\":{d},\"height\":{d},\"native_controls\":{d},\"capabilities\":{d},\"generation\":{d}}}", .{ @tagName(s.requested_mode), @tagName(s.effective_mode), @tagName(s.controls_owner), @tagName(s.fallback_reason), s.maximized, s.fullscreen, s.fullscreen_transitioning, s.active, s.width, s.height, s.native_controls_count, @as(u8, @bitCast(s.capabilities)), s.state_generation }) catch null;
}
var accept_close = false;
var close_count: ?*ui.Signal(u32) = null;
fn closeRequest(_: *app.App) bool {
    if (close_count) |count| count.set(count.peek() + 1);
    return accept_close;
}
fn allowClose(_: *ui.Cx) void {
    accept_close = true;
}
fn clearCount() void {
    close_count = null;
    test_search = null;
}
fn close(cx: *ui.Cx) void {
    cx.performWindowAction(.close) catch {};
}
fn maximize(cx: *ui.Cx) void {
    cx.performWindowAction(.toggle_maximize) catch |err| std.log.warn("Maximize request: {s}", .{@errorName(err)});
}
fn fullscreen(cx: *ui.Cx) void {
    const s = cx.windowChrome() catch return;
    cx.performWindowAction(.{ .fullscreen = !s.peek().fullscreen }) catch |err| std.log.warn("Fullscreen request: {s}", .{@errorName(err)});
}
fn commonHeader(scope: *ui.Scope, cx: *ui.Cx, title: []const u8) !*ui.Node {
    const search = try scope.createText("", .{});
    test_search = search;
    const owner = (try cx.windowChrome()).peek().controls_owner;
    const controls = if (owner == .application or owner == .none) try W.WindowControls(.{}).mount(scope, cx) else null;
    return W.WindowHeader(.{ .test_id = "chrome.header", .style = header_style }, .{
        W.DragRegion(.{ .test_id = "chrome.drag", .style = .{ .width = .fill, .height = .fill, .justify = .center } }, .{v.text(.{ .test_id = "chrome.backend" }, title)}),
        controls,
        v.box(.{ .test_id = "chrome.search", .window_region = .client }, .{W.Input(.{ .value = search, .placeholder = "Search", .width = 180 })}),
    }).mount(scope, cx);
}
const header_style = ui.css(.{ .width = .fill, .height = ui.arb.px(52), .padding = .{ .left = 12, .right = 12 }, .align_items = .center, .gap = 12, .background = ui.arb.hex(0xe9edf4) });
const MacHeader = struct {
    fn mount(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        return commonHeader(scope, cx, "AppKit Header");
    }
};
const WindowsHeader = struct {
    fn mount(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        return commonHeader(scope, cx, "Win32 Header");
    }
};
const LinuxHeader = struct {
    fn mount(scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
        return commonHeader(scope, cx, "Wayland Header");
    }
};
const Header = switch (app.build_environment.window_backend) {
    .appkit => MacHeader,
    .win32 => WindowsHeader,
    .wayland => LinuxHeader,
    else => @compileError("Unsupported window backend"),
};
fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    cx.setTheme(&ui.theme.light);
    const count = try scope.createSignal(u32, 0);
    close_count = count;
    try scope.onCleanup(ui.Cx, cx, struct {
        fn clean(_: *ui.Cx) void {
            clearCount();
        }
    }.clean);
    const header = try Header.mount(scope, cx);
    const s = try cx.windowChrome();
    return v.render(scope, cx, v.col(.{ .style = .{ .width = .fill, .height = .fill } }, .{
        header,
        v.col(.{ .style = .{ .width = .fill, .padding = ui.Padding.all(20), .gap = 12 } }, .{
            v.text(.{ .test_id = "chrome.state" }, v.fmt("requested={any}, effective={any}, owner={any}, fallback={any}", .{ ui.field(s, .requested_mode), ui.field(s, .effective_mode), ui.field(s, .controls_owner), ui.field(s, .fallback_reason) })),
            v.text(.{ .test_id = "chrome.close-count" }, v.fmt("Close requests: {d}", .{count})),
            v.attrs(.{ .test_id = "chrome.close" }, W.Button(.{ .label = "Request close (initially cancelled)", .on_click = cx.on(ui.Cx, cx, close) })),
            v.attrs(.{ .test_id = "chrome.allow-close" }, W.Button(.{ .label = "Allow closing", .on_click = cx.on(ui.Cx, cx, allowClose) })),
            v.attrs(.{ .test_id = "chrome.maximize" }, W.Button(.{ .label = "Toggle maximize", .on_click = cx.on(ui.Cx, cx, maximize) })),
            v.attrs(.{ .test_id = "chrome.fullscreen" }, W.Button(.{ .label = "Toggle fullscreen", .on_click = cx.on(ui.Cx, cx, fullscreen) })),
        }),
    }));
}
var smoke_close_calls: u32 = 0;
fn smokeVeto(window: *app.App) bool {
    smoke_close_calls += 1;
    // A close hook may itself request close; it must never recursively re-enter.
    window.requestClose() catch {};
    return false;
}
fn smokeMount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return v.render(scope, cx, W.WindowHeader(.{}, .{"Independent window"}));
}
fn multiSmoke(allocator: std.mem.Allocator, io: std.Io) !void {
    var application = app.MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 0 });
    defer application.deinit();
    const a = try application.createWindowWith(.{ .io = io, .window = .{ .width = 500, .height = 300, .chrome = .{ .custom = .{ .controls = .application } } }, .on_close_request = smokeVeto }, smokeMount);
    const b = try application.createWindowWith(.{ .io = io, .window = .{ .width = 420, .height = 280, .chrome = .{ .frameless = .{} } } }, smokeMount);
    const a_id = a.windowId();
    const b_id = b.windowId();
    if ((try a.cx.windowChrome()) == (try b.cx.windowChrome())) return error.SharedChromeSignal;
    if (a.chromeState().controls_owner != .application or b.chromeState().controls_owner != .none) return error.SharedChromePolicy;
    _ = try application.tick();
    try a.requestClose();
    _ = try application.tick();
    if (smoke_close_calls != 1 or application.windowCount() != 2 or application.window(a_id) == null) return error.CloseVetoFailed;
    try b.requestClose();
    _ = try application.tick();
    if (application.windowCount() != 1 or application.window(a_id) == null or application.window(b_id) != null) return error.CloseIsolationFailed;
    if (!application.closeWindow(a_id)) return error.SurvivorCleanupFailed;
    if (application.windowCount() != 0 or app.MultiWindowApp.nativeWindowCount() != 0) return error.NativeWindowLeak;
    std.log.info("chrome multi-window: independent state, reentrant veto, accepted close, survivor and native cleanup passed", .{});
}
pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var config: @typeInfo(@TypeOf(app.App.init)).@"fn".param_types[1].? = .{ .io = init.io, .window = .{ .width = 900, .height = 600, .title = "Zenit Window Chrome", .chrome = .{ .custom = .{} } }, .on_close_request = closeRequest };
    var strict = false;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--multi-smoke")) return multiSmoke(gpa.allocator(), init.io);
        if (std.mem.eql(u8, arg, "--native")) config.window.chrome = .native else if (std.mem.eql(u8, arg, "--application-controls")) config.window.chrome = .{ .custom = .{ .controls = .application } } else if (std.mem.eql(u8, arg, "--frameless")) config.window.chrome = .{ .frameless = .{} } else if (std.mem.eql(u8, arg, "--strict")) strict = true else if (std.mem.eql(u8, arg, "--validation")) {
            if (comptime app.build_environment.os == .linux) config.require_gpu_validation = true;
        } else return error.InvalidArgument;
    }
    if (strict) switch (config.window.chrome.?) {
        .custom => |*c| c.unsupported = .fail,
        .frameless => |*c| c.unsupported = .fail,
        .native => {},
    };
    const window = try app.App.init(gpa.allocator(), config);
    defer window.deinit();
    if (comptime app.test_harness.enabled) {
        test_window = window;
        app.setTestRouteHandler(testRoute);
    }
    defer test_window = null;
    try window.runWith(mount);
}

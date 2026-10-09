/// hello_button: minimal runnable zenit demo
///
/// One native macOS window + Button + counter text. Click increments, text updates
/// reactively; after a click the counter panel switches to the highlight variant.
///
/// UI in view.yix (Yix -> ui.view, compile-time):
///   - `var count: u32 = signal(0)`: component state; template writes `{count}`, not
///     `.get()`
///   - `onClick={count += 1}`: events write the signal inline, no Bindings struct
///   - styles from styles.zig `ui.css` + `ui.cva` (variants receive computed source)
/// This file only starts: `App.runWith(mountUI)` starts the main loop.
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const HelloButton = @import("_view.yix.zig").HelloButton;

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return ui.view.render(scope, cx, HelloButton(.{}));
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const app = try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .width = 640, .height = 480, .title = "Hello Button" },
    });
    defer app.deinit();

    try app.runWith(mountUI);
}

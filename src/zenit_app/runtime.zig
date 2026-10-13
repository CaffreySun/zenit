const chrome_backend = @import("chrome_backend.zig");
const chrome_controller = @import("chrome_controller.zig");
/// runtime, zenit app runtime (app helper)
///
/// Replaces ~110 lines of startup + main loop boilerplate with one line:
///
/// ```
/// pub fn main() !void {
///     var gpa = std.heap.DebugAllocator(.{}){};
///     defer _ = gpa.deinit();
///
///     var app = try App.init(gpa.allocator(), .{
///         .window = .{ .width = 800, .height = 600, .title = "My App" },
///     });
///     defer app.deinit();
///
///     try mountUI(app.cx);
///
///     try app.run();
/// }
/// ```
///
/// covers:
///   - platform init (NSApplication delegate / main menu)
///   - window creation
///   - GPU instance / device / queue / surface
///   - AppRenderer + FontManager + default font load
///   - SystemSdk
///   - UI Cx init + viewport setup + measure_fn wiring
///   - main loop (event pump + type conversion + dispatch + resize detect + frame)
///
/// does not cover (application layer, user writes):
///   - mountUI() building the UI tree
///   - devtools, hot reload, advanced IME paths, devtools deferred dispatch
///   - complex font config (Inter/Lora/JetBrains multi-family + multi-weight)
///
/// Multi-window apps use MultiWindowApp below; it keeps independent App/GPU/UI state per native
/// window plus unified event routing, close and exit handling. For a fully custom event loop,
/// App fields are still pub; processEvents / maybeReconfigureSurface / frame can be called
/// independently.
extern fn zenit_text_input_preedit_applied(window_id: u32, start_utf16: u64, end_utf16: u64, start_utf8: u32, end_utf8: u32) callconv(.c) c_int;
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const ui = @import("ui");
const platform = @import("platform");
const system_sdk = @import("system_sdk");
const gpu = @import("gpu");
const render = @import("render");

// macOS NSAccessibility push-side C ABI (window_bridge.m provides). Only App links it;
// runtime.App.init calls ui.a11y.macos_bridge.setPushHooks registered to macos_bridge.zig
// so tests don't require ObjC link.
extern fn zenit_a11y_push_children_changed(window_id: u32, element_raw: u64) callconv(.c) c_int;
extern fn zenit_a11y_push_property_changed(window_id: u32, element_raw: u64, flags: u16) callconv(.c) c_int;
extern fn zenit_a11y_push_focus_changed(window_id: u32, element_raw: u64) callconv(.c) c_int;
extern fn zenit_a11y_push_announce(window_id: u32, text_ptr: [*]const u8, text_len: c_int, priority: u8) callconv(.c) c_int;
extern fn zenit_a11y_push_active_descendant(window_id: u32, container_raw: u64, active_raw: u64) callconv(.c) c_int;
extern fn zenit_a11y_push_window_cleared(window_id: u32) callconv(.c) c_int;
extern fn zenit_a11y_push_element_destroyed(window_id: u32, element_raw: u64) callconv(.c) c_int;
extern fn zenit_a11y_push_flush_end(window_id: u32) callconv(.c) c_int;
extern fn zenit_a11y_display_options() callconv(.c) u32;
extern fn zenit_a11y_observe_display_options() callconv(.c) void;

const renderer_mod = @import("renderer.zig");
const window_lifecycle = @import("window_lifecycle.zig");
const text_hook_owners = @import("text_hook_owners.zig");
const selector_scale = @import("selector_scale.zig");
const render_pacing = @import("render_pacing.zig");

/// One autorelease pool per main loop iteration.
///
/// The main loop (pump + layout + encode + CoreText shaping + present) runs outside the AppKit
/// run loop with no outer pool, so ObjC-side autoreleased temporaries (NSAttributeDictionary /
/// NSNumber / MTLBuffer / CAMetalLayer refs...) would never be released. With
/// OBJC_DEBUG_MISSING_POOLS=YES, an 8s text_input run reports 735 "just leaking", an 8s
/// storybook run ~98k (mostly AGXG16XFamilyBuffer).
/// libobjc push/pop is the @autoreleasepool implementation; nesting overhead is negligible.
const AutoreleasePool = struct {
    token: ?*anyopaque,

    extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
    extern "c" fn objc_autoreleasePoolPop(token: ?*anyopaque) void;

    fn push() AutoreleasePool {
        if (comptime builtin.os.tag != .macos) return .{ .token = null };
        return .{ .token = objc_autoreleasePoolPush() };
    }

    fn pop(self: AutoreleasePool) void {
        if (comptime builtin.os.tag != .macos) return;
        objc_autoreleasePoolPop(self.token);
    }
};
const AppRenderer = renderer_mod.AppRenderer;
const ClearColor = renderer_mod.ClearColor;

const test_harness = @import("test_harness");

const pointer_isolation = @import("pointer_isolation.zig");
/// ZENIT_E2E_ISOLATE_POINTER=1: in test-mode, ignore system mouse; accept only harness injection.
fn isolateOsPointer() bool {
    return pointer_isolation.enabled(false);
}

// E2E test harness global cx reference (single-window app; multi-window needs extension).
var g_test_cx: ?*ui.Cx = null;
fn getTestCx() ?*ui.Cx {
    return g_test_cx;
}

// E2E test harness screenshot, global App reference (single-window). Callback only registers
// request; actual pixel read happens in renderer.frame() before present.
var g_screenshot_app: ?*App = null;
fn getFrameStats() test_harness.FrameStatsSnapshot {
    const app = g_screenshot_app orelse return .{};
    var stats: test_harness.FrameStatsSnapshot = .{
        .renderer_backend = @tagName(gpu.backend_kind),
        .gpu_validation_errors = if (comptime (gpu.backend_kind == .vulkan or gpu.backend_kind == .opengl)) (if (app.device.context) |context| context.device.validationErrors() else null) else null,
        .gpu_software = if (comptime (gpu.backend_kind == .vulkan or gpu.backend_kind == .opengl)) app.device.isSoftware() else null,
        .retained_hits = @intCast(app.renderer.total_retained_hits),
        .retained_misses = @intCast(app.renderer.total_retained_misses),
        .retained_partial_repaints = @intCast(app.renderer.total_retained_partial_repaints),
        .offscreen_pool_exhausted = app.renderer.offscreen_pool.exhausted_count,
        .text_uniform_overflow = render.textUniformOverflowTotal(),
        .path_draw_calls = app.renderer.last_frame_stats.path_draw_calls,
        .frame_count = app.renderer.frame_count,
        .backdrop_luminance = app.renderer.backdrop_luminance orelse -1,
        .paint_duplicate_fills = app.cx.paint_duplicate_fills,
        .paint_duplicate_node = app.cx.paint_duplicate_node,

        // Single-frame timing (noisy, log only).
        .gpu_execute_us = app.renderer.last_frame_stats.gpu_execute_us,
        .cpu_frame_us = app.renderer.last_frame_stats.cpu_frame_us,
        .layout_us = app.renderer.last_frame_stats.layout_us,
        .render_gen_us = app.renderer.last_frame_stats.render_gen_us,
        .gpu_encode_us = app.renderer.last_frame_stats.gpu_encode_us,
        .wait_for_frame_us = app.renderer.last_frame_stats.wait_for_frame_us,
        .acquire_texture_us = app.renderer.last_frame_stats.acquire_texture_us,
        .encode_us = app.renderer.last_frame_stats.encode_us,
        .flush_us = app.renderer.last_frame_stats.flush_us,
        .glass_count = app.renderer.last_frame_stats.glass_count,
        .glass_us = app.renderer.last_frame_stats.glass_us,
        .texture_creates = app.renderer.last_frame_stats.texture_creates,
        .render_passes = app.renderer.last_frame_stats.render_passes,
        .blit_passes = app.renderer.last_frame_stats.blit_passes,
        .pass_native_us = app.renderer.last_frame_stats.pass_native_us,
        .total_frame_us = app.renderer.last_frame_stats.total_frame_us,

        // Cross-frame P95 (for gate assertions).
        .gpu_p95_us = app.renderer.timing_ring.gpuPercentile(95),
        .cpu_p95_us = app.renderer.timing_ring.cpuPercentile(95),
        .total_p95_us = app.renderer.timing_ring.totalPercentile(95),
        .timing_samples = @intCast(app.renderer.timing_ring.len),
    };
    if (comptime builtin.os.tag == .linux) {
        stats.clipboard_write_ready = app.win.clipboardWriteReady();
        if (app.win.nativeSurface()) |surface| {
            stats.window_logical_width = surface.logical_width;
            stats.window_logical_height = surface.logical_height;
            stats.window_pixel_width = surface.pixel_width;
            stats.window_pixel_height = surface.pixel_height;
        } else |_| {}
    }
    return stats;
}

/// Clear cross-frame timing ring. E2E perf gates switch to heavy scene, wait settle, then call
/// so subsequent P95 reflects only that scene (no prior story samples).
fn resetTiming() void {
    const app = g_screenshot_app orelse return;
    app.renderer.timing_ring.reset();
    app.renderer.gpu_timing_ring.reset();
}

fn wakeTestHarness() void {
    // The file-RPC producer runs off the main thread. Publishing a native
    // application event wakes AppKit without touching App/UI state there.
    if (builtin.target.os.tag == .macos) platform.Window.postEmptyEvent();
}

fn quitForHarness() bool {
    const app = g_screenshot_app orelse return false;
    app.quit();
    return true;
}
fn windowCommandForHarness(command: test_harness.WindowCommand) ?test_harness.WindowSnapshot {
    if (comptime builtin.os.tag != .linux) return null;
    const app = g_screenshot_app orelse return null;
    switch (command) {
        .status => {},
        .maximize => app.win.setMaximized(true) catch return null,
        .restore => app.win.setMaximized(false) catch return null,
        .minimize => app.win.minimize() catch return null,
        .close => app.win.closeNative() catch return null,
    }
    const flags = app.win.native.windowState();
    const size = app.win.getSize();
    return .{ .decoration_height = app.win.native.decorationHeight(), .decorated = app.win.native.hasDecorations(), .maximized = flags & 2 != 0, .active = flags & 1 != 0, .suspended = flags & 128 != 0, .width = size[0], .height = size[1] };
}
fn resizeWindowForHarness(width: u32, height: u32) bool {
    const app = g_screenshot_app orelse return false;
    app.win.setSize(width, height);
    // Size changes reconfigure surface via maybeReconfigureSurface in later frame; here just
    // trigger.
    // Anchor: after reconfig, usage must retain test-mode CPU readback (surfaceConfigFor single
    // outlet),
    // else resize -> /screenshot all corrupt.
    app.cx.needs_redraw = true;
    return true;
}

/// e2e `/visual-quality`: the same tiers and sticky blur-failure injection as
/// the Windows runtime, so degraded glass is testable on macOS too.
fn visualQualityForHarness(command: test_harness.VisualQualityCommand) ?[]const u8 {
    const app = g_screenshot_app orelse return null;
    switch (command) {
        .status => {},
        .auto => app.setVisualQuality(.auto),
        .full => app.setVisualQuality(.full),
        .frosted => app.setVisualQuality(.frosted),
        .basic => app.setVisualQuality(.basic),
        .fail_blur => {
            app.renderer.persistent_gpu.blur_pipeline_failed = true;
            app.cx.needs_redraw = true;
            if (app.cx.root) |root| root.markRenderDirty();
        },
    }
    return @tagName(app.renderer.visual_quality);
}

fn captureScreenshot(path: []const u8) bool {
    const app = g_screenshot_app orelse return false;
    // Preferred: read retained copy of last truly-presented frame (don't drive new frame). Driving
    // new frame runs pending layout/dirty, screenshot newer than screen. During render layer bug:
    // screen full ghosting, screenshot clean, e2e false-green for three days.
    if (app.renderer.captureRetainedToPng(path)) return true;
    // Fallback (early startup, no retained frame yet): old path, drive one frame then readback.
    if (!app.renderer.requestCapture(path)) return false;
    app.frame() catch return false;
    return app.renderer.last_screenshot_ok;
}

fn mapWindowRecordingState(native: platform.Window.WindowRecordingState) test_harness.RecordingState {
    var state: test_harness.RecordingState = .{
        .ok = native.ok != 0,
        .active = native.active != 0,
        .width = native.width,
        .height = native.height,
        .fps = native.fps,
        .duration_ms = native.duration_ms,
        .file_size = native.file_size,
        .frame_count = native.frame_count,
        .dropped_frames = native.dropped_frames,
    };
    state.setPath(native.pathText());
    state.setError(native.errorText());
    return state;
}

fn startWindowRecording(path: []const u8, fps: u32) test_harness.RecordingState {
    const app = g_screenshot_app orelse {
        var state: test_harness.RecordingState = .{};
        state.setError("no harness application window");
        return state;
    };
    const state = mapWindowRecordingState(app.win.startWindowRecording(path, fps));
    app.renderer.setRecordingActive(state.ok and state.active);
    return state;
}

fn appendWindowRecordingFrame(texture: *const gpu.Backend.Texture) bool {
    const app = g_screenshot_app orelse return false;
    const handle = texture.nativeHandleForRecording() orelse return false;
    return app.win.appendWindowRecordingFrame(handle);
}

fn windowRecordingStatus() test_harness.RecordingState {
    const app = g_screenshot_app orelse {
        var state: test_harness.RecordingState = .{};
        state.setError("no harness application window");
        return state;
    };
    return mapWindowRecordingState(app.win.windowRecordingStatus());
}

fn stopWindowRecording() test_harness.RecordingState {
    const app = g_screenshot_app orelse {
        var state: test_harness.RecordingState = .{};
        state.setError("no harness application window");
        return state;
    };
    app.renderer.setRecordingActive(false);
    return mapWindowRecordingState(app.win.stopWindowRecording());
}

const Window = platform.Window;
const FontManager = render.FontManager;
const FontSelector = render.FontSelector;
const Font = render.Font;

pub const TitlebarStyle = @import("window_config.zig").TitlebarStyle;
pub const WindowConfig = @import("window_config.zig").WindowConfig;

pub const FontConfig = @import("font_config.zig").FontConfig;

pub const FramePacing = enum { poll, display_link };

pub const Config = struct {
    /// Application-owned I/O implementation, valid until all windows are destroyed.
    io: std.Io,
    /// Linux Vulkan acceptance/debug options. Hardware is required by default.
    allow_software_gpu: bool = false,
    require_gpu_validation: bool = false,
    visual_quality: ?@import("render").visual_quality.Quality = null,
    window: WindowConfig = .{},
    /// Return false to cancel. Called for native and application close requests.
    on_close_request: ?*const fn (*App) bool = null,
    font: FontConfig = .{},
    /// Per-window diagnostic console sinks and bounded capture capacity.
    console: ui.console.Config = ui.console.defaultConfig(),
    /// Background color (cleared each frame). Default white.
    clear_color: ClearColor = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
    /// sdk.pump timeout milliseconds. 16 ~= 60Hz idle wake. Only effective with .poll frame pacing.
    pump_timeout_ms: u32 = 16,
    /// Frame pacing source:
    /// - .display_link (default): CVDisplayLink wakes per vsync, pump uses a long timeout (pure
    ///   event
    ///   block); idle stops the link -> CPU silent. ProMotion auto 120Hz.
    /// - .poll: legacy, periodic pump(pump_timeout_ms). Rollback switch.
    /// Env ZENIT_FRAME_PACING=poll|display_link overrides (App.init reads).
    frame_pacing: FramePacing = .display_link,
    /// display-link mode pump fallback timeout ms (prevent deadline tasks starving on pure event
    /// block);
    /// actual timeout = min(this, remaining until next wake deadline).
    idle_wait_ms: u32 = 500,
    /// Idle skip entire GPU submit (tree clean + no animations + no deferred work).
    /// Escape: suspect missing redraw, set false for regression test.
    idle_skip_frames: bool = true,
};

/// App, one-stop app runtime.
///
/// Fields are pub so power users can bypass run() and write a custom main loop:
///   var app = try App.init(...);
///   defer app.deinit();
///   while (custom condition) {
///     _ = try app.sdk.pump(16);
///     app.processEvents();              // dispatch sdk events to cx
///     try app.maybeReconfigureSurface(); // resize detect
///     try app.frame();                   // render one frame
///   }
pub const App = struct {
    allocator: Allocator,
    config: Config,

    win: Window,
    instance: gpu.Backend.Instance,
    device: gpu.Backend.Device,
    queue: gpu.Backend.Queue,
    surface: gpu.Backend.Surface,
    renderer: *AppRenderer,
    font_manager: FontManager,
    /// Font family registry from host (optional). App borrows pointer, notify on scale change;
    /// see setFontRegistry.
    font_registry: ?*render.FontRegistry = null,
    fonts: [3]*Font, // small / medium / large
    /// Actual font family resolved from base font (reused when loading by weight).
    resolved_font_family: ?[]const u8 = null,
    font_selector: FontSelector,
    sdk: system_sdk.api.SystemSdk,
    cx: *ui.Cx,

    // Main loop state.
    current_drawable_w: u32,
    current_drawable_h: u32,
    viewport_w: f32,
    viewport_h: f32,
    scale: f32,
    chrome: chrome_controller.Controller,
    should_quit: bool = false,
    /// display-link pacing state (when frame_pacing == .display_link).
    display_link_running: bool = false,
    display_tick_gate: render_pacing.DisplayTickGate = .{},
    resize_frame_pending: bool = false,
    /// Consecutive idle (want=false) count; stop link when threshold hit (dampen clean/dirty
    /// jitter).
    idle_streak: u8 = 0,
    /// live-resize sync render guard (setFrameSize callback may nest).
    in_live_resize_render: bool = false,
    /// ZENIT_DEBUG_JANK: time of last consecutive render frame (multi-window loop, see jankProbe).
    debug_jank_prev: ?@import("zenit_time").Instant = null,

    fn titlebarHitTestCb(ctx: ?*anyopaque, x: f32, y: f32) callconv(.c) c_int {
        const app: *App = @ptrCast(@alignCast(ctx orelse return 0));
        return if (app.cx.legacyWindowControlAt(x, y)) 1 else 0;
    }

    pub const chromeState = chrome_controller.chromeState;
    pub const windowCapabilities = chrome_controller.windowCapabilities;
    pub const requestClose = chrome_controller.requestClose;
    pub const minimize = chrome_controller.minimize;
    pub const setMaximized = chrome_controller.setMaximized;
    pub const toggleMaximize = chrome_controller.toggleMaximize;
    pub const setFullscreen = chrome_controller.setFullscreen;
    pub const performWindowAction = chrome_controller.performWindowAction;

    fn chromeAction(context: *anyopaque, action: chrome_backend.chrome.Action) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        try self.performWindowAction(action);
    }
    fn chromeHit(context: ?*anyopaque, x: f32, y: f32) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(context orelse return 1));
        return @intCast(@backingInt(self.cx.windowRegionAt(x, y)));
    }

    pub fn init(allocator: Allocator, config: Config) !*App {
        // Window / Metal device / font assembly similarly outside any run loop pool.
        const pool = AutoreleasePool.push();
        defer pool.pop();
        // App heap-allocated; else cx.measure_fn stub can't get stable pointer.
        var app = try allocator.create(App);
        errdefer allocator.destroy(app);

        app.allocator = allocator;
        app.config = config;
        // allocator.create does not apply field defaults. A scale transition
        // may consult this borrowed registry before a host installs one.
        app.font_registry = null;
        // Win32 has no display-link callback yet; use the timed message pump.
        if (builtin.os.tag == .windows) app.config.frame_pacing = .poll;
        app.should_quit = false;
        app.display_link_running = false;
        app.display_tick_gate = .{};
        app.resize_frame_pending = false;
        app.idle_streak = 0;
        app.in_live_resize_render = false;
        app.debug_jank_prev = null;

        // Rollback: ZENIT_FRAME_PACING=poll forces legacy polling pacing, one-line env rollback.
        const pacing_env = @import("zenit_environment").getOwned(allocator, "ZENIT_FRAME_PACING") catch null;
        defer if (pacing_env) |value| allocator.free(value);
        if (pacing_env) |val| {
            if (std.mem.eql(u8, val, "poll")) {
                app.config.frame_pacing = .poll;
            } else if (builtin.os.tag == .macos and std.mem.eql(u8, val, "display_link")) {
                app.config.frame_pacing = .display_link;
            } else {
                std.log.scoped(.zenit_runtime).warn("ZENIT_FRAME_PACING={s} 无效（poll|display_link），忽略", .{val});
            }
        }

        // Register macOS NSAccessibility push-side hooks (window_bridge.m zenit_a11y_push_*) to
        // ui.a11y.macos_bridge; cx.render() end flushToBridge pushes dirty events via these fn ptrs
        // to NSAccessibilityPostNotification.
        if (builtin.os.tag == .macos) {
            ui.a11y.macos_bridge.setPushHooks(.{
                .property_changed = zenit_a11y_push_property_changed,
                .focus_changed = zenit_a11y_push_focus_changed,
                .children_changed = zenit_a11y_push_children_changed,
                .announce = zenit_a11y_push_announce,
                .active_descendant_changed = zenit_a11y_push_active_descendant,
                .window_cleared = zenit_a11y_push_window_cleared,
                .element_destroyed = zenit_a11y_push_element_destroyed,
                .flush_end = zenit_a11y_push_flush_end,
            });
            ui.a11y.macos_bridge.setTextInputAppliedHook(zenit_text_input_preedit_applied);
        }

        // System accessibility preference: inject reader fn, read once, listen for changes.
        if (comptime builtin.os.tag == .macos) {
            ui.a11y.preferences.system_reader = zenit_a11y_display_options;
            _ = ui.a11y.preferences.refresh();
            zenit_a11y_observe_display_options();
        }

        // Platform init.
        Window.initAppWithDelegate();
        app.win = try Window.init(config.window.width, config.window.height, config.window.title);
        errdefer app.win.deinit();

        app.chrome = .{ .initial = try chrome_backend.configure(&app.win, @import("window_config.zig").requestedChrome(config.window), config.window.titlebar_height) };
        if (config.window.chrome) |requested| if (requested == .native) try chrome_backend.useSystemTitlebar(&app.win);
        try chrome_backend.configureHeader(&app.win, app.chrome.initial, config.window.fullscreen_header, config.window.titlebar_height);
        try chrome_backend.setMinimumSize(&app.win, config.window.min_width, config.window.min_height);
        if (config.window.chrome == null and app.chrome.initial.effective_mode == .custom and config.window.titlebar == .custom_inset) {
            // Traffic light centered vertically on custom title bar; x default system origin 7.
            app.win.setTrafficLightsInset(7, config.window.titlebar_height / 2.0);
            app.win.setTitlebarDragHeight(config.window.titlebar_height);
            if (config.window.titlebar_drag_right_inset > 0) {
                app.win.setTitlebarDragRightInset(config.window.titlebar_drag_right_inset);
            }
        }

        // GPU
        app.instance = if (comptime (gpu.backend_kind == .vulkan or gpu.backend_kind == .opengl)) blk: {
            const native_surface = try app.win.nativeSurface();
            break :blk try gpu.Backend.Instance.initWithOptions(allocator, .{}, .{
                .allow_software = config.allow_software_gpu,
                .require_validation = config.require_gpu_validation,
                .wayland_display = native_surface.display,
                .wayland_surface = native_surface.surface,
            });
        } else try gpu.Backend.Instance.init(allocator, .{});
        errdefer app.instance.deinit();
        const adapters = try app.instance.enumerateAdapters();
        defer {
            for (adapters) |*adapter| adapter.deinit();
            allocator.free(adapters);
        }
        if (adapters.len == 0) return error.NoGPU;
        const device_and_queue = try adapters[0].requestDevice(allocator, .{});
        app.device = device_and_queue.device;
        app.queue = device_and_queue.queue;
        errdefer app.device.deinit();
        errdefer app.queue.deinit();

        // Surface. Handles passed to backend as *anyopaque, App runtime doesn't know CAMetalLayer
        // and shouldn't (see Surface.init comment).
        app.surface = gpu.Backend.Surface.init(app.win.getNativeSurfaceHandle());
        errdefer app.surface.deinit();
        const drawable = app.win.getDrawableSize();
        app.current_drawable_w = drawable[0];
        app.current_drawable_h = drawable[1];
        try app.surface.configure(allocator, &app.device, surfaceConfigFor(drawable[0], drawable[1]));

        // AppRenderer
        app.renderer = try allocator.create(AppRenderer);
        errdefer allocator.destroy(app.renderer);
        app.renderer.* = try AppRenderer.init(allocator, config.io, &app.device, &app.queue, &app.surface, .{
            .clear_color = config.clear_color,
            .visual_quality = config.visual_quality orelse .auto,
        });
        errdefer app.renderer.deinit();

        // Font
        app.font_manager = try FontManager.init(allocator, config.io);
        errdefer app.font_manager.deinit();
        app.scale = app.win.getScaleFactor();

        const sizes = [_]u32{ config.font.small_size, config.font.medium_size, config.font.large_size };
        var loaded_count: usize = 0;
        errdefer for (app.fonts[0..loaded_count]) |f| f.deinit();
        var resolved_family: ?[]const u8 = null;
        for (sizes, 0..) |sz, i| {
            const r = try findFontWithFallback(&app.font_manager, sz, config.font.fallback_families);
            r.font.setScaleFactor(app.scale);
            app.fonts[i] = r.font;
            if (resolved_family == null) resolved_family = r.family;
            loaded_count += 1;
        }
        // "system" family converges to rendering family (GlyphRun pipeline shapeText/visualLine and
        // FontSelector render must use same base font, else Latin kerning and emoji 🈶 fallback
        // parsing diverge: measurement != rendering).
        app.font_manager.setDefaultFamily(resolved_family);

        app.font_selector = .{
            .small = app.fonts[0],
            .medium = app.fonts[1],
            .large = app.fonts[2],
        };
        // Load by weight: same family, target weight (600/700...). Else all bold silently reverts
        // regular.
        app.resolved_font_family = resolved_family;
        app.font_selector.weight_loader = .{ .context = @ptrCast(app), .load = loadWeightedFont };
        if (comptime builtin.os.tag == .macos) app.font_selector.system_ui_loader = .{ .context = @ptrCast(app), .load = loadSystemUiFont };
        app.renderer.setFonts(&app.font_selector);
        app.renderer.initFontDerivedCache(allocator);

        // Real system window id for this window (macOS = NSWindow.windowNumber). Must not be a
        // constant: two Apps would route a11y/system API to the same id and clobber each other.
        // 0 means the layer has no window yet; fall back to a monotonic per-process synthetic id,
        // not
        // a shared constant (two Apps at 0 would register the same key, silently clobbering again).
        // Synthetic ids start high to avoid collision with real windowNumbers.
        const window_id: system_sdk.events.WindowId = blk: {
            const raw = app.win.getWindowId();
            if (raw != 0) break :blk raw;
            const S = struct {
                var next_synthetic: u32 = 0x7F00_0000;
            };
            S.next_synthetic += 1;
            std.log.warn("[App] window id unavailable, using synthetic {d}", .{S.next_synthetic});
            break :blk S.next_synthetic;
        };

        // SystemSdk
        app.sdk = try system_sdk.backends.initSystemSdk(allocator, &app.win, window_id);
        errdefer app.sdk.deinit();

        // UI Cx
        app.cx = try ui.Cx.init(allocator, config.io);
        app.cx.console().configure(app.config.console);
        errdefer app.cx.deinit();
        // Render reads background luminance per glass (except basic fidelity): declare before any
        // UI
        // mount (startup-mounted glass must also run first-frame detection).
        app.cx.backdrop_luminance_readback = app.renderer.visual_quality != .basic;
        app.cx.setWindowId(window_id);
        app.cx.setSystemSdk(&app.sdk);
        const win_size = app.win.getSize();
        app.viewport_w = @floatFromInt(win_size[0]);
        app.viewport_h = @floatFromInt(win_size[1]);
        app.cx.setWindowMetrics(app.viewport_w, app.viewport_h, app.scale);

        // Drag-region hit (downstream app): custom_inset title bar mouseDown true hit-test first;
        // if on interactive control, dispatch normal event, else empty space drags window.
        // Rect model (drag_right_inset) still applies as coarse pre-filter.
        const chrome_signal = try app.cx.windowChrome();
        chrome_signal.set(app.chromeState());
        app.cx.window_service = .{ .context = app, .perform = chromeAction };
        if (config.window.chrome != null and app.chrome.initial.effective_mode != .native) {
            chrome_backend.setHitCallback(&app.win, chromeHit, app);
        } else if ((builtin.os.tag == .macos or builtin.os.tag == .windows) and config.window.titlebar == .custom_inset) {
            app.win.setTitlebarHitCallback(titlebarHitTestCb, app);
        }

        errdefer {
            chrome_backend.setHitCallback(&app.win, null, null);
            if (comptime builtin.os.tag == .macos or builtin.os.tag == .windows) app.win.setTitlebarHitCallback(null, null);
        }

        // Connect to measure_fn. Prefer version with context: it passes this App's own FontSelector
        // as context, each concurrent App measures its own fonts. Fallback pointer-global
        // no-context
        // remains for compat but no longer primary path; it was one of two non-World globals in
        // multi-window.
        app.cx.text.measure_ctx_fn = measureTextWithCtx;
        app.cx.text.measure_ctx = @ptrCast(&app.font_selector);
        app.cx.text.measure_fn = measureText;

        // GlyphRun pipeline takes over old measure path, injecting FontManager to cx so
        // cx.shapeText
        // finds Font + calls TextShaper. setSystemSdk style: one-way inject, cx holds ?*FontSystem
        // weak ref; cx.deinit before font_manager.deinit on App.deinit (lifespan backstop).
        app.cx.text.setFontSystem(&app.font_manager);

        // The runtime owns the complete text pipeline, so its default setup
        // must not leave rich-text layout on the legacy system-font fallback.
        // App and renderer are heap-stable here; the callbacks stay pointed at
        // this App's selector until a newer App takes the top of the owner
        // stack or deinit hands them back to the next live App.
        installProcessTextHooks(try g_text_hook_owners.push(app, &app.font_selector));

        // live resize sync render: AppKit resize tracking loop blocks pump entirely; main loop
        // stops
        // during drag, MetalView.setFrameSize callback is only render chance. Missing it,
        // CoreAnimation
        // stretches old frame ("canvas warps like image").
        app.win.setRenderCallback(liveResizeRender, @ptrCast(app));

        return app;
    }

    /// Replace the runtime's built-in FontSelector (app.font_selector) with the App's own.
    ///
    /// == Why this API exists rather than just renderer.setFonts ==
    /// "How wide is text?" has four outlets in the runtime, all bound to built-in fonts at init():
    ///   1. renderer.fonts: draws glyphs
    ///   2. cx.measure_ctx, measure_ctx_fn context
    ///   3. g_font_selector_for_measure: measure_fn fallback (no context)
    ///   4. GlyphRun pipeline (shapeViaPipeline) self-resolved fonts, used for cursor position,
    ///      selection endpoints, hit test
    ///
    /// The first three use FontSelector; the fourth bypasses it completely. Swapping only the
    /// selector or only the renderer is insufficient: all four must be swapped together.
    ///
    /// The fourth cannot use font_manager.setDefaultFamily("Inter"): that only renames "system" and
    /// queries system-installed fonts. Inter/Lora loaded by the App from repo files are not in the
    /// system library, the query fails and the silent fallback widens text (1.442px -> 3.783px).
    /// Only passing FontSelector itself as the pipeline parser guarantees measurement and rendering
    /// read the same *Font.
    ///
    /// == If the fourth is missing ==
    /// measureTextWidthWithSpans is not pure: measureProportional tries g_shape_measure_fn first
    /// (GlyphRun pipeline, outlet 4); NaN falls back to measure_ctx_fn/measure_fn (outlets 1-3).
    /// Same text and params give different widths depending on whether the hook is wired:
    ///   fs=14 fw=450 "ssdf x<emoji>" (Inter layout, default_family still HelveticaNeue)
    ///     hook wired (GlyphRun/HelveticaNeue) = 57.906   <- computeCursorPos uses
    ///     hook unwired (FontSelector/Inter)  = 59.348   <- layout and draw use
    ///   Diff 1.442px; cursor/selection endpoints fall short of the glyph right edge, growing
    ///   toward
    ///   the line end. Per-char widths differ for Latin letters too (s 7.465->7.266, d
    ///   8.614->8.554,
    ///   f 5.247->4.410...), so it is not emoji-specific; a trailing emoji just exposes it.
    ///
    /// The selector is caller-held and its lifespan must cover the entire App; only a pointer is
    /// borrowed here.
    pub fn setFontSelector(self: *App, selector: *FontSelector) void {
        self.renderer.setFonts(selector);
        self.renderer.initFontDerivedCache(self.allocator);
        // Immediately align current backing scale: scale_changed only triggers on change; selector
        // already on 2x screen rasterizes 1x if never fires.
        selector.setScaleFactor(self.scale);
        self.cx.text.measure_ctx_fn = measureTextWithCtx;
        self.cx.text.measure_ctx = @ptrCast(selector);
        // Outlet 3 + 4: no-context fallback and GlyphRun pipeline font parser (process-global,
        // registered per ownership stack, see text_hook_owners.zig). self already registered at
        // init:
        // update existing owner no-realloc, won't fail.
        installProcessTextHooks(g_text_hook_owners.push(self, selector) catch
            @panic("text hook owner update must not allocate"));
    }

    /// Wire the font family parser (render.FontRegistry).
    ///
    /// Applies to the currently active FontSelector (built-in, or one installed via
    /// setFontSelector). Since resolveFonts is the single measurement/render entry point, wiring
    /// here covers all four outlets.
    ///
    /// The registry is caller-held, its lifespan must cover the entire App; only a pointer is
    /// borrowed.
    pub fn setFontRegistry(self: *App, registry: *render.FontRegistry) void {
        const sel = self.renderer.fonts orelse &self.font_selector;
        sel.family_resolve_fn = &resolveFamilyFont;
        sel.family_resolve_ctx = @ptrCast(registry);
        self.font_registry = registry;
        // Immediately align current scale; if already on 2x screen at load, waiting until next
        // scale change to sync means first screen is blurry.
        registry.setScaleFactor(self.scale);
    }

    pub fn deinit(self: *App) void {
        // Invalidate every native->Zig edge before releasing Cx/render state.
        // A closing window can still be inside live resize, IME composition, or
        // a drag session, so teardown order is part of the public contract.
        chrome_backend.setHitCallback(&self.win, null, null);
        self.cx.window_service = null;
        self.win.setRenderCallback(null, null);
        if (builtin.os.tag == .macos or builtin.os.tag == .windows) self.win.setTitlebarHitCallback(null, null);
        if (self.display_link_running) {
            self.win.stopDisplayLink();
            self.display_link_running = false;
        }
        if (test_harness.enabled and g_screenshot_app == self) {
            self.renderer.setRecordingActive(false);
            const recording = self.win.windowRecordingStatus();
            if (recording.active != 0) _ = self.win.stopWindowRecording();
        }
        if (g_test_cx == self.cx) g_test_cx = null;
        if (g_screenshot_app == self) g_screenshot_app = null;
        // Cx.deinit owns the atomic discard + disable transition. Calling the
        // backend here as well would reintroduce a second IME state writer.
        // These are legacy process-wide hooks. Hand them back to the next live
        // App (or clear them when none is left) before either the Cx or
        // selector can be released: never leave a dangling callback behind,
        // and never strip the hooks from another still-open window (closing
        // DevTools used to break measurement in the main window).
        installProcessTextHooks(g_text_hook_owners.remove(self));
        self.cx.deinit();
        self.sdk.deinit();
        // WARNING: remove the external selector first, then touch font-derived caches.
        //
        // After setFontSelector, renderer.fonts points to the host's own FontSelector, whose
        // lifespan the
        // App does not manage. Typical host pattern:
        //   var app = try App.init(...);   defer app.deinit();
        //   const font_set = try loadFonts(...);  defer font_set.deinit();
        // defer is LIFO, so font_set frees first and App.deinit runs later:
        // deinitFontDerivedCache() then iterates a freed selector (EXC_BAD_ACCESS in
        // runtime.App.deinit).
        //
        // So the App falls back to the built-in selector before tearing down. The external selector
        // is
        // the caller's responsibility; we neither free it nor read it again. Both defer orders are
        // safe;
        // the lifespan contract must not depend on declaration order.
        if (self.renderer.fonts != &self.font_selector) {
            self.renderer.setFonts(&self.font_selector);
        }
        self.renderer.deinitFontDerivedCache();
        // Renderer fallback faces borrow the FontSystem library/context. Release
        // them while the manager and primary fonts still exist.
        self.renderer.deinit();
        self.allocator.destroy(self.renderer);
        for (self.fonts) |f| f.deinit();
        self.font_manager.deinit();
        self.surface.deinit();
        self.queue.deinit();
        self.device.deinit();
        self.instance.deinit();
        self.win.deinit();
        const allocator = self.allocator;
        // g_font_selector_for_measure already fell back via ownership stack to next live App
        // (or null). External selector may be shared by multiple windows; only assert built-in.
        std.debug.assert(g_font_selector_for_measure != &self.font_selector);
        allocator.destroy(self);
    }

    /// Mount fn signature; runWith / mount accept this callback. Scope created and held
    /// by App; returned root node mounts directly.
    pub const MountFn = *const fn (cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node;

    /// Create root_scope, call mount_fn to build the UI tree, attach root to cx.
    /// Replaces the 4-line boilerplate every mountUI() would write.
    /// test-mode: rebinds the file-RPC harness target to this App. mount() registration is
    /// "last one wins"; in a multi-window host (DevTools auxiliary windows also use App.mount)
    /// g_test_cx / g_screenshot_app would point to the auxiliary window and all RPC
    /// keys/screenshots
    /// go to the wrong window. After creating an auxiliary window, the host calls this to take the
    /// main window back. No-op outside test-mode.
    pub fn rebindTestHarness(self: *App) void {
        if (!test_harness.enabled) return;
        g_test_cx = self.cx;
        g_screenshot_app = self;
    }

    pub fn mount(self: *App, mount_fn: MountFn) !void {
        // Build-first / commit-last transaction: any step failure must return the App to the
        // "unmounted"
        // state with no dangling pointers to freed memory. User idiom: defer app.deinit(), and
        // cx.deinit() runs first, re-traversing root_scope / root.
        //
        // The assignment cannot simply move to the end: mount_fn's cx.provide() calls
        // ensureRootScope(); if cx.root_scope is still null it creates and attaches another scope,
        // so
        // provide's context lands on an orphaned scope (consumers cannot see it) and our root_scope
        // has
        // no refs left. So it must be visible during build and rolled back on failure.
        const allocator = self.cx.allocator;
        // The window-root portal must exist before mount_fn runs. Popover / Tooltip build their
        // tree
        // inside mount_fn; if cx.popover_portal_root were filled after mount_fn returns, they would
        // degrade to anchored siblings and never use the portal. The portal is the window-level
        // containing block: absolute floating content below behaves like CSS position:fixed,
        // positioned only in viewport coords, independent of the trigger's ancestors.
        const app_root = try ui.box(self.cx, .{
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
        }, .{});
        var app_root_orphan = true;
        errdefer if (app_root_orphan) app_root.destroy(allocator);

        const portal = try ui.box(self.cx, .{
            .position = .absolute,
            .width = .{ .grow = .{} },
            .height = .{ .grow = .{} },
        }, .{});
        var portal_orphan = true;
        errdefer if (portal_orphan) portal.destroy(allocator);
        portal.meta.ownership.meta.component_name = "WindowOverlayPortal";
        const portal_ext = try portal.style.ensureExtFallible(allocator);
        portal_ext.z_index = ui.Cx.window_portal_z_index;
        portal_ext.hit_behavior = .children_only;
        // WARNING: do not use setHitTestVisible(false); hit-test recurses and cuts the entire
        // subtree
        // at invisible nodes (hit_runtime.buildRecursive: !participates -> return), making every
        // Modal/Sheet in the portal unclickable (x cannot close, mask does not dismiss).
        // The portal is explicitly children-only for pointer and window-chrome
        // queries: its transparent viewport must not block Header drag while children
        // (barrier/dialog) participate normally. Scope is created after both nodes; errdefer
        // disposes
        // the scope first so portaled content cleanup can safely access the portal, then destroys
        // the
        // tree.
        const root_scope = try ui.Scope.init(allocator, null, self.cx.owner);
        var root_scope_owned = true;
        errdefer if (root_scope_owned) {
            if (self.cx.root_scope == root_scope) self.cx.root_scope = null;
            if (self.cx.popover_portal_root == portal) self.cx.popover_portal_root = null;
            if (self.cx.root == app_root) self.cx.root = null;
            root_scope.dispose();
        };

        self.cx.root_scope = root_scope;
        self.cx.root = app_root;
        // Portal temporarily detached tree, but pointer stable during mount; floating nodes
        // attach directly. After tree complete, commit entire portal as last child of app_root,
        // ensuring it draws above user tree.
        self.cx.popover_portal_root = portal;

        // Components may start transitions/animations during mount: first bind this window's
        // clock (multi-window: clock is global).
        self.cx.bindEventClock();
        const user_root = try mount_fn(self.cx, root_scope);

        // Next two appends are last failing steps in transaction. On failure, dispose scope
        // first (removes floating content from detached portal), then destroy orphaned user_root
        // / app_root; don't rely on default errdefer reverse.
        app_root.appendChild(allocator, user_root) catch |err| {
            root_scope.dispose();
            root_scope_owned = false;
            self.cx.root_scope = null;
            self.cx.popover_portal_root = null;
            self.cx.root = null;
            user_root.destroy(allocator);
            return err;
        };
        app_root.appendChild(allocator, portal) catch |err| {
            root_scope.dispose();
            root_scope_owned = false;
            self.cx.root_scope = null;
            self.cx.popover_portal_root = null;
            self.cx.root = null;
            return err;
        };
        portal_orphan = false; // Ownership transferred to app_root.

        // -- COMMIT --
        // All failing steps done. Below: all non-failing field assignments committed at once;
        // app_root ownership goes to cx (cx.deinit destroys entire tree).
        root_scope_owned = false;
        app_root_orphan = false;
        self.cx.is_mounted = true;
        self.cx.content_root = user_root;

        // E2E test harness: register cx reference + screenshot callback + start file RPC
        // server (when test-mode=true).
        if (test_harness.enabled) {
            g_test_cx = self.cx;
            g_screenshot_app = self;
            // Per-frame render invariant check (repeat emission count via /stats for e2e gate).
            self.cx.paint_invariant_check = true;
            // Enable presented frame retained copy so /screenshot reads actual presentation, not
            // new render.
            self.renderer.retain_present_copy = true;
            self.renderer.setRecordingFrameCallback(appendWindowRecordingFrame);
            test_harness.setScreenshotCallback(captureScreenshot);
            test_harness.setRecordingCallbacks(startWindowRecording, windowRecordingStatus, stopWindowRecording);
            test_harness.setFrameStatsCallback(getFrameStats);
            test_harness.setResetTimingCallback(resetTiming);
            test_harness.setWindowCommandCallback(windowCommandForHarness);
            test_harness.setResizeWindowCallback(resizeWindowForHarness);
            test_harness.setQuitCallback(quitForHarness);
            test_harness.setVisualQualityCallback(visualQualityForHarness);
            test_harness.init(self.config.io, getTestCx, wakeTestHarness);
        }
    }

    /// one-stop: mount + run main loop. recommended entry.
    /// ```
    /// try app.runWith(mountUI); // mountUI: fn(*ui.Cx, *ui.Scope) !*ui.Node
    /// ```
    pub fn runWith(self: *App, mount_fn: MountFn) !void {
        try self.mount(mount_fn);
        try self.run();
    }

    pub fn setMenuModel(self: *App, model: system_sdk.MenuModel) !void {
        try self.sdk.setMenuModel(model);
    }

    pub fn bindMenuCommand(self: *App, command_id: u64, action: ui.actions.Action) void {
        self.cx.bindCommandAction(command_id, action);
    }

    pub fn postHeaderPointerForTesting(self: *App, x: f32, y: f32, right: bool) !void {
        if (!@import("build_options").test_mode) return error.TestModeRequired;
        try chrome_backend.postHeaderPointer(&self.win, x, y, right);
    }
    pub fn postHeaderSystemHoverForTesting(self: *App, edge: bool) !void {
        if (!@import("build_options").test_mode) return error.TestModeRequired;
        try chrome_backend.postHeaderSystemHover(&self.win, edge);
    }
    pub fn headerReadyForTesting(self: *App) bool {
        if (!@import("build_options").test_mode) return false;
        return chrome_backend.headerReadyForTesting(&self.win);
    }

    pub fn windowId(self: *const App) system_sdk.events.WindowId {
        return self.cx.window_id;
    }

    /// Programmatically make this window the active/key window. AppKit also
    /// establishes the window's Metal view as first responder for IME/Edit
    /// command routing.
    pub fn activate(self: *App) void {
        self.win.activate();
    }

    /// Run main loop until window closes. Call mount / runWith to set up UI first, or use
    /// older "manually write mountUI then app.run()" flow. Advanced: manual pump +
    /// processEvents + frame, control cadence yourself.
    pub fn run(self: *App) !void {
        // First frame always renders (needs_redraw defaults true as backup, belt-and-suspenders).
        var force_frame = true;
        const display_link_mode = self.config.frame_pacing == .display_link;
        // ZENIT_DEBUG_FRAMEPACE=1: frame pacing stats, one line per 120 consecutive render
        // frames with mean/min/max/stddev dt (ms). Verify vsync lock (60Hz should tight 16.67ms,
        // no 16/33ms beat pattern). Idle gaps (>100ms) excluded.
        const pace_debug = @import("zenit_environment").has("ZENIT_DEBUG_FRAMEPACE");
        // ZENIT_DEBUG_JANK=1: per-frame probe, logs line when consecutive render dt > 20ms
        // (skip >100ms as idle gap). Pinpoint animation stutter.
        const jank_debug = @import("zenit_environment").has("ZENIT_DEBUG_JANK");
        var jank_prev: ?@import("zenit_time").Instant = null;
        var pace_prev: ?@import("zenit_time").Instant = null;
        var pace_dts: [120]f64 = undefined;
        var pace_n: usize = 0;
        while (!self.should_quit) {
            const pool = AutoreleasePool.push();
            defer pool.pop();
            // .poll: timed polling.
            // .display_link: pump uses a long timeout (pure block); the link wakes at each vsync
            // via an empty
            //   event; a stopped (idle) link is woken by input events, with timeout clamped to the
            //   nearest
            //   wake deadline (cursor blink scheduleRedrawAfterNs / deferred tasks), fallback
            //   idle_wait_ms.
            const pump_timeout: u32 = if (display_link_mode)
                self.computeIdleTimeoutMs()
            else
                self.config.pump_timeout_ms;
            const pump_result = self.sdk.pump(pump_timeout) catch |err| {
                std.log.scoped(.zenit_runtime).err("sdk.pump failed: {s}", .{@errorName(err)});
                return err;
            };
            // Render at least one frame after any input event: hover/cursor paths don't guarantee
            // needs_redraw flip.
            if (self.sdk.events().len > 0 or pump_result.requested_redraw) force_frame = true;
            self.processEvents();
            // E2E test harness: consume command queue (when test-mode=true).
            if (test_harness.enabled) {
                if (test_harness.drainCommandsRequestFrame()) force_frame = true;
            }
            if (self.should_quit) break;
            try self.maybeReconfigureSurface();

            // Idle frame gate: skip the entire GPU acquire/encode/present when the tree is clean,
            // no
            // animations are running and no deferred work is pending.
            // needs_redraw is consumed by advanceFrameClock at the frame edge (cleared after the
            // clock
            // read); do not clear it early here, or this wakeup's clock freezes and time-driven
            // overlay
            // entry animations stick at 0.
            _ = self.renderer.pollBackdropLuminance(self.cx);
            if (self.shouldRenderAutomaticFrame(force_frame)) {
                force_frame = false;
                const jank_t0 = if (jank_debug) @import("zenit_time").Instant.now(self.config.io) catch null else null;
                try self.frame();
                if (test_harness.enabled) test_harness.afterFrame();
                if (jank_debug) {
                    if (@import("zenit_time").Instant.now(self.config.io) catch null) |now| {
                        const cpu_ms = if (jank_t0) |t0| @as(f64, @floatFromInt(now.since(t0))) / 1e6 else 0;
                        if (jank_prev) |prev| {
                            const dt_ms = @as(f64, @floatFromInt(now.since(prev))) / 1e6;
                            if (dt_ms > 20.0 and dt_ms < 100.0) {
                                std.debug.print("[jank] dt={d:.1}ms frame_wall={d:.1}ms\n", .{ dt_ms, cpu_ms });
                            }
                        }
                        jank_prev = now;
                    }
                }
                if (pace_debug) {
                    if (@import("zenit_time").Instant.now(self.config.io) catch null) |now| {
                        if (pace_prev) |prev| {
                            const dt_ms = @as(f64, @floatFromInt(now.since(prev))) / 1e6;
                            if (dt_ms < 100.0) {
                                pace_dts[pace_n] = dt_ms;
                                pace_n += 1;
                                if (pace_n == pace_dts.len) {
                                    var sum: f64 = 0;
                                    var min: f64 = pace_dts[0];
                                    var max: f64 = pace_dts[0];
                                    for (pace_dts) |d| {
                                        sum += d;
                                        min = @min(min, d);
                                        max = @max(max, d);
                                    }
                                    const mean = sum / @as(f64, @floatFromInt(pace_dts.len));
                                    var var_sum: f64 = 0;
                                    for (pace_dts) |d| var_sum += (d - mean) * (d - mean);
                                    const stddev = @sqrt(var_sum / @as(f64, @floatFromInt(pace_dts.len)));
                                    std.log.scoped(.zenit_framepace).info(
                                        "{d} frames: mean={d:.2}ms min={d:.2}ms max={d:.2}ms stddev={d:.2}ms",
                                        .{ pace_dts.len, mean, min, max, stddev },
                                    );
                                    pace_n = 0;
                                }
                            }
                        }
                        pace_prev = now;
                    }
                }
            }
        }
        // Stop link on exit main loop (destroy_window also backstops stop+release).
        if (self.display_link_running) {
            self.win.stopDisplayLink();
            self.display_link_running = false;
        }
    }

    /// display-link mode pump timeout: min(idle_wait_ms, distance to nearest wake deadline).
    /// Test harness clamps to 16ms; e2e RPC commands live in files, pure event block
    /// won't wake.
    fn computeIdleTimeoutMs(self: *App) u32 {
        var timeout_ms: u64 = self.config.idle_wait_ms;
        if (test_harness.enabled) timeout_ms = @min(timeout_ms, 16);
        // A just-submitted backdrop measurement may finish after the last UI
        // frame. Poll it promptly without keeping GPU rendering awake.
        if (self.renderer.hasPendingBackdropLuminance()) timeout_ms = @min(timeout_ms, 16);
        if (self.cx.nextWakeDelayNs()) |delay_ns| {
            // Ceil + at least 1ms: premature wake idles one cycle then sleeps; late wake
            // perceptible
            // latency.
            const delay_ms = (delay_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
            timeout_ms = @min(timeout_ms, @max(delay_ms, 1));
        }
        return @intCast(timeout_ms);
    }

    /// Each wake start/stop CVDisplayLink by want. Start immediate (next vsync guaranteed);
    /// stop debounced 2x, animation finish frames often jitter at clean/dirty boundary,
    /// immediate stop causes rapid link churn.
    fn syncDisplayLink(self: *App, want: bool) void {
        if (want) {
            self.idle_streak = 0;
            if (!self.display_link_running) {
                self.win.startDisplayLink();
                self.display_link_running = true;
            }
        } else if (self.display_link_running) {
            self.idle_streak +|= 1;
            if (self.idle_streak >= 2) {
                self.win.stopDisplayLink();
                self.display_link_running = false;
            }
        }
    }

    fn displayRenderTick(self: *const App) ?u64 {
        if (self.config.frame_pacing != .display_link) return null;
        if (comptime @hasDecl(Window, "getDisplayTick")) return self.win.getDisplayTick();
        return null;
    }

    fn displayPresentationSample(self: *const App) ?ui.Cx.PresentationSample {
        if (self.config.frame_pacing != .display_link) return null;
        if (comptime @hasDecl(Window, "getDisplayTiming")) {
            const timing = self.win.getDisplayTiming();
            return .{
                .tick = timing.tick,
                .target_time_ms = if (timing.target_time_seconds > timing.current_time_seconds and timing.current_time_seconds > 0)
                    timing.target_time_seconds * 1000
                else
                    null,
                .period_ms = 1000.0 / @as(f64, @floatCast(@max(1.0, self.cx.display_refresh_hz))),
            };
        }
        return null;
    }

    fn shouldRenderAutomaticFrame(self: *App, forced: bool) bool {
        chrome_controller.syncChrome(self);
        // Read before wantsFrame consumes an expired scheduled-redraw deadline.
        const deadline_due = if (self.cx.nextWakeDelayNs()) |delay| delay == 0 else false;
        const force_frame = forced or self.resize_frame_pending or !self.config.idle_skip_frames;
        const want = force_frame or self.cx.wantsFrame() or self.renderer.recording_active;
        // Denying a duplicate tick must keep an active display link running.
        if (self.config.frame_pacing == .display_link) self.syncDisplayLink(want);
        return self.display_tick_gate.shouldRender(self.displayRenderTick(), .{
            .wants_frame = want,
            .forced = force_frame,
            .deadline_due = deadline_due,
        });
    }

    /// Dispatch sdk event queue to ui.Cx, handle quit / resize signals.
    pub fn processEvents(self: *App) void {
        // Traversing borrowed slice of event_queue: any handler reentrant pump() calls
        // clear() releasing payload mid-traverse. Flag + pump assert pin contract.
        self.sdk.dispatching = true;
        defer self.sdk.dispatching = false;
        for (self.sdk.events()) |evt| _ = self.processEvent(evt);
    }

    /// Dispatch one event if it belongs to this window. This strict boundary
    /// makes `App` safe with a shared/multi-window backend while preserving the
    /// existing single-window `processEvents()` API.
    pub fn processEvent(self: *App, evt: system_sdk.events.Event) bool {
        if (!self.sdk.imeEventCurrent(evt)) return false;
        defer self.cx.refreshTextInputSession();
        if (evt.targetWindowId()) |target| {
            if (target != self.windowId()) return false;
        }
        // e2e input isolation: the harness injects pointer events directly into Cx (bypassing
        // here).
        // Real mouse move/button/wheel/magnify from the machine, if also handled here, would
        // overwrite
        // the injected hover position and break clicks (e.g. zindex floater tests fail flakily
        // while a
        // dev uses the computer). Only dropped when built in test-mode AND explicitly enabled;
        // manual
        // operation of a test-mode app is unaffected.
        if (test_harness.enabled and isolateOsPointer() and pointer_isolation.isOsPointerEvent(evt)) return true;
        // Optional keyboard isolation (ZENIT_E2E_ISOLATE_KEYBOARD=1): same rationale as pointer
        // isolation for machines shared between an e2e run and a live user.
        if (test_harness.enabled and pointer_isolation.keyboardEnabled() and pointer_isolation.isOsKeyboardEvent(evt)) return true;
        switch (evt) {
            .quit => self.should_quit = true,
            .window_close_requested => self.requestClose() catch {},
            .frame_requested, .window_resized, .system_theme_changed => self.cx.needs_redraw = true,
            .window_focused => |e| {
                self.cx.needs_redraw = true;
                // Test-mode app resides in background: unless explicit real activation request (for
                // inactive appearance baseline), always treat as active, else all e2e baselines
                // land on
                // inactive material.
                const appears_active = if (test_harness.enabled and @import("zenit_environment").getBorrowed("ZENIT_E2E_REAL_ACTIVATION") == null) true else e.appears_active;
                if (self.cx.window_active != appears_active) {
                    self.cx.window_active = appears_active;
                    // Inactive window glass material differs (Glass.tint desaturates): re-parse all
                    // GlassBox
                    // hooks.
                    if (self.cx.root) |root| root.markSubtreeBeforeRenderHook();
                }
                // Blur cancels in-flight pointer interactions (drag, etc.): blur from polling edge,
                // frame latency acceptable (docs/DRAG_INTERACTION_DESIGN.md section 11.2).
                if (!e.focused) self.cx.cancelPointerInteractions(.window_blur) else self.cx.replayCursor();
            },
            .mouse_move => |e| self.cx.handleMouseMoveEx(e.x, e.y, sdkModifiersToUi(e.modifiers)),
            .mouse_button => |e| {
                if (e.cancelled) {
                    self.cx.needs_redraw = true;
                    self.cx.cancelPointerInteractions(.pointer_cancel);
                    return true;
                }
                const ui_btn = sdkMouseButtonToUi(e.button) orelse return true;
                const ui_mods = sdkModifiersToUi(e.modifiers);
                if (e.pressed) {
                    self.cx.handleMouseDownEx(e.x, e.y, ui_btn, ui_mods);
                } else {
                    self.cx.handleMouseUpEx(e.x, e.y, ui_btn, ui_mods);
                }
            },
            .mouse_wheel => |e| self.cx.handleSdkWheel(e),
            .magnify => |e| self.cx.handleMagnify(e.magnification, e.x, e.y, @fromBackingInt(@intCast(e.phase))),
            .drag => |e| {
                // kind=4 = drag source completion receipt (cx.handleDrag defensive ignore). Debug
                // visibility: ZENIT_DEBUG_DRAG=1 logs actual operation (0=cancelled 1=copy 2=move
                // 4=link).
                if (e.kind == 4 and @import("zenit_environment").has("ZENIT_DEBUG_DRAG")) {
                    std.debug.print("[DRAG] source-completed token={d} op={d}\n", .{ e.source_token, e.operation });
                }
                self.cx.handlePlatformDrag(e.x, e.y, e.kind, e.paths, e.payload_kind, e.payload_truncated, e.payload_is_untrusted);
            },
            .menu_command => |e| {
                if (@import("zenit_environment").has("ZENIT_DEBUG_MENU")) {
                    std.debug.print("[MENU] command_id={d} window_id={d} (self={d})\n", .{ e.command_id, e.window_id, self.windowId() });
                }
                self.cx.handleCommand(e.command_id);
            },
            .key => |e| {
                const key = if (builtin.target.os.tag == .windows)
                    ui.events.KeyCode.fromWindowsVirtualKey(e.keycode)
                else if (builtin.target.os.tag == .linux)
                    ui.events.KeyCode.fromLinuxEvdev(e.keycode)
                else
                    ui.events.KeyCode.fromRawKeycode(e.keycode);
                const ui_mods = sdkModifiersToUi(e.modifiers);
                if (e.pressed) self.cx.handleKeyDown(key, ui_mods) else self.cx.handleKeyUp(key, ui_mods);
            },
            .text_input => |e| self.cx.handleTextInput(e.text),
            .ime_preedit => |e| self.cx.handleImePreeditEvent(.{ .text = e.text, .cursor_utf8_offset = e.cursor_utf8_offset, .cursor_visible = e.cursor_visible, .selection_end_utf8 = e.selection_end_utf8, .replace_start_utf8 = e.replace_start_utf8, .replace_end_utf8 = e.replace_end_utf8 }),
            .ime_commit => |e| self.cx.handleImeCommitReplace(e.text, e.replace_start_utf8, e.replace_end_utf8),
            .ime_delete_surrounding => |e| self.cx.handleImeDeleteSurrounding(e.before_bytes, e.after_bytes),
        }
        return true;
    }

    /// Single surface config outlet: init and resize reconfig must produce identical config.
    /// The drawable must be readable (framebufferOnly=false): glass blits the current target each
    /// frame to sample the backplate, and native blur groups also sample it directly; a
    /// framebufferOnly drawable is illegal for both (Metal validation: "sourceTexture must not be
    /// framebufferOnly texture", missing ShaderRead), and only happens to work with validation
    /// disabled. test-mode e2e screenshots also need CPU readback. Matches Windows render.
    fn surfaceConfigFor(width: u32, height: u32) gpu.Backend.SurfaceConfiguration {
        return .{
            // Not _sRGB: blend in sRGB-encoded values (matches AppKit, docs/SRGB_BLENDING_PLAN.md);
            // layer colorspace set explicitly to sRGB in window_bridge.
            .format = .bgra8_unorm,
            .width = width,
            .height = height,
            .usage = .color_target_and_read,
            .present_mode = .fifo,
            .alpha_mode = .fully_opaque,
            .maximum_frame_latency = 2,
        };
    }

    /// Detect window size change, reconfigure surface and viewport as needed.
    pub fn maybeReconfigureSurface(self: *App) !void {
        const new_drawable = self.win.getDrawableSize();
        if (new_drawable[0] != self.current_drawable_w or new_drawable[1] != self.current_drawable_h) {
            self.current_drawable_w = new_drawable[0];
            self.current_drawable_h = new_drawable[1];
            try self.surface.configure(self.allocator, &self.device, surfaceConfigFor(self.current_drawable_w, self.current_drawable_h));
            // Drawable size/DPI change must redraw, else pure DPI switch only reconfigs surface,
            // screen corrupts.
            self.cx.needs_redraw = true;
            self.resize_frame_pending = true;
        }
        // HiDPI: a backing scale change (window dragged to a different DPI screen, or system
        // resolution
        // change) must flow through the whole chain: fonts rasterize at the new scale and
        // cx.window_scale (SVG raster size) must follow it.
        //
        // Per-frame polling rather than a windowDidChangeBackingProperties observer: this function
        // already runs every frame and already handles the drawable size change from the same
        // event;
        // polling one CGFloat is negligible, whereas an observer adds cross-ObjC->Zig event queue
        // coupling and a separate timing path (observer first, drawable later) that is harder to
        // keep
        // in sync within a frame. system_sdk polls getScaleFactor anyway.
        const new_scale = self.win.getScaleFactor();
        const scale_changed = new_scale > 0 and new_scale != self.scale;
        if (scale_changed) {
            self.scale = new_scale;
            // Fonts must rasterize at the new scale. Font.scale_factor is mutable in place, the
            // pointer is
            // unchanged; glyph atlas GlyphKey contains scale_q, so a new scale naturally creates
            // new cache
            // entries and old entries are recycled by page age-based GC (EVICT_THRESHOLD); no
            // manual atlas
            // clear needed.
            //
            // Use font_selector, not just self.fonts: the latter only has small/medium/large base
            // fonts,
            // while non-standard sizes use FontSelector extension slots and lazily derived fonts;
            // missing
            // them gives "some sizes sharpened, others still blurry". The host's selector installed
            // via
            // setFontSelector (renderer.fonts) is what actually draws/measures and must be updated
            // too;
            // updating only the built-in one leaves host fonts at the old scale.
            selector_scale.syncSelectorScale(&self.font_selector, self.renderer.fonts, new_scale);
            // Font registry faces independently created, not in font_selector slot chain; must
            // scale separately, else custom fonts on canvas stay blurry after screen change.
            if (self.font_registry) |reg| reg.setScaleFactor(new_scale);
        }

        // Sync refresh rate to Cx: DevTools Performance panel target line / bar height baseline,
        // renderer frame interval clamping both read cx.display_refresh_hz. Like scale, per-
        // frame poll; dragging window between ProMotion<->60Hz mixed must keep up; CGFloat
        // read cost negligible.
        const refresh_hz = self.win.getDisplayRefreshRate();
        if (refresh_hz > 0 and refresh_hz != self.cx.display_refresh_hz) {
            self.cx.display_refresh_hz = refresh_hz;
        }

        const new_size = self.win.getSize();
        const new_w: f32 = @floatFromInt(new_size[0]);
        const new_h: f32 = @floatFromInt(new_size[1]);
        if (new_w != self.viewport_w or new_h != self.viewport_h or scale_changed) {
            self.viewport_w = new_w;
            self.viewport_h = new_h;
            // Note: use setWindowMetrics not setViewport: latter hardcodes scale to 1.0; on Retina
            // every resize resets cx.window_scale to 1.0, SVG rasterizes at 1x
            // (resolveSvgRasterSize
            // reads it).
            self.cx.setWindowMetrics(self.viewport_w, self.viewport_h, self.scale);
            self.cx.needs_redraw = true;
            self.resize_frame_pending = true;
        }
    }

    /// Render one frame.
    pub fn frame(self: *App) !void {
        chrome_controller.syncChrome(self);
        defer self.cx.publishWindowRegions();
        // Host writing custom main loop (pump + frame, control cadence) also needs pool;
        // outside run()/tick() is already one, nesting another harmless.
        const pool = AutoreleasePool.push();
        defer pool.pop();
        const presentation_sample = self.displayPresentationSample();
        const render_tick = if (presentation_sample) |sample| sample.tick else self.displayRenderTick();
        const frame_count_before = self.renderer.frame_count;
        try self.renderer.frameWithPresentation(self.cx, self.viewport_w, self.viewport_h, self.scale, presentation_sample);
        if (self.renderer.frame_count != frame_count_before) {
            self.display_tick_gate.didRender(render_tick);
            self.resize_frame_pending = false;
        }
        // e2e per-frame observation: after submit, locally record target node geometry
        // (mirrors Windows paint path), test reads once at leisure, sample timing no longer
        // depends on RPC roundtrip.
        if (test_harness.enabled) test_harness.observeSubmittedFrame(self.cx);
    }

    /// Actively exit main loop (call from event handler).
    pub fn setVisualQuality(self: *App, quality: @import("render").visual_quality.Quality) void {
        self.renderer.setVisualQuality(quality);
        self.cx.renderer_reduced_motion = self.renderer.visual_quality == .basic;
        self.cx.backdrop_luminance_readback = self.renderer.visual_quality != .basic;
        self.cx.needs_redraw = true;
        if (self.cx.root) |root| root.markRenderDirty();
    }

    pub fn quit(self: *App) void {
        self.should_quit = true;
    }
};

/// Application-level configuration for the public multi-window runtime.
pub const MultiWindowConfig = struct {
    /// Only the first window pump may block. Remaining registered windows are
    /// drained non-blockingly after AppKit has distributed the native events.
    pump_timeout_ms: u32 = 16,
};

/// A real multi-window application runtime.
///
/// Every returned `*App` owns an independent native window, Cx, font system,
/// Metal surface, renderer, device/queue, IME route, and accessibility route.
/// `MultiWindowApp` owns the application loop and routes native events/menu
/// commands by window id. Closing one window destroys only that window; closing
/// the last window terminates `run()`.
///
/// The existing single-window `App` API remains unchanged.
pub const MultiWindowApp = struct {
    /// Explicit public bound for the allocation-free lifecycle ledger.
    /// `createWindow*` returns `error.TooManyWindows` above this count.
    pub const max_windows: usize = window_lifecycle.MAX_WINDOWS;

    const ManagedWindow = struct {
        app: *App,
        force_frame: bool = true,
    };

    allocator: Allocator,
    config: MultiWindowConfig,
    windows: std.ArrayList(ManagedWindow) = .empty,
    lifecycle: window_lifecycle.State = .{},
    iterating: bool = false,

    pub fn init(allocator: Allocator, config: MultiWindowConfig) MultiWindowApp {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *MultiWindowApp) void {
        // Reverse creation order mirrors nested ownership and avoids activating
        // fallback windows while the whole application is shutting down.
        while (self.windows.items.len > 0) {
            const managed = self.windows.pop().?;
            managed.app.deinit();
        }
        self.windows.deinit(self.allocator);
        self.lifecycle = .{};
        self.iterating = false;
    }

    pub fn windowCount(self: *const MultiWindowApp) usize {
        return self.windows.items.len;
    }

    /// Native registry count for lifecycle diagnostics and real-window smoke
    /// evidence. Application logic should normally use `windowCount()`.
    pub fn nativeWindowCount() u32 {
        return Window.liveWindowCount();
    }

    pub fn window(self: *MultiWindowApp, window_id: system_sdk.events.WindowId) ?*App {
        const index = self.indexOf(window_id) orelse return null;
        return self.windows.items[index].app;
    }

    pub fn activeWindow(self: *MultiWindowApp) ?*App {
        return self.window(self.lifecycle.active_window_id orelse return null);
    }

    /// Create an unmounted window. Call `App.mount` on the result before run,
    /// or use `createWindowWith` for transactional create+mount.
    pub fn createWindow(self: *MultiWindowApp, config: Config) !*App {
        try self.ensureWindowCapacity();
        const app = try App.init(self.allocator, config);
        errdefer app.deinit();
        try self.adopt(app);
        return app;
    }

    /// Transactional create+mount: a mount failure tears down every native/GPU
    /// resource and does not leave a half-registered application window.
    pub fn createWindowWith(self: *MultiWindowApp, config: Config, mount_fn: App.MountFn) !*App {
        try self.ensureWindowCapacity();
        const app = try App.init(self.allocator, config);
        errdefer app.deinit();
        try app.mount(mount_fn);
        try self.adopt(app);
        return app;
    }

    pub fn activateWindow(self: *MultiWindowApp, window_id: system_sdk.events.WindowId) bool {
        const app = self.window(window_id) orelse return false;
        self.lifecycle.setFocused(window_id, true);
        app.activate();
        return true;
    }

    /// Close one window. Calls from an input/menu/render callback are queued and
    /// committed at the safe iteration boundary; calls outside the loop tear it
    /// down immediately.
    pub fn closeWindow(self: *MultiWindowApp, window_id: system_sdk.events.WindowId) bool {
        if (!self.lifecycle.requestClose(window_id)) return false;
        if (!self.iterating) self.applyPendingCloses();
        return true;
    }

    /// Set the process-global macOS menu model. Custom command callbacks remain
    /// per-window because native invocation captures the key window id.
    pub fn setMenuModel(self: *MultiWindowApp, model: system_sdk.MenuModel) !void {
        const target = self.activeWindow() orelse return error.NoWindows;
        try target.setMenuModel(model);
    }

    pub fn bindMenuCommand(
        self: *MultiWindowApp,
        window_id: system_sdk.events.WindowId,
        command_id: u64,
        action: ui.actions.Action,
    ) !void {
        const target = self.window(window_id) orelse return error.UnknownWindow;
        target.bindMenuCommand(command_id, action);
    }

    /// Pump AppKit once and dispatch all per-window queues. Returns false after
    /// Cmd+Q, explicit `quit`, or teardown of the last window.
    pub fn pump(self: *MultiWindowApp, timeout_ms: u32) !bool {
        if (!self.shouldContinue()) return false;
        // Retire already accepted closes before any potentially blocking native wait.
        for (self.windows.items) |managed| {
            if (managed.app.should_quit) _ = self.lifecycle.requestClose(managed.app.windowId());
        }
        self.applyPendingCloses();
        if (!self.shouldContinue()) return false;
        {
            std.debug.assert(!self.iterating);
            self.iterating = true;
            defer self.iterating = false;

            var index: usize = 0;
            while (index < self.windows.items.len) : (index += 1) {
                const managed = &self.windows.items[index];
                const result = try managed.app.sdk.pump(if (index == 0) timeout_ms else 0);
                if (!result.should_continue) self.lifecycle.requestQuit();
                if (result.requested_redraw or managed.app.sdk.events().len > 0) {
                    managed.force_frame = true;
                }
                managed.app.sdk.dispatching = true;
                defer managed.app.sdk.dispatching = false;
                for (managed.app.sdk.events()) |evt| self.dispatchEvent(managed.app.windowId(), evt);
                if (managed.app.should_quit) _ = self.lifecycle.requestClose(managed.app.windowId());
                if (self.lifecycle.quit_requested) break;
            }
        }
        self.applyPendingCloses();
        return self.shouldContinue();
    }

    /// Reconfigure and render every live window independently.
    pub fn frame(self: *MultiWindowApp) !void {
        if (!self.shouldContinue()) return;
        {
            std.debug.assert(!self.iterating);
            self.iterating = true;
            defer self.iterating = false;

            const jank_debug = @import("zenit_environment").getBorrowed("ZENIT_DEBUG_JANK") != null;
            for (self.windows.items) |*managed| {
                const app = managed.app;
                try app.maybeReconfigureSurface();
                _ = app.renderer.pollBackdropLuminance(app.cx);
                if (app.shouldRenderAutomaticFrame(managed.force_frame)) {
                    managed.force_frame = false;
                    const t0 = if (jank_debug) @import("zenit_time").Instant.now(app.config.io) catch null else null;
                    try app.frame();
                    if (jank_debug) jankProbe(app.config.io, &app.debug_jank_prev, t0);
                }
            }
        }
        self.applyPendingCloses();
    }

    pub fn tick(self: *MultiWindowApp) !bool {
        const pool = AutoreleasePool.push();
        defer pool.pop();
        if (!try self.pump(self.config.pump_timeout_ms)) return false;
        // MultiWindowApp owns the event loop just like App.run(). Drain the
        // process-global Harness queue exactly once after platform events so
        // DevTools and other auxiliary-window apps remain automatable.
        if (test_harness.enabled and test_harness.drainCommandsRequestFrame()) {
            for (self.windows.items) |*managed| {
                if (managed.app.cx == g_test_cx) managed.force_frame = true;
            }
        }
        // App.quit() may come from a harness command or application callback,
        // without a native event to pass through dispatchToWindow. Retire such
        // windows before rendering instead of waiting for another input event.
        for (self.windows.items) |managed| {
            if (managed.app.should_quit) _ = self.lifecycle.requestClose(managed.app.windowId());
        }
        self.applyPendingCloses();
        if (!self.shouldContinue()) return false;
        try self.frame();
        if (test_harness.enabled) test_harness.afterFrame();
        return self.shouldContinue();
    }

    /// Run until the last window closes or an application-wide quit is
    /// requested. Quit stops pumping and returns; the owning caller's deferred
    /// `deinit()` then destroys every remaining native/GPU/UI window resource.
    pub fn run(self: *MultiWindowApp) !void {
        while (try self.tick()) {}
        for (self.windows.items) |*managed| {
            if (managed.app.display_link_running) {
                managed.app.win.stopDisplayLink();
                managed.app.display_link_running = false;
            }
        }
    }

    pub fn quit(self: *MultiWindowApp) void {
        self.lifecycle.requestQuit();
        Window.postEmptyEvent();
    }

    pub fn shouldContinue(self: *const MultiWindowApp) bool {
        return !self.lifecycle.quit_requested and self.windows.items.len > 0;
    }

    fn ensureWindowCapacity(self: *MultiWindowApp) !void {
        if (self.windows.items.len >= max_windows) return error.TooManyWindows;
        try self.windows.ensureUnusedCapacity(self.allocator, 1);
    }

    fn adopt(self: *MultiWindowApp, app: *App) !void {
        try self.lifecycle.add(app.windowId());
        self.windows.appendAssumeCapacity(.{ .app = app });
    }

    fn dispatchEvent(
        self: *MultiWindowApp,
        pump_owner_window_id: system_sdk.events.WindowId,
        evt: system_sdk.events.Event,
    ) void {
        switch (evt) {
            .quit => {
                self.lifecycle.requestQuit();
                return;
            },
            .window_close_requested => |e| {
                self.dispatchToWindow(e.window_id, evt);
                return;
            },
            .window_focused => |e| {
                self.lifecycle.setFocused(e.window_id, e.focused);
                self.dispatchToWindow(e.window_id, evt);
                return;
            },
            .menu_command => |e| {
                // The native menu queue is process-global, so A's SDK pump may
                // dequeue a command captured while B was key. Never infer the
                // target from the pump owner; route the captured id instead.
                const target = self.lifecycle.menuTargetFromPump(pump_owner_window_id, e.window_id) orelse return;
                self.dispatchToWindow(target, evt);
                return;
            },
            .frame_requested, .system_theme_changed => {
                for (self.windows.items) |*managed| {
                    _ = managed.app.processEvent(evt);
                    managed.force_frame = true;
                }
                return;
            },
            else => {},
        }
        const target = evt.targetWindowId() orelse return;
        self.dispatchToWindow(target, evt);
    }

    fn dispatchToWindow(self: *MultiWindowApp, window_id: system_sdk.events.WindowId, evt: system_sdk.events.Event) void {
        const index = self.indexOf(window_id) orelse return;
        const managed = &self.windows.items[index];
        if (managed.app.processEvent(evt)) managed.force_frame = true;
        // `App.quit()` remains meaningful when a window is managed: it closes
        // that window, while `MultiWindowApp.quit()` exits the application.
        if (managed.app.should_quit) _ = self.lifecycle.requestClose(window_id);
    }

    fn applyPendingCloses(self: *MultiWindowApp) void {
        std.debug.assert(!self.iterating);
        while (self.lifecycle.popPendingClose()) |window_id| {
            self.destroyWindowNow(window_id);
        }
    }

    fn destroyWindowNow(self: *MultiWindowApp, window_id: system_sdk.events.WindowId) void {
        const index = self.indexOf(window_id) orelse return;
        const managed = self.windows.orderedRemove(index);
        _ = self.lifecycle.removed(window_id);
        managed.app.deinit();
        // AppKit normally promotes a remaining window. Make the lifecycle
        // fallback explicit so first responder/IME/menu routing is never left
        // attached to the destroyed context.
        if (!self.lifecycle.quit_requested) {
            if (self.activeWindow()) |active| active.activate();
        }
    }

    fn indexOf(self: *const MultiWindowApp, window_id: system_sdk.events.WindowId) ?usize {
        for (self.windows.items, 0..) |managed, index| {
            if (managed.app.windowId() == window_id) return index;
        }
        return null;
    }
};

// ============================================================================
// private helpers
// ============================================================================

/// Synced from MetalView.setFrameSize during live resize: reconfigure surface/viewport
/// and render so content reflows frame-by-frame (native behavior), not CoreAnimation
/// stretch of old frame. Native code also calls this at the final resize boundary,
/// after live resize ends. Other programmatic setFrameSize calls use the main loop.
fn liveResizeRender(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));
    if (app.in_live_resize_render) return;
    app.in_live_resize_render = true;
    defer app.in_live_resize_render = false;
    // Native Header policy may change layout without changing the outer window.
    // Publish that state/layout before reading the drawable and testing dirtiness;
    // otherwise the final resize can be skipped or use the previous projection.
    chrome_controller.syncChrome(app);
    app.maybeReconfigureSurface() catch |err| {
        std.log.scoped(.zenit_runtime).warn("live-resize surface reconfigure failed: {s}", .{@errorName(err)});
        return;
    };
    // Called both by setFrameSize: (size changed -> maybeReconfigureSurface sets needs_redraw)
    // and by native live-resize ticker at refresh rate (drives animation during drag hold);
    // skips redraw when static and size unchanged.
    if (!app.cx.wantsFrame()) return;
    app.frame() catch |err| {
        std.log.scoped(.zenit_runtime).warn("live-resize frame failed: {s}", .{@errorName(err)});
    };
}

/// ZENIT_DEBUG_JANK=1: logs line when consecutive render dt > 20ms (and < 100ms, longer is
/// idle gap): [jank] dt=... frame_wall=... : dt wall-clock vs prior frame, frame_wall
/// this frame's own cost.
fn jankProbe(io: std.Io, prev: *?@import("zenit_time").Instant, t0: ?@import("zenit_time").Instant) void {
    const now = @import("zenit_time").Instant.now(io) catch return;
    defer prev.* = now;
    const p = prev.* orelse return;
    const dt_ms = @as(f64, @floatFromInt(now.since(p))) / 1e6;
    const wall_ms = if (t0) |t| @as(f64, @floatFromInt(now.since(t))) / 1e6 else 0;
    if (dt_ms > 20.0 and dt_ms < 100.0) std.debug.print("[jank] dt={d:.1}ms frame_wall={d:.1}ms\n", .{ dt_ms, wall_ms });
}

/// Font fallback chain; return first usable. macOS also tries system font dir absolute
/// path as last backstop.
const ResolvedFont = struct { font: *Font, family: []const u8 };

fn loadWeightedFont(context: *anyopaque, font_size: f32, font_weight: u16) ?*Font {
    const app: *App = @ptrCast(@alignCast(context));
    const family = app.resolved_font_family orelse return null;
    const Desc = @import("zenit_reflection").params(@TypeOf(FontManager.findFont))[1].type.?;
    const weight: @FieldType(Desc, "weight") = if (font_weight <= 100) .thin else if (font_weight <= 300) .light else if (font_weight <= 400) .regular else if (font_weight <= 500) .medium else if (font_weight <= 600) .semibold else if (font_weight <= 700) .bold else if (font_weight <= 800) .heavy else .black;
    return app.font_manager.findFont(.{ .family = family, .size = font_size, .weight = weight, .style = .normal }) catch null;
}

/// The platform UI font (TextProps.font_family = system UI): CoreText's system font, whose
/// optical size and tracking follow the point size (native controls' labels).
fn loadSystemUiFont(context: *anyopaque, font_size: f32, font_weight: u16) ?*Font {
    const app: *App = @ptrCast(@alignCast(context));
    const Desc = @import("zenit_reflection").params(@TypeOf(FontManager.findFont))[1].type.?;
    const weight: @FieldType(Desc, "weight") = if (font_weight <= 100) .thin else if (font_weight <= 300) .light else if (font_weight <= 400) .regular else if (font_weight <= 500) .medium else if (font_weight <= 600) .semibold else if (font_weight <= 700) .bold else if (font_weight <= 800) .heavy else .black;
    return app.font_manager.findFont(.{ .family = "system-ui", .size = font_size, .weight = weight, .style = .normal }) catch null;
}

fn findFontWithFallback(fm: *FontManager, size: u32, families: []const []const u8) !ResolvedFont {
    for (families) |family| {
        if (fm.findFont(.{
            .family = family,
            .size = @floatFromInt(size),
            .weight = .regular,
            .style = .normal,
        }) catch null) |font| {
            return .{ .font = font, .family = family };
        }
    }
    if (comptime builtin.os.tag == .macos) {
        const paths = [_][:0]const u8{
            "/System/Library/Fonts/Helvetica.ttc",
            "/System/Library/Fonts/Menlo.ttc",
        };
        const path_families = [_][]const u8{ "Helvetica", "Menlo" };
        inline for (paths, path_families) |path, fam| {
            if (fm.loadFont(path, size) catch null) |font| {
                return .{ .font = font, .family = fam };
            }
        }
    }
    return error.FontLoadFailed;
}

// measure_fn signature (fn([*]const u8, usize, f32, u16, bool) f32) takes no context
// param, only global static pointer. Retained for compat reading old Cx.measure_fn;
// framework internals and layout main path use measure_ctx_fn / Cx.measureTextWidth
// to isolate multi-window font context.
var g_font_selector_for_measure: ?*FontSelector = null;

/// Process-level text hook ownership stack: hooks always point to top-of-stack App's
/// selector.
var g_text_hook_owners: text_hook_owners.OwnerStack(MultiWindowApp.max_windows) = .{};

/// Point three process-level text outlets (no-context measure fallback / GlyphRun font
/// parser / drawn-width measure) all to ctx (a *FontSelector), or null to unwind all.
fn installProcessTextHooks(ctx: ?*anyopaque) void {
    if (ctx) |c| {
        g_font_selector_for_measure = @ptrCast(@alignCast(c));
        ui.text_shaping.setShapeFontResolver(&resolveShapeFont, c);
        ui.text_shaping.setDrawnTextMeasure(&measureShapeTextAsDrawn, c);
    } else {
        g_font_selector_for_measure = null;
        ui.text_shaping.setShapeFontResolver(null, null);
        ui.text_shaping.setDrawnTextMeasure(null, null);
    }
}

/// Context-aware measure: context is this App's FontSelector, so concurrent Apps don't
/// clobber each other (contrast global static pointer measure below).
fn measureTextWithCtx(ctx: *anyopaque, text_ptr: [*]const u8, text_len: usize, font_size: f32, font_weight: u16, use_italic: bool) f32 {
    const fs: *FontSelector = @ptrCast(@alignCast(ctx));
    return fs.measureTextWidth(text_ptr[0..text_len], font_size, font_weight, use_italic);
}

/// GlyphRun pipeline font parser: shares FontSelector.resolveFonts with render, and passes
/// **content**, so it cuts to fallback for CJK/hiragana/Hangul exactly as render does.
///
/// == Why shapingFont(), not fallback orelse primary ==
/// Render (command_encoder.encodeText) passes primary to the shaper as the font for the entire
/// segment; fallback is only a per-glyph supplemental hint (CoreText picks per run attribute, see
/// text_renderer.getOrCreateGlyphFallbackFont). Preferring fallback in measure would shape the
/// whole segment with a font differing from render.
///
/// Italic is where the wrong path always bites: resolveContentFallback always returns the upright
/// regular_font for italic (fallback when the italic face lacks glyphs), so every italic segment
/// measures with the upright font but renders italic. Inter Italic is wider than upright, so a
/// .fit container tightens to upright width and italic glyphs clip at the right edge (long
/// filenames lose end chars in an italic preview file tab).
fn resolveFamilyFont(
    ctx: *anyopaque,
    family: u16,
    size: f32,
    weight: u16,
    italic: bool,
) ?*Font {
    const reg: *render.FontRegistry = @ptrCast(@alignCast(ctx));
    return reg.resolve(@fromBackingInt(@intCast(family)), size, weight, italic);
}

fn resolveShapeFont(
    ctx: *anyopaque,
    content: []const u8,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    font_family: u16,
) ?*Font {
    const fs: *FontSelector = @ptrCast(@alignCast(ctx));
    return fs.resolveFonts(content, .{
        .font_size = font_size,
        .font_weight = font_weight,
        // Must pass as-is; this is outlet 4. Skip it and measure uses default family, render
        // uses user choice, cursor/selection systematically offset.
        .font_family = font_family,
        .use_italic = use_italic,
        .use_monospace = use_monospace,
    }).shapingFont();
}

/// Authoritative rich-text measurement bridge. FontSelector is already bound
/// by AppRenderer.setFonts to this App's stable TextRenderer, so this executes
/// the same segmentation, fallback-stack selection and glyph-advance loop as
/// drawing instead of reshaping with an approximate local font.
fn measureShapeTextAsDrawn(
    ctx: *anyopaque,
    content: []const u8,
    font_size: f32,
    font_weight: u16,
    use_italic: bool,
    use_monospace: bool,
    font_family: u16,
    use_symbols: bool,
    monospace_char_width: f32,
) ?f32 {
    const fs: *FontSelector = @ptrCast(@alignCast(ctx));
    return fs.measureTextWidthWithProps(content, .{
        .font_size = font_size,
        .font_weight = font_weight,
        .font_family = font_family,
        .use_italic = use_italic,
        .use_monospace = use_monospace,
        .use_symbols = use_symbols,
        .monospace_char_width = monospace_char_width,
    });
}

fn measureText(text_ptr: [*]const u8, text_len: usize, font_size: f32, font_weight: u16, use_italic: bool) f32 {
    const fs = g_font_selector_for_measure orelse return @as(f32, @floatFromInt(text_len)) * font_size * 0.5;
    return fs.measureTextWidth(text_ptr[0..text_len], font_size, font_weight, use_italic);
}

fn sdkModifiersToUi(m: system_sdk.events.Modifiers) ui.events.Modifiers {
    return .{ .shift = m.shift, .ctrl = m.ctrl, .alt = m.alt, .super = m.super };
}

fn sdkMouseButtonToUi(btn: system_sdk.events.MouseButton) ?ui.events.MouseButton {
    return switch (btn) {
        .left => .left,
        .right => .right,
        .middle => .middle,
        .other => null,
    };
}

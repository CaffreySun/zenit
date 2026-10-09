//! Pixel-producing Windows App runtime built on the current Direct2D paint
//! subset. It uses the same Cx and SystemSdk event path as the macOS App.
const std = @import("std");
const ui = @import("ui");
const platform = @import("platform");
const system_sdk = @import("system_sdk");
const text = @import("text");
const shared_renderer = @import("gpu").backend_kind == .d3d12;
const windows_paint = if (shared_renderer) @import("windows_shared_paint.zig") else @import("windows_paint.zig");
const test_harness = @import("test_harness");
const ClearColor = @import("renderer.zig").ClearColor;
const window_lifecycle = @import("window_lifecycle.zig");

const pointer_isolation = @import("pointer_isolation.zig");
/// Background e2e runs (ZENIT_E2E_BACKGROUND=1) isolate by default; see pointer_isolation.zig.
fn isolateOsPointer() bool {
    return pointer_isolation.enabled(true);
}

pub const FontConfig = @import("font_config.zig").FontConfig;
const FontSelector = @import("render").FontSelector;

pub const TitlebarStyle = @import("window_config.zig").TitlebarStyle;
pub const WindowConfig = @import("window_config.zig").WindowConfig;

pub const Config = struct {
    /// Application-owned I/O implementation, valid until all windows are destroyed.
    io: std.Io,
    window: WindowConfig = .{},
    font: FontConfig = .{},
    clear_color: ClearColor = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    visual_quality: ?@import("render").visual_quality.Quality = null,
    pump_timeout_ms: u32 = 16,
    idle_skip_frames: bool = true,
};

/// D3D12 compiles HLSL at runtime, and the blur + glass sources (~87 KB) take
/// about two seconds on first use — the wait behind "the first glass story
/// opens slowly". Compile them once on a background thread right after
/// startup: the native compiler keeps the DXBC in the per-user disk cache, so
/// the first glass frame (and every later launch) loads bytecode instead.
/// The modules are discarded; D3DCompile is thread-safe and the device is not
/// touched. A glass frame that comes first simply compiles in parallel.
fn prewarmShaderCache(device: *@import("gpu").Backend.Device) void {
    const gpu = @import("gpu");
    warmShaderSource(device, "blur", gpu.Backend.shaders.blur);
    warmShaderSource(device, "glass", gpu.Backend.shaders.glass);
}

fn warmShaderSource(device: *@import("gpu").Backend.Device, name: []const u8, source: []const u8) void {
    var module = @import("gpu").Backend.ShaderModule.initFromSource(device, source) catch |err| {
        std.log.warn("[d3d12] shader cache warm-up of {s} failed: {}", .{ name, err });
        return;
    };
    module.deinit();
}

pub const App = struct {
    allocator: std.mem.Allocator,
    win: platform.Window,
    /// D3D12 shader-cache warm-up; joined before the painter goes away.
    prewarm_thread: ?std.Thread = null,
    sdk: system_sdk.SystemSdk,
    font_system: text.FontSystem,
    fonts: [3]*text.Font,
    font_selector: FontSelector,
    resolved_font_family: []const u8,
    font_registry: ?*@import("render").FontRegistry,
    fallback_stack: ?*@import("render").font_fallback_stack.FontFallbackStack,
    cx: *ui.Cx,
    painter: windows_paint.Painter,
    renderer: *windows_paint.Painter,
    should_quit: bool = false,
    width: u32,
    height: u32,
    scale: f32,
    pump_timeout_ms: u32,
    idle_skip_frames: bool,
    native_frame_active: bool,
    native_redraw_pending: bool,
    in_native_callback: bool,

    pub const MountFn = *const fn (*ui.Cx, *ui.Scope) anyerror!*ui.Node;

    pub fn init(allocator: std.mem.Allocator, config: Config) !*App {
        const sizes = [_]u32{ config.font.small_size, config.font.medium_size, config.font.large_size };
        for (sizes) |size| if (size == 0) return error.InvalidFontSize;
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.should_quit = false;
        self.font_registry = null;
        self.fallback_stack = null;
        self.win = try platform.Window.init(config.window.width, config.window.height, config.window.title);
        errdefer self.win.deinit();
        if (config.window.titlebar == .custom_inset) {
            try self.win.setCustomTitlebar(config.window.titlebar_height, config.window.titlebar_drag_right_inset);
            if (!self.win.setSizeChecked(config.window.width, config.window.height)) return error.WindowResizeFailed;
        }
        self.sdk = try system_sdk.backends.initSystemSdk(allocator, &self.win, self.win.getWindowId());
        errdefer self.sdk.deinit();
        self.font_system = try text.FontSystem.init(allocator, config.io);
        errdefer self.font_system.deinit();
        self.font_system.setDefaultLocale(config.font.locale);
        // Resolve once for all slots, own the family independently of Config.
        var chosen: ?*text.Font = null;
        for (config.font.fallback_families) |family| {
            chosen = self.font_system.findFont(.{ .family = family, .size = @floatFromInt(sizes[0]) }) catch |err| switch (err) {
                error.FontNotFound => continue,
                else => return err,
            };
            break;
        }
        self.fonts[0] = chosen orelse try self.font_system.findFont(.{ .family = "system", .size = @floatFromInt(sizes[0]) });
        var loaded: usize = 1;
        errdefer for (self.fonts[0..loaded]) |font| font.deinit();
        self.resolved_font_family = try allocator.dupe(u8, self.fonts[0].family);
        errdefer allocator.free(self.resolved_font_family);
        self.font_system.setDefaultFamily(self.resolved_font_family);
        // Keep the default locale tied to the owned small slot, not borrowed Config memory.
        self.font_system.setDefaultLocale(self.fonts[0].locale);
        for (sizes[1..], 1..) |size, index| {
            self.fonts[index] = try self.font_system.findFont(.{ .family = "system", .size = @floatFromInt(size) });
            loaded += 1;
        }
        self.font_selector = .{ .small = self.fonts[0], .medium = self.fonts[1], .large = self.fonts[2] };
        self.font_selector.weight_loader = .{ .context = self, .load = loadWeightedFont };
        self.font_selector.initDerivedCache(allocator);
        errdefer self.font_selector.deinitDerivedCache();
        self.cx = try ui.Cx.init(allocator, config.io);
        errdefer self.cx.deinit();
        self.cx.setWindowId(self.win.getWindowId());
        self.cx.setSystemSdk(&self.sdk);
        self.cx.text.setFontSystem(&self.font_system);
        self.cx.text.manage_legacy_font_hooks = true;
        const size = self.win.getSize();
        self.width = size[0];
        self.height = size[1];
        self.scale = self.win.getScaleFactor();
        self.font_selector.setScaleFactor(self.scale);
        self.cx.display_refresh_hz = self.win.getDisplayRefreshRate();
        self.pump_timeout_ms = config.pump_timeout_ms;
        self.idle_skip_frames = config.idle_skip_frames;
        self.native_frame_active = false;
        self.native_redraw_pending = false;
        self.in_native_callback = false;
        self.cx.setWindowMetrics(@floatFromInt(self.width), @floatFromInt(self.height), self.scale);
        self.painter = try windows_paint.Painter.init(allocator, config.io, &self.win, .{
            config.clear_color.r,
            config.clear_color.g,
            config.clear_color.b,
            config.clear_color.a,
        });
        errdefer self.painter.deinit(&self.win);
        if (config.visual_quality) |quality| self.setVisualQuality(quality);
        // Painters read back per-glass backdrop luminance (refreshLuminance),
        // except the shared renderer at basic quality. Declare it before any UI
        // mounts so new glass takes the first-frame family probe, as on macOS.
        self.cx.backdrop_luminance_readback = if (comptime shared_renderer) self.painter.state.renderer.visual_quality != .basic else true;
        try self.painter.setDefaultFontFamily(self.resolved_font_family);
        try self.painter.setDefaultLocale(config.font.locale);
        self.renderer = &self.painter;
        if (shared_renderer) self.setFontSelector(&self.font_selector);
        if (comptime shared_renderer) {
            self.prewarm_thread = std.Thread.spawn(.{}, prewarmShaderCache, .{self.painter.state.renderer.device}) catch null;
        }
        errdefer if (self.prewarm_thread) |thread| thread.join();
        // Native sizing/moving runs a nested Win32 loop. Rebuild Cx geometry
        // there instead of replaying commands prepared for the old viewport.
        self.win.setRenderCallback(renderNative, self);
        if (config.window.titlebar == .custom_inset) self.win.setTitlebarHitCallback(titlebarHitTest, self);
        @import("windows_accessibility.zig").install(self.cx, &self.win) catch |err| {
            std.log.err("Windows accessibility handler: {s}", .{@errorName(err)});
        };
        return self;
    }

    fn titlebarHitTest(context: ?*anyopaque, x: f32, y: f32) callconv(.c) c_int {
        const self: *App = @ptrCast(@alignCast(context orelse return 0));
        return if (self.cx.hitTest(x, y) != null) 1 else 0;
    }

    pub fn deinit(self: *App) void {
        if (self.prewarm_thread) |thread| thread.join();
        self.prewarm_thread = null;
        self.win.setTitlebarHitCallback(null, null);
        self.win.setRenderCallback(null, null);
        @import("windows_accessibility.zig").detach(&self.win);
        if (test_harness.enabled and g_test_cx == self.cx) g_test_cx = null;
        if (test_harness.enabled and g_test_app == self) g_test_app = null;
        self.cx.deinit();
        self.painter.deinit(&self.win);
        self.font_selector.deinitDerivedCache();
        for (self.fonts) |font| font.deinit();
        self.font_system.deinit();
        self.allocator.free(self.resolved_font_family);
        self.sdk.deinit();
        self.win.deinit();
        self.allocator.destroy(self);
    }

    /// Caller owns selector and its fonts; keep them alive through App.deinit.
    pub fn setFontSelector(self: *App, selector: *FontSelector) void {
        if (self.font_registry) |registry| {
            selector.family_resolve_fn = resolveFamily;
            selector.family_resolve_ctx = registry;
        }
        selector.initDerivedCache(self.allocator);
        selector.setScaleFactor(self.scale);
        self.cx.text.clearManagedFontHooks();
        self.painter.setFonts(selector);
        self.cx.text.measure_ctx_fn = measureSelector;
        self.cx.text.measure_ctx = self;
        self.cx.text.font_resolve_fn = resolveSelector;
        self.cx.text.font_resolve_ctx = self;
        self.cx.text.legacy_font_resolve_fn = resolveLegacySelector;
        self.cx.text.font_props_measure_fn = measureFontProps;
        self.cx.text.resetShapingCache();
        self.invalidateFontLayout();
    }

    /// Caller owns registry and configures its FontSystem; keep it alive through App lifetime.
    pub fn setFontRegistry(self: *App, registry: *@import("render").FontRegistry) void {
        self.font_registry = registry;
        registry.setScaleFactor(self.scale);
        self.setFontSelector(self.painter.fonts orelse &self.font_selector);
    }

    /// Bind the same immutable selection factory to geometry and native paint.
    /// Rebind after its fonts/rules change, even if ctx/provider are unchanged.
    pub fn setFontRangesProvider(self: *App, ctx: ?*anyopaque, provider: @TypeOf(@as(ui.Cx, undefined).text.font_ranges_fn)) void {
        self.fallback_stack = null;
        if (shared_renderer) self.painter.setFallbackStack(null);
        self.painter.stack_mode = false;
        self.bindFontRangesProvider(ctx, provider);
    }

    /// Caller owns the stack and source Font objects until it is unbound.
    /// Rebind after mutating its families/fonts, including at the same address.
    pub fn setFallbackStack(self: *App, stack: ?*@import("render").font_fallback_stack.FontFallbackStack) void {
        self.fallback_stack = stack;
        if (shared_renderer) self.painter.setFallbackStack(stack);
        self.painter.stack_mode = stack != null;
        self.bindFontRangesProvider(if (stack != null) self else null, if (stack != null) stackRanges else null);
    }

    fn stackRanges(raw: *anyopaque, opts: ui.Cx.ShapeTextOpts, primary: *text.Font, allocator: std.mem.Allocator) !?*text.FontRanges {
        const self: *App = @ptrCast(@alignCast(raw));
        const stack = self.fallback_stack orelse return null;
        const snapshot = try allocator.create(text.FontRanges);
        errdefer allocator.destroy(snapshot);
        snapshot.* = try @import("windows_font_ranges.zig").build(allocator, stack, primary, opts.text, opts.font_size, opts.use_italic);
        return snapshot;
    }

    fn bindFontRangesProvider(self: *App, ctx: ?*anyopaque, provider: @TypeOf(@as(ui.Cx, undefined).text.font_ranges_fn)) void {
        if (provider != null and self.painter.fonts == null) self.setFontSelector(&self.font_selector);
        self.cx.text.setFontRangesProvider(ctx, provider);
        self.painter.setFontRangesProvider(ctx, provider);
        self.invalidateFontLayout();
    }

    pub fn resetFontSelector(self: *App) void {
        if (self.font_registry != null) {
            self.setFontSelector(&self.font_selector);
            return;
        }
        self.cx.text.clearManagedFontHooks();
        self.painter.setFonts(null);
        self.fallback_stack = null;
        if (shared_renderer) self.painter.setFallbackStack(null);
        self.painter.stack_mode = false;
        self.cx.text.setFontRangesProvider(null, null);
        self.painter.setFontRangesProvider(null, null);
        self.cx.text.measure_ctx_fn = null;
        self.cx.text.measure_ctx = null;
        self.cx.text.font_resolve_fn = null;
        self.cx.text.font_resolve_ctx = null;
        self.cx.text.legacy_font_resolve_fn = null;
        self.cx.text.font_props_measure_fn = null;
        self.cx.text.resetShapingCache();
        self.invalidateFontLayout();
    }

    fn invalidateFontLayout(self: *App) void {
        if (self.cx.root) |root| invalidateFontNode(root);
        self.cx.needs_redraw = true;
    }

    fn invalidateFontNode(node: *ui.Node) void {
        node.markSizingDirty();
        for (node.children.items) |child| invalidateFontNode(child);
    }

    fn measureSelector(raw: *anyopaque, bytes: [*]const u8, length: usize, size: f32, weight: u16, italic: bool) f32 {
        return measureFontProps(raw, bytes[0..length], size, weight, italic, false, 0, false, 0) orelse 0;
    }

    fn resolveSelector(raw: *anyopaque, opts: ui.Cx.ShapeTextOpts) ?*text.Font {
        const self: *App = @ptrCast(@alignCast(raw));
        const selector = self.painter.fonts orelse &self.font_selector;
        return selector.resolveFonts(opts.text, .{ .stack_mode_override = if (self.fallback_stack != null) true else null, .font_size = opts.font_size, .font_weight = opts.font_weight, .use_italic = opts.use_italic, .font_family = opts.font_family_id, .use_monospace = opts.use_monospace, .use_symbols = opts.use_symbols }).shapingFont();
    }

    fn resolveFamily(raw: *anyopaque, family: u16, size: f32, weight: u16, italic: bool) ?*text.Font {
        const registry: *@import("render").FontRegistry = @ptrCast(@alignCast(raw));
        return registry.resolve(@fromBackingInt(@intCast(family)), size, weight, italic);
    }

    fn resolveLegacySelector(raw: *anyopaque, content: []const u8, size: f32, weight: u16, italic: bool, mono: bool, family: u16) ?*text.Font {
        const self: *App = @ptrCast(@alignCast(raw));
        const selector = self.painter.fonts orelse &self.font_selector;
        return selector.resolveFonts(content, .{ .stack_mode_override = if (self.fallback_stack != null) true else null, .font_size = size, .font_weight = weight, .use_italic = italic, .use_monospace = mono, .font_family = family }).shapingFont();
    }

    fn measureFontProps(raw: *anyopaque, content: []const u8, size: f32, weight: u16, italic: bool, mono: bool, family: u16, symbols: bool, cell: f32) ?f32 {
        const self: *App = @ptrCast(@alignCast(raw));
        const selector = self.painter.fonts orelse &self.font_selector;
        if (self.cx.text.font_ranges_fn != null) {
            if (mono and cell > 0 and allAscii(content))
                return @as(f32, @floatFromInt(content.len)) * cell;
            const shaped = self.cx.text.shapeText(.{
                .text = content,
                .font_family = "system",
                .font_family_id = family,
                .font_size = size,
                .font_weight = weight,
                .use_italic = italic,
                .use_monospace = mono,
                .use_symbols = symbols,
            }) catch return null;
            return shaped.total_advance;
        }
        return selector.measureTextWidthWithProps(content, .{ .font_size = size, .font_weight = weight, .use_italic = italic, .use_monospace = mono, .font_family = family, .use_symbols = symbols, .monospace_char_width = cell });
    }

    fn allAscii(content: []const u8) bool {
        for (content) |byte| if (byte >= 128) return false;
        return true;
    }

    fn loadWeightedFont(raw: *anyopaque, size: f32, weight: u16) ?*text.Font {
        const self: *App = @ptrCast(@alignCast(raw));
        const mapped: text.FontWeight = if (weight <= 100) .thin else if (weight <= 300) .light else if (weight <= 400) .regular else if (weight <= 500) .medium else if (weight <= 600) .semibold else if (weight <= 700) .bold else if (weight <= 800) .heavy else .black;
        return self.font_system.findFont(.{ .family = self.resolved_font_family, .size = size, .weight = mapped }) catch null;
    }

    pub fn mount(self: *App, mount_fn: MountFn) !void {
        if (self.cx.root != null) return error.AlreadyMounted;
        const allocator = self.cx.allocator;
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
        (try portal.style.ensureExtFallible(allocator)).z_index = ui.Cx.window_portal_z_index;

        const scope = try ui.Scope.init(allocator, null, self.cx.owner);
        var scope_owned = true;
        errdefer if (scope_owned) {
            if (self.cx.root_scope == scope) self.cx.root_scope = null;
            if (self.cx.popover_portal_root == portal) self.cx.popover_portal_root = null;
            if (self.cx.root == app_root) self.cx.root = null;
            scope.dispose();
        };
        self.cx.root_scope = scope;
        self.cx.root = app_root;
        self.cx.popover_portal_root = portal;

        const user_root = try mount_fn(self.cx, scope);
        app_root.appendChild(allocator, user_root) catch |err| {
            scope.dispose();
            scope_owned = false;
            self.cx.root_scope = null;
            self.cx.popover_portal_root = null;
            self.cx.root = null;
            user_root.destroy(allocator);
            return err;
        };
        app_root.appendChild(allocator, portal) catch |err| {
            scope.dispose();
            scope_owned = false;
            self.cx.root_scope = null;
            self.cx.popover_portal_root = null;
            self.cx.root = null;
            return err;
        };
        portal_orphan = false;
        scope_owned = false;
        app_root_orphan = false;
        self.cx.is_mounted = true;
        self.cx.needs_redraw = true;
        if (test_harness.enabled) {
            self.rebindTestHarness();
            test_harness.init(self.config.io, getTestCx, wakeTestHarness);
        }
    }

    pub fn runWith(self: *App, mount_fn: MountFn) !void {
        try self.mount(mount_fn);
        try self.run();
    }

    pub fn windowId(self: *const App) system_sdk.events.WindowId {
        return self.win.getWindowId();
    }

    pub fn rebindTestHarness(self: *App) void {
        if (!test_harness.enabled) return;
        g_test_cx = self.cx;
        g_test_app = self;
        test_harness.setResizeWindowCallback(resizeWindowForHarness);
        test_harness.setScreenshotCallback(captureScreenshotForHarness);
        test_harness.setFrameStatsCallback(frameStatsForHarness);
        test_harness.setResetTimingCallback(resetTimingForHarness);
        test_harness.setVisualQualityCallback(visualQualityForHarness);
        if (shared_renderer) test_harness.setRecordingCallbacks(startRecordingForHarness, recordingStatusForHarness, stopRecordingForHarness);
    }

    pub fn activate(self: *App) void {
        self.win.activate();
        self.cx.bindFrameClock();
    }

    pub fn setVisualQuality(self: *App, quality: @import("render").visual_quality.Quality) void {
        if (comptime shared_renderer) {
            self.painter.state.renderer.setVisualQuality(quality);
            self.cx.renderer_reduced_motion = self.painter.state.renderer.visual_quality == .basic;
            self.cx.backdrop_luminance_readback = self.painter.state.renderer.visual_quality != .basic;
            self.cx.needs_redraw = true;
            if (self.cx.root) |root| root.markRenderDirty();
        }
    }

    pub fn quit(self: *App) void {
        self.should_quit = true;
    }

    fn renderNative(context: ?*anyopaque) callconv(.c) void {
        const self: *App = @ptrCast(@alignCast(context orelse return));
        if (self.native_frame_active) {
            self.native_redraw_pending = true;
            return;
        }
        self.in_native_callback = true;
        defer self.in_native_callback = false;
        self.cx.needs_redraw = true;
        self.frame() catch |err| {
            std.log.err("Windows native paint: {s}", .{@errorName(err)});
            self.cx.needs_redraw = true;
        };
    }

    pub fn frame(self: *App) !void {
        if (self.native_frame_active) {
            self.native_redraw_pending = true;
            return;
        }
        self.native_frame_active = true;
        defer {
            self.native_frame_active = false;
            if (self.native_redraw_pending) {
                self.native_redraw_pending = false;
                self.cx.needs_redraw = true;
            }
        }
        const size = self.win.getSize();
        const scale = self.win.getScaleFactor();
        self.cx.display_refresh_hz = self.win.getDisplayRefreshRate();
        if (size[0] != self.width or size[1] != self.height or scale != self.scale) {
            self.width = size[0];
            self.height = size[1];
            self.scale = scale;
            self.font_selector.setScaleFactor(scale);
            if (self.painter.fonts) |fonts| fonts.setScaleFactor(scale);
            if (self.font_registry) |registry| registry.setScaleFactor(scale);
            self.cx.setWindowMetrics(@floatFromInt(self.width), @floatFromInt(self.height), scale);
        }
        self.cx.bindFrameClock();
        // Native paint must not execute queued provider/business mutations.
        if (!self.in_native_callback) {
            _ = self.cx.drainDeferredWork(self.cx.deferredBudgetUs());
            @import("windows_accessibility.zig").drain(&self.win);
        }
        // Poll completed tiny readbacks even while rendering is idle. A new
        // measurement requests one frame so adaptive hooks see it; unfinished
        // readbacks neither block the UI nor force continuous GPU redraws.
        if (self.painter.refreshLuminance(self.cx)) self.cx.needs_redraw = true;
        if (!self.idle_skip_frames or self.cx.wantsFrame() or self.win.windowRecordingStatus().active != 0) try self.painter.update(self.cx, &self.win);
    }

    pub fn run(self: *App) !void {
        self.cx.needs_redraw = true;
        try self.frame();
        while (!self.should_quit and !self.win.shouldClose()) {
            const timeout = if (self.cx.wantsFrame()) 0 else if (test_harness.enabled) @min(self.pump_timeout_ms, 16) else self.pump_timeout_ms;
            platform.Window.pumpAppEventsTimeout(timeout);
            self.cx.bindFrameClock();
            if (test_harness.enabled) test_harness.drainCommands();
            const result = try self.sdk.pump(0);
            for (self.sdk.events()) |event| self.processEvent(event);
            if (!result.should_continue or self.should_quit) break;
            try self.frame();
        }
    }

    pub fn processEvent(self: *App, event: system_sdk.events.Event) void {
        if (event.targetWindowId()) |target| {
            if (target != self.windowId()) return;
        }
        // Harness pointer injection calls Cx directly, so dropping the OS pointer here leaves
        // only the test's own input. Without it, a person using the machine during a background
        // run moves the real cursor over the window and its hover state lands in screenshots.
        if (test_harness.enabled and isolateOsPointer() and pointer_isolation.isOsPointerEvent(event)) return;
        switch (event) {
            .quit, .window_close_requested => self.should_quit = true,
            .window_resized, .frame_requested, .system_theme_changed => self.cx.needs_redraw = true,
            .window_focused => |e| {
                self.cx.needs_redraw = true;
                if (!e.focused) self.cx.cancelPointerInteractions(.window_blur);
            },
            .mouse_move => |e| self.cx.handleMouseMoveEx(e.x, e.y, toUiModifiers(e.modifiers)),
            .mouse_button => |e| {
                if (e.cancelled) {
                    self.cx.needs_redraw = true;
                    self.cx.cancelPointerInteractions(.pointer_cancel);
                    return;
                }
                const button: ui.events.MouseButton = switch (e.button) {
                    .left => .left,
                    .right => .right,
                    .middle => .middle,
                    .other => return,
                };
                if (e.pressed) self.cx.handleMouseDownEx(e.x, e.y, button, toUiModifiers(e.modifiers)) else self.cx.handleMouseUpEx(e.x, e.y, button, toUiModifiers(e.modifiers));
            },
            .mouse_wheel => |e| self.cx.handleSdkWheel(e),
            .key => |e| {
                const key = ui.events.KeyCode.fromWindowsVirtualKey(e.keycode);
                if (e.pressed) self.cx.handleKeyDown(key, toUiModifiers(e.modifiers)) else self.cx.handleKeyUp(key, toUiModifiers(e.modifiers));
            },
            .text_input => |e| self.cx.handleTextInput(e.text),
            .ime_preedit => |e| self.cx.handleImePreeditReplace(e.text, e.cursor_utf8_offset, e.replace_start_utf8, e.replace_end_utf8),
            .ime_commit => |e| self.cx.handleImeCommitReplace(e.text, e.replace_start_utf8, e.replace_end_utf8),
            .magnify => |e| self.cx.handleMagnify(e.magnification, e.x, e.y, @fromBackingInt(@intCast(e.phase))),
            .drag => |e| {
                if (e.kind == 4) self.cx.cancelPointerInteractions(.native_handoff);
                self.cx.handlePlatformDrag(e.x, e.y, e.kind, e.paths, e.payload_kind, e.payload_truncated, e.payload_is_untrusted);
            },
            .menu_command => |e| self.cx.handleCommand(e.command_id),
        }
    }
};

pub const MultiWindowConfig = struct { pump_timeout_ms: u32 = 16 };

pub const MultiWindowApp = struct {
    pub const max_windows = window_lifecycle.MAX_WINDOWS;
    allocator: std.mem.Allocator,
    config: MultiWindowConfig,
    windows: std.ArrayList(*App) = .empty,
    lifecycle: window_lifecycle.State = .{},
    iterating: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: MultiWindowConfig) MultiWindowApp {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *MultiWindowApp) void {
        while (self.windows.pop()) |app| app.deinit();
        self.windows.deinit(self.allocator);
        self.lifecycle = .{};
    }

    pub fn windowCount(self: *const MultiWindowApp) usize {
        return self.windows.items.len;
    }
    pub fn nativeWindowCount() u32 {
        return platform.Window.liveWindowCount();
    }
    pub fn window(self: *MultiWindowApp, id: system_sdk.events.WindowId) ?*App {
        for (self.windows.items) |app| if (app.windowId() == id) return app;
        return null;
    }
    pub fn activeWindow(self: *MultiWindowApp) ?*App {
        return self.window(self.lifecycle.active_window_id orelse return null);
    }
    fn reserve(self: *MultiWindowApp) !void {
        if (self.windowCount() >= max_windows) return error.TooManyWindows;
        // Keep the backing slice stable when a native event callback opens a
        // window. The current traversal uses its original length; the new
        // window joins the following frame. Closes remain deferred.
        try self.windows.ensureTotalCapacity(self.allocator, max_windows);
    }
    pub fn createWindow(self: *MultiWindowApp, config: Config) !*App {
        try self.reserve();
        const app = try App.init(self.allocator, config);
        errdefer app.deinit();
        try self.lifecycle.add(app.windowId());
        self.windows.appendAssumeCapacity(app);
        return app;
    }
    pub fn createWindowWith(self: *MultiWindowApp, config: Config, mount_fn: App.MountFn) !*App {
        try self.reserve();
        const app = try App.init(self.allocator, config);
        errdefer {
            app.deinit();
            if (self.activeWindow()) |survivor| survivor.rebindTestHarness();
        }
        try app.mount(mount_fn);
        try self.lifecycle.add(app.windowId());
        self.windows.appendAssumeCapacity(app);
        return app;
    }
    pub fn activateWindow(self: *MultiWindowApp, id: system_sdk.events.WindowId) bool {
        const app = self.window(id) orelse return false;
        self.lifecycle.setFocused(id, true);
        app.activate();
        return true;
    }
    pub fn closeWindow(self: *MultiWindowApp, id: system_sdk.events.WindowId) bool {
        if (!self.lifecycle.requestClose(id)) return false;
        if (!self.iterating) self.applyPendingCloses();
        return true;
    }
    fn applyPendingCloses(self: *MultiWindowApp) void {
        while (self.lifecycle.popPendingClose()) |id| {
            for (self.windows.items, 0..) |app, index| {
                if (app.windowId() != id) continue;
                _ = self.windows.orderedRemove(index);
                _ = self.lifecycle.removed(id);
                app.deinit();
                if (self.activeWindow()) |survivor| survivor.rebindTestHarness();
                break;
            }
        }
    }
    pub fn pump(self: *MultiWindowApp, timeout_ms: u32) !bool {
        if (!self.shouldContinue()) return false;
        platform.Window.pumpAppEventsTimeout(timeout_ms);
        self.iterating = true;
        {
            defer self.iterating = false;
            for (self.windows.items) |app| {
                app.cx.bindFrameClock();
                const result = try app.sdk.pump(0);
                if (!result.should_continue or app.win.shouldClose()) {
                    _ = self.lifecycle.requestClose(app.windowId());
                    continue;
                }
                app.sdk.dispatching = true;
                defer app.sdk.dispatching = false;
                for (app.sdk.events()) |event| {
                    if (event == .quit) {
                        self.quit();
                        break;
                    }
                    if (event == .window_focused) self.lifecycle.setFocused(event.window_focused.window_id, event.window_focused.focused);
                    app.processEvent(event);
                }
                if (app.should_quit) _ = self.lifecycle.requestClose(app.windowId());
            }
        }
        self.applyPendingCloses();
        return self.shouldContinue();
    }
    pub fn frame(self: *MultiWindowApp) !void {
        self.iterating = true;
        {
            defer self.iterating = false;
            for (self.windows.items) |app| try app.frame();
        }
        self.applyPendingCloses();
    }
    pub fn tick(self: *MultiWindowApp) !bool {
        var timeout = self.config.pump_timeout_ms;
        for (self.windows.items) |app| {
            if (app.cx.wantsFrame()) {
                timeout = 0;
                break;
            }
        }
        if (!try self.pump(timeout)) return false;
        if (test_harness.enabled) test_harness.drainCommands();
        if (!self.shouldContinue()) return false;
        try self.frame();
        return self.shouldContinue();
    }
    pub fn run(self: *MultiWindowApp) !void {
        while (try self.tick()) {}
    }
    pub fn quit(self: *MultiWindowApp) void {
        self.lifecycle.requestQuit();
    }
    pub fn shouldContinue(self: *const MultiWindowApp) bool {
        return !self.lifecycle.quit_requested and self.windows.items.len > 0;
    }
};

var g_test_cx: ?*ui.Cx = null;
var g_test_app: ?*App = null;

fn getTestCx() ?*ui.Cx {
    return g_test_cx;
}

fn wakeTestHarness() void {
    // The bounded Windows event loop checks the queue at least every 16 ms.
}

fn resizeWindowForHarness(width: u32, height: u32) bool {
    const app = g_test_app orelse return false;
    app.win.setSize(width, height);
    app.cx.needs_redraw = true;
    return true;
}

fn resetTimingForHarness() void {
    if (g_test_app) |app| app.painter.resetTiming();
}

fn frameStatsForHarness() test_harness.FrameStatsSnapshot {
    const app = g_test_app orelse return .{};
    const st = app.painter.timingStats();
    const retained = app.painter.retainedStats();
    return .{
        .renderer_backend = if (shared_renderer) "d3d12" else "legacy",
        .frame_count = st.frame_count,
        .path_draw_calls = app.painter.path_draw_calls,
        .backdrop_luminance = app.painter.backdrop_luminance orelse -1,
        .retained_hits = retained.hits,
        .retained_misses = retained.misses,
        .retained_partial_repaints = retained.partial,
        .gpu_execute_us = st.last.gpu_execute_us,
        .cpu_frame_us = st.last.cpu_frame_us,
        .total_frame_us = st.last.total_frame_us,
        .layout_us = st.last.layout_us,
        .render_gen_us = st.last.render_gen_us,
        .gpu_encode_us = st.last.gpu_encode_us,
        .wait_for_frame_us = if (shared_renderer) app.painter.state.renderer.last_frame_stats.wait_for_frame_us else null,
        .acquire_texture_us = if (shared_renderer) app.painter.state.renderer.last_frame_stats.acquire_texture_us else null,
        .encode_us = if (shared_renderer) app.painter.state.renderer.last_frame_stats.encode_us else null,
        .flush_us = if (shared_renderer) app.painter.state.renderer.last_frame_stats.flush_us else null,
        .glass_count = if (shared_renderer) app.painter.state.renderer.last_frame_stats.glass_count else 0,
        .glass_us = if (shared_renderer) app.painter.state.renderer.last_frame_stats.glass_us else 0,
        .texture_creates = if (shared_renderer) app.painter.state.renderer.last_frame_stats.texture_creates else 0,
        .render_passes = if (shared_renderer) app.painter.state.renderer.last_frame_stats.render_passes else 0,
        .blit_passes = if (shared_renderer) app.painter.state.renderer.last_frame_stats.blit_passes else 0,
        .pass_native_us = if (shared_renderer) app.painter.state.renderer.last_frame_stats.pass_native_us else 0,
        .gpu_p95_us = st.gpu_p95_us,
        .cpu_p95_us = st.cpu_p95_us,
        .total_p95_us = st.total_p95_us,
        .timing_samples = @intCast(st.timing_samples),
        .cpu_timing_samples = @intCast(st.cpu_timing_samples),
        .gpu_timing_disjoint_samples = st.disjoint_samples,
        .gpu_timing_failed_samples = st.failed_samples,
        .gpu_timing_pending_queries = @intCast(st.pending_queries),
        .gpu_timing_query_supported = switch (st.query_supported) {
            0 => null,
            1 => true,
            else => false,
        },
    };
}

fn captureScreenshotForHarness(path: []const u8) bool {
    // The HTTP worker requests a BMP and converts it to the host's PNG path.
    // Reject other suffixes rather than write BMP bytes under a PNG filename.
    if (!std.mem.endsWith(u8, path, ".bmp")) return false;
    const app = g_test_app orelse return false;
    // Both painters retain the submitted surface in test mode. A screenshot
    // reads that surface without advancing animation or generating a new frame.
    return app.painter.captureBmp(path) catch false;
}

fn toUiModifiers(mods: system_sdk.events.Modifiers) ui.events.Modifiers {
    return .{ .shift = mods.shift, .ctrl = mods.ctrl, .alt = mods.alt, .super = mods.super };
}

fn mapRecordingState(native: platform.Window.WindowRecordingState) test_harness.RecordingState {
    var state: test_harness.RecordingState = .{ .ok = native.ok != 0, .active = native.active != 0, .width = native.width, .height = native.height, .fps = native.fps, .duration_ms = native.duration_ms, .file_size = native.file_size, .frame_count = native.frame_count, .dropped_frames = native.dropped_frames };
    state.setPath(native.pathText());
    state.setError(native.errorText());
    return state;
}
fn startRecordingForHarness(path: []const u8, fps: u32) test_harness.RecordingState {
    if (comptime !shared_renderer) {
        var state: test_harness.RecordingState = .{};
        state.setError("window recording requires the D3D12 renderer");
        return state;
    }
    const app = g_test_app orelse return .{};
    if (shared_renderer) app.painter.flushRecording(&app.win);
    return mapRecordingState(app.win.startWindowRecording(path, fps));
}
fn recordingStatusForHarness() test_harness.RecordingState {
    const app = g_test_app orelse return .{};
    return mapRecordingState(app.win.windowRecordingStatus());
}
fn stopRecordingForHarness() test_harness.RecordingState {
    const app = g_test_app orelse return .{};
    if (shared_renderer) app.painter.flushRecording(&app.win);
    return mapRecordingState(app.win.stopWindowRecording());
}

fn visualQualityForHarness(command: test_harness.VisualQualityCommand) ?[]const u8 {
    if (comptime !shared_renderer) return null;
    const app = g_test_app orelse return null;
    switch (command) {
        .status => {},
        .auto => app.setVisualQuality(.auto),
        .full => app.setVisualQuality(.full),
        .frosted => app.setVisualQuality(.frosted),
        .basic => app.setVisualQuality(.basic),
        .fail_blur => {
            // Test-only fault injection through the same sticky failure state
            // that a failed blur shader compilation sets in production.
            app.painter.state.renderer.persistent_gpu.blur_pipeline_failed = true;
            app.cx.needs_redraw = true;
            if (app.cx.root) |root| root.markRenderDirty();
        },
    }
    return @tagName(app.painter.state.renderer.visual_quality);
}

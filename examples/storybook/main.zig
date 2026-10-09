/// storybook - centralized component showcase with e2e verification.
///
/// Layout: master-detail, left sidebar (component list) and right content panel. A
/// left row click only switches the right panel (no long scrolling page), so e2e
/// always operates on the visible component.
///
/// Architecture:
/// - each component has one WIDGETS entry: { key, title, buildFn }
/// - active signal (current story index) + search signal drive all UI: sidebar
///   selection/filter, breadcrumb, right panel (v.dynamic rebuilds per active)
/// - the window is one declarative ui.view tree, no post-mount node mutations
const std = @import("std");
const ui = @import("ui");
const zenit_app = @import("zenit_app");
const MultiWindowApp = zenit_app.MultiWindowApp;

const Padding = ui.Padding;
const light = ui.theme.modes.light;

const stories = @import("stories.zig");
const S = @import("styles.zig");

const v = ui.view;
const W = ui.widgets;

var g_storybook_cx: ?*ui.Cx = null;
var g_devtools_close_requested = false;
var g_windows_custom_titlebar = false;
/// SIGTERM/SIGINT request a graceful quit so `gpa.deinit()` runs and reports
/// leaks. The e2e runner stops the app with SIGTERM; without this the process
/// died before the leak check and every run was leak-blind.
var g_quit_requested = std.atomic.Value(bool).init(false);

fn onTerminateSignal(_: std.posix.SIG) callconv(.c) void {
    g_quit_requested.store(true, .release);
}

fn installTerminateHandlers() void {
    if (@import("builtin").os.tag == .windows) return;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onTerminateSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
}

fn requestDevtoolsClose(flag: *bool) void {
    flag.* = true;
}

fn mountDevtools(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    cx.setTheme(&ui.theme.modes.light);
    return ui.devtools.mountPanel(cx, g_storybook_cx orelse return error.StorybookTargetMissing, .{
        .title = "Zenit Storybook DevTools",
        .on_close = ui.Cx.handlerFrom(bool, &g_devtools_close_requested, requestDevtoolsClose),
    });
}

// component registry - each item: sidebar title + test_id key (nav.<key> / story.<key>) + story
// builder.
const WidgetSpec = struct {
    key: []const u8,
    title: []const u8,
    build: *const fn (*ui.Scope, *ui.Cx) anyerror!*ui.Node,
    /// content area wrapped in scrollable ScrollArea (default). PaintReplay-like stories that need
    /// 'container outside scroll' turn this off: descendants of scroll container skip legacy
    /// overflow cache, wrapping prevents testing that path.
    scrolls: bool = true,
    /// What the story demonstrates or checks, for whoever reads Storybook: shown above the story
    /// panel, outside `story.<key>` (the website frames that panel's root: notes stay out of its
    /// screenshots and videos).
    note: []const u8 = "",
    /// The story root spans the panel's width; otherwise it hugs its content, centred.
    wide: bool = false,
};

const WIDGETS = [_]WidgetSpec{
    .{ .key = "button", .title = "Button", .build = stories.buildButton },
    .{ .key = "checkbox", .title = "Checkbox", .build = stories.buildCheckbox },
    .{ .key = "switch", .title = "Switch", .build = stories.buildSwitch },
    .{ .key = "radio", .title = "Radio", .build = stories.buildRadio },
    .{ .key = "slider", .title = "Slider", .build = stories.buildSlider },
    .{ .key = "rate", .title = "Rate", .build = stories.buildRate },
    .{ .key = "stepper", .title = "NumberStepper", .build = stories.buildNumberStepper },
    .{ .key = "group", .title = "Group", .build = stories.buildGroup },
    .{ .key = "input", .title = "Input", .build = stories.buildInput },
    .{ .key = "textarea", .title = "Textarea", .build = stories.buildTextarea },
    .{ .key = "editabletext", .title = "EditableText", .build = stories.buildEditableText },
    .{ .key = "select", .title = "Select", .build = stories.buildSelect },
    .{ .key = "combobox", .title = "ComboBox", .build = stories.buildComboBox },
    .{ .key = "tags", .title = "TagsInput", .build = stories.buildTagsInput },
    .{ .key = "upload", .title = "FileUpload", .build = stories.buildFileUpload },
    .{ .key = "datepicker", .title = "DatePicker", .build = stories.buildDatePicker },
    .{ .key = "daterange", .title = "DateRangePicker", .build = stories.buildDateRangePicker },
    .{ .key = "form", .title = "Form", .build = stories.buildForm },
    .{ .key = "formcompose", .title = "Form Composition", .build = @import("form_composition.zig").build },
    .{ .key = "badge", .title = "Badge", .build = stories.buildBadge },
    .{ .key = "tag", .title = "Tag", .build = stories.buildTag },
    .{ .key = "chip", .title = "Chip", .build = stories.buildChip },
    .{ .key = "card", .title = "Card", .build = stories.buildCard },
    .{ .key = "alert", .title = "Alert", .build = stories.buildAlert },
    .{ .key = "progress", .title = "Progress", .build = stories.buildProgress },
    .{ .key = "spinner", .title = "Spinner", .build = stories.buildSpinner },
    .{ .key = "skeleton", .title = "Skeleton", .build = stories.buildSkeleton },
    .{ .key = "timeline", .title = "Timeline", .build = stories.buildTimeline },
    .{ .key = "table", .title = "Table", .build = stories.buildTable },
    .{ .key = "datatable", .title = "DataTable", .build = stories.buildDataTable },
    .{ .key = "tree", .title = "Tree", .build = stories.buildTree },
    .{ .key = "calendar", .title = "Calendar", .build = stories.buildCalendar },
    .{ .key = "markdown", .title = "Markdown", .build = stories.buildMarkdown },
    .{ .key = "icons", .title = "Icons", .build = stories.buildIconGallery, .note = "System icon contract (provider-neutral subset)" },
    .{ .key = "tabs", .title = "Tabs", .build = stories.buildTabs },
    .{ .key = "accordion", .title = "Accordion", .build = stories.buildAccordion },
    .{ .key = "menu", .title = "Menu", .build = stories.buildMenu, .note = "Click the trigger to open the menu" },
    .{ .key = "breadcrumb", .title = "Breadcrumb", .build = stories.buildBreadcrumb },
    .{ .key = "steps", .title = "Steps", .build = stories.buildSteps },
    .{ .key = "notification", .title = "Notification", .build = stories.buildNotification },
    .{ .key = "tooltip", .title = "Tooltip", .build = stories.buildTooltip, .note = "Hover a button to see the tooltip (4 positions)" },
    .{ .key = "popover", .title = "Popover", .build = stories.buildPopover, .note = "Click the button to toggle the popover" },
    .{ .key = "modal", .title = "Modal", .build = stories.buildModal },
    .{ .key = "sheet", .title = "Sheet", .build = stories.buildSheet },
    .{ .key = "zindex", .title = "ZIndex", .build = stories.buildZIndex },
    .{ .key = "divider", .title = "Divider", .build = stories.buildDivider },
    .{ .key = "stack", .title = "Stack", .build = stories.buildStack },
    .{ .key = "layoutbox", .title = "Layout / Box Model", .build = stories.buildLayoutBoxModel },
    .{ .key = "virtuallist", .title = "VirtualList", .build = stories.buildVirtualList },
    .{ .key = "virtuallistdynamic", .title = "VirtualList (Dynamic)", .build = stories.buildVirtualListDynamic },
    .{ .key = "scrollarea", .title = "ScrollArea", .build = stories.buildScrollArea },
    .{ .key = "grid", .title = "Grid", .build = stories.buildGrid },
    .{ .key = "glassbox", .title = "Liquid Glass", .build = stories.buildGlassBox },
    .{ .key = "glasslab", .title = "Glass Lab", .build = stories.buildGlassLab },
    .{ .key = "glasscontrols", .title = "Glass slider & toggle", .build = stories.buildGlassControls, .note = "GlassSlider / GlassToggle: press a knob — it turns into clear Liquid Glass and grows; release restores the white knob" },
    .{ .key = "glasscontrolsios", .title = "iOS slider & switch", .build = stories.buildGlassControlsIos },
    .{ .key = "glasstoolbar", .title = "Glass toolbar", .build = stories.buildGlassToolbar, .note = "GlassToolbar: hover shows a plate, press deepens it, the selected segment keeps one; separators only between unselected segments. Dark title bar: the glass flips to the dark family and the plates turn white" },
    .{ .key = "glassiosbars", .title = "iOS bars & glass buttons", .build = stories.buildGlassIosBars },
    .{ .key = "glasspopover", .title = "Glass popover", .build = stories.buildGlassPopover, .note = "Glass button + .popover: the popover scales from its arrow tip (spring, opacity follows scale); the button does not morph" },
    .{ .key = "glasschrome", .title = "Toolbar over content", .build = stories.buildGlassChrome, .note = "Toolbar over scrolling content: GlassToolbar controls on the measured title-bar edge (content washes toward the window background; no custom blur)" },
    .{ .key = "glassmotion", .title = "Glass Transitions", .build = stories.buildGlassMotion },
    .{ .key = "glasssplit", .title = "Glass Split & Merge", .build = stories.buildGlassSplit },
    .{ .key = "glassunion", .title = "GlassEffectContainer: union", .build = stories.buildGlassUnion, .note = "glassEffectUnion(id:): members sharing an id merge into one shape over their bounding box (Apple sample on top)" },
    .{ .key = "glassadapt", .title = "Glass adaptivity (scroll)", .build = stories.buildGlassAdapt, .note = "Scroll white → black: the 36 pt glass bar flips dark below 48/255 (back above 120); the large panel never flips" },
    .{ .key = "glassconcentric", .title = "Concentric corners", .build = stories.buildGlassConcentric, .note = "ConcentricRectangle: each corner = max(container radius − max(dx, dy), minimum); glass follows the same shape" },
    .{ .key = "glassextension", .title = "Background extension", .build = stories.buildGlassExtension, .note = "backgroundExtensionEffect: mirrored copies fill the leading safe area; only the view's own safe area is blurred" },
    .{ .key = "canvasevents", .title = "CanvasEvents", .build = stories.buildCanvasEvents, .note = "Canvas events: scroll modifiers / magnify / drag / clipboard image" },
    .{ .key = "drag", .title = "Drag", .build = stories.buildDrag, .note = "Drag: ui.interaction.drag primitive (threshold 4px, Escape cancels, arrows nudge when focused)" },
    .{ .key = "multiclick", .title = "Gestures", .build = stories.buildMultiClick, .note = "Gesture arena: tap/double/triple counts + press-and-hold long_press (500ms) + pointer-cancel state" },
    .{ .key = "animctl", .title = "AnimControls", .build = stories.buildAnimCtl, .note = "Animation controls: yoyo replay / timeline reverse / keyframes catch-up / degenerate spring" },
    .{ .key = "vectorpath", .title = "VectorPath", .build = stories.buildVectorPath, .note = "Batched fill_path: adjacent stars (polygon mode)" },
    .{ .key = "blend", .title = "BlendModes", .build = stories.buildBlend, .note = "Blend modes (exact-color e2e targets)" },
    .{ .key = "emoji", .title = "Emoji", .build = stories.buildEmoji, .note = "Color emoji (BGRA atlas page + shader color branch)" },
    .{ .key = "rtl", .title = "RTL", .build = stories.buildRtl, .note = "RTL bidi text (CoreText 已做 bidi，glyph 数组为视觉序)" },
    .{ .key = "wordnav", .title = "WordNav", .build = stories.buildWordNav, .note = "Word navigation: Alt+←/→ jumps whole Greek/Cyrillic words; double-click selects the word; family emoji is one cluster" },
    .{ .key = "viewdsl", .title = "View DSL", .build = @import("view_dsl_story.zig").build },
    .{ .key = "wall", .title = "Component Wall", .build = @import("component_wall.zig").build },
    .{ .key = "glassgroup", .title = "GlassEffectContainer: sampling", .build = stories.buildGlassGroup, .note = "GlassGroup: one capture per container; both rows must match pixel-for-pixel" },
    .{ .key = "glassmerge", .title = "GlassEffectContainer: merge", .build = stories.buildGlassMerge, .note = "GlassMerge: two capsules in a GlassGroup; neck heights must match native GlassEffectContainer" },
    .{ .key = "glasstint", .title = "GlassEffectContainer: tint fusion", .build = stories.buildGlassTintMerge, .note = "Tint fusion in a GlassEffectContainer (spacing 40), white backdrop: bridges stay untinted, tints feather into neighbours and compose where they overlap" },
    .{ .key = "glassislands", .title = "Regression: blur islands", .build = stories.buildGlassIslands, .note = "Two blur+rounded-clip islands: BOTH must show their content", .wide = true },
    .{ .key = "glassappkit", .title = "NSGlassEffectView parameters", .build = stories.buildGlassAppKit },
    .{ .key = "glassidiom", .title = "Glass idiom: macOS / iOS", .build = stories.buildGlassIdiom },
    .{ .key = "glassioslens", .title = "iOS tab lens fixtures", .build = stories.buildGlassIosLens },
    .{ .key = "blendlab", .title = "Blend lab", .build = stories.buildBlendLab, .note = "BlendLab: translucency, group opacity, text, gradients, shadows, edges and scaled images (native_blend_reference.swift geometry)" },
    .{ .key = "glassedge", .title = "Glass at the window edge", .build = stories.buildGlassEdge, .note = "Glass reaching the window edge samples past it (the capture beyond the window is transparent black): the wallpaper's colours must run cleanly to the right and bottom edges under the inspector and the toolbar, with no dark rim." },
    .{ .key = "popoverregress", .title = "Popover regressions", .build = stories.buildPopoverRegressions },
    .{ .key = "paintreplay", .title = "PaintReplay", .build = stories.buildPaintReplay, .scrolls = false },
    .{ .key = "heavytext", .title = "HeavyText", .build = stories.buildHeavyText },
    .{ .key = "textanimjitter", .title = "TextAnimJitter", .build = stories.buildTextAnimJitter },
    .{ .key = "cleanup", .title = "CleanupHooks", .build = stories.buildCleanup },
    .{ .key = "interactionlifecycle", .title = "Interaction Lifecycle", .build = stories.buildInteractionLifecycle },
    .{ .key = "teardownstress", .title = "Lifecycle Stress", .build = stories.buildTeardownStress },
    .{ .key = "secsvg", .title = "Security / SVG", .build = stories.buildSecuritySvg },
    .{ .key = "secopacity", .title = "Security / Opacity", .build = stories.buildSecurityOpacity },
    .{ .key = "sectext", .title = "Security / Text", .build = stories.buildSecurityText },
};

const NavSection = struct {
    start_key: []const u8,
    label: []const u8,
};

/// Sections are anchored by stable story keys instead of numeric offsets, so
/// inserting a component inside a group cannot silently misclassify every
/// section after it.
const NAV_SECTIONS = [_]NavSection{
    .{ .start_key = "button", .label = "ACTIONS" },
    .{ .start_key = "input", .label = "INPUTS" },
    .{ .start_key = "badge", .label = "DATA DISPLAY" },
    .{ .start_key = "tabs", .label = "NAVIGATION" },
    .{ .start_key = "notification", .label = "OVERLAYS" },
    .{ .start_key = "divider", .label = "LAYOUT" },
    .{ .start_key = "glassbox", .label = "LIQUID GLASS" },
    .{ .start_key = "canvasevents", .label = "LABS" },
    .{ .start_key = "glassgroup", .label = "GLASS REGRESSIONS" },
    .{ .start_key = "popoverregress", .label = "REGRESSIONS" },
    .{ .start_key = "secsvg", .label = "SECURITY REGRESSIONS" },
};

const COMPONENT_COUNT_LABEL = std.fmt.comptimePrint("{d} components", .{WIDGETS.len});

/// nav items (canonical order): section titles and story rows. compile-time expand from WIDGETS /
/// NAV_SECTIONS.
const NavEntry = struct {
    /// row: WIDGETS index; section title: null
    widget: ?usize,
    /// section title: WIDGETS index range [first, end) for this group
    first: usize = 0,
    end: usize = 0,
};

const NAV_ENTRIES = blk: {
    @setEvalBranchQuota(20_000);
    var out: [WIDGETS.len + NAV_SECTIONS.len]NavEntry = undefined;
    var n: usize = 0;
    for (WIDGETS, 0..) |_, i| {
        if (isSectionStart(i)) {
            var end = i + 1;
            while (end < WIDGETS.len and !isSectionStart(end)) end += 1;
            out[n] = .{ .widget = null, .first = i, .end = end };
            n += 1;
        }
        out[n] = .{ .widget = i };
        n += 1;
    }
    break :blk out;
};

/// sidebar shared state: current story and search term.
const Nav = struct {
    active: *ui.Signal(usize),
    /// owned text signal: Input on_change slice valid only during callback, copy on assignment.
    query: *ui.Signal([]const u8),
};

fn matches(widget: WidgetSpec, raw_query: []const u8) bool {
    const query = std.mem.trim(u8, raw_query, " \t");
    if (query.len == 0) return true;
    return std.ascii.findIgnoreCase(widget.title, query) != null or
        std.ascii.findIgnoreCase(widget.key, query) != null;
}

fn anyMatch(first: usize, end: usize, query: []const u8) bool {
    for (WIDGETS[first..end]) |w| {
        if (matches(w, query)) return true;
    }
    return false;
}

fn sectionForIndex(index: usize) []const u8 {
    var cursor = @min(index + 1, WIDGETS.len);
    while (cursor > 0) {
        cursor -= 1;
        for (NAV_SECTIONS) |section| {
            if (std.mem.eql(u8, WIDGETS[cursor].key, section.start_key)) return section.label;
        }
    }
    unreachable;
}

fn titleForIndex(index: usize) []const u8 {
    return WIDGETS[index].title;
}

fn isSectionStart(comptime index: usize) bool {
    for (NAV_SECTIONS) |section| {
        if (std.mem.eql(u8, WIDGETS[index].key, section.start_key)) return true;
    }
    return false;
}

/// one nav item. item's own derived state (selected / search match) is memo on item scope: row
/// index is runtime value, inline derive (ui.map) cannot capture.
fn navEntry(p: struct { nav: Nav, entry: NavEntry }, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    const e = p.entry;
    const index = e.widget orelse {
        const has_match = try scope.createMemo(bool, .{ .query = p.nav.query, .first = e.first, .end = e.end }, struct {
            fn f(c: anytype) bool {
                return anyMatch(c.first, c.end, c.query.get());
            }
        }.f);
        return v.render(scope, cx, v.box(.{ .style = S.navSection, .visible = has_match }, .{
            v.text(.{ .style = S.navSectionText }, sectionForIndex(e.first)),
        }));
    };
    const spec = WIDGETS[index];
    const selected = try scope.createMemo(bool, .{ .active = p.nav.active, .index = index }, struct {
        fn f(c: anytype) bool {
            return c.active.get() == c.index;
        }
    }.f);
    const shown = try scope.createMemo(bool, .{ .query = p.nav.query, .index = index }, struct {
        fn f(c: anytype) bool {
            return matches(WIDGETS[c.index], c.query.get());
        }
    }.f);
    const select = try ui.on.bind(scope, .{ .active = p.nav.active, .index = index }, struct {
        fn f(c: anytype) void {
            c.active.set(c.index);
        }
    }.f);
    const parts = S.Nav.of(.{ .selected = selected });
    return v.render(scope, cx, v.row(.{
        .style = parts.root,
        .test_id = nav_ids[index],
        .visible = shown,
        .on_click = select,
    }, .{
        v.text(.{ .style = parts.label }, spec.title),
    }));
}

fn navItem(nav: Nav, entry: NavEntry) v.ComponentOf(navEntry) {
    return v.component(navEntry, .{ .nav = nav, .entry = entry });
}

/// test_id for each row (runtime index -> static string, node borrows).
const nav_ids = blk: {
    var ids: [WIDGETS.len][]const u8 = undefined;
    for (WIDGETS, 0..) |w, i| ids[i] = "nav." ++ w.key;
    break :blk ids;
};

fn noneMatch(query: []const u8) bool {
    return !anyMatch(0, WIDGETS.len, query);
}

fn toggleDevtools(cx: *ui.Cx) void {
    cx.inspector.enabled = !cx.inspector.enabled;
    if (!cx.inspector.enabled) {
        cx.inspector.pick_mode = false;
        cx.inspector.clearSelection();
    }
    cx.needs_redraw = true;
}

/// decorative text (separators etc): draws normally, not exposed to a11y.
const decorative = .{ .style = S.category, .a11y = ui.A11yProps{ .hidden = true } };

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    // 74 inline story builders plus key-anchored section lookup exceed Zig's
    // conservative default comptime branch budget during monomorphization.
    comptime {
        @setEvalBranchQuota(20_000);
    }

    // framework default theme is dark (cx.tokens=&theme.dark). storybook uses light colors
    // throughout, explicitly switch to light so components draw backgrounds (Table/Calendar use
    // cx.tokens) matching light text in story, avoid dark-on-dark.
    cx.setTheme(&ui.theme.modes.light);

    // ZENIT_STORYBOOK_STORY=<key>: startup opens specified story (observe first mount outside
    // harness in normal build).
    const initial_index: usize = blk: {
        // getEnvVarOwned not posix.getenv: storybook builds on Windows too (WTF-16 environment
        // block).
        var env_buf: [128]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&env_buf);
        const want = @import("zenit_environment").getOwned(fba.allocator(), "ZENIT_STORYBOOK_STORY") catch break :blk 0;
        for (WIDGETS, 0..) |w, i| if (std.mem.eql(u8, w.key, want)) break :blk i;
        break :blk 0;
    };
    const nav = Nav{
        .active = try scope.createSignal(usize, initial_index), // default select first
        .query = try scope.createText("", .{}),
    };
    if (zenit_app.test_harness.enabled and @import("builtin").os.tag == .macos) {
        for (WIDGETS, 0..) |spec, index| {
            if (std.mem.eql(u8, spec.key, "emoji"))
                @import("reactive_oom_fixture.zig").install(nav.active, index);
        }
    }

    return v.render(scope, cx, v.row(.{ .style = S.root }, .{
        // left sidebar - landmark: VoiceOver landmark rotor can jump directly between sidebar nav
        // and main content; sidebar becomes one nav unit, no longer interleaved with main area by
        // screen position (verified on real VoiceOver).
        v.col(.{ .style = S.sidebar, .test_id = "sidebar", .a11y = ui.A11yProps{ .role = .navigation, .label = "Component library" } }, .{
            v.row(.{ .style = S.brand }, .{
                v.box(.{ .style = S.logoMark }, .{v.text(.{ .style = S.logoLetter }, "Z")}),
                v.text(.{ .style = S.brandName }, "Zenit Storybook"),
            }),
            v.box(.{ .style = S.searchWrap }, .{
                v.row(.{ .style = S.searchField }, .{
                    v.icon(.{ .style = S.searchIcon, .tint = S.searchIconTint }, ui.system_icons.search),
                    // search box self-draws shell (border / background / icon), embedded Input only
                    // keeps editable text surface.
                    v.attrs(.{ .test_id = "storybook.search", .style = S.searchInput }, W.Input(.{
                        .placeholder = "Search components",
                        .placeholder_color = light.tokens.color.fg_tertiary,
                        .size = .sm,
                        .embedded = true,
                        .on_change = ui.on.assign(nav.query),
                    })),
                }),
            }),
            // nav list in ScrollArea: scrollable when component count exceeds window height (mouse
            // wheel / trackpad). width/height empty -> container grow default, consume remaining
            // height below header. e2e clickTestId uses test harness scroll-into-view (scroll
            // target into view before command), so off-screen rows still clickable, see
            // src/test_harness/command_executor.zig.
            v.with(W.ScrollArea(.{
                .direction = .vertical,
                .padding = .{ .top = 0, .right = 10, .bottom = 12, .left = 10 },
            }), .{
                v.listWith(nav, &NAV_ENTRIES, navItem),
                v.text(.{ .style = S.navEmptyHint, .visible = ui.map(nav.query, noneMatch) }, "No matching components"),
            }),
            v.box(.{ .style = S.sidebarFooter }, .{
                v.text(.{ .style = S.sidebarFooterText }, COMPONENT_COUNT_LABEL),
            }),
        }),

        // right workspace
        v.col(.{ .style = S.workspace, .a11y = ui.A11yProps{ .role = .main } }, .{
            // Windows custom title bar: reserve right side for window buttons.
            v.row(.{ .style = .{ S.toolbar, if (g_windows_custom_titlebar) ui.BoxStyle{ .padding = .{ .right = 160 } } else ui.BoxStyle{} } }, .{
                v.row(.{ .style = S.heading }, .{
                    v.text(.{ .style = S.category }, ui.map(nav.active, sectionForIndex)),
                    v.text(decorative, "/"),
                    v.text(.{ .style = S.title, .test_id = "storybook.title" }, ui.map(nav.active, titleForIndex)),
                }),
                v.row(.{
                    .style = S.devtoolsButton,
                    .test_id = "storybook.devtools",
                    .a11y = ui.A11yProps{ .role = .button, .label = "Open DevTools" },
                    .on_click = ui.on.call(cx, toggleDevtools),
                }, .{v.text(.{ .style = S.devtoolsLabel }, "DevTools  ⌥⌘I")}),
            }),
            // right content panel (unload old, mount new on story change, see renderContent).
            v.dynamic(nav.active, renderContent),
        }),
    }));
}

fn renderContent(index: usize, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    @setEvalBranchQuota(200_000);
    inline for (WIDGETS, 0..) |spec, i| {
        if (i == index) return renderStoryContent(spec, scope, cx);
    }
    unreachable;
}

/// content area: wrapped in vertical ScrollArea by default (scrollable when story exceeds window
/// height; padding on ScrollArea, content moves with scroll); story with scrolls=false goes
/// directly in same-padding-and-background column. test_id='content' for e2e locate.
fn renderStoryContent(comptime spec: WidgetSpec, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    // the note (if any) above the panel; no node at all without one (it would take the gap)
    const body = if (spec.note.len > 0) .{
        v.text(.{ .style = S.storyNote }, spec.note),
        v.component(StoryPanel(spec).build, {}),
    } else .{v.component(StoryPanel(spec).build, {})};
    if (spec.scrolls) return v.render(scope, cx, v.with(W.ScrollArea(.{
        .direction = .vertical,
        .padding = Padding.all(light.tokens.space.space800),
        .background = light.tokens.color.bg_primary,
    }), .{
        v.col(.{ .style = S.contentColumn, .test_id = "content" }, body),
    }));
    return v.render(scope, cx, v.col(.{ .style = S.plainContent, .test_id = "content" }, body));
}

fn StoryPanel(comptime spec: WidgetSpec) type {
    return struct {
        fn build(scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
            return renderStoryPanel(spec, scope, cx);
        }
    };
}

/// story displayed on content canvas, retains separate mount boundary and test marker.
fn renderStoryPanel(comptime spec: WidgetSpec, scope: *ui.Scope, cx: *ui.Cx) !*ui.Node {
    return v.render(scope, cx, v.col(.{ .style = if (spec.wide) S.panel else S.panelCentred, .test_id = "story." ++ spec.key }, .{
        v.component(spec.build, {}),
    }));
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    // Args.toSlice may own several allocations on Windows; the process arena
    // owns the complete argument view on every platform.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var custom_titlebar = false;
    for (args[1..]) |arg| if (std.mem.eql(u8, arg, "--zenit-custom-titlebar")) {
        custom_titlebar = true;
    };
    g_windows_custom_titlebar = custom_titlebar and @import("builtin").os.tag == .windows;
    var application = MultiWindowApp.init(allocator, .{ .pump_timeout_ms = 16 });
    defer application.deinit();

    const storybook = try application.createWindowWith(.{
        .io = init.io,
        .font = .{ .locale = "zh-CN" },
        .window = .{ .width = 1100, .height = 1000, .title = "zenit Storybook", .titlebar = if (custom_titlebar) .custom_inset else .default, .titlebar_drag_right_inset = if (custom_titlebar) 160 else 0 },
        .idle_skip_frames = true,
    }, mountUI);
    const storybook_window_id = storybook.windowId();
    if (zenit_app.test_harness.enabled and @import("builtin").os.tag == .macos)
        @import("atlas_eviction_fixture.zig").install(storybook);
    // BlendLab 32x32 checkerboard (8px squares), same image as native_blend_reference.swift.
    {
        var px: [32 * 32 * 4]u8 = undefined;
        for (0..32) |y| for (0..32) |x| {
            const val: u8 = if (((x / 8) + (y / 8)) % 2 == 0) 0 else 255;
            const o = (y * 32 + x) * 4;
            px[o] = val;
            px[o + 1] = val;
            px[o + 2] = val;
            px[o + 3] = 255;
        };
        stories.g_blend_checker_texture = storybook.renderer.image_renderer.loadTexture(32, 32, &px) catch |err| blk: {
            std.log.warn("BlendLab checker texture: {}", .{err});
            break :blk null;
        };
    }
    g_storybook_cx = storybook.cx;
    defer g_storybook_cx = null;

    installTerminateHandlers();

    var devtools_window_id: ?u64 = null;
    while (try application.tick()) {
        if (g_quit_requested.load(.acquire)) {
            application.quit();
            break;
        }
        const target = application.window(storybook_window_id) orelse {
            application.quit();
            break;
        };

        // Native close and the panel close button both converge here. The
        // target inspector bit is the single source of truth for Cmd+Opt+I,
        // the toolbar button, and the DevTools window lifecycle.
        if (devtools_window_id) |id| {
            if (application.window(id) == null) {
                devtools_window_id = null;
                target.cx.inspector.enabled = false;
                target.rebindTestHarness();
                // DevTools was the last laid-out Cx. Reset text_layout's
                // process bridge to the surviving Storybook font context
                // before a test RPC can render/query the target directly.
                target.cx.layout();
            }
        }
        if (g_devtools_close_requested) {
            g_devtools_close_requested = false;
            target.cx.inspector.enabled = false;
        }

        if (target.cx.inspector.enabled) {
            if (devtools_window_id == null) {
                const devtools = try application.createWindowWith(.{
                    .io = init.io,
                    .window = .{ .width = 980, .height = 720, .title = "Zenit Storybook DevTools" },
                    .idle_skip_frames = true,
                }, mountDevtools);
                devtools_window_id = devtools.windowId();
            }
        } else if (devtools_window_id) |id| {
            _ = application.closeWindow(id);
            devtools_window_id = null;
            target.rebindTestHarness();
            target.cx.layout();
        }
    }
}

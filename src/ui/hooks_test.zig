//! Unit tests for public UI hooks.
//!
//! Kept in a dedicated test module so the production hooks module remains a
//! focused implementation surface. src/ui/ui.zig imports this file explicitly.

const std = @import("std");
const core = @import("core.zig");
const hooks = @import("hooks.zig");
const Cx = core.Cx;
const Scope = core.Scope;
const Color = core.Color;
const useHover = hooks.useHover;
const useHoverHighlight = hooks.useHoverHighlight;
const onMount = hooks.onMount;
const onCleanup = hooks.onCleanup;
const useAnimatedBackground = hooks.useAnimatedBackground;
const AnimBgState = hooks.AnimBgState;
const invalidateSubtreeHookState = hooks.invalidateSubtreeHookState;
const ToggleState = hooks.ToggleState;
const useFocusRing = hooks.useFocusRing;
const FocusRingAnimState = hooks.FocusRingAnimState;

test "removeAllChildren cleanup reentry preserves siblings and World links" {
    const Mode = enum { self_detach, sibling_detach, reparent, recursive_clear, reorder };
    const Probe = struct {
        cx: *Cx,
        parent: *core.Node,
        destination: *core.Node,
        nodes: [3]*core.Node,
        calls: [3]u32 = .{ 0, 0, 0 },
        mode: Mode,
        fn first(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.calls[0] += 1;
            switch (p.mode) {
                .self_detach => p.cx.detachChild(p.parent, p.nodes[0]),
                .sibling_detach => p.cx.detachChild(p.parent, p.nodes[1]),
                .reparent => p.destination.appendChild(p.cx.allocator, p.nodes[0]) catch unreachable,
                .recursive_clear => p.parent.removeAllChildren(),
                .reorder => {},
            }
        }
        fn second(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.calls[1] += 1;
            if (p.mode == .reorder and p.nodes[0].parent == p.parent) {
                // B stays at index 1 and length stays 3, but unvisited C moves
                // behind the traversal cursor. Slot/length checks miss it.
                p.parent.replaceChildOrder(p.cx.allocator, &.{ p.nodes[2], p.nodes[1], p.nodes[0] }) catch unreachable;
            }
        }
        fn third(raw: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(raw));
            p.calls[2] += 1;
        }
    };
    for ([_]bool{ false, true }) |nested| {
        for (std.enums.values(Mode)) |mode| {
            const cx = try Cx.init(std.testing.allocator, std.testing.io);
            defer cx.deinit();
            const root = try core.box(cx, .{}, .{});
            cx.root = root;
            const parent = try core.box(cx, .{}, .{});
            const destination = try core.box(cx, .{}, .{});
            try root.appendChild(cx.allocator, parent);
            try root.appendChild(cx.allocator, destination);
            var outer: ?*core.Node = null;
            if (nested) {
                outer = try core.box(cx, .{}, .{});
                try root.appendChild(cx.allocator, outer.?);
                try outer.?.appendChild(cx.allocator, parent);
            }
            var nodes: [3]*core.Node = undefined;
            for (&nodes) |*slot| {
                slot.* = try core.box(cx, .{}, .{});
                try parent.appendChild(cx.allocator, slot.*);
                slot.*.frame_state.state_bits.flags.is_mounted = true;
            }
            var probe = Probe{ .cx = cx, .parent = parent, .destination = destination, .nodes = nodes, .mode = mode };
            onCleanup(nodes[0], Cx.simpleHandler(Probe.first, &probe));
            onCleanup(nodes[1], Cx.simpleHandler(Probe.second, &probe));
            onCleanup(nodes[2], Cx.simpleHandler(Probe.third, &probe));
            (outer orelse parent).removeAllChildren();
            try std.testing.expectEqualSlices(u32, &.{ 1, 1, 1 }, &probe.calls);
            if (nested) {
                try std.testing.expect(parent.parent == null);
                // Detaching a subtree cleans descendants but retains their links.
                parent.removeAllChildren();
            }
            try std.testing.expectEqual(@as(usize, 0), parent.children.items.len);
            const parent_eid = core.world.ElementId.fromRaw(parent.element_id_raw);
            try std.testing.expectEqual(@as(u32, 0), cx.world.elements.childCount(parent_eid));
            for (nodes, 0..) |node, i| {
                const expected_parent: ?*core.Node = if (mode == .reparent and i == 0) destination else null;
                try std.testing.expect(node.parent == expected_parent);
                const links = cx.world.elements.links(core.world.ElementId.fromRaw(node.element_id_raw)).?;
                if (expected_parent) |p| {
                    try std.testing.expect(links.parent.eql(core.world.ElementId.fromRaw(p.element_id_raw)));
                } else {
                    try std.testing.expect(links.parent.isNull());
                    cx.freeNode(node);
                }
            }
            if (nested) cx.freeNode(parent);
        }
    }
}

test "useHover: basic" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(std.testing.allocator, node);

    const is_hovered = try useHover(scope, node);

    // initial state
    try std.testing.expect(!is_hovered.get());

    // simulate hover
    node.behavior.events.on_hover.?.invoke();
    try std.testing.expect(is_hovered.get());

    // simulate leave
    node.behavior.events.on_leave.?.invoke();
    try std.testing.expect(!is_hovered.get());
}

test "useHoverHighlight: border_color with animation" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const container = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    const inner = try box(ctx, .{
        .width = .{ .px = 80 },
        .height = .{ .px = 30 },
        .border = .{ .width = 1, .color = t.tokens.color.checkbox_border },
    }, .{});
    try root.appendChild(std.testing.allocator, container);
    try container.appendChild(std.testing.allocator, inner);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    const render_engine = @import("core/render_engine/mod.zig");
    var now_ms: f64 = 0;

    _ = try useHoverHighlight(scope, container, inner, .border_color, t.tokens.color.checkbox_border, t.tokens.color.accent, .{});

    // initial: normal color
    try std.testing.expect(Color.eql(inner.style.border.color, t.tokens.color.checkbox_border));

    // hover -> animation triggered, after enough ticks should converge to accent color. note:
    // setTarget uses render_engine.current_frame_time_ms as animation start (hooks.zig:609), so
    // must **set frame clock to current value first then invoke**, else start at 0 but ticks from
    // 16ms, progress misaligned.
    render_engine.current_frame_time_ms = now_ms;
    render_engine.current_frame_dt_ms = 16.0;
    container.behavior.events.on_hover.?.invoke();
    for (0..30) |_| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        render_engine.current_frame_dt_ms = 16.0;
        for (inner.meta.per_frame.hooks.before_render.hooks[0..inner.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(inner);
        }
    }
    try std.testing.expect(Color.eql(inner.style.border.color, t.tokens.color.accent));

    // leave -> after enough frames restore normal color (align frame clock first too)
    render_engine.current_frame_time_ms = now_ms;
    container.behavior.events.on_leave.?.invoke();
    for (0..30) |_| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        render_engine.current_frame_dt_ms = 16.0;
        for (inner.meta.per_frame.hooks.before_render.hooks[0..inner.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(inner);
        }
    }
    try std.testing.expect(Color.eql(inner.style.border.color, t.tokens.color.checkbox_border));
}

test "onMount: triggered after layout" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const child = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(std.testing.allocator, child);

    var mounted = false;
    onMount(child, core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const ptr: *bool = @ptrCast(@alignCast(c));
            ptr.* = true;
        }
    }.handler, &mounted));

    // doesn't trigger before layout
    try std.testing.expect(!mounted);
    try std.testing.expect(!child.frame_state.state_bits.flags.is_mounted);

    // triggers after layout
    ctx.layout();
    try std.testing.expect(mounted);
    try std.testing.expect(child.frame_state.state_bits.flags.is_mounted);

    // re-layout doesn't trigger again
    mounted = false;
    root.markLayoutDirty();
    ctx.layout();
    try std.testing.expect(!mounted); // not duplicate
}

test "onCleanup: triggered on removeChild" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const child = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(std.testing.allocator, child);

    // counter not bool: double-trigger's second write true has no effect, history missed on_cleanup
    // second invoke on detachChild -> freeNode chain (refcount underflow bug)
    var clean_count: u32 = 0;
    onCleanup(child, core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const ptr: *u32 = @ptrCast(@alignCast(c));
            ptr.* += 1;
        }
    }.handler, &clean_count));

    // layout first to mount
    ctx.layout();
    try std.testing.expect(child.frame_state.state_bits.flags.is_mounted);
    try std.testing.expectEqual(@as(u32, 0), clean_count);

    // remove triggers cleanup
    ctx.detachChild(root, child);
    try std.testing.expectEqual(@as(u32, 1), clean_count);
    try std.testing.expect(!child.frame_state.state_bits.flags.is_mounted);

    // manually free removed node (not in tree, ctx.deinit won't free). freeNode must not trigger
    // on_cleanup again, one-time consume.
    ctx.freeNode(child);
    try std.testing.expectEqual(@as(u32, 1), clean_count);
}

test "onCleanup: recursive for nested children" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const parent_node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 80 } }, .{});
    const child_node = try box(ctx, .{ .width = .{ .px = 50 }, .height = .{ .px = 50 } }, .{});
    try root.appendChild(std.testing.allocator, parent_node);
    try parent_node.appendChild(std.testing.allocator, child_node);

    var parent_clean_count: u32 = 0;
    var child_clean_count: u32 = 0;
    onCleanup(parent_node, core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const ptr: *u32 = @ptrCast(@alignCast(c));
            ptr.* += 1;
        }
    }.handler, &parent_clean_count));
    onCleanup(child_node, core.Cx.simpleHandler(struct {
        fn handler(c: *anyopaque) void {
            const ptr: *u32 = @ptrCast(@alignCast(c));
            ptr.* += 1;
        }
    }.handler, &child_clean_count));

    ctx.layout();

    // removing parent_node should also trigger child cleanup
    ctx.detachChild(root, parent_node);
    try std.testing.expectEqual(@as(u32, 1), parent_clean_count);
    try std.testing.expectEqual(@as(u32, 1), child_clean_count);

    // manually free removed node; subtree nodes' on_cleanup must not trigger twice
    ctx.freeNode(parent_node);
    try std.testing.expectEqual(@as(u32, 1), parent_clean_count);
    try std.testing.expectEqual(@as(u32, 1), child_clean_count);
}

test "useAnimatedBackground: creates state and hover signal" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.tokens.color.accent }, .{});
    try root.appendChild(std.testing.allocator, node);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const is_hovered = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.tokens.color.accent,
        .hover = t.tokens.color.accent_hover,
    });

    // initial state
    try std.testing.expect(!is_hovered.get());
    try std.testing.expect(node.meta.per_frame.hooks.before_render.main != null or node.meta.per_frame.hooks.before_render.count > 0);

    // hover -> set Signal
    node.behavior.events.on_hover.?.invoke();
    try std.testing.expect(is_hovered.get());
}

test "useAnimatedBackground: normal override survives recipe color refresh" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    ctx.root = node;
    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();
    _ = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.tokens.color.accent,
        .hover = t.tokens.color.accent_hover,
    });

    const state: *AnimBgState = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.animated_bg_state.?));
    const override = Color.hex(0x123456);
    const refreshed_recipe = Color.hex(0x654321);
    state.setNormalOverride(override);
    state.setColors(refreshed_recipe, t.tokens.color.bg_hover);
    try std.testing.expect(Color.eql(state.normal_bg, override));
    try std.testing.expect(Color.eql(state.recipe_normal_bg, refreshed_recipe));

    state.setNormalOverride(null);
    try std.testing.expect(Color.eql(state.normal_bg, refreshed_recipe));
}

test "useAnimatedBackground: uses dedicated node slot" {
    const box = core.box;
    const render_engine = @import("core/render_engine/mod.zig");
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.tokens.color.accent }, .{});
    try root.appendChild(std.testing.allocator, node);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    _ = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.tokens.color.accent,
        .hover = t.tokens.color.accent_hover,
    });

    var dummy: u8 = 0;
    node.meta.per_frame.hooks.slots.anim_state = @ptrCast(&dummy);
    node.behavior.events.on_hover.?.invoke();

    var now_ms: f64 = 0;
    for (0..30) |_| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        render_engine.current_frame_dt_ms = 16.0;
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }

    try std.testing.expect(node.meta.per_frame.hooks.slots.anim_state == @as(?*anyopaque, @ptrCast(&dummy)));
    try std.testing.expect(node.meta.per_frame.hooks.slots.animated_bg_state != null);
}

test "useAnimatedBackground: scope dispose removes hook state" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.tokens.color.accent }, .{});
    try root.appendChild(std.testing.allocator, node);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    _ = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.tokens.color.accent,
        .hover = t.tokens.color.accent_hover,
    });

    try std.testing.expect(node.meta.per_frame.hooks.slots.animated_bg_state != null);
    try std.testing.expect(node.meta.per_frame.hooks.before_render.count > 0);

    scope.dispose();

    try std.testing.expect(node.meta.per_frame.hooks.slots.animated_bg_state == null);
    try std.testing.expectEqual(@as(u8, 0), node.meta.per_frame.hooks.before_render.count);
}

test "useAnimatedBackground: beforeRender clears stale hover state from detached interaction" {
    const box = core.box;
    const render_engine = @import("core/render_engine/mod.zig");
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.tokens.color.accent }, .{});
    try root.appendChild(std.testing.allocator, node);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const is_hovered = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.tokens.color.accent,
        .hover = t.tokens.color.accent_hover,
    });

    node.behavior.events.on_hover.?.invoke();
    ctx.hovered_node = null;

    var now_ms: f64 = 0;
    for (0..30) |_| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }

    try std.testing.expect(!is_hovered.get());
    try std.testing.expect(Color.eql(node.getBackground(), t.tokens.color.accent));
}

test "useAnimatedBackground: beforeRender reacts to pressed state release without hover signal change" {
    const box = core.box;
    const render_engine = @import("core/render_engine/mod.zig");
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.tokens.color.accent }, .{});
    try root.appendChild(std.testing.allocator, node);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    _ = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.tokens.color.accent,
        .hover = t.tokens.color.accent_hover,
        .pressed = t.tokens.color.bg_active,
    });

    node.behavior.events.on_hover.?.invoke();
    ctx.hovered_node = node;
    ctx.pressed_node = node;

    var now_ms: f64 = 0;
    for (0..30) |_| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }
    try std.testing.expect(Color.eql(node.getBackground(), t.tokens.color.bg_active));

    ctx.pressed_node = null;
    for (0..30) |_| {
        now_ms += 16.0;
        render_engine.current_frame_time_ms = now_ms;
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }

    try std.testing.expect(Color.eql(node.getBackground(), t.tokens.color.accent_hover));
}

test "invalidateSubtreeHookState detaches hook back-pointers before scope dispose" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.tokens.color.accent }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    _ = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.tokens.color.accent,
        .hover = t.tokens.color.accent_hover,
    });
    try useFocusRing(scope, ctx, node, .{});

    const anim_state: *AnimBgState = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.animated_bg_state.?));
    const ring_state: *FocusRingAnimState = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.focus_ring_anim.?));
    try std.testing.expect(anim_state.node == node);
    try std.testing.expect(ring_state.node == node);

    invalidateSubtreeHookState(node);

    try std.testing.expect(anim_state.node == null);
    try std.testing.expect(ring_state.node == null);

    scope.dispose();
    try std.testing.expect(node.meta.per_frame.hooks.slots.animated_bg_state == null);
    try std.testing.expect(node.meta.per_frame.hooks.slots.focus_ring_anim == null);
}

test "invalidateSubtreeHookState unhooks focus-ring handlers so blur after scope dispose is safe" {
    // reproduce Notification in-place convert: invalidate hook, dispose scope first, then unlink
    // while focus still on node (clearFocus -> on_blur). pre-fix on_blur reads/writes FocusRingCtx
    // / signal freed with scope.
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;
    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    const Prev = struct {
        var blurs: u32 = 0;
        fn onBlur(_: *anyopaque) void {
            blurs += 1;
        }
    };
    Prev.blurs = 0;
    var dummy: u8 = 0;
    node.behavior.events.on_blur = Cx.simpleHandler(Prev.onBlur, &dummy);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    try useFocusRing(scope, ctx, node, .{});
    ctx.focus_manager.setFocus(node);

    invalidateSubtreeHookState(node);
    // focus ring handler removed, restore original handler
    try std.testing.expect(node.behavior.events.on_focus == null);
    try std.testing.expect(node.behavior.events.on_blur.?.callback == &Prev.onBlur);
    scope.dispose();
    ctx.detachChildRetained(root, node); // clearFocus -> on_blur: only call original handler
    try std.testing.expectEqual(@as(u32, 1), Prev.blurs);
    ctx.freeNode(node);
}

test "freeNode detaches hook back-pointers for nodes owned by external scope" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const parent = try box(ctx, .{ .width = .{ .px = 120 }, .height = .{ .px = 80 } }, .{});
    try root.appendChild(std.testing.allocator, parent);

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 }, .background = t.tokens.color.accent }, .{});
    try parent.appendChild(std.testing.allocator, node);

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    var scope_disposed = false;
    defer if (!scope_disposed) scope.dispose();

    _ = try useAnimatedBackground(scope, ctx, node, .{
        .normal = t.tokens.color.accent,
        .hover = t.tokens.color.accent_hover,
    });

    const anim_state: *AnimBgState = @ptrCast(@alignCast(node.meta.per_frame.hooks.slots.animated_bg_state.?));
    try std.testing.expect(anim_state.node == node);

    ctx.detachChild(parent, node);
    ctx.freeNode(node);

    try std.testing.expect(anim_state.node == null);

    scope.dispose();
    scope_disposed = true;
}

test "useToggle: click toggles state" {
    var state = ToggleState{ .checked = false };

    try std.testing.expect(!state.checked);
    state.toggle();
    try std.testing.expect(state.checked);
    state.toggle();
    try std.testing.expect(!state.checked);
}

test "useToggle: disabled prevents toggle" {
    var state = ToggleState{ .checked = false, .disabled = true };
    state.toggle();
    try std.testing.expect(!state.checked);
}

test "useToggle: callback fires" {
    const Ctx = struct {
        last_value: bool = false,
        count: u32 = 0,
    };
    var cb_ctx = Ctx{};

    var state = ToggleState{
        .checked = false,
        .on_change = core.Cx.boolHandlerFrom(Ctx, &cb_ctx, struct {
            fn handler(c: *Ctx, new_val: bool) void {
                c.last_value = new_val;
                c.count += 1;
            }
        }.handler),
    };

    state.toggle();
    try std.testing.expect(cb_ctx.last_value);
    try std.testing.expectEqual(@as(u32, 1), cb_ctx.count);

    state.toggle();
    try std.testing.expect(!cb_ctx.last_value);
    try std.testing.expectEqual(@as(u32, 2), cb_ctx.count);
}

test "useFocusRing: tab focus shows outline with animation, blur fades out" {
    const box = core.box;
    const t = &core.theme.dark;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    try useFocusRing(scope, ctx, node, .{});

    // initial: no outline
    try std.testing.expect(node.style.outline() == null);

    // Tab focus -> after enough frames outline appears (opacity -> 1.0)
    ctx.focus_manager.last_focus_reason = .tab;
    node.behavior.events.on_focus.?.invoke();
    for (0..30) |_| {
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }
    try std.testing.expect(node.style.outline() != null);
    // outline color alpha should be close to focus_ring original alpha
    try std.testing.expectEqual(@as(f32, 1.5), node.style.outline().?.width);
    try std.testing.expectEqual(@as(f32, 2), node.style.outline().?.offset);
    // color should be close to focus_ring (alpha may be identical due to opacity=1.0)
    try std.testing.expect(Color.eql(node.style.outline().?.color, t.tokens.color.focus_ring));

    // blur -> after enough frames outline disappears (opacity -> 0.0)
    node.behavior.events.on_blur.?.invoke();
    for (0..30) |_| {
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }
    try std.testing.expect(node.style.outline() == null);
}

test "useFocusRing: click focus does NOT show outline" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    try useFocusRing(scope, ctx, node, .{});

    // mouse click focus -> outline still not shown after tick
    ctx.focus_manager.last_focus_reason = .click;
    node.behavior.events.on_focus.?.invoke();
    for (0..30) |_| {
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }
    try std.testing.expect(node.style.outline() == null);
}

test "useFocusRing: focused input scrolled out of ScrollArea does not steal clicks" {
    // spec $9.2 item 14 (appendix A probe 3 component version). useFocusRing on focus-visible
    // raises control to z_index=1 (over siblings). old impl z>0 cleared ancestor clip chain, got
    // global stacking_z: control scrolled outside ScrollArea viewport, pixels clipped, yet stole
    // header outside-viewport clicks.
    const box = core.box;
    const scroll_area = @import("components/scroll_area/mod.zig");
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();
    ctx.setViewport(300, 300);

    const root = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 300 }, .direction = .column }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const header = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 100 } }, .{});
    header.setFocusable(true);
    try root.appendChild(std.testing.allocator, header);

    const area = try scroll_area.ScrollArea(.{ .width = 300, .height = 200, .content_height = 600 }).mount(scope, ctx);
    try root.appendChild(std.testing.allocator, area.container);

    const lead = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 150 } }, .{});
    try area.content.appendChild(std.testing.allocator, lead);
    const field = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 40 } }, .{});
    field.setFocusable(true);
    try area.content.appendChild(std.testing.allocator, field);
    const tail = try box(ctx, .{ .width = .{ .px = 300 }, .height = .{ .px = 410 } }, .{});
    try area.content.appendChild(std.testing.allocator, tail);

    try useFocusRing(scope, ctx, field, .{});

    ctx.layout();
    _ = ctx.render();

    // Tab focus -> focus-visible -> z_index raised to 1.
    ctx.focus_manager.last_focus_reason = .tab;
    field.behavior.events.on_focus.?.invoke();
    try std.testing.expectEqual(@as(i16, 1), field.style.z_index());
    ctx.frame_time_ms += 16;
    ctx.layout();
    _ = ctx.render();

    // not scrolled: field in viewport (world y = 100+150 = 250..290), hittable.
    try std.testing.expectEqual(field, ctx.hitTest(20, 260).?);

    // scroll 200: field world y = 50..90, entire above viewport (y >= 100), in header area.
    scroll_area.setScrollY(area.state, area.content, 200);
    ctx.frame_time_ms += 16;
    ctx.layout();
    _ = ctx.render();
    try std.testing.expectApproxEqAbs(@as(f32, 50), field.globalRect().y, 0.5);
    try std.testing.expectEqual(@as(i16, 1), field.style.z_index());

    // header area outside viewport must hit header, not clipped-invisible field.
    try std.testing.expectEqual(header, ctx.hitTest(20, 60).?);
}

test "useFocusRing: custom config with tab" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    defer scope.dispose();

    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    try useFocusRing(scope, ctx, node, .{
        .color = Color.hex(0xff0000),
        .width = 2,
        .offset = 3,
    });

    ctx.focus_manager.last_focus_reason = .tab;
    node.behavior.events.on_focus.?.invoke();
    // tick enough frames for animation convergence
    for (0..30) |_| {
        for (node.meta.per_frame.hooks.before_render.hooks[0..node.meta.per_frame.hooks.before_render.count]) |cb_opt| {
            if (cb_opt) |cb| cb(node);
        }
    }
    const out = node.style.outline().?;
    try std.testing.expect(Color.eql(out.color, Color.hex(0xff0000)));
    try std.testing.expectEqual(@as(f32, 2), out.width);
    try std.testing.expectEqual(@as(f32, 3), out.offset);
}

test "useFocusRing: scope dispose removes hook state" {
    const box = core.box;
    var ctx = try Cx.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const root = try box(ctx, .{ .width = .{ .px = 200 }, .height = .{ .px = 100 } }, .{});
    ctx.root = root;

    const scope = try Scope.init(std.testing.allocator, null, ctx.owner);
    const node = try box(ctx, .{ .width = .{ .px = 100 }, .height = .{ .px = 50 } }, .{});
    node.setFocusable(true);
    try root.appendChild(std.testing.allocator, node);

    try useFocusRing(scope, ctx, node, .{});
    try std.testing.expect(node.meta.per_frame.hooks.slots.focus_ring_anim != null);
    try std.testing.expect(node.meta.per_frame.hooks.before_render.count > 0);

    scope.dispose();

    try std.testing.expect(node.meta.per_frame.hooks.slots.focus_ring_anim == null);
    try std.testing.expectEqual(@as(u8, 0), node.meta.per_frame.hooks.before_render.count);
}

test "hover subscriptions detach independently and survive callback disposal" {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const a = try scope.childScope();
    const b = try scope.childScope();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    _ = try useHover(a, node);
    const second = try useHover(b, node);
    a.dispose(); // oldest listener first; newer listener stays wired
    try std.testing.expectEqual(@as(u8, 1), node.meta.ownership.debug_slots.signal_count);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(second)), node.meta.ownership.debug_slots.signals[0].?.ptr);
    node.behavior.events.on_hover.?.invoke();
    try std.testing.expect(second.peek());
    b.dispose();
    try std.testing.expectEqual(@as(u8, 0), node.meta.ownership.debug_slots.signal_count);
    try std.testing.expect(node.behavior.events.on_hover == null);
    const c = try scope.childScope();
    _ = try useHover(c, node);
    const Callback = struct {
        scope: ?*Scope,
        node: *core.Node,
        calls: usize = 0,
        fn remove(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.scope) |child| {
                self.scope = null;
                child.dispose();
                // Cleanup is deferred. A reentrant event must skip pending scopes.
                self.node.behavior.events.on_hover.?.invoke();
            }
        }
    };
    const callback = try scope.createState(Callback, .{ .scope = c, .node = node });
    hooks.setHoverHandler(node, true, Cx.simpleHandler(Callback.remove, callback));
    node.behavior.events.on_hover.?.invoke();
    try std.testing.expectEqual(@as(usize, 1), callback.calls);
    try std.testing.expect(node.meta.per_frame.hooks.slots.hover_listeners == null);
    try std.testing.expectEqual(@as(u8, 0), node.meta.ownership.debug_slots.signal_count);
    node.behavior.events.on_hover = null;
}

test "hover handler replacement preserves subscriptions and cleanup preserves a later writer" {
    const cx = try Cx.init(std.testing.allocator, std.testing.io);
    defer cx.deinit();
    const scope = try Scope.init(std.testing.allocator, null, cx.owner);
    defer scope.dispose();
    const child = try scope.childScope();
    const node = try core.box(cx, .{}, .{});
    cx.root = node;
    const hover = try useHover(child, node);
    const Callback = struct {
        fn run(raw: *anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(raw));
            count.* += 1;
        }
    };
    var calls: usize = 0;
    const callback = Cx.simpleHandler(Callback.run, &calls);
    hooks.setHoverHandler(node, true, callback);
    try std.testing.expect(hooks.hoverHandlersIntact(node));
    node.behavior.events.on_hover.?.invoke();
    try std.testing.expect(hover.peek());
    try std.testing.expectEqual(@as(usize, 1), calls);
    // Deliberate contract violation: detected before native dispatch, but cleanup
    // still must not clobber the later callback in builds without assertions.
    node.behavior.events.on_hover = callback;
    try std.testing.expect(!hooks.hoverHandlersIntact(node));
    child.dispose();
    node.behavior.events.on_hover.?.invoke();
    try std.testing.expectEqual(@as(usize, 2), calls);
    try std.testing.expect(node.behavior.events.on_leave == null);
}

//! Cx -> World table sync: node hook into World (ElementTag mapping), layerize,
//! layout / paint / interaction 3-table per-frame sync, layout shadow-sync completeness audit.

const std = @import("std");
const core = @import("../core.zig");
const Cx = core.Cx;
const ComputedRect = core.ComputedRect;
const ElementTag = core.ElementTag;
const Node = core.Node;
const interaction_table = core.interaction_table;
const layerize_mod = core.layerize_mod;
const paint_table = core.paint_table;
const render_engine = core.render_engine;
const world = core.world;

/// Node.tag (UI side) -> ElementTable.ElementTag (SoA side) mapping.
/// Two enums uncoupled: UI side component-level (box/button/scroll/list/...),
/// SoA side render categories (container/text/image/input/component/...).
pub fn nodeTagToWorldTag(t: ElementTag) world.ElementTag {
    return switch (t) {
        .box, .scroll, .list, .spacer, .anchor => .container,
        .text => .text,
        .image => .image,
        .input, .button => .input,
        .custom => .component,
    };
}

pub fn linkNodeToWorld(self: *Cx, node: *Node) void {
    if (node.element_id_raw != 0xFFFFFFFF) return; // Already registered, idempotent
    const eid = self.world.createElement(.{
        .tag = nodeTagToWorldTag(node.tag),
        .key = node.id,
    }) catch return;
    node.element_id_raw = eid.raw();
}

/// Frame start: layerize, group World.elements into LayerTree.
/// Returns layer count (includes root).
///
/// Auto-collects PromotionHint from World.interaction; scroll containers
/// are auto-promoted to their own layer. No caller hints needed.
/// PaintTable.bounds primary + LayoutTable.rect fallback.
fn paintChunkBoundsOrLayoutFallback(w: *world.World, eid: world.ElementId) paint_table.Bounds {
    if (w.paint.get(eid)) |chunk| {
        if (!chunk.bounds.isEmpty()) return chunk.bounds;
    }
    if (w.layout.rect(eid)) |r| {
        return paint_table.Bounds{
            .min_x = r.x,
            .min_y = r.y,
            .max_x = r.x + r.width,
            .max_y = r.y + r.height,
        };
    }
    return paint_table.Bounds{};
}

pub fn layerizeFrame(self: *Cx, extra_hints: []const layerize_mod.LayerizeInput) u32 {
    // Frame start: clear layer damage state
    self.layer_tree.beginFrame();

    // Auto-collect promotion hints from InteractionTable (scroll containers etc)
    var collected = @as(std.ArrayList(layerize_mod.LayerizeInput), .empty);
    defer collected.deinit(self.allocator);

    var iter = self.world.interaction.data.iterator();
    while (iter.next()) |entry| {
        const eid = world.ElementId.fromRaw(entry.key_ptr.*);
        const data = entry.value_ptr.*;
        // scroll_id valid -> promotion hint = scroll container
        if (data.scroll_id != std.math.maxInt(u32)) {
            // Take chunk bounds from PaintTable (shadow-sync ready).
            const bounds = paintChunkBoundsOrLayoutFallback(&self.world, eid);
            collected.append(self.allocator, .{
                .element = eid,
                .hint = .{ .is_scroll_container = true },
                .world_bounds = bounds,
            }) catch continue;
        }
    }

    // v0.5-P3 Stage 3-3 Phase 4 (session 38): also promote elements with non-root effect via
    // PaintChunk.property_state.effect_id (opacity layer / backdrop_blur etc).
    // Stage 5 deletes deferred file key dependency: layerize no longer listens to InteractionTable
    // alone,
    // truly consumes PaintTable 4-table SoT.
    for (self.world.paint.chunks.items, 0..) |chunk, idx| {
        const effect_id = chunk.property_state.effect_id;
        if (effect_id == std.math.maxInt(u32)) continue;
        if (effect_id >= self.property_tree.effects.items.len) continue;
        const effect = self.property_tree.effects.items[effect_id];
        // Only promote effects truly needing offscreen (opacity layer / backdrop blur)
        if (!effect.requires_offscreen) continue;

        const eid_idx: u24 = @intCast(idx);
        const eid: world.ElementId = .{
            .index = eid_idx,
            .generation = self.world.elements.generations.items[eid_idx],
        };
        // Skip already added by scroll_id, prevent duplicate
        var already_collected = false;
        for (collected.items) |c| {
            if (c.element.eql(eid)) {
                already_collected = true;
                break;
            }
        }
        if (already_collected) continue;

        const hint: layerize_mod.PromotionHint = switch (effect.kind) {
            .opacity, .composited_group => .{ .opacity_animating = true },
            .backdrop_blur => .{ .has_filter = true },
            else => layerize_mod.PromotionHint.NONE,
        };
        if (!hint.shouldPromote() and !hint.has_filter) continue;

        collected.append(self.allocator, .{
            .element = eid,
            .hint = hint,
            .world_bounds = paintChunkBoundsOrLayoutFallback(&self.world, eid),
        }) catch break;
    }
    // Append caller's explicit hints
    for (extra_hints) |h| collected.append(self.allocator, h) catch break;

    layerize_mod.layerize(&self.layer_tree, collected.items) catch return 0;
    return self.layer_tree.liveLayerCount();
}

/// See `Cx.syncLayoutToTable`. Flip to true to restore the old defensive walk.
const walk_layout_tree_each_frame = false;

pub fn syncLayoutToTable(self: *Cx, root: *Node) void {
    if (comptime walk_layout_tree_each_frame) syncLayoutNodeRecursive(self, root);
}

pub fn syncNodeRect(self: *Cx, node: *Node) void {
    if (node.element_id_raw == 0xFFFFFFFF) return;
    const eid = world.ElementId.fromRaw(node.element_id_raw);
    self.world.layout.ensureSlot(eid) catch return;
}

fn syncLayoutNodeRecursive(self: *Cx, node: *Node) void {
    self.syncNodeRect(node);
    for (node.children.items) |child| syncLayoutNodeRecursive(self, child);
}

pub fn syncPaintToTable(self: *Cx, root: *Node) void {
    self.perf.synced_node_count = 0;
    syncPaintNodeRecursive(self, root);
}

fn syncPaintNodeRecursive(self: *Cx, node: *Node) void {
    self.perf.synced_node_count +|= 1;
    if (node.element_id_raw != 0xFFFFFFFF) {
        const eid = world.ElementId.fromRaw(node.element_id_raw);
        // rect read once-reused: per-frame per-node path, rectFromWorldOrFallback
        // once ≈ 6-8 layer calls (Debug without CSE, write 4 times = 4 full chains).
        const rect = node.rectFromWorldOrFallback();
        const hash = paintContentHash(node, rect);
        const bounds: paint_table.Bounds = .{
            .min_x = rect.x,
            .min_y = rect.y,
            .max_x = rect.x + rect.w,
            .max_y = rect.y + rect.h,
        };
        // beginRecord returns true = need re-record (hash mismatch / first time); false = cache
        // hit.
        const need_record = self.world.paint.beginRecord(eid, hash) catch return;
        // v0.5-P3 Stage 3-3 Phase 3 (session 37): take property tree refs from SceneRuntime
        // (transform_id / clip_id / effect_id), take scroll_id from InteractionTable, write to
        // chunk.property_state.
        const runtime = self.scene_runtime.get(node.id);
        const interaction_data = self.world.interaction.get(eid);
        const property_state = paint_table.PropertyStateRef{
            .transform_id = if (runtime) |rt| rt.transform_id else std.math.maxInt(u32),
            .clip_id = if (runtime) |rt| rt.clip_id else std.math.maxInt(u32),
            .effect_id = if (runtime) |rt| rt.effect_id else std.math.maxInt(u32),
            .scroll_id = if (interaction_data) |d| d.scroll_id else std.math.maxInt(u32),
        };
        if (need_record) {
            // Truly mirror node's own DisplayItem range.
            if (runtime) |rt| {
                const start: usize = rt.display_item_start;
                const count: usize = rt.display_item_count;
                if (count > 0 and start + count <= self.display_list.items.items.len) {
                    const gpu_draw_shadow = @import("render_engine/gpu_draw_shadow.zig");
                    var i: usize = 0;
                    while (i < count) : (i += 1) {
                        const di = self.display_list.items.items[start + i];
                        // Unique display_list -> paint_table
                        // mapping point (merged mapDisplayItem from cx internal to shadow path's
                        // lowerDisplayItem). Both paths produce identical paint_table.DisplayItem.
                        const mapped = gpu_draw_shadow.lowerDisplayItem(di);
                        // Failure causes node's paint chunk **lose some items** ->
                        // local screen gap, no signal. Count for diagnostics
                        // (review report §3's silent-error family).
                        self.world.paint.pushItem(eid, mapped) catch {
                            core.paint_push_failures += 1;
                        };
                    }
                }
            }
            self.world.paint.endRecord(eid, property_state);
        }
        // Single get merges two writes: a cache hit must also update property_state
        // (transform_id / scroll_id can change); chunk.bounds is the world-space
        // element rect. pushItem's internal unionWith accumulates local_bounds
        // (item-local coords), a semantic mismatch with world bounds, so override here.
        // Downstream (LayerTree.layerizeFrame) needs world bounds.
        if (self.world.paint.get(eid)) |chunk| {
            if (!need_record) chunk.property_state = property_state;
            chunk.bounds = bounds;
        }
    }
    for (node.children.items) |child| syncPaintNodeRecursive(self, child);
}

/// Lightweight content hash for Stage 3-3 Phase 1+ cache invalidation.
/// Takes background + border + opacity + width/height + text + image/icon refs.
/// Session 43: expanded from background-only to 8 common visual properties,
/// letting PaintTable cache invalidation cover more real-world change scenarios.
fn paintContentHash(node: *const Node, rect: ComputedRect) u64 {
    var h = std.hash.Wyhash.init(0);
    const bg = node.getBackground();
    h.update(std.mem.asBytes(&bg));
    h.update(std.mem.asBytes(&node.style.border.color));
    h.update(std.mem.asBytes(&node.style.border.width));
    h.update(std.mem.asBytes(&node.getOpacity()));
    const w = rect.w;
    const ht = rect.h;
    h.update(std.mem.asBytes(&w));
    h.update(std.mem.asBytes(&ht));
    if (node.getText()) |t| {
        h.update(t.content);
        h.update(std.mem.asBytes(&t.font_size));
        h.update(std.mem.asBytes(&t.color));
    }
    if (node.getImage()) |im| {
        h.update(std.mem.asBytes(&im.texture_id));
        h.update(std.mem.asBytes(&im.tint));
    }
    if (node.getIcon()) |ic| {
        h.update(std.mem.asBytes(&ic.icon_id));
        h.update(std.mem.asBytes(&ic.tint));
    }
    return h.final();
}

pub fn syncInteractionToTable(self: *Cx, root: *Node) void {
    syncInteractionNodeRecursive(self, root);
}

fn syncInteractionNodeRecursive(self: *Cx, node: *Node) void {
    if (node.element_id_raw != 0xFFFFFFFF) {
        const eid = world.ElementId.fromRaw(node.element_id_raw);
        const has_a11y = node.behavior.interaction.a11y != null;
        const has_event = nodeHasAnyEvent(node);
        // v0.5-P3 Stage 3-4 fix (session 34): preserve existing scroll_id
        // (ScrollArea.mount injection), not erased by syncInteractionToTable after each frame
        // render.
        const existing_scroll_id: u32 = if (self.world.interaction.get(eid)) |existing|
            existing.scroll_id
        else
            std.math.maxInt(u32);
        const has_scroll = existing_scroll_id != std.math.maxInt(u32);
        if (node.behavior.interaction.focusable or has_a11y or has_event or has_scroll) {
            const focused = if (self.focus_manager.current_focus) |fn_node| (fn_node == node) else false;
            const ti: i16 = if (node.behavior.interaction.tab_index) |t|
                @as(i16, @intCast(@max(@min(t, std.math.maxInt(i16)), std.math.minInt(i16))))
            else
                0;
            const role: u16 = if (node.behavior.interaction.a11y) |a| @backingInt(a.role) else 0;
            const data: interaction_table.InteractionData = .{
                .focus = .{
                    .focusable = node.behavior.interaction.focusable,
                    .tabbable = node.behavior.interaction.tab_index != null,
                    .focused = focused,
                },
                .tab_index = ti,
                .event_mask = if (has_event) 0xFFFF_FFFF else 0,
                .a11y_role = role,
                .scroll_id = existing_scroll_id,
            };
            // failure -> that node this frame **cannot be hit** (click/hover fail silent),
            // completely silent. Same 'silent degradation' family as core.paint_push_failures.
            self.world.interaction.put(eid, data) catch {
                core.interaction_put_failures += 1;
            };
        } else {
            _ = self.world.interaction.remove(eid);
        }
    }
    for (node.children.items) |child| syncInteractionNodeRecursive(self, child);
}

fn nodeHasAnyEvent(node: *const Node) bool {
    const e = node.behavior.events;
    return e.on_click != null or e.on_hover != null or e.on_leave != null or
        e.on_focus != null or e.on_blur != null or
        e.on_key_down != null or e.on_key_up != null or
        e.on_event != null or e.on_event_capture != null or e.on_action != null;
}

pub fn assertLayoutSyncIntegrity(self: *Cx, root: *Node) bool {
    return assertLayoutSyncIntegrityRecursive(self, root);
}

fn assertLayoutSyncIntegrityRecursive(self: *Cx, node: *Node) bool {
    if (node.element_id_raw != 0xFFFFFFFF) {
        const eid = world.ElementId.fromRaw(node.element_id_raw);
        const lr = self.rectOf(eid) orelse return false;
        const eps: f32 = 0.001;
        // World.LayoutTable is the sole source of truth for rect (no frame_state.rect).
        // Invariant enforced below: PaintTable.bounds must equal LayoutTable.rect
        // (shadow-sync guaranteed by syncPaintToTable). Any PaintTable shadow miss is caught here.
        if (self.world.paint.get(eid)) |chunk| {
            if (!chunk.bounds.isEmpty()) {
                if (@abs(chunk.bounds.min_x - lr.x) > eps) return false;
                if (@abs(chunk.bounds.min_y - lr.y) > eps) return false;
                if (@abs(chunk.bounds.max_x - (lr.x + lr.width)) > eps) return false;
                if (@abs(chunk.bounds.max_y - (lr.y + lr.height)) > eps) return false;
            }
        }
        // v0.5-P3 Stage 3-2 Phase 2 attempt (session 41, REVERTED):
        // tried adding ElementTable parent-child chain consistency invariant, but Node.parent vs
        // World.elements parent are stale mid-layout pass (Input component reparent timing
        // complex).
        // Crashed panic, reverted. True ElementTable invariant gate needs prior hook 'sync when'
        // granularity.
    }
    for (node.children.items) |child| {
        if (!assertLayoutSyncIntegrityRecursive(self, child)) return false;
    }
    return true;
}

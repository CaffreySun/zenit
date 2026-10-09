//! LayoutOutputTable: NodeLayoutOutput SoA, dense by ElementId
//!
//! One-to-one with ElementTable: ensureSlot on element create. Currently dual-write:
//! Node.visuals.layout_output remains the source of truth; this table is a **non-owning mirror**, a
//! shallow copy of NodeLayoutOutput (aliasing ?PathGeometry pointers). The in-place fields still
//! own the path clone/freePathGeometry lifecycle; clearing this table **doesn't free** (else
//! double-free with the in-place fields).
//!
//! When the in-place fields are deleted, this table becomes the source of truth and clear takes
//! over freePathGeometry (see V10_ALIGNMENT_PLAN.md section L, Stage 3 + risk section).
//!
//! NodeLayoutOutput.artifacts.text_layout is a fixed-size TextLayout struct (no heap, no
//! self-referential slice), so a plain value copy is safe, with no ContentTable fixupAfterMove
//! issue.

const std = @import("std");
const testing = std.testing;
const element_id_mod = @import("element_id.zig");
const nlo = @import("node_layout_output.zig");

pub const ElementId = element_id_mod.ElementId;
pub const NodeLayoutOutput = nlo.NodeLayoutOutput;

pub const LayoutOutputTable = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(NodeLayoutOutput),

    pub fn init(allocator: std.mem.Allocator) LayoutOutputTable {
        return .{ .allocator = allocator, .items = .empty };
    }

    pub fn deinit(self: *LayoutOutputTable) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Grow items to index. NodeLayoutOutput has no self-referential slice (TextLayout fixed,
    /// PathGeometry pointer), ArrayList realloc move needs no re-fixup.
    pub fn ensureSlot(self: *LayoutOutputTable, id: ElementId) !void {
        if (id.isNull()) return;
        const idx = id.index;
        while (self.items.items.len <= idx) {
            try self.items.append(self.allocator, .{});
        }
    }

    pub fn get(self: *const LayoutOutputTable, id: ElementId) ?NodeLayoutOutput {
        if (id.isNull() or id.index >= self.items.items.len) return null;
        return self.items.items[id.index];
    }

    /// Get mutable pointer (layout_engine per-frame in-place modify artifacts, avoid whole struct
    /// write-back).
    pub fn getPtr(self: *LayoutOutputTable, id: ElementId) ?*NodeLayoutOutput {
        if (id.isNull() or id.index >= self.items.items.len) return null;
        return &self.items.items[id.index];
    }

    pub fn set(self: *LayoutOutputTable, id: ElementId, v: NodeLayoutOutput) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        self.items.items[id.index] = v;
    }

    /// Cx.destroyElement call. Stage 1: non-owning mirror, **only reset not free** (path geometry
    /// owner by in-place field). Stage 3 take free.
    pub fn clear(self: *LayoutOutputTable, id: ElementId) void {
        if (id.isNull() or id.index >= self.items.items.len) return;
        self.items.items[id.index] = .{};
    }
};

// ============================================================================
// Tests
// ============================================================================

test "LayoutOutputTable: init/deinit empty" {
    var t = LayoutOutputTable.init(testing.allocator);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.items.items.len);
}

test "LayoutOutputTable: ensureSlot grows up to index" {
    var t = LayoutOutputTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 3, .generation = 1 };
    try t.ensureSlot(id);
    try testing.expectEqual(@as(usize, 4), t.items.items.len);
    // Default empty NodeLayoutOutput
    const got = t.get(id).?;
    try testing.expect(got.vector.fill.path == null);
    try testing.expect(got.artifacts.children_bbox == null);
}

test "LayoutOutputTable: set / get roundtrip (artifacts + stroke POD)" {
    var t = LayoutOutputTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 0, .generation = 1 };
    try t.ensureSlot(id);

    var v: NodeLayoutOutput = .{};
    v.artifacts.children_bbox = .{ .x = 1, .y = 2, .w = 30, .h = 40 };
    v.vector.stroke.width = 3.5;
    t.set(id, v);

    const got = t.get(id).?;
    try testing.expectEqual(@as(f32, 30), got.artifacts.children_bbox.?.w);
    try testing.expectEqual(@as(f32, 3.5), got.vector.stroke.width);
}

test "LayoutOutputTable: getPtr mutates in place" {
    var t = LayoutOutputTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 1, .generation = 1 };
    try t.ensureSlot(id);

    const p = t.getPtr(id).?;
    p.artifacts.children_bbox = .{ .x = 0, .y = 0, .w = 99, .h = 0 };
    try testing.expectEqual(@as(f32, 99), t.get(id).?.artifacts.children_bbox.?.w);
}

test "LayoutOutputTable: clear resets slot (non-owning, no free)" {
    var t = LayoutOutputTable.init(testing.allocator);
    defer t.deinit();

    const id = ElementId{ .index = 0, .generation = 1 };
    try t.ensureSlot(id);
    var v: NodeLayoutOutput = .{};
    v.artifacts.children_bbox = .{ .x = 0, .y = 0, .w = 5, .h = 5 };
    t.set(id, v);

    t.clear(id);
    try testing.expect(t.get(id).?.artifacts.children_bbox == null);
}

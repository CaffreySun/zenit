//! ShapingCache: (text_hash, font, width) -> cached GlyphRun.
//!
//! TextShaper.shape() on CoreText costs ~10-100us; reshaping identical text is waste. Key is
//! (content_hash, font_id, max_width). Target hit rate >95%. Reference: HarfBuzz hb_shape_plan_t
//! cache.
//!
//! Pitfalls:
//! - **do not** hold Allocator-owned []GlyphPosition in entries; use a per-frame arena buffer +
//!   slice view
//! - **do not** set a small hard capacity; default 4096 entries + LRU eviction
//! - **do not** key on `[]const u8` (ptr unstable); key on hash + length, caller passes original to
//!   verify

const std = @import("std");
const testing = std.testing;
const glyph_run = @import("glyph_run.zig");
const text_coordinates = @import("text_core").text_coordinates;

pub const GlyphRun = glyph_run.GlyphRun;
pub const GlyphPosition = glyph_run.GlyphPosition;
pub const Cluster = glyph_run.Cluster;
pub const FontMetrics = glyph_run.FontMetrics;

/// Shaping cache key
pub const ShapingKey = struct {
    /// Source hash (caller generates using std.hash.Wyhash or similar)
    text_hash: u64,
    /// Text length (prevents hash collision + size estimation)
    text_len: u32,
    /// Font id (zenit FontSystem internal id; 0 = default)
    font_id: u32,
    /// max_width (used for line break; 0 = single line no wrap)
    max_width: f32,
    /// Font size
    font_size: f32,

    pub fn hash(self: ShapingKey) u64 {
        var h = std.hash.Wyhash.init(0xDEADBEEFCAFEBABE);
        h.update(std.mem.asBytes(&self.text_hash));
        h.update(std.mem.asBytes(&self.text_len));
        h.update(std.mem.asBytes(&self.font_id));
        h.update(std.mem.asBytes(&self.max_width));
        h.update(std.mem.asBytes(&self.font_size));
        return h.final();
    }

    pub fn eq(a: ShapingKey, b: ShapingKey) bool {
        return a.text_hash == b.text_hash and
            a.text_len == b.text_len and
            a.font_id == b.font_id and
            a.max_width == b.max_width and
            a.font_size == b.font_size;
    }
};

/// Cache entry, owned glyph + cluster slices (arena allocated)
pub const Entry = struct {
    key: ShapingKey,
    /// Arena-allocated glyph sequence
    glyphs: []GlyphPosition,
    /// Arena-allocated cluster sequence
    clusters: []Cluster,
    metrics: FontMetrics,
    direction: glyph_run.Direction,
    total_advance: f32,
    /// LRU timestamp: most recently used frame index
    last_used_frame: u64,

    pub fn toRun(self: Entry) GlyphRun {
        return .{
            .glyphs = self.glyphs,
            .clusters = self.clusters,
            .metrics = self.metrics,
            .direction = self.direction,
            .total_advance = self.total_advance,
        };
    }
};

pub const ShapingCacheStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    pub fn hitRate(self: ShapingCacheStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: ShapingKey) u64 {
        return k.hash();
    }
    pub fn eql(_: KeyContext, a: ShapingKey, b: ShapingKey) bool {
        return ShapingKey.eq(a, b);
    }
};

const VisualEntry = struct {
    caret_stops: []text_coordinates.CaretStop,
    width: f32,
    ascent: f32,
    descent: f32,
    leading: f32,
    base_direction: text_coordinates.Direction,
    last_used_frame: u64,

    fn toLine(self: VisualEntry, text_len: usize) text_coordinates.VisualLine {
        return .{
            .source_start = .{ .value = 0 },
            .source_end = .{ .value = text_len },
            .caret_stops = self.caret_stops,
            .width = self.width,
            .ascent = self.ascent,
            .descent = self.descent,
            .leading = self.leading,
            .base_direction = self.base_direction,
        };
    }
};

pub const ShapingCache = struct {
    allocator: std.mem.Allocator,
    /// Arena for glyph/cluster slices; entire arena reset on each evict + cache.deinit
    arena: std.heap.ArenaAllocator,
    /// HashMap key -> entry index
    map: std.HashMapUnmanaged(ShapingKey, Entry, KeyContext, 80),
    visual_map: std.HashMapUnmanaged(ShapingKey, VisualEntry, KeyContext, 80),
    capacity: u32,
    current_frame: u64 = 0,
    stats: ShapingCacheStats = .{},

    pub fn init(parent_allocator: std.mem.Allocator, capacity: u32) ShapingCache {
        return .{
            .allocator = parent_allocator,
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .map = .{},
            .visual_map = .{},
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *ShapingCache) void {
        self.map.deinit(self.allocator);
        self.visual_map.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn beginFrame(self: *ShapingCache) void {
        self.current_frame +%= 1;
    }

    /// Query cache. Hit -> return GlyphRun + bump last_used_frame; miss -> null.
    pub fn lookup(self: *ShapingCache, key: ShapingKey) ?GlyphRun {
        if (self.map.getPtr(key)) |entry| {
            entry.last_used_frame = self.current_frame;
            self.stats.hits += 1;
            return entry.toRun();
        }
        self.stats.misses += 1;
        return null;
    }

    pub fn lookupVisual(self: *ShapingCache, key: ShapingKey) ?text_coordinates.VisualLine {
        if (self.visual_map.getPtr(key)) |entry| {
            entry.last_used_frame = self.current_frame;
            return entry.toLine(key.text_len);
        }
        return null;
    }

    pub fn insertVisual(self: *ShapingCache, key: ShapingKey, line: text_coordinates.VisualLine) !void {
        if (self.visual_map.count() >= self.capacity) {
            // Caret geometry is small and cheap to rebuild. A bounded wholesale
            // reset avoids per-entry arena ownership and keeps lookup O(1).
            self.visual_map.clearRetainingCapacity();
        }
        if (self.arena.queryCapacity() >= ARENA_CLEAR_BYTES and self.map.count() == 0) {
            self.visual_map.clearRetainingCapacity();
            _ = self.arena.reset(.retain_capacity);
        }
        const owned = try self.arena.allocator().alloc(text_coordinates.CaretStop, line.caret_stops.len);
        @memcpy(owned, line.caret_stops);
        try self.visual_map.put(self.allocator, key, .{
            .caret_stops = owned,
            .width = line.width,
            .ascent = line.ascent,
            .descent = line.descent,
            .leading = line.leading,
            .base_direction = line.base_direction,
            .last_used_frame = self.current_frame,
        });
    }

    /// Insert cache entry. Caller provides shaping result (glyph/cluster slice stored by
    /// cache-internal arena, so caller can pass stack-allocated). Evict by LRU when full.
    pub fn insert(
        self: *ShapingCache,
        key: ShapingKey,
        glyphs: []const GlyphPosition,
        clusters: []const Cluster,
        metrics: FontMetrics,
        direction: glyph_run.Direction,
        total_advance: f32,
    ) !void {
        if (self.map.count() >= self.capacity) {
            self.evictBatch();
        }

        const arena_alloc = self.arena.allocator();
        const owned_glyphs = try arena_alloc.alloc(GlyphPosition, glyphs.len);
        @memcpy(owned_glyphs, glyphs);
        const owned_clusters = try arena_alloc.alloc(Cluster, clusters.len);
        @memcpy(owned_clusters, clusters);

        try self.map.put(self.allocator, key, .{
            .key = key,
            .glyphs = owned_glyphs,
            .clusters = owned_clusters,
            .metrics = metrics,
            .direction = direction,
            .total_advance = total_advance,
            .last_used_frame = self.current_frame,
        });
    }

    /// Entries unused for more than this frame count are stale; batch eviction prioritizes clearing
    /// them.
    const STALE_FRAMES: u64 = 120;
    /// Entry slices hung on internal arena; evict individually without reclaiming memory.
    /// When arena exceeds threshold, clear fully (map + arena reset); next frame reshapes hot set.
    const ARENA_CLEAR_BYTES: usize = 32 * 1024 * 1024;

    /// Batch eviction: old per-entry LRU when full scans O(capacity) per miss with no arena
    /// reclaim. Free >= capacity/4 per eviction, amortizing scan cost to O(4)/miss.
    fn evictBatch(self: *ShapingCache) void {
        if (self.map.count() == 0) return;

        if (self.arena.queryCapacity() >= ARENA_CLEAR_BYTES) {
            // Unbounded arena growth fallback: reset fully. Cost is peak shaping next frame;
            // happens rarely.
            self.stats.evictions += self.map.count();
            self.map.clearRetainingCapacity();
            self.visual_map.clearRetainingCapacity();
            _ = self.arena.reset(.retain_capacity);
            return;
        }

        const target: u64 = @max(self.capacity / 4, 1);
        // Progressively tighten age threshold: scan all, batch removeByPtr (remove no rehash;
        // deletion during iteration is std.HashMap-supported). First clear STALE_FRAMES unused.
        // If insufficient, halve threshold and rescan; worst O(log(STALE_FRAMES)) rounds until
        // cutoff
        // = current frame, guaranteed to free enough target.
        var age_threshold: u64 = STALE_FRAMES;
        var removed: u64 = 0;
        while (removed < target) {
            const cutoff = self.current_frame -| age_threshold;
            var iter = self.map.iterator();
            while (iter.next()) |kv| {
                if (kv.value_ptr.last_used_frame <= cutoff) {
                    self.map.removeByPtr(kv.key_ptr);
                    removed += 1;
                }
            }
            if (removed >= target or age_threshold == 0) break;
            age_threshold /= 2;
        }
        self.stats.evictions += removed;
    }

    pub fn count(self: *const ShapingCache) u32 {
        return @intCast(self.map.count());
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ShapingKey eq + hash stable" {
    const a = ShapingKey{ .text_hash = 0xCAFE, .text_len = 5, .font_id = 1, .max_width = 200, .font_size = 14 };
    const b = ShapingKey{ .text_hash = 0xCAFE, .text_len = 5, .font_id = 1, .max_width = 200, .font_size = 14 };
    try testing.expect(ShapingKey.eq(a, b));
    try testing.expectEqual(a.hash(), b.hash());
}

test "ShapingKey different params → different hash" {
    const a = ShapingKey{ .text_hash = 1, .text_len = 5, .font_id = 1, .max_width = 200, .font_size = 14 };
    const b = ShapingKey{ .text_hash = 1, .text_len = 5, .font_id = 1, .max_width = 200, .font_size = 16 };
    try testing.expect(!ShapingKey.eq(a, b));
}

test "ShapingCache: insert + lookup hit" {
    var cache = ShapingCache.init(testing.allocator, 16);
    defer cache.deinit();

    const key = ShapingKey{ .text_hash = 0x1, .text_len = 5, .font_id = 0, .max_width = 0, .font_size = 14 };
    const glyphs = [_]GlyphPosition{
        .{ .glyph_id = 1, .x_advance = 10 },
    };
    const clusters = [_]Cluster{
        .{ .byte_offset = 0, .glyph_start = 0, .glyph_end = 1 },
    };
    const metrics = FontMetrics{ .ascent = 12, .descent = 4, .line_gap = 0, .font_size = 14 };

    try cache.insert(key, &glyphs, &clusters, metrics, .ltr, 10);

    const got = cache.lookup(key);
    try testing.expect(got != null);
    try testing.expectEqual(@as(usize, 1), got.?.glyphs.len);
    try testing.expectEqual(@as(f32, 10), got.?.total_advance);
    try testing.expectEqual(@as(u64, 1), cache.stats.hits);
    try testing.expectEqual(@as(u64, 0), cache.stats.misses);
}

test "ShapingCache: lookup miss" {
    var cache = ShapingCache.init(testing.allocator, 16);
    defer cache.deinit();

    const key = ShapingKey{ .text_hash = 0x1, .text_len = 5, .font_id = 0, .max_width = 0, .font_size = 14 };
    try testing.expect(cache.lookup(key) == null);
    try testing.expectEqual(@as(u64, 1), cache.stats.misses);
}

test "ShapingCache: batch eviction keeps recently-used, drops stale" {
    var cache = ShapingCache.init(testing.allocator, 4);
    defer cache.deinit();

    const empty_glyphs: []const GlyphPosition = &.{};
    const empty_clusters: []const Cluster = &.{};
    const m = FontMetrics{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 };
    const k1 = ShapingKey{ .text_hash = 1, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };
    const k2 = ShapingKey{ .text_hash = 2, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };
    const k3 = ShapingKey{ .text_hash = 3, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };
    const k4 = ShapingKey{ .text_hash = 4, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };
    const k5 = ShapingKey{ .text_hash = 5, .text_len = 0, .font_id = 0, .max_width = 0, .font_size = 14 };

    cache.beginFrame();
    try cache.insert(k1, empty_glyphs, empty_clusters, m, .ltr, 0);
    try cache.insert(k2, empty_glyphs, empty_clusters, m, .ltr, 0);
    try cache.insert(k3, empty_glyphs, empty_clusters, m, .ltr, 0);
    try cache.insert(k4, empty_glyphs, empty_clusters, m, .ltr, 0);
    try testing.expectEqual(@as(u32, 4), cache.count());

    // Advance 200 frames; k1 continuously used, rest become stale.
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        cache.beginFrame();
        _ = cache.lookup(k1);
    }

    // Capacity full; insert k5 triggers batch eviction, stale k2/k3/k4 cleared, k1 survives.
    try cache.insert(k5, empty_glyphs, empty_clusters, m, .ltr, 0);
    try testing.expect(cache.lookup(k1) != null);
    try testing.expect(cache.lookup(k2) == null);
    try testing.expect(cache.lookup(k3) == null);
    try testing.expect(cache.lookup(k4) == null);
    try testing.expect(cache.lookup(k5) != null);
    try testing.expect(cache.stats.evictions >= 3);
}

test "ShapingCache: hit rate calculation" {
    var stats = ShapingCacheStats{ .hits = 95, .misses = 5 };
    try testing.expectApproxEqAbs(@as(f64, 0.95), stats.hitRate(), 0.001);
}

test "ShapingCache: stats hits + misses tracked" {
    var cache = ShapingCache.init(testing.allocator, 16);
    defer cache.deinit();

    const key = ShapingKey{ .text_hash = 1, .text_len = 5, .font_id = 0, .max_width = 0, .font_size = 14 };
    _ = cache.lookup(key); // miss
    _ = cache.lookup(key); // miss
    try cache.insert(key, &.{}, &.{}, .{ .ascent = 0, .descent = 0, .line_gap = 0, .font_size = 14 }, .ltr, 0);
    _ = cache.lookup(key); // hit
    _ = cache.lookup(key); // hit
    _ = cache.lookup(key); // hit

    try testing.expectEqual(@as(u64, 3), cache.stats.hits);
    try testing.expectEqual(@as(u64, 2), cache.stats.misses);
    try testing.expectApproxEqAbs(@as(f64, 0.6), cache.stats.hitRate(), 0.001);
}

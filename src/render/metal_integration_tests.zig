//! Tests that require a live Metal device.
//!
//! Keep this root separate from `render.zig`: `zig build test-headless` must be
//! runnable in a macOS session without a Metal device or WindowServer, while
//! `zig build test-metal` is a deliberate infrastructure contract.

const std = @import("std");
const gpu = @import("gpu");
const text = @import("text");
const atlas_mod = @import("glyph_atlas.zig");
const text_renderer_mod = @import("text_renderer.zig");

comptime {
    _ = @import("sdf_gpu_bench.zig");
    _ = @import("glass_material_tests.zig");
}

const GlyphAtlas = atlas_mod.GlyphAtlas;
const PageFormat = atlas_mod.PageFormat;
const packSubpixelBin = atlas_mod.packSubpixelBin;

test "path slot rollback preserves distinct native buffer owners for retry" {
    const raw = gpu.Backend.metal_bindings.metal_create_system_default_device() orelse
        return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{ .raw_device = raw, .features = .{}, .limits = .{} };
    defer device.deinit();
    var path = try @import("path_renderer.zig").PathRenderer.init(std.testing.allocator, &device);
    defer path.deinit();
    path.vertex_buffer = try device.createBuffer(std.testing.allocator, .{ .size = 256, .usage = .{ .vertex = true } });
    path.vertex_buffer_capacity = 256;
    path.parked_buffers[1] = try device.createBuffer(std.testing.allocator, .{ .size = 512, .usage = .{ .vertex = true } });
    path.parked_capacities[1] = 512;
    const previous = path.vertex_buffer.?.raw;
    const retry = path.parked_buffers[1].?.raw;
    path.restoreFrameBufferSlot(1);
    try std.testing.expectEqual(retry, path.vertex_buffer.?.raw);
    path.restoreFrameBufferSlot(0);
    try std.testing.expectEqual(previous, path.vertex_buffer.?.raw);
    try std.testing.expectEqual(retry, path.parked_buffers[1].?.raw);
    try std.testing.expectEqual(@as(usize, 256), path.vertex_buffer_capacity);
    try std.testing.expectEqual(@as(usize, 512), path.parked_capacities[1]);
    try std.testing.expect(path.parked_buffers[0] == null);
    path.restoreFrameBufferSlot(0); // Idempotent restoration cannot duplicate an owner.
    try std.testing.expect(path.parked_buffers[0] == null);
}

test "atlas first-page failure releases native sampler owners and permits clean retry" {
    const raw_device = gpu.Backend.metal_bindings.metal_create_system_default_device() orelse
        return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{ .raw_device = raw_device, .features = .{}, .limits = .{} };
    defer device.deinit();
    device.fail_next_texture_for_testing = true;
    try std.testing.expectError(error.TextureCreationFailed, GlyphAtlas.init(std.testing.allocator, &device));
    try std.testing.expectEqual(@as(usize, 2), device.sampler_count);
    try std.testing.expectEqual(@as(usize, 0), device.samplers_live_for_testing);
    {
        var atlas = try GlyphAtlas.init(std.testing.allocator, &device);
        defer atlas.deinit();
        try std.testing.expectEqual(@as(u32, 1), atlas.page_count);
        try std.testing.expectEqual(@as(usize, 2), device.samplers_live_for_testing);
    }
    try std.testing.expectEqual(@as(usize, 0), device.samplers_live_for_testing);
}

test "metal preflight + atlas: color and grayscale pages coexist" {
    const testing = std.testing;
    const mtl = gpu.Backend.metal_bindings;

    // A missing device is an infrastructure failure for `test-metal`, not a
    // skipped unit test hidden inside the deterministic suite.
    const raw_device = mtl.metal_create_system_default_device() orelse
        return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{
        .raw_device = raw_device,
        .features = .{},
        .limits = .{},
    };
    defer device.deinit();

    var atlas = try GlyphAtlas.init(testing.allocator, &device);
    defer atlas.deinit();

    try testing.expectEqual(@as(u32, 1), atlas.page_count);
    try testing.expectEqual(PageFormat.gray, atlas.getPageFormat(0).?);

    var fs = try text.FontSystem.init(testing.allocator, @import("std").testing.io);
    defer fs.deinit();
    const helvetica = try fs.findFont(.{ .family = "Helvetica", .size = 32 });
    defer helvetica.deinit();
    const emoji = try fs.findFont(.{ .family = "Apple Color Emoji", .size = 32 });
    defer emoji.deinit();

    const gray_region = try atlas.getOrInsert(helvetica, helvetica.glyphIndexForCodepoint('A'));
    try testing.expect(gray_region.width > 0);
    try testing.expect(!gray_region.is_color);
    try testing.expectEqual(PageFormat.gray, atlas.getPageFormat(gray_region.page_index).?);

    const emoji_glyph = emoji.glyphIndexForCodepoint(0x1F600);
    try testing.expect(emoji_glyph != 0);
    const color_region = try atlas.getOrInsert(emoji, emoji_glyph);
    try testing.expect(color_region.width > 0);
    try testing.expect(color_region.is_color);
    try testing.expectEqual(PageFormat.color, atlas.getPageFormat(color_region.page_index).?);
    try testing.expect(color_region.page_index != gray_region.page_index);

    try testing.expectEqual(@as(u32, 2), atlas.page_count);
    try testing.expectEqual(GlyphAtlas.PAGE_BYTES * 5, atlas.bytesUsed());

    const cache_before = atlas.getCacheSize();
    const same = try atlas.getOrInsertSubpixel(emoji, emoji_glyph, packSubpixelBin(2, 0));
    try testing.expectEqual(cache_before, atlas.getCacheSize());
    try testing.expectEqual(color_region.page_index, same.page_index);
    try testing.expect(same.is_color);
}

test "metal atlas: a scale change creates a new physical glyph entry" {
    const testing = std.testing;

    var inst = try gpu.Backend.Instance.init(testing.allocator, .{});
    defer inst.deinit();
    const adapters = try inst.enumerateAdapters();
    defer testing.allocator.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(testing.allocator, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();

    var atlas = try GlyphAtlas.init(testing.allocator, &dq.device);
    defer atlas.deinit();

    var fs = try text.FontSystem.init(testing.allocator, @import("std").testing.io);
    defer fs.deinit();
    const font = try fs.findFont(.{ .family = "Helvetica", .size = 32 });
    defer font.deinit();
    const glyph = font.glyphIndexForCodepoint('M');
    try testing.expect(glyph != 0);

    font.setScaleFactor(1.0);
    const one_x = try atlas.getOrInsert(font, glyph);
    const entries_after_1x = atlas.getCacheSize();
    try testing.expect(entries_after_1x >= 1);
    _ = try atlas.getOrInsert(font, glyph);
    try testing.expectEqual(entries_after_1x, atlas.getCacheSize());

    font.setScaleFactor(2.0);
    const two_x = try atlas.getOrInsert(font, glyph);
    try testing.expectEqual(entries_after_1x + 1, atlas.getCacheSize());
    try testing.expect(two_x.width > one_x.width);

    font.setScaleFactor(1.0);
    _ = try atlas.getOrInsert(font, glyph);
    try testing.expectEqual(entries_after_1x + 1, atlas.getCacheSize());

    const bin = packSubpixelBin(1, 2);
    const before_sub = atlas.getCacheSize();
    _ = try atlas.getOrInsertSubpixel(font, glyph, bin);
    const after_sub_1x = atlas.getCacheSize();
    try testing.expectEqual(before_sub + 1, after_sub_1x);
    _ = try atlas.getOrInsertSubpixel(font, glyph, bin);
    try testing.expectEqual(after_sub_1x, atlas.getCacheSize());

    font.setScaleFactor(2.0);
    _ = try atlas.getOrInsertSubpixel(font, glyph, bin);
    try testing.expectEqual(after_sub_1x + 1, atlas.getCacheSize());
}

test "metal command encoder rejects stale pass generations across render and blit" {
    const testing = std.testing;

    var inst = try gpu.Backend.Instance.init(testing.allocator, .{});
    defer inst.deinit();
    const adapters = try inst.enumerateAdapters();
    defer testing.allocator.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(testing.allocator, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();

    const texture_desc: gpu.TextureDescriptor = .{
        .size = .{ .width = 8, .height = 8 },
        .format = .bgra8_unorm,
        .usage = .{ .render_attachment = true, .copy_src = true, .copy_dst = true },
    };
    var source = try dq.device.createTexture(testing.allocator, texture_desc);
    defer source.destroy();
    var destination = try dq.device.createTexture(testing.allocator, texture_desc);
    defer destination.destroy();

    var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
    errdefer encoder.deinit();
    var source_view = source.binding().createView();
    defer source_view.destroy();

    var render_pass = try encoder.beginRenderPass(.{
        .color_attachments = &.{.{
            .view = source_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    });
    var stale_render_alias = render_pass;
    try testing.expect(render_pass.isActive());
    try testing.expect(stale_render_alias.isActive());
    try testing.expectError(error.InvalidEncoderState, encoder.finish());
    render_pass.end();
    try testing.expect(!render_pass.isActive());
    try testing.expect(!stale_render_alias.isActive());

    var blit_pass = try encoder.beginBlitPass();
    try testing.expect(blit_pass.isActive());
    // The old render alias must remain invalid even when Metal reuses an
    // Objective-C encoder address for this different pass kind.
    try testing.expect(!stale_render_alias.isActive());
    try blit_pass.copyTextureRegion(source.binding(), 0, 0, 8, 8, destination.binding(), 0, 0);
    blit_pass.end();
    try testing.expect(!blit_pass.isActive());

    var destination_view = destination.binding().createView();
    defer destination_view.destroy();
    var second_render_pass = try encoder.beginRenderPass(.{
        .color_attachments = &.{.{
            .view = destination_view,
            .load_op = .load,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    });
    try testing.expect(second_render_pass.isActive());
    try testing.expect(!stale_render_alias.isActive());
    second_render_pass.end();

    var command_buffer = try encoder.finish();
    command_buffer.deinit();
}

test "metal text renderer: direct_animated 坐标连续无吸附, static 双侧吸附幂等" {
    const testing = std.testing;
    const mtl = gpu.Backend.metal_bindings;

    const raw_device = mtl.metal_create_system_default_device() orelse
        return error.MetalDeviceUnavailable;
    var device = gpu.Backend.Device{
        .raw_device = raw_device,
        .features = .{},
        .limits = .{},
    };
    defer device.deinit();

    // init compiles text.metal from embedded source, also verifies shader side changes of
    // shader_snap field.
    var tr = try text_renderer_mod.TextRenderer.init(testing.allocator, &device);
    defer tr.deinit();
    tr.setViewport(800, 600, 2.0); // 2x DPR: half-pixel snapping observable.

    var fs = try text.FontSystem.init(testing.allocator, @import("std").testing.io);
    defer fs.deinit();
    const font = try fs.findFont(.{ .family = "Helvetica", .size = 16 });
    defer font.deinit();

    const white = text_renderer_mod.Color.WHITE;
    const frac_x: f32 = 10.37;
    const frac_y: f32 = 20.13;

    // -- Static path: CPU snap to physical pixels + shader_snap=1 (shader round idempotent) --
    try tr.drawTextWithOptions("Hello", frac_x, frac_y, font, white, 16, false, null, false, true, 0);
    const static_nearest = tr.instances_nearest.items.len;
    const static_linear = tr.instances_linear.items.len;
    try testing.expect(static_nearest + static_linear > 0);
    for (tr.instances_nearest.items) |inst| {
        try testing.expect(inst.shader_snap > 0.5);
        // CPU already snapped by round(x*scale)/scale -> position*scale should be integer
        const px = inst.position[0] * 2.0;
        const py = inst.position[1] * 2.0;
        try testing.expectApproxEqAbs(@round(px), px, 1e-3);
        try testing.expectApproxEqAbs(@round(py), py, 1e-3);
    }
    for (tr.instances_linear.items) |inst| {
        try testing.expect(inst.shader_snap > 0.5);
    }

    // -- Animated path (direct_animated): continuous coords + shader_snap=0 --
    const anim_base_nearest = tr.instances_nearest.items.len;
    const anim_base_linear = tr.instances_linear.items.len;
    try tr.drawTextWithOptions("Hello", frac_x, frac_y, font, white, 16, false, null, true, false, 0);
    // force_linear -> all go in linear list
    try testing.expectEqual(anim_base_nearest, tr.instances_nearest.items.len);
    const anim_a_start = anim_base_linear;
    const anim_a_len = tr.instances_linear.items.len - anim_a_start;
    try testing.expect(anim_a_len > 0);
    for (tr.instances_linear.items[anim_a_start..]) |inst| {
        try testing.expect(inst.shader_snap < 0.5);
    }

    // same text translated sub-pixel 0.3px redraw: per-glyph position difference must be exactly
    // 0.3 (rounding either side discretizes 0.3 into 0 or 0.5 mix -> kerning jitter)
    const shift: f32 = 0.3;
    const b_start = tr.instances_linear.items.len;
    try tr.drawTextWithOptions("Hello", frac_x + shift, frac_y, font, white, 16, false, null, true, false, 0);
    const anim_b_len = tr.instances_linear.items.len - b_start;
    try testing.expectEqual(anim_a_len, anim_b_len);
    var gi: usize = 0;
    while (gi < anim_a_len) : (gi += 1) {
        const ia = tr.instances_linear.items[anim_a_start + gi];
        const ib = tr.instances_linear.items[b_start + gi];
        try testing.expectApproxEqAbs(ia.position[0] + shift, ib.position[0], 1e-3);
        try testing.expectApproxEqAbs(ia.position[1], ib.position[1], 1e-3);
    }
}

test "metal text renderer: overflow instance pool 同帧累加、跨帧复用不重建" {
    const testing = std.testing;

    var inst_gpu = try gpu.Backend.Instance.init(testing.allocator, .{});
    defer inst_gpu.deinit();
    const adapters = try inst_gpu.enumerateAdapters();
    defer testing.allocator.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(testing.allocator, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();

    var tr = try text_renderer_mod.TextRenderer.init(testing.allocator, &dq.device);
    defer tr.deinit();

    const GlyphInstance = std.meta.Elem(@TypeOf(tr.instances_nearest.items));
    const glyph = GlyphInstance{
        .position = .{ 0, 0 },
        .size = .{ 1, 1 },
        .uv_rect = .{ 0, 0, 0, 0 },
        .color = .{ 1, 1, 1, 1 },
    };
    // instance capacity of main instance buffer (inferred from buffer bytes, independent of private
    // constants)
    const max_instances: usize = @intCast(tr.instance_buffers[0].size / @sizeOf(GlyphInstance));

    var target = try dq.device.createTexture(testing.allocator, .{
        .size = .{ .width = 8, .height = 8 },
        .format = .bgra8_unorm,
        .usage = .{ .render_attachment = true },
    });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();

    var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);

    const pass_desc: gpu.RenderPassDescriptor = .{
        .color_attachments = &.{.{
            .view = view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        }},
    };

    // -- Frame A: overflow 8192 instances, allocate pool buffer for current slot --
    tr.beginFrame(8, 8, 1.0);
    try tr.instances_nearest.appendNTimes(testing.allocator, glyph, max_instances + 8192);
    {
        var pass = try encoder.beginRenderPass(pass_desc);
        try tr.endFrame(&pass);
        pass.end();
    }
    const slot = tr.current_buffer;
    try testing.expect(tr.overflow_buffers[slot] != null);
    const raw0 = tr.overflow_buffers[slot].?.raw;
    const cap0 = tr.overflow_capacities[slot];
    try testing.expectEqual(@sizeOf(GlyphInstance) * 8192, cap0);
    try testing.expectEqual(@sizeOf(GlyphInstance) * 8192, tr.overflow_write_offset);

    // -- idle BUFFER_COUNT-1 frames, wrap to same slot --
    var i: usize = 0;
    while (i < tr.overflow_buffers.len - 1) : (i += 1) {
        tr.beginFrame(8, 8, 1.0);
        var pass = try encoder.beginRenderPass(pass_desc);
        try tr.endFrame(&pass);
        pass.end();
    }

    // -- Frame C (same slot): smaller overflow must reuse existing buffer, don't create new --
    tr.beginFrame(8, 8, 1.0);
    try testing.expectEqual(slot, tr.current_buffer);
    try testing.expectEqual(@as(usize, 0), tr.overflow_write_offset);
    try tr.instances_nearest.appendNTimes(testing.allocator, glyph, max_instances + 4096);
    {
        var pass = try encoder.beginRenderPass(pass_desc);
        try tr.endFrame(&pass);
        // second flush in same frame: main buffer full, all go overflow path and accumulate in pool
        try tr.instances_nearest.appendNTimes(testing.allocator, glyph, 4096);
        try tr.flush(&pass);
        pass.end();
    }
    try testing.expectEqual(raw0, tr.overflow_buffers[slot].?.raw);
    try testing.expectEqual(cap0, tr.overflow_capacities[slot]);
    try testing.expectEqual(@sizeOf(GlyphInstance) * 8192, tr.overflow_write_offset);

    var command_buffer = try encoder.finish();
    command_buffer.deinit();
}

test "metal command encoder deinit ends a pass abandoned by an error path" {
    // AppRenderer.frame after beginRenderPass any `try` failure, only errdefer gpu_encoder.deinit()
    // left. deinit must endEncoding + release that live pass, or encoder leaks and command buffer
    // with unended encoder freed (Metal validation: MTL_DEBUG_LAYER=1 asserts crash).
    const testing = std.testing;

    var inst = try gpu.Backend.Instance.init(testing.allocator, .{});
    defer inst.deinit();
    const adapters = try inst.enumerateAdapters();
    defer testing.allocator.free(adapters);
    if (adapters.len == 0) return error.MetalAdapterUnavailable;
    var adapter = adapters[0];
    defer adapter.deinit();
    var dq = try adapter.requestDevice(testing.allocator, .{});
    defer dq.device.deinit();
    defer dq.queue.deinit();

    var target = try dq.device.createTexture(testing.allocator, .{
        .size = .{ .width = 8, .height = 8 },
        .format = .bgra8_unorm,
        .usage = .{ .render_attachment = true, .copy_src = true },
    });
    defer target.destroy();
    var view = target.binding().createView();
    defer view.destroy();

    for (0..2) |kind| {
        var encoder = try gpu.Backend.CommandEncoder.init(&dq.queue);
        if (kind == 0) {
            const pass = try encoder.beginRenderPass(.{
                .color_attachments = &.{.{
                    .view = view,
                    .load_op = .clear,
                    .store_op = .store,
                    .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                }},
            });
            try testing.expect(pass.isActive());
        } else {
            const pass = try encoder.beginBlitPass();
            try testing.expect(pass.isActive());
        }
        try testing.expect(encoder.active_pass_raw != null);
        encoder.deinit(); // pass never ended
    }
}

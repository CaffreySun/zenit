const std = @import("std");
const gpu = @import("gpu");
const d12 = gpu.Backend.native;
const a = std.heap.page_allocator;

fn compute(device: *d12.Device, raw: bool) !void {
    var bindings = try device.createBindGroupLayout(a, .{ .entries = &.{
        .{ .binding = 3, .count = 2, .visibility = .{ .compute = true }, .ty = .{ .buffer = .{ .ty = .storage } } },
        .{ .binding = 7, .count = 2, .visibility = .{ .compute = true }, .ty = .{ .buffer = .{ .ty = .read_only_storage } } },
    } });
    defer bindings.deinit();
    var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{bindings} });
    defer layout.deinit();
    const structured_source =
        \\StructuredBuffer<uint> source[2]:register(t7); RWStructuredBuffer<uint> result[2]:register(u3);
        \\[numthreads(4,1,1)] void initialize(uint3 id:SV_DispatchThreadID){uint n,s;source[1].GetDimensions(n,s);result[0][id.x]=source[0][id.x]+10+n;result[1][id.x]=source[1][id.x]+20;}
        \\[numthreads(4,1,1)] void update(uint3 id:SV_DispatchThreadID){uint old;InterlockedAdd(result[1][id.x],30,old);InterlockedAdd(result[NonUniformResourceIndex(id.x%2)][id.x],100+source[NonUniformResourceIndex(id.x%2)][id.x],old);}
    ;
    const raw_source =
        \\ByteAddressBuffer source[2]:register(t7); RWByteAddressBuffer result[2]:register(u3);
        \\[numthreads(4,1,1)] void initialize(uint3 id:SV_DispatchThreadID){uint n;source[1].GetDimensions(n);result[0].Store(id.x*4,source[0].Load(id.x*4)+10+n/4);result[1].Store(id.x*4,source[1].Load(id.x*4)+20);}
        \\[numthreads(4,1,1)] void update(uint3 id:SV_DispatchThreadID){uint old;result[1].InterlockedAdd(id.x*4,30,old);result[NonUniformResourceIndex(id.x%2)].InterlockedAdd(id.x*4,100+source[NonUniformResourceIndex(id.x%2)].Load(id.x*4),old);}
    ;
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = if (raw) raw_source else structured_source, .entry_points = &.{ .{ .name = "initialize", .stage = .compute }, .{ .name = "update", .stage = .compute } } } } });
    defer module.deinit();
    var initialize = try module.getFunction("initialize");
    defer initialize.deinit();
    var update = try module.getFunction("update");
    defer update.deinit();
    var first = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &initialize });
    defer first.deinit();
    var second = try device.createComputePipeline(.{ .layout = &layout, .compute_function = &update });
    defer second.deinit();
    var input = try device.createBuffer(a, .{ .size = 64, .usage = .{ .storage = true, .map_write = true } });
    defer input.destroy();
    const numbers = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    @memcpy(try input.getMappedRange(0, 64), std.mem.sliceAsBytes(&numbers));
    var out0 = try device.createBuffer(a, .{ .size = 16, .usage = .{ .storage = true, .copy_src = true } });
    defer out0.destroy();
    var out1 = try device.createBuffer(a, .{ .size = 16, .usage = .{ .storage = true, .copy_src = true } });
    defer out1.destroy();
    const stride: u32 = if (raw) 0 else 4;
    var group = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &.{
        .{ .binding = 7, .array_index = 1, .buffer = &input, .offset = 32, .size = 16, .stride = stride },
        .{ .binding = 3, .array_index = 0, .buffer = &out0, .stride = stride },
        .{ .binding = 7, .array_index = 0, .buffer = &input, .offset = 16, .size = 16, .stride = stride },
        .{ .binding = 3, .array_index = 1, .buffer = &out1, .stride = stride },
    } });
    defer group.deinit();
    var readback = try device.createBuffer(a, .{ .size = 64, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("array queue teardown failed");
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    try encoder.dispatch(&first, &.{group}, 1, 1, 1);
    try encoder.copyBufferToBuffer(&out0, 0, &readback, 0, 16);
    try encoder.copyBufferToBuffer(&out1, 0, &readback, 16, 16);
    try encoder.dispatch(&second, &.{group}, 1, 1, 1);
    try encoder.copyBufferToBuffer(&out0, 0, &readback, 32, 16);
    try encoder.copyBufferToBuffer(&out1, 0, &readback, 48, 16);
    var command = try encoder.finish();
    defer command.deinit();
    _ = try queue.submit(&.{command});
    try queue.waitIdle(5000);
    const bytes = try readback.getMappedRange(0, 64);
    const expected = [_]u32{ 19, 20, 21, 22, 29, 30, 31, 32, 124, 20, 128, 22, 59, 170, 61, 174 };
    if (!std.mem.eql(u8, bytes, std.mem.sliceAsBytes(&expected))) {
        std.debug.print("buffer array writes mismatch raw={} bytes={s}\n", .{ raw, std.fmt.bytesToHex(bytes[0..64].*, .lower) });
        return error.IncorrectBufferArrayWrites;
    }
}

fn graphics(device: *d12.Device) !void {
    var empty = try device.createBindGroupLayout(a, .{ .entries = &.{} });
    defer empty.deinit();
    var bindings = try device.createBindGroupLayout(a, .{ .entries = &.{.{ .binding = 4, .count = 2, .visibility = .{ .vertex = true, .fragment = true }, .ty = .{ .buffer = .{ .ty = .read_only_storage } } }} });
    defer bindings.deinit();
    var layout = try device.createPipelineLayout(a, .{ .bind_group_layouts = &.{ empty, bindings } });
    defer layout.deinit();
    const source =
        \\StructuredBuffer<float> values[2]:register(t4,space1);
        \\struct V{float4 position:SV_Position;float value:TEXCOORD0;};
        \\V vertex(uint id:SV_VertexID){V v;v.position=float4(id==0?float2(-1,-1):id==1?float2(3,-1):float2(-1,3),0,1);v.value=values[1][0];return v;}
        \\uint fragment(V v):SV_Target{return uint(v.value+values[1][0]+100*values[NonUniformResourceIndex(uint(v.position.x)%2)][0]);}
    ;
    var module = try device.createShaderModule(a, .{ .source = .{ .hlsl = .{ .code = source, .entry_points = &.{ .{ .name = "vertex", .stage = .vertex }, .{ .name = "fragment", .stage = .fragment } } } } });
    defer module.deinit();
    var vertex = try module.getFunction("vertex");
    defer vertex.deinit();
    var fragment = try module.getFunction("fragment");
    defer fragment.deinit();
    var pipeline = try device.createRenderPipeline(.{ .layout = &layout, .vertex_function = &vertex, .fragment_function = &fragment, .targets = &.{.{ .format = .r32_uint }} });
    defer pipeline.deinit();
    var input = try device.createBuffer(a, .{ .size = 32, .usage = .{ .map_write = true, .storage = true } });
    defer input.destroy();
    const numbers = [_]f32{ 5, 0, 0, 0, 9, 0, 0, 0 };
    @memcpy(try input.getMappedRange(0, 32), std.mem.sliceAsBytes(&numbers));
    var g0 = try device.createBindGroup(a, .{ .layout = &layout, .group = 0, .entries = &.{} });
    defer g0.deinit();
    var g1 = try device.createBindGroup(a, .{ .layout = &layout, .group = 1, .entries = &.{
        .{ .binding = 4, .array_index = 0, .buffer = &input, .size = 16, .stride = 4 },
        .{ .binding = 4, .array_index = 1, .buffer = &input, .offset = 16, .size = 16, .stride = 4 },
    } });
    defer g1.deinit();
    var texture = try device.createTexture(a, .{ .size = .{ .width = 4, .height = 2 }, .format = .r32_uint, .usage = .{ .render_attachment = true, .copy_src = true } });
    defer texture.destroy();
    const region = try texture.fullRegion(0, 0);
    const footprint = try texture.copyLayout(region, 0);
    var readback = try device.createBuffer(a, .{ .size = footprint.required_bytes, .usage = .{ .map_read = true, .copy_dst = true } });
    defer readback.destroy();
    var queue = try device.createQueue();
    defer queue.deinit(5000) catch @panic("array graphics queue teardown failed");
    var encoder = try device.createCommandEncoder();
    defer encoder.deinit();
    var pass = try encoder.beginRenderPass(.{ .color_attachments = &.{.{ .texture = &texture, .load_op = .clear }} });
    defer pass.deinit();
    try pass.draw(.{ .pipeline = &pipeline, .bind_groups = &.{ g0, g1 }, .vertex_count = 3 });
    try pass.end();
    try encoder.copyTextureToBuffer(&texture, region, &readback, 0, footprint.row_pitch);
    var command = try encoder.finish();
    defer command.deinit();
    _ = try queue.submit(&.{command});
    try queue.waitIdle(5000);
    const bytes = try readback.getMappedRange(0, readback.size);
    for (0..2) |y| for (0..4) |x| {
        const actual = std.mem.readInt(u32, bytes[y * footprint.row_pitch + x * 4 ..][0..4], .little);
        if (actual != (if (x % 2 == 0) @as(u32, 518) else 918)) return error.IncorrectBufferArrayPixel;
    };
}

pub fn run() !void {
    for ([_]bool{ false, true }) |warp| {
        var device = try d12.Device.init(warp);
        defer device.destroy();
        try compute(&device, false);
        try compute(&device, true);
        try graphics(&device);
        std.debug.print("PASS: buffer arrays: raw/structured SRV/UAV, dimensions, static/dynamic atomics, vertex/pixel indexing; 40 exact readbacks (forced_warp={})\n", .{warp});
    }
}

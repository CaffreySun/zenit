//! Test-mode pointer isolation shared by the macOS and Windows runtimes.
//!
//! The e2e harness injects pointer input by calling Cx directly. Real OS pointer events from a
//! person using the machine would otherwise overwrite the injected hover position, so hover
//! states and clicks land on whatever the physical cursor is over. When isolation is on, the
//! runtime drops OS pointer events and only the harness drives the pointer.
const std = @import("std");
const system_sdk = @import("system_sdk");

/// ZENIT_E2E_ISOLATE_POINTER decides explicitly ("0"/empty = off). Without it, a background e2e
/// run isolates when `background_default` is set: the Windows worker exports
/// ZENIT_E2E_BACKGROUND=1 for every job without --allow-foreground, while foreground jobs drive
/// the real cursor through SendInput and must keep OS pointer input.
pub fn enabledFrom(isolate: ?[]const u8, background: ?[]const u8, background_default: bool) bool {
    if (isolate) |v| return flag(v);
    if (background_default) if (background) |v| return flag(v);
    return false;
}

fn flag(value: []const u8) bool {
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

/// Reads the process environment once per process.
pub fn enabled(comptime background_default: bool) bool {
    const Cache = struct {
        var value: ?bool = null;
    };
    if (Cache.value) |v| return v;
    const page = std.heap.page_allocator;
    const isolate = @import("zenit_environment").getOwned(page, "ZENIT_E2E_ISOLATE_POINTER") catch null;
    defer if (isolate) |v| page.free(v);
    const background = @import("zenit_environment").getOwned(page, "ZENIT_E2E_BACKGROUND") catch null;
    defer if (background) |v| page.free(v);
    const v = enabledFrom(isolate, background, background_default);
    Cache.value = v;
    return v;
}

/// OS pointer events that isolation drops. Keyboard, IME, focus, resize and drag-and-drop
/// sessions are untouched.
pub fn isOsPointerEvent(event: system_sdk.events.Event) bool {
    return switch (event) {
        .mouse_move, .mouse_button, .mouse_wheel, .magnify => true,
        else => false,
    };
}

test "explicit ZENIT_E2E_ISOLATE_POINTER wins over the background default" {
    try std.testing.expect(enabledFrom("1", null, false));
    try std.testing.expect(!enabledFrom("0", "1", true));
    try std.testing.expect(!enabledFrom("", "1", true));
}

test "background e2e runs isolate only where the platform opts in" {
    try std.testing.expect(enabledFrom(null, "1", true));
    try std.testing.expect(!enabledFrom(null, "0", true));
    try std.testing.expect(!enabledFrom(null, null, true));
    // macOS keeps its explicit opt-in; ZENIT_E2E_BACKGROUND alone does not change it.
    try std.testing.expect(!enabledFrom(null, "1", false));
}

test "only OS pointer events are dropped" {
    const E = system_sdk.events.Event;
    inline for (@import("zenit_reflection").fields(E)) |field| {
        const expected = comptime std.mem.eql(u8, field.name, "mouse_move") or
            std.mem.eql(u8, field.name, "mouse_button") or
            std.mem.eql(u8, field.name, "mouse_wheel") or
            std.mem.eql(u8, field.name, "magnify");
        const event = @unionInit(E, field.name, std.mem.zeroes(field.type));
        try std.testing.expectEqual(expected, isOsPointerEvent(event));
    }
}

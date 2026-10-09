const std = @import("std");

/// Bundle resource path resolution
///
/// Detects at runtime whether the executable is in .app/Contents/MacOS/:
/// - Bundle mode: resources in .app/Contents/Resources/
/// - Dev mode: resources in CWD's assets/ directory
pub const ResourcePath = struct {
    /// Resource root directory (ends with '/')
    /// Bundle mode: "/path/to/MyApp.app/Contents/Resources/"
    /// Dev mode: prefer resolve to .../assets/ in executable's parent directory
    /// null means fallback to relative path "assets/"
    base_path: ?[]const u8,

    var static_buf: [std.fs.max_path_bytes]u8 = undefined;
    var static_len: usize = 0;

    pub fn init() ResourcePath {
        static_len = 0;
        var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const self_path = std.fs.selfExePath(&self_path_buf) catch {
            return .{ .base_path = null };
        };

        const marker = "/Contents/MacOS/";
        if (std.mem.indexOf(u8, self_path, marker)) |pos| {
            const contents_end = pos + "/Contents/".len;
            const resources_suffix = "Resources/";
            const total_len = contents_end + resources_suffix.len;
            if (total_len <= static_buf.len) {
                @memcpy(static_buf[0..contents_end], self_path[0..contents_end]);
                @memcpy(static_buf[contents_end..total_len], resources_suffix);
                static_len = total_len;
                return .{ .base_path = static_buf[0..total_len] };
            }
        }

        if (std.fs.path.dirname(self_path)) |self_dir| {
            if (findAssetsBase(self_dir)) |base_path| {
                return .{ .base_path = base_path };
            }
        }

        return .{ .base_path = null };
    }

    /// Write resource relative path into caller-provided buffer, return sentinel-terminated slice
    ///
    /// Input: "fonts/Roboto.ttf"
    /// Bundle mode: "/path/to/MyApp.app/Contents/Resources/fonts/Roboto.ttf"
    /// Dev mode: "/abs/path/to/assets/fonts/Roboto.ttf" or fallback to "assets/fonts/..."
    pub fn resolve(self: *const ResourcePath, buf: []u8, rel_path: []const u8) [:0]const u8 {
        if (self.base_path) |base| {
            const total = base.len + rel_path.len;
            if (total < buf.len) {
                @memcpy(buf[0..base.len], base);
                @memcpy(buf[base.len..total], rel_path);
                buf[total] = 0;
                return buf[0..total :0];
            }
        }

        const prefix = "assets/";
        const total = prefix.len + rel_path.len;
        if (total < buf.len) {
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len..total], rel_path);
            buf[total] = 0;
            return buf[0..total :0];
        }

        buf[0] = 0;
        return buf[0..0 :0];
    }

    fn findAssetsBase(start_dir: []const u8) ?[]const u8 {
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (start_dir.len == 0 or start_dir.len >= dir_buf.len) return null;
        @memcpy(dir_buf[0..start_dir.len], start_dir);

        var current: []const u8 = dir_buf[0..start_dir.len];
        while (true) {
            var candidate_buf: [std.fs.max_path_bytes]u8 = undefined;
            const candidate = joinPath(&candidate_buf, current, "assets", false) orelse return null;
            if (std.fs.openDirAbsolute(candidate, .{})) |opened_dir| {
                var dir = opened_dir;
                dir.close();
                return storeBasePath(current, "assets");
            } else |_| {}

            if (current.len == 1 and current[0] == std.fs.path.sep) break;
            current = std.fs.path.dirname(current) orelse break;
        }
        return null;
    }

    fn storeBasePath(dir_path: []const u8, child: []const u8) ?[]const u8 {
        const base = joinPath(&static_buf, dir_path, child, true) orelse return null;
        static_len = base.len;
        return static_buf[0..static_len];
    }

    fn joinPath(buf: []u8, dir_path: []const u8, child: []const u8, trailing_slash: bool) ?[]u8 {
        const at_root = dir_path.len == 1 and dir_path[0] == std.fs.path.sep;
        if (at_root) {
            if (trailing_slash) {
                return std.fmt.bufPrint(buf, "{s}{s}/", .{ dir_path, child }) catch null;
            }
            return std.fmt.bufPrint(buf, "{s}{s}", .{ dir_path, child }) catch null;
        }

        if (trailing_slash) {
            return std.fmt.bufPrint(buf, "{s}/{s}/", .{ dir_path, child }) catch null;
        }
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir_path, child }) catch null;
    }
};

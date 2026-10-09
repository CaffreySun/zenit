//! Storybook navigation and content layout. Stories render directly on the canvas.
const ui = @import("ui");
const TOKENS = ui.theme.refs;

pub const root = ui.css(.{ .width = .fill, .height = .fill, .direction = .row, .background = TOKENS.color.bg_primary });
pub const sidebar = ui.css(.{
    .width = ui.arb.px(216),
    .height = .fill,
    .direction = .column,
    .background = TOKENS.color.bg_secondary,
    .border_right_width = TOKENS.border_width.thin,
    .border_right_color = TOKENS.color.border,
});
pub const brand = ui.css(.{
    .direction = .row,
    .align_items = .center,
    .gap = TOKENS.space.space200,
    .padding = .{ .x = TOKENS.space.space400, .top = TOKENS.space.space600, .bottom = TOKENS.space.space400 },
});
pub const logoMark = ui.css(.{
    .width = ui.arb.px(24),
    .height = ui.arb.px(24),
    .align_items = .center,
    .justify = .center,
    .background = TOKENS.color.accent,
    .corner_radius = TOKENS.radius.lg,
});
pub const logoLetter = ui.css(.{ .font_size = TOKENS.font_size.lg, .font_weight = 700, .color = TOKENS.color.fg_inverse });
pub const brandName = ui.css(.{ .font_size = TOKENS.font_size.lg, .font_weight = 600, .color = TOKENS.color.fg_primary });
pub const searchWrap = ui.css(.{ .padding = .{ .x = TOKENS.space.space300, .bottom = TOKENS.space.space200 } });
pub const searchField = ui.css(.{
    .width = .fill,
    .height = ui.arb.px(32),
    .direction = .row,
    .align_items = .center,
    .gap = TOKENS.space.space200,
    .padding = .{ .x = TOKENS.space.space200 },
    .background = TOKENS.color.bg_primary,
    .border = .{ .width = .thin, .color = TOKENS.color.border, .radius = .lg },
});
pub const searchIcon = ui.css(.{ .width = TOKENS.size.sm, .height = TOKENS.size.sm });
pub fn searchIconTint(t: *const ui.theme.Values) ui.Color {
    return t.tokens.color.fg_tertiary;
}
pub const searchInput = ui.css(.{ .width = .{ .grow = .{ .min = 0 } } });
pub const navEmptyHint = ui.css(.{ .font_size = TOKENS.font_size.sm, .color = TOKENS.color.fg_tertiary });
pub const navSection = ui.css(.{ .padding = .{ .x = TOKENS.space.space200, .top = TOKENS.space.space400, .bottom = TOKENS.space.space200 } });
pub const navSectionText = ui.css(.{ .font_size = TOKENS.font_size.xs, .font_weight = 500, .color = TOKENS.color.fg_tertiary });
pub const Nav = ui.sva(.{
    .slots = .{ .root, .label },
    .base = .{
        .root = .{
            .width = .fill,
            .height = ui.arb.px(32),
            .direction = .row,
            .align_items = .center,
            .padding = .{ .x = TOKENS.space.space200 },
            .corner_radius = TOKENS.radius.lg,
            .cursor = .pointer,
            ._hover = .{ .background = TOKENS.color.bg_hover },
        },
        .label = .{ .font_size = TOKENS.font_size.md, .font_weight = 400, .color = TOKENS.color.fg_secondary },
    },
    .variants = .{ .selected = .{
        .false = .{},
        .true = .{
            .root = .{ .background = TOKENS.color.bg_tertiary },
            .label = .{ .font_weight = 600, .color = TOKENS.color.fg_primary },
        },
    } },
    .defaults = .{ .selected = false },
});
pub const sidebarFooter = ui.css(.{ .padding = TOKENS.space.space400 });
pub const sidebarFooterText = ui.css(.{ .font_size = TOKENS.font_size.xs, .color = TOKENS.color.fg_tertiary });
pub const workspace = ui.css(.{ .width = .fill, .height = .fill, .direction = .column, .background = TOKENS.color.bg_primary });
pub const toolbar = ui.css(.{
    .width = .fill,
    .height = ui.arb.px(64),
    .direction = .row,
    .align_items = .center,
    .justify = .space_between,
    .padding = .{ .x = TOKENS.space.space800 },
    .border_bottom_width = TOKENS.border_width.thin,
    .border_bottom_color = TOKENS.color.border,
});
pub const heading = ui.css(.{ .direction = .row, .align_items = .center, .gap = TOKENS.space.space300 });
pub const category = ui.css(.{ .font_size = TOKENS.font_size.xs, .font_weight = 500, .color = TOKENS.color.fg_tertiary });
pub const title = ui.css(.{ .font_size = TOKENS.font_size.xxl, .font_weight = 600, .color = TOKENS.color.fg_primary });
pub const devtoolsButton = ui.css(.{
    .direction = .row,
    .align_items = .center,
    .padding = .{ .x = TOKENS.space.space200, .y = TOKENS.space.space150 },
    .corner_radius = TOKENS.radius.lg,
    .cursor = .pointer,
    ._hover = .{ .background = TOKENS.color.bg_hover },
});
pub const devtoolsLabel = ui.css(.{ .font_size = TOKENS.font_size.sm, .color = TOKENS.color.fg_secondary });
/// Content column: the story note above the story panel. The gap (32) keeps the note out of the
/// website's frames (the story root padded 28).
pub const contentColumn = ui.css(.{ .width = .fill, .gap = TOKENS.space.space800 });
/// Non-scrolling content area (WidgetSpec.scrolls = false): padding and bg color
/// same as ScrollArea
pub const plainContent = ui.css(.{ .width = .fill, .height = .fill, .padding = TOKENS.space.space800, .gap = TOKENS.space.space800, .background = TOKENS.color.bg_primary });
pub const panel = ui.css(.{ .width = .fill, .direction = .column });
/// Story panel whose root hugs its content, centred (WidgetSpec.wide = false).
pub const panelCentred = ui.css(.{ .width = .fill, .direction = .column, .align_items = .center });
/// The story note (WidgetSpec.note): secondary text above the panel, wrapping.
/// Wraps at a readable measure (and stays clear of stories that draw over the window's right side).
pub const storyNote = ui.css(.{ .font_size = TOKENS.font_size.sm, .color = TOKENS.color.fg_secondary, .wrap = .word, .width = .fill, .max_width = 480 });

// -- Story content common styles (shared by stories.zig and other story files) --

/// Vertical layout, gap spacing (px)
pub fn stack(comptime gap: f32) @TypeOf(ui.css(.{ .gap = gap })) {
    return .{};
}

/// Horizontal layout, vertically centered, gap spacing (px)
pub fn line(comptime gap: f32) @TypeOf(ui.css(.{ .gap = gap, .align_items = .center })) {
    return .{};
}

/// Fixed width (px)
pub fn fixedWidth(comptime px: f32) @TypeOf(ui.css(.{ .width = px })) {
    return .{};
}

/// Story subsection label / state echo text (13px secondary color)
pub const storyLabel = ui.css(.{ .font_size = 13, .color = TOKENS.color.fg_secondary });

/// Story body text (13-14px primary color)
pub const storyBody = ui.css(.{ .font_size = 14, .color = TOKENS.color.fg_primary });

const std = @import("std");
const builtin = @import("builtin");
const atomic = std.atomic;
const base64Encoder = std.base64.standard.Encoder;
const zigimg = @import("zigimg");

const Cell = @import("Cell.zig");
const Image = @import("Image.zig");
const InternalScreen = @import("InternalScreen.zig");
const Key = @import("Key.zig");
const Mouse = @import("Mouse.zig");
const Screen = @import("Screen.zig");
const Cursor = Screen.Cursor;
const unicode = @import("unicode.zig");
const Window = @import("Window.zig");
const sixel = @import("sixel.zig");

const Hyperlink = Cell.Hyperlink;
const KittyFlags = Key.KittyFlags;
const Shape = Mouse.Shape;
const Style = Cell.Style;
const Winsize = @import("main.zig").Winsize;

const ctlseqs = @import("ctlseqs.zig");
const gwidth = @import("gwidth.zig");

const assert = std.debug.assert;

const Vaxis = @This();

const log = std.log.scoped(.vaxis);

pub const Capabilities = struct {
    kitty_keyboard: bool = false,
    kitty_graphics: bool = false,
    /// Sixel raster graphics. Set only when the primary device attributes
    /// claim attribute 4 and the terminal answered the XTSMGRAPHICS geometry
    /// query; never inferred from a terminal name.
    sixel_graphics: bool = false,
    no_color: bool = false,
    rgb: bool = false,
    unicode: gwidth.Method = .wcwidth,
    sgr_pixels: bool = false,
    color_scheme_updates: bool = false,
    explicit_width: bool = false,
    scaled_text: bool = false,
    multi_cursor: bool = false,
};

/// A cell rectangle occupied by a sixel raster.
pub const Rect = struct {
    col: u16,
    row: u16,
    cols: u16,
    rows: u16,

    pub fn eql(a: Rect, b: Rect) bool {
        return a.col == b.col and a.row == b.row and a.cols == b.cols and a.rows == b.rows;
    }

    pub fn contains(self: Rect, col: u16, row: u16) bool {
        return col >= self.col and col < self.col + self.cols and
            row >= self.row and row < self.row + self.rows;
    }
};

/// A sixel placement together with the rectangle it landed on.
const SixelFrame = struct {
    rect: Rect,
    placement: sixel.Placement,
};

pub const Options = struct {
    kitty_keyboard_flags: KittyFlags = .{},
    /// When supplied, this allocator will be used for system clipboard
    /// requests. If not supplied, it won't be possible to request the system
    /// clipboard
    system_clipboard_allocator: ?std.mem.Allocator = null,
};

io: std.Io,
env_map: *std.process.Environ.Map,

/// the screen we write to
screen: Screen,
/// The last screen we drew. We keep this so we can efficiently update on
/// the next render
screen_last: InternalScreen,

caps: Capabilities = .{},

opts: Options = .{},

/// if we should redraw the entire screen on the next render
refresh: bool = false,

/// blocks the main thread until a DA1 query has been received, or the
/// futex times out
query_futex: atomic.Value(u32) = atomic.Value(u32).init(0),

/// If Queries were sent, we set this to false. We reset to true when all queries are complete. This
/// is used because we do explicit cursor position reports in the queries, which interfere with F3
/// key encoding. This can be used as a flag to determine how we should evaluate this sequence
queries_done: atomic.Value(bool) = atomic.Value(bool).init(true),

// images
next_img_id: u32 = 1,

/// The maximum sixel raster the terminal reported, or null if it never
/// answered the geometry query.
sixel_geometry: ?@import("event.zig").SixelGeometry = null,

/// Loaded sixel rasters, owned by Vaxis: decoded and quantized, ready to
/// encode. Nothing has been sent to the terminal.
sixel_images: std.ArrayList(sixel.Image) = .empty,
next_sixel_id: u32 = 1,
/// The allocator the sixel rasters were loaded with; `render` takes no
/// allocator and payloads are encoded there.
sixel_gpa: ?std.mem.Allocator = null,
/// The cell rectangle the last rendered sixel occupied, so the next render
/// can erase it. The invariant is that this describes exactly what is on
/// screen.
sixel_last_rect: ?Rect = null,
/// What was last sent, so an unchanged raster is not streamed again.
sixel_last_placement: ?sixel.Placement = null,

sgr: enum {
    standard,
    legacy,
} = .standard,

/// Enable workarounds for escape sequence handling issues/bugs in terminals
/// So far this just enables a UL escape sequence workaround for conpty
enable_workarounds: bool = true,

state: struct {
    /// if we are in the alt screen
    alt_screen: bool = false,
    /// if we have entered kitty keyboard
    kitty_keyboard: bool = false,
    bracketed_paste: bool = false,
    mouse: bool = false,
    pixel_mouse: bool = false,
    color_scheme_updates: bool = false,
    in_band_resize: bool = false,
    changed_default_fg: bool = false,
    changed_default_bg: bool = false,
    changed_cursor_color: bool = false,
    cursor: Cursor = .{},
    cursor_secondary: []Cursor = &.{},
    prev_cursor_secondary: []const Cursor = &.{},
} = .{},

/// Initialize Vaxis with runtime options
pub fn init(io: std.Io, alloc: std.mem.Allocator, env_map: *std.process.Environ.Map, opts: Options) !Vaxis {
    return .{
        .io = io,
        .env_map = env_map,
        .opts = opts,
        .screen = .{},
        .screen_last = try .init(alloc, 0, 0),
    };
}

/// Resets the terminal to it's original state. If an allocator is
/// passed, this will free resources associated with Vaxis. This is left as an
/// optional so applications can choose to not free resources when the
/// application will be exiting anyways
pub fn deinit(self: *Vaxis, alloc: ?std.mem.Allocator, tty: *std.Io.Writer) void {
    self.resetState(tty) catch {};

    if (alloc) |a| {
        self.clearSixelImages(a);
        if (self.state.prev_cursor_secondary.ptr != self.screen.cursor_secondary.ptr)
            a.free(self.state.prev_cursor_secondary);
        a.free(self.screen.cursor_secondary);
        self.screen.deinit(a);
        self.screen_last.deinit(a);
    }
}

/// resets enabled features, sends cursor to home and clears below cursor
pub fn resetState(self: *Vaxis, tty: *std.Io.Writer) !void {
    // always show the cursor on state reset
    tty.writeAll(ctlseqs.show_cursor) catch {};
    tty.writeAll(ctlseqs.sgr_reset) catch {};
    if (self.screen.cursor_shape != .default) {
        // In many terminals, `.default` will set to the configured cursor shape. Others, it will
        // change to a blinking block.
        tty.print(ctlseqs.cursor_shape, .{@intFromEnum(Cell.CursorShape.default)}) catch {};
    }
    if (self.state.kitty_keyboard) {
        try tty.writeAll(ctlseqs.csi_u_pop);
        self.state.kitty_keyboard = false;
    }
    if (self.state.mouse) {
        try self.setMouseMode(tty, false);
    }
    if (self.state.bracketed_paste) {
        try self.setBracketedPaste(tty, false);
    }
    if (self.state.alt_screen) {
        try tty.writeAll(ctlseqs.home);
        try tty.writeAll(ctlseqs.erase_below_cursor);
        try self.exitAltScreen(tty);
    } else {
        try tty.writeByte('\r');
        var i: u16 = 0;
        while (i < self.state.cursor.row) : (i += 1) {
            try tty.writeAll(ctlseqs.ri);
        }
        try tty.writeAll(ctlseqs.erase_below_cursor);
    }
    // Whatever raster was on screen is gone with the erase above.
    self.sixel_last_rect = null;
    self.sixel_last_placement = null;
    if (self.state.color_scheme_updates) {
        try tty.writeAll(ctlseqs.color_scheme_reset);
        self.state.color_scheme_updates = false;
    }
    if (self.state.in_band_resize) {
        try tty.writeAll(ctlseqs.in_band_resize_reset);
        self.state.in_band_resize = false;
    }
    if (self.state.changed_default_fg) {
        try tty.writeAll(ctlseqs.osc10_reset);
        self.state.changed_default_fg = false;
    }
    if (self.state.changed_default_bg) {
        try tty.writeAll(ctlseqs.osc11_reset);
        self.state.changed_default_bg = false;
    }
    if (self.state.changed_cursor_color) {
        try tty.writeAll(ctlseqs.osc12_reset);
        self.state.changed_cursor_color = false;
    }

    try tty.flush();
}

/// resize allocates a slice of cells equal to the number of cells
/// required to display the screen (ie width x height). Any previous screen is
/// freed when resizing. The cursor will be sent to it's home position and a
/// hardware clear-below-cursor will be sent
pub fn resize(
    self: *Vaxis,
    alloc: std.mem.Allocator,
    tty: *std.Io.Writer,
    winsize: Winsize,
) !void {
    log.debug("resizing screen: width={d} height={d}", .{ winsize.cols, winsize.rows });
    // Rasters are encoded for one cell geometry, and a resize can change the
    // pixel size of a cell, so every loaded sixel is stale here.
    self.clearSixelImages(alloc);
    self.screen.deinit(alloc);
    self.screen = try Screen.init(alloc, winsize);
    self.screen.width_method = self.caps.unicode;
    // try self.screen.int(alloc, winsize.cols, winsize.rows);
    // we only init our current screen. This has the effect of redrawing
    // every cell
    self.screen_last.deinit(alloc);
    self.screen_last = try InternalScreen.init(alloc, winsize.cols, winsize.rows);
    if (self.state.alt_screen)
        try tty.writeAll(ctlseqs.home)
    else {
        for (0..self.state.cursor.row) |_| {
            try tty.writeAll(ctlseqs.ri);
        }
        try tty.writeByte('\r');
    }
    self.state.cursor.row = 0;
    self.state.cursor.col = 0;
    try tty.writeAll(ctlseqs.sgr_reset ++ ctlseqs.erase_below_cursor);
    try tty.flush();
}

/// returns a Window comprising of the entire terminal screen
pub fn window(self: *Vaxis) Window {
    return .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = self.screen.width,
        .height = self.screen.height,
        .screen = &self.screen,
    };
}

/// enter the alternate screen. The alternate screen will automatically
/// be exited if calling deinit while in the alt screen.
pub fn enterAltScreen(self: *Vaxis, tty: *std.Io.Writer) !void {
    try tty.writeAll(ctlseqs.smcup);
    try tty.flush();
    self.state.alt_screen = true;
}

/// exit the alternate screen. Does not flush the writer.
pub fn exitAltScreen(self: *Vaxis, tty: *std.Io.Writer) !void {
    try tty.writeAll(ctlseqs.rmcup);
    try tty.flush();
    self.state.alt_screen = false;
}

/// write queries to the terminal to determine capabilities. Individual
/// capabilities will be delivered to the client and possibly intercepted by
/// Vaxis to enable features.
///
/// This call will block until Vaxis.query_futex is woken up, or the timeout.
/// Event loops can wake up this futex when cap_da1 is received
pub fn queryTerminal(self: *Vaxis, tty: *std.Io.Writer, timeout: std.Io.Duration) !void {
    try self.queryTerminalSend(tty);
    try std.Io.futexWaitTimeout(
        self.io,
        atomic.Value(u32),
        &self.query_futex,
        .init(0),
        .{
            .duration = .{
                .clock = .real,
                .raw = timeout,
            },
        },
    );
    self.queries_done.store(true, .unordered);
    try self.enableDetectedFeatures(tty);
}

/// write queries to the terminal to determine capabilities. This function
/// is only for use with a custom main loop. Call Vaxis.queryTerminal() if
/// you are using Loop.run()
pub fn queryTerminalSend(vx: *Vaxis, tty: *std.Io.Writer) !void {
    vx.queries_done.store(false, .unordered);

    // TODO: re-enable this
    // const colorterm = std.posix.getenv("COLORTERM") orelse "";
    // if (std.mem.eql(u8, colorterm, "truecolor") or
    //     std.mem.eql(u8, colorterm, "24bit"))
    // {
    //     if (@hasField(Event, "cap_rgb")) {
    //         self.postEvent(.cap_rgb);
    //     }
    // }

    // TODO: XTGETTCAP queries ("RGB", "Smulx")
    // TODO: decide if we actually want to query for focus and sync. It
    // doesn't hurt to blindly use them
    // _ = try tty.write(ctlseqs.decrqm_focus);
    // _ = try tty.write(ctlseqs.decrqm_sync);
    try tty.writeAll(ctlseqs.decrqm_sgr_pixels ++
        ctlseqs.decrqm_unicode ++
        ctlseqs.decrqm_color_scheme ++
        ctlseqs.in_band_resize_set ++

        // Explicit width query. We send the cursor home, then do an explicit width command, then
        // query the position. If the parsed value is an F3 with shift, we support explicit width.
        // The returned response will be something like \x1b[1;2R...which when parsed as a Key is a
        // shift + F3 (the row is ignored). We only care if the column has moved from 1->2, which is
        // why we see a Shift modifier
        ctlseqs.home ++
        ctlseqs.explicit_width_query ++
        ctlseqs.cursor_position_request ++
        // Explicit width query. We send the cursor home, then do an scaled text command, then
        // query the position. If the parsed value is an F3 with al, we support scaled text.
        // The returned response will be something like \x1b[1;3R...which when parsed as a Key is a
        // alt + F3 (the row is ignored). We only care if the column has moved from 1->3, which is
        // why we see a Shift modifier
        ctlseqs.home ++
        ctlseqs.scaled_text_query ++
        ctlseqs.multi_cursor_query ++
        ctlseqs.cursor_position_request ++
        ctlseqs.xtversion ++
        ctlseqs.csi_u_query ++
        ctlseqs.kitty_graphics_query ++
        // Before the device attributes on purpose: DA1 is what ends the query
        // phase, and the sixel decision needs this answer already in hand.
        ctlseqs.sixel_geometry_query ++
        ctlseqs.primary_device_attrs);

    try tty.flush();
}

/// Enable features detected by responses to queryTerminal. This function
/// is only for use with a custom main loop. Call Vaxis.queryTerminal() if
/// you are using Loop.run()
pub fn enableDetectedFeatures(self: *Vaxis, tty: *std.Io.Writer) !void {
    // Apply NO_COLOR before OS-specific feature handling so it works on Windows too.
    if (self.env_map.get("NO_COLOR")) |nc| {
        if (nc.len != 0)
            self.caps.no_color = true;
    }

    switch (builtin.os.tag) {
        .windows => {
            // No feature detection on windows. We just hard enable some knowns for ConPTY
            self.sgr = .legacy;
        },
        else => {
            // Apply any environment variables
            if (self.env_map.get("TERMUX_VERSION")) |_|
                self.sgr = .legacy;
            if (self.env_map.get("VHS_RECORD")) |_| {
                self.caps.unicode = .wcwidth;
                self.caps.kitty_keyboard = false;
                self.sgr = .legacy;
            }
            if (self.env_map.get("TERM_PROGRAM")) |prg| {
                if (std.mem.eql(u8, prg, "vscode"))
                    self.sgr = .legacy;
            }
            if (self.env_map.get("VAXIS_FORCE_LEGACY_SGR")) |_|
                self.sgr = .legacy;
            if (self.env_map.get("VAXIS_FORCE_WCWIDTH")) |_|
                self.caps.unicode = .wcwidth;
            if (self.env_map.get("VAXIS_FORCE_UNICODE")) |_|
                self.caps.unicode = .unicode;

            // enable detected features
            if (self.caps.kitty_keyboard) {
                try self.enableKittyKeyboard(tty, self.opts.kitty_keyboard_flags);
            }
            // Only enable mode 2027 if we don't have explicit width
            if (self.caps.unicode == .unicode and !self.caps.explicit_width) {
                try tty.writeAll(ctlseqs.unicode_set);
            }
        },
    }

    try tty.flush();
}

// the next render call will refresh the entire screen
pub fn queueRefresh(self: *Vaxis) void {
    self.refresh = true;
}

/// draws the screen to the terminal
pub fn render(self: *Vaxis, tty: *std.Io.Writer) !void {
    defer self.refresh = false;
    assert(self.screen.buf.len == @as(usize, @intCast(self.screen.width)) * self.screen.height); // correct size
    assert(self.screen.buf.len == self.screen_last.buf.len); // same size

    var started: bool = false;
    var sync_active: bool = false;
    errdefer if (sync_active) tty.writeAll(ctlseqs.sync_reset) catch {};

    const cursor_vis_changed = self.screen.cursor_vis != self.screen_last.cursor_vis;
    const cursor_shape_changed = self.screen.cursor_shape != self.screen_last.cursor_shape;
    const mouse_shape_changed = self.screen.mouse_shape != self.screen_last.mouse_shape;
    const cursor_pos_changed = self.screen.cursor_vis and
        (self.screen.cursor.row != self.state.cursor.row or
            self.screen.cursor.col != self.state.cursor.col);
    const cursor_secondary_changed = self.screen.cursor_vis and
        std.meta.eql(self.screen.cursor_secondary, self.state.cursor_secondary);
    const needs_render = self.refresh or
        cursor_vis_changed or
        cursor_shape_changed or
        mouse_shape_changed or
        cursor_pos_changed or
        cursor_secondary_changed;

    // initialize some variables
    var reposition: bool = false;
    var row: u16 = 0;
    var col: u16 = 0;
    var cursor: Style = .{};
    var link: Hyperlink = .{};
    const CursorPos = struct {
        row: u16 = 0,
        col: u16 = 0,
    };
    var cursor_pos: CursorPos = .{};

    const startRender = struct {
        fn run(
            vx: *Vaxis,
            io: *std.Io.Writer,
            cursor_pos_ptr: *CursorPos,
            reposition_ptr: *bool,
            started_ptr: *bool,
            sync_active_ptr: *bool,
        ) !void {
            if (started_ptr.*) return;
            started_ptr.* = true;
            sync_active_ptr.* = true;
            // Set up sync before we write anything
            try io.writeAll(ctlseqs.sync_set);
            // Send the cursor to 0,0
            try io.writeAll(ctlseqs.hide_cursor);
            if (vx.state.alt_screen)
                try io.writeAll(ctlseqs.home)
            else {
                try io.writeByte('\r');
                for (0..vx.state.cursor.row) |_| {
                    try io.writeAll(ctlseqs.ri);
                }
            }
            try io.writeAll(ctlseqs.sgr_reset);
            cursor_pos_ptr.* = .{};
            reposition_ptr.* = true;
            // Clear all images
            if (vx.caps.kitty_graphics)
                try io.writeAll(ctlseqs.kitty_graphics_clear);
        }
    };

    // Reset skip flag on all last_screen cells
    for (self.screen_last.buf) |*last_cell| {
        last_cell.skip = false;
    }

    if (needs_render) {
        try startRender.run(self, tty, &cursor_pos, &reposition, &started, &sync_active);
    }

    // Found before the cell pass so the pass can tell whether it painted
    // inside the raster's rectangle: sixel pixels live in the terminal's cell
    // buffer, so a repainted cell wipes them, and the raster is written after
    // the cell pass and re-sent when that happens.
    const sixel_place: ?SixelFrame = if (self.caps.sixel_graphics) self.findSixelPlacement() else null;
    var sixel_overdrawn = false;

    var i: usize = 0;
    while (i < self.screen.buf.len) {
        const cell = self.screen.buf[i];
        const w: u16 = blk: {
            if (cell.char.width != 0) break :blk cell.char.width;

            const method: gwidth.Method = self.caps.unicode;
            const width: u16 = @intCast(gwidth.gwidth(cell.char.grapheme, method));
            break :blk @max(1, width);
        };
        defer {
            // advance by the width of this char mod 1
            std.debug.assert(w > 0);
            var j = i + 1;
            while (j < i + w) : (j += 1) {
                if (j >= self.screen_last.buf.len) break;
                self.screen_last.buf[j].skipped = true;
            }
            col += w;
            i += w;
        }
        if (col >= self.screen.width) {
            row += 1;
            col = 0;
            // Rely on terminal wrapping to reposition into next row instead of forcing it
            if (!cell.wrapped)
                reposition = true;
        }
        // If cell is the same as our last frame, we don't need to do
        // anything
        const last = self.screen_last.buf[i];
        if ((!self.refresh and
            last.eql(cell) and
            !last.skipped and
            cell.image == null) or
            last.skip)
        {
            reposition = true;
            // Close any osc8 sequence we might be in before
            // repositioning
            if (link.uri.len > 0) {
                try tty.writeAll(ctlseqs.osc8_clear);
            }
            continue;
        }
        if (!started) {
            try startRender.run(self, tty, &cursor_pos, &reposition, &started, &sync_active);
        }
        self.screen_last.buf[i].skipped = false;
        if (sixel_place) |place| {
            if (place.rect.contains(col, row)) sixel_overdrawn = true;
        }
        defer {
            cursor = cell.style;
            link = cell.link;
        }
        // Set this cell in the last frame
        self.screen_last.writeCell(col, row, cell);

        // If we support scaled text, we set the flags now
        if (self.caps.scaled_text and cell.scale.scale > 1) {
            // The cell is scaled. Set appropriate skips. We only need to do this if the scale factor is
            // > 1
            assert(cell.char.width > 0);
            const cols = cell.scale.scale * cell.char.width;
            const rows = cell.scale.scale;
            for (0..rows) |skipped_row| {
                for (0..cols) |skipped_col| {
                    if (skipped_row == 0 and skipped_col == 0) {
                        continue;
                    }
                    const skipped_i = (@as(usize, @intCast(skipped_row + row)) * self.screen_last.width) + (skipped_col + col);
                    self.screen_last.buf[skipped_i].skip = true;
                }
            }
        }

        // reposition the cursor, if needed
        if (reposition) {
            reposition = false;
            link = .{};
            if (self.state.alt_screen)
                try tty.print(ctlseqs.cup, .{ row + 1, col + 1 })
            else {
                if (cursor_pos.row == row) {
                    const n = col - cursor_pos.col;
                    if (n > 0)
                        try tty.print(ctlseqs.cuf, .{n});
                } else {
                    const n = row - cursor_pos.row;
                    for (0..n) |_| {
                        try tty.writeByte('\n');
                    }
                    try tty.writeByte('\r');
                    if (col > 0)
                        try tty.print(ctlseqs.cuf, .{col});
                }
            }
        }

        if (cell.image) |img| {
            try tty.print(
                ctlseqs.kitty_graphics_preamble,
                .{img.img_id},
            );
            if (img.options.pixel_offset) |offset| {
                try tty.print(
                    ",X={d},Y={d}",
                    .{ offset.x, offset.y },
                );
            }
            if (img.options.clip_region) |clip| {
                if (clip.x) |x|
                    try tty.print(",x={d}", .{x});
                if (clip.y) |y|
                    try tty.print(",y={d}", .{y});
                if (clip.width) |width|
                    try tty.print(",w={d}", .{width});
                if (clip.height) |height|
                    try tty.print(",h={d}", .{height});
            }
            if (img.options.size) |size| {
                if (size.rows) |rows|
                    try tty.print(",r={d}", .{rows});
                if (size.cols) |cols|
                    try tty.print(",c={d}", .{cols});
            }
            if (img.options.z_index) |z| {
                try tty.print(",z={d}", .{z});
            }
            try tty.writeAll(ctlseqs.kitty_graphics_closing);
        }

        // something is different, so let's loop through everything and
        // find out what

        // foreground
        if (!self.caps.no_color and !Cell.Color.eql(cursor.fg, cell.style.fg)) {
            switch (cell.style.fg) {
                .default => try tty.writeAll(ctlseqs.fg_reset),
                .index => |idx| {
                    switch (idx) {
                        0...7 => try tty.print(ctlseqs.fg_base, .{idx}),
                        8...15 => try tty.print(ctlseqs.fg_bright, .{idx - 8}),
                        else => {
                            switch (self.sgr) {
                                .standard => try tty.print(ctlseqs.fg_indexed, .{idx}),
                                .legacy => try tty.print(ctlseqs.fg_indexed_legacy, .{idx}),
                            }
                        },
                    }
                },
                .rgb => |rgb| {
                    switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.fg_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => try tty.print(ctlseqs.fg_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
                    }
                },
            }
        }
        // background
        if (!self.caps.no_color and !Cell.Color.eql(cursor.bg, cell.style.bg)) {
            switch (cell.style.bg) {
                .default => try tty.writeAll(ctlseqs.bg_reset),
                .index => |idx| {
                    switch (idx) {
                        0...7 => try tty.print(ctlseqs.bg_base, .{idx}),
                        8...15 => try tty.print(ctlseqs.bg_bright, .{idx - 8}),
                        else => {
                            switch (self.sgr) {
                                .standard => try tty.print(ctlseqs.bg_indexed, .{idx}),
                                .legacy => try tty.print(ctlseqs.bg_indexed_legacy, .{idx}),
                            }
                        },
                    }
                },
                .rgb => |rgb| {
                    switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.bg_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => try tty.print(ctlseqs.bg_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
                    }
                },
            }
        }
        // underline color
        if (!self.caps.no_color and !Cell.Color.eql(cursor.ul, cell.style.ul)) {
            switch (cell.style.ul) {
                .default => try tty.writeAll(ctlseqs.ul_reset),
                .index => |idx| {
                    switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.ul_indexed, .{idx}),
                        .legacy => try tty.print(ctlseqs.ul_indexed_legacy, .{idx}),
                    }
                },
                .rgb => |rgb| {
                    if (self.enable_workarounds)
                        try tty.print(ctlseqs.ul_rgb_conpty, .{ rgb[0], rgb[1], rgb[2] })
                    else switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.ul_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => try tty.print(ctlseqs.ul_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
                    }
                },
            }
        }
        // underline style
        if (cursor.ul_style != cell.style.ul_style) {
            const seq = switch (cell.style.ul_style) {
                .off => ctlseqs.ul_off,
                .single => ctlseqs.ul_single,
                .double => ctlseqs.ul_double,
                .curly => ctlseqs.ul_curly,
                .dotted => ctlseqs.ul_dotted,
                .dashed => ctlseqs.ul_dashed,
            };
            try tty.writeAll(seq);
        }
        // bold
        if (cursor.bold != cell.style.bold) {
            const seq = switch (cell.style.bold) {
                true => ctlseqs.bold_set,
                false => ctlseqs.bold_dim_reset,
            };
            try tty.writeAll(seq);
            if (cell.style.dim) {
                try tty.writeAll(ctlseqs.dim_set);
            }
        }
        // dim
        if (cursor.dim != cell.style.dim) {
            const seq = switch (cell.style.dim) {
                true => ctlseqs.dim_set,
                false => ctlseqs.bold_dim_reset,
            };
            try tty.writeAll(seq);
            if (cell.style.bold) {
                try tty.writeAll(ctlseqs.bold_set);
            }
        }
        // dim
        if (cursor.italic != cell.style.italic) {
            const seq = switch (cell.style.italic) {
                true => ctlseqs.italic_set,
                false => ctlseqs.italic_reset,
            };
            try tty.writeAll(seq);
        }
        // dim
        if (cursor.blink != cell.style.blink) {
            const seq = switch (cell.style.blink) {
                true => ctlseqs.blink_set,
                false => ctlseqs.blink_reset,
            };
            try tty.writeAll(seq);
        }
        // reverse
        if (cursor.reverse != cell.style.reverse) {
            const seq = switch (cell.style.reverse) {
                true => ctlseqs.reverse_set,
                false => ctlseqs.reverse_reset,
            };
            try tty.writeAll(seq);
        }
        // invisible
        if (cursor.invisible != cell.style.invisible) {
            const seq = switch (cell.style.invisible) {
                true => ctlseqs.invisible_set,
                false => ctlseqs.invisible_reset,
            };
            try tty.writeAll(seq);
        }
        // strikethrough
        if (cursor.strikethrough != cell.style.strikethrough) {
            const seq = switch (cell.style.strikethrough) {
                true => ctlseqs.strikethrough_set,
                false => ctlseqs.strikethrough_reset,
            };
            try tty.writeAll(seq);
        }

        // url
        if (!std.mem.eql(u8, link.uri, cell.link.uri)) {
            var ps = cell.link.params;
            if (cell.link.uri.len == 0) {
                // Empty out the params no matter what if we don't have
                // a url
                ps = "";
            }
            try tty.print(ctlseqs.osc8, .{ ps, cell.link.uri });
        }

        // scale
        if (self.caps.scaled_text and !cell.scale.eql(.{})) {
            const scale = cell.scale;
            // We have a scaled cell.
            switch (cell.scale.denominator) {
                // Denominator cannot be 0
                0 => unreachable,
                1 => {
                    // no fractional scaling, just a straight scale factor
                    try tty.print(
                        ctlseqs.scaled_text,
                        .{ scale.scale, w, cell.char.grapheme },
                    );
                },
                else => {
                    // fractional scaling
                    // no fractional scaling, just a straight scale factor
                    try tty.print(
                        ctlseqs.scaled_text_with_fractions,
                        .{
                            scale.scale,
                            w,
                            scale.numerator,
                            scale.denominator,
                            @intFromEnum(scale.vertical_alignment),
                            cell.char.grapheme,
                        },
                    );
                },
            }
            cursor_pos.col = col + (w * scale.scale);
            cursor_pos.row = row;
            continue;
        }

        // If we have explicit width and our width is greater than 1, let's use it
        if (self.caps.explicit_width and w > 1) {
            try tty.print(ctlseqs.explicit_width, .{ w, cell.char.grapheme });
        } else {
            try tty.writeAll(cell.char.grapheme);
        }
        cursor_pos.col = col + w;
        cursor_pos.row = row;
    }

    // The raster goes last, on top of the cells.
    if (self.caps.sixel_graphics) sixel_draw: {
        const place = sixel_place orelse {
            // Nothing to show; erase whatever was showing.
            const last = self.sixel_last_rect orelse break :sixel_draw;
            if (!started)
                try startRender.run(self, tty, &cursor_pos, &reposition, &started, &sync_active);
            try eraseSixelRect(tty, last.col, last.row, last.cols, last.rows);
            self.blankSixelRect(last);
            self.sixel_last_rect = null;
            self.sixel_last_placement = null;
            reposition = true;
            break :sixel_draw;
        };

        // Streamed, not retained: send only when it would differ from what
        // the terminal already has -- a new frame, a move, a full refresh, or
        // cells repainted over its pixels.
        const same = if (self.sixel_last_placement) |prev|
            prev.eql(place.placement) and
                (if (self.sixel_last_rect) |last| last.eql(place.rect) else false)
        else
            false;
        if (same and !sixel_overdrawn and !self.refresh) break :sixel_draw;

        const gpa = self.sixel_gpa orelse break :sixel_draw;
        const img = self.findSixelImage(place.placement.img_id) orelse break :sixel_draw;
        if (!started)
            try startRender.run(self, tty, &cursor_pos, &reposition, &started, &sync_active);

        const payload: []const u8 = payload: {
            if (place.placement.clip) |clip| {
                // Clipped frames occur only while the raster crosses a
                // screen edge; they are encoded on demand rather than
                // cached.
                break :payload sixel.encodeAlloc(gpa, img.*, clip) catch |err| {
                    log.debug("sixel encode failed: {t}", .{err});
                    break :sixel_draw;
                };
            }
            if (img.payload == null) {
                img.payload = sixel.encodeAlloc(gpa, img.*, null) catch |err| {
                    log.debug("sixel encode failed: {t}", .{err});
                    break :sixel_draw;
                };
            }
            break :payload img.payload.?;
        };
        defer if (place.placement.clip != null) gpa.free(payload);

        // Erase where it was, if that is somewhere else, then where it is
        // going. The second erase runs on every frame: a transparent frame
        // leaves untouched pixels alone, so without it the previous frame
        // shows through its holes.
        if (self.sixel_last_rect) |last| {
            if (!last.eql(place.rect)) {
                try eraseSixelRect(tty, last.col, last.row, last.cols, last.rows);
                self.blankSixelRect(last);
            }
        }
        try eraseSixelRect(tty, place.rect.col, place.rect.row, place.rect.cols, place.rect.rows);
        self.blankSixelRect(place.rect);

        // A sixel leaves the cursor wherever the terminal decides, so save
        // and restore it around the payload.
        try tty.writeAll(ctlseqs.save_cursor);
        try tty.print(ctlseqs.cup, .{ place.rect.row + 1, place.rect.col + 1 });
        try tty.writeAll(payload);
        try tty.writeAll(ctlseqs.restore_cursor);
        self.sixel_last_rect = place.rect;
        self.sixel_last_placement = place.placement;
        reposition = true;
    }

    if (!started) return;
    if (self.screen.cursor_vis) {
        if (self.state.alt_screen) {
            try tty.print(
                ctlseqs.cup,
                .{
                    self.screen.cursor.row + 1,
                    self.screen.cursor.col + 1,
                },
            );
        } else {
            // TODO: position cursor relative to current location
            try tty.writeByte('\r');
            if (self.screen.cursor.row >= cursor_pos.row) {
                for (0..(self.screen.cursor.row - cursor_pos.row)) |_| {
                    try tty.writeByte('\n');
                }
            } else {
                for (0..(cursor_pos.row - self.screen.cursor.row)) |_| {
                    try tty.writeAll(ctlseqs.ri);
                }
            }
            if (self.screen.cursor.col > 0)
                try tty.print(ctlseqs.cuf, .{self.screen.cursor.col});
        }
        self.state.cursor.row = self.screen.cursor.row;
        self.state.cursor.col = self.screen.cursor.col;
        try tty.writeAll(ctlseqs.show_cursor);
    } else {
        self.state.cursor.row = cursor_pos.row;
        self.state.cursor.col = cursor_pos.col;
    }
    if (self.screen.cursor_vis and self.caps.multi_cursor) {
        try tty.print(ctlseqs.reset_secondary_cursors, .{});
        for (self.screen.cursor_secondary) |cur|
            try tty.print(ctlseqs.show_secondary_cursor, .{ cur.row + 1, cur.col + 1 });
        if (cursor_secondary_changed) {
            self.state.prev_cursor_secondary = self.state.cursor_secondary;
            self.state.cursor_secondary = self.screen.cursor_secondary;
        }
    }
    self.screen_last.cursor_vis = self.screen.cursor_vis;
    if (self.screen.mouse_shape != self.screen_last.mouse_shape) {
        try tty.print(
            ctlseqs.osc22_mouse_shape,
            .{@tagName(self.screen.mouse_shape)},
        );
        self.screen_last.mouse_shape = self.screen.mouse_shape;
    }
    if (self.screen.cursor_shape != self.screen_last.cursor_shape) {
        try tty.print(
            ctlseqs.cursor_shape,
            .{@intFromEnum(self.screen.cursor_shape)},
        );
        self.screen_last.cursor_shape = self.screen.cursor_shape;
    }

    try tty.writeAll(ctlseqs.sync_reset);
    try tty.flush();
}

fn enableKittyKeyboard(self: *Vaxis, tty: *std.Io.Writer, flags: Key.KittyFlags) !void {
    const flag_int: u5 = @bitCast(flags);
    try tty.print(ctlseqs.csi_u_push, .{flag_int});
    try tty.flush();
    self.state.kitty_keyboard = true;
}

/// send a system notification
pub fn notify(_: *Vaxis, tty: *std.Io.Writer, title: ?[]const u8, body: []const u8) !void {
    if (title) |t|
        try tty.print(ctlseqs.osc777_notify, .{ t, body })
    else
        try tty.print(ctlseqs.osc9_notify, .{body});

    try tty.flush();
}

/// sets the window title
pub fn setTitle(_: *Vaxis, tty: *std.Io.Writer, title: []const u8) !void {
    try tty.print(ctlseqs.osc2_set_title, .{title});
    try tty.flush();
}

// turn bracketed paste on or off. An event will be sent at the
// beginning and end of a detected paste. All keystrokes between these
// events were pasted
pub fn setBracketedPaste(self: *Vaxis, tty: *std.Io.Writer, enable: bool) !void {
    const seq = if (enable)
        ctlseqs.bp_set
    else
        ctlseqs.bp_reset;
    try tty.writeAll(seq);
    try tty.flush();
    self.state.bracketed_paste = enable;
}

/// set the mouse shape
pub fn setMouseShape(self: *Vaxis, shape: Shape) void {
    self.screen.mouse_shape = shape;
}

/// Change the mouse reporting mode
pub fn setMouseMode(self: *Vaxis, tty: *std.Io.Writer, enable: bool) !void {
    if (enable) {
        self.state.mouse = true;
        if (self.caps.sgr_pixels) {
            log.debug("enabling mouse mode: pixel coordinates", .{});
            self.state.pixel_mouse = true;
            try tty.writeAll(ctlseqs.mouse_set_pixels);
        } else {
            log.debug("enabling mouse mode: cell coordinates", .{});
            try tty.writeAll(ctlseqs.mouse_set);
        }
    } else {
        try tty.writeAll(ctlseqs.mouse_reset);
    }

    try tty.flush();
}

/// Translate pixel mouse coordinates to cell + offset
pub fn translateMouse(self: Vaxis, mouse: Mouse) Mouse {
    if (self.screen.width == 0 or self.screen.height == 0) return mouse;
    var result = mouse;
    if (self.state.pixel_mouse) {
        std.debug.assert(mouse.xoffset == 0);
        std.debug.assert(mouse.yoffset == 0);
        const xpos = mouse.col;
        const ypos = mouse.row;
        const xextra = self.screen.width_pix % self.screen.width;
        const yextra = self.screen.height_pix % self.screen.height;
        const xcell: i16 = @intCast((self.screen.width_pix - xextra) / self.screen.width);
        const ycell: i16 = @intCast((self.screen.height_pix - yextra) / self.screen.height);
        if (xcell == 0 or ycell == 0) return mouse;
        result.col = @divFloor(xpos, xcell);
        result.row = @divFloor(ypos, ycell);
        result.xoffset = @intCast(@mod(xpos, xcell));
        result.yoffset = @intCast(@mod(ypos, ycell));
    }
    return result;
}

/// Transmit an image using the local filesystem. Allocates only for base64 encoding
pub fn transmitLocalImagePath(
    self: *Vaxis,
    allocator: std.mem.Allocator,
    tty: *std.Io.Writer,
    payload: []const u8,
    width: u16,
    height: u16,
    medium: Image.TransmitMedium,
    format: Image.TransmitFormat,
) !Image {
    if (!self.caps.kitty_graphics) return error.NoGraphicsCapability;

    defer self.next_img_id += 1;

    const id = self.next_img_id;

    const size = base64Encoder.calcSize(payload.len);
    if (size >= 4096) return error.PathTooLong;

    const buf = try allocator.alloc(u8, size);
    const encoded = base64Encoder.encode(buf, payload);
    defer allocator.free(buf);

    const medium_char: u8 = switch (medium) {
        .file => 'f',
        .temp_file => 't',
        .shared_mem => 's',
    };

    switch (format) {
        .rgb => {
            try tty.print(
                "\x1b_Gf=24,s={d},v={d},i={d},t={c};{s}\x1b\\",
                .{ width, height, id, medium_char, encoded },
            );
        },
        .rgba => {
            try tty.print(
                "\x1b_Gf=32,s={d},v={d},i={d},t={c};{s}\x1b\\",
                .{ width, height, id, medium_char, encoded },
            );
        },
        .png => {
            try tty.print(
                "\x1b_Gf=100,i={d},t={c};{s}\x1b\\",
                .{ id, medium_char, encoded },
            );
        },
    }

    try tty.flush();
    return .{
        .id = id,
        .width = width,
        .height = height,
    };
}

/// Transmit an image which has been pre-base64 encoded
pub fn transmitPreEncodedImage(
    self: *Vaxis,
    tty: *std.Io.Writer,
    bytes: []const u8,
    width: u16,
    height: u16,
    format: Image.TransmitFormat,
) !Image {
    if (!self.caps.kitty_graphics) return error.NoGraphicsCapability;

    defer self.next_img_id += 1;
    const id = self.next_img_id;

    const fmt: u8 = switch (format) {
        .rgb => 24,
        .rgba => 32,
        .png => 100,
    };

    if (bytes.len < 4096) {
        try tty.print(
            "\x1b_Gf={d},s={d},v={d},i={d};{s}\x1b\\",
            .{
                fmt,
                width,
                height,
                id,
                bytes,
            },
        );
    } else {
        var n: usize = 4096;

        try tty.print(
            "\x1b_Gf={d},s={d},v={d},i={d},m=1;{s}\x1b\\",
            .{ fmt, width, height, id, bytes[0..n] },
        );
        while (n < bytes.len) : (n += 4096) {
            const end: usize = @min(n + 4096, bytes.len);
            const m: u2 = if (end == bytes.len) 0 else 1;
            try tty.print(
                "\x1b_Gm={d};{s}\x1b\\",
                .{
                    m,
                    bytes[n..end],
                },
            );
        }
    }

    try tty.flush();
    return .{
        .id = id,
        .width = width,
        .height = height,
    };
}

pub fn transmitImage(
    self: *Vaxis,
    alloc: std.mem.Allocator,
    tty: *std.Io.Writer,
    img: *const zigimg.Image,
    format: Image.TransmitFormat,
) !Image {
    if (!self.caps.kitty_graphics) return error.NoGraphicsCapability;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var img_modifiable = img.*;

    const buf = switch (format) {
        .png => png: {
            const png_buf = try arena.allocator().alloc(u8, img.imageByteSize());
            const png = try img.writeToMemory(arena.allocator(), png_buf, .{ .png = .{} });
            break :png png;
        },
        .rgb => rgb: {
            try img_modifiable.convertNoFree(arena.allocator(), .rgb24);
            break :rgb img_modifiable.rawBytes();
        },
        .rgba => rgba: {
            try img_modifiable.convertNoFree(arena.allocator(), .rgba32);
            break :rgba img_modifiable.rawBytes();
        },
    };

    const b64_buf = try arena.allocator().alloc(u8, base64Encoder.calcSize(buf.len));
    const encoded = base64Encoder.encode(b64_buf, buf);

    return self.transmitPreEncodedImage(tty, encoded, @intCast(img.width), @intCast(img.height), format);
}

pub fn loadImage(
    self: *Vaxis,
    alloc: std.mem.Allocator,
    tty: *std.Io.Writer,
    src: Image.Source,
) !Image {
    if (!self.caps.kitty_graphics) return error.NoGraphicsCapability;

    var read_buffer: [1024 * 1024]u8 = undefined; // 1MB buffer
    var img = switch (src) {
        .path => |path| try zigimg.Image.fromFilePath(alloc, self.io, path, &read_buffer),
        .mem => |bytes| try zigimg.Image.fromMemory(alloc, bytes),
    };
    defer img.deinit(alloc);
    return self.transmitImage(alloc, tty, &img, .png);
}

/// Applies the primary device attributes. Sixel needs both halves: the
/// attribute bit claims the protocol, and the geometry report proves the
/// terminal answered a graphics query -- a multiplexer can forward the bit
/// while swallowing the query.
pub fn applyDa1(self: *Vaxis, da1: @import("event.zig").Da1) void {
    if (da1.sixel and self.sixel_geometry != null) {
        log.info("sixel graphics capability detected", .{});
        self.caps.sixel_graphics = true;
    } else if (da1.sixel) {
        log.info("sixel claimed in device attributes but no geometry reported; not enabling", .{});
    }
}

/// The measured pixel size of one cell, or null when the terminal reported
/// no usable pixel geometry; callers fall back rather than guess.
pub fn cellPixelSize(self: Vaxis) ?struct { width: u16, height: u16 } {
    if (self.screen.width == 0 or self.screen.height == 0) return null;
    if (self.screen.width_pix == 0 or self.screen.height_pix == 0) return null;
    const w = self.screen.width_pix / self.screen.width;
    const h = self.screen.height_pix / self.screen.height;
    if (w == 0 or h == 0) return null;
    return .{ .width = w, .height = h };
}

/// Decodes an image and holds it at the pixel size of a `cols` x `rows` cell
/// rectangle, ready to be placed. Nothing is written to the terminal here:
/// payloads travel at render time. The returned id stays valid until
/// `clearSixelImages`, which resize and teardown both call.
pub fn loadSixelImage(
    self: *Vaxis,
    gpa: std.mem.Allocator,
    bytes: []const u8,
    cols: u16,
    rows: u16,
) !u32 {
    if (!self.caps.sixel_graphics) return error.NoGraphicsCapability;
    const cell = self.cellPixelSize() orelse return sixel.Error.SixelGeometryUnusable;
    const width = std.math.mul(u16, cols, cell.width) catch return sixel.Error.SixelRasterTooLarge;
    const height = std.math.mul(u16, rows, cell.height) catch return sixel.Error.SixelRasterTooLarge;
    if (self.sixel_geometry) |max| {
        if (width > max.width or height > max.height) return sixel.Error.SixelRasterTooLarge;
    }

    const id = self.next_sixel_id;
    var img = try sixel.decode(gpa, id, bytes, width, height);
    errdefer img.deinit(gpa);
    try self.sixel_images.append(gpa, img);
    self.sixel_gpa = gpa;
    self.next_sixel_id += 1;
    return id;
}

/// Whether a raster is still loaded. A resize drops every raster, so this is
/// how a caller notices its ids went stale and re-loads.
pub fn hasSixelImage(self: *Vaxis, id: u32) bool {
    return self.findSixelImage(id) != null;
}

fn findSixelImage(self: *Vaxis, id: u32) ?*sixel.Image {
    for (self.sixel_images.items) |*img| {
        if (img.id == id) return img;
    }
    return null;
}

/// The first sixel placement in scan order, if any. One placement per frame
/// is the contract: sixel is streamed, and several rasters would multiply
/// the per-frame byte cost.
fn findSixelPlacement(self: *Vaxis) ?SixelFrame {
    for (self.screen.buf, 0..) |cell, i| {
        const placement = cell.sixel orelse continue;
        return .{
            .rect = .{
                .col = @intCast(i % self.screen.width),
                .row = @intCast(i / self.screen.width),
                .cols = placement.cols,
                .rows = placement.rows,
            },
            .placement = placement,
        };
    }
    return null;
}

/// Records that `rect` was erased by making the diff's copy of it blank, so
/// the diff repaints content it would otherwise believe is still visible.
/// Blank rather than dirty: blank next-frame cells produce no output and
/// leave the raster alone.
fn blankSixelRect(self: *Vaxis, rect: Rect) void {
    var r: u16 = 0;
    while (r < rect.rows) : (r += 1) {
        const y = rect.row + r;
        if (y >= self.screen_last.height) break;
        var c: u16 = 0;
        while (c < rect.cols) : (c += 1) {
            const x = rect.col + c;
            if (x >= self.screen_last.width) break;
            self.screen_last.writeCell(x, y, .{});
            self.screen_last.buf[@as(usize, y) * self.screen_last.width + x].skipped = false;
        }
    }
}

/// Drops every loaded sixel raster and forgets what was on screen. Called on
/// resize and teardown: payloads are only valid for the cell geometry they
/// were encoded at.
pub fn clearSixelImages(self: *Vaxis, gpa: std.mem.Allocator) void {
    for (self.sixel_images.items) |*img| img.deinit(gpa);
    self.sixel_images.clearAndFree(gpa);
    self.sixel_last_rect = null;
    self.sixel_last_placement = null;
    self.sixel_gpa = null;
}

/// Erases the cell rectangle a sixel occupied. Sixel pixels live in the
/// terminal's cell buffer, so erasing the cells is what removes them.
fn eraseSixelRect(
    tty: *std.Io.Writer,
    col: u16,
    row: u16,
    cols: u16,
    rows: u16,
) !void {
    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        try tty.print(ctlseqs.cup, .{ row + r + 1, col + 1 });
        try tty.print(ctlseqs.erase_chars, .{cols});
    }
}

/// deletes an image from the terminal's memory
pub fn freeImage(_: Vaxis, tty: *std.Io.Writer, id: u32) void {
    tty.print("\x1b_Ga=d,d=I,i={d};\x1b\\", .{id}) catch |err| {
        log.err("couldn't delete image {d}: {}", .{ id, err });
        return;
    };
    tty.flush() catch {};
}

pub fn copyToSystemClipboard(_: Vaxis, tty: *std.Io.Writer, text: []const u8, encode_allocator: std.mem.Allocator) !void {
    const encoder = std.base64.standard.Encoder;
    const size = encoder.calcSize(text.len);
    const buf = try encode_allocator.alloc(u8, size);
    const b64 = encoder.encode(buf, text);
    defer encode_allocator.free(buf);
    try tty.print(
        ctlseqs.osc52_clipboard_copy,
        .{b64},
    );

    try tty.flush();
}

pub fn requestSystemClipboard(self: Vaxis, tty: *std.Io.Writer) !void {
    if (self.opts.system_clipboard_allocator == null) return error.NoClipboardAllocator;
    try tty.print(
        ctlseqs.osc52_clipboard_request,
        .{},
    );
    try tty.flush();
}

/// Set the default terminal foreground color
pub fn setTerminalForegroundColor(self: *Vaxis, tty: *std.Io.Writer, rgb: [3]u8) !void {
    try tty.print(ctlseqs.osc10_set, .{ rgb[0], rgb[0], rgb[1], rgb[1], rgb[2], rgb[2] });
    try tty.flush();
    self.state.changed_default_fg = true;
}

/// Set the default terminal background color
pub fn setTerminalBackgroundColor(self: *Vaxis, tty: *std.Io.Writer, rgb: [3]u8) !void {
    try tty.print(ctlseqs.osc11_set, .{ rgb[0], rgb[0], rgb[1], rgb[1], rgb[2], rgb[2] });
    try tty.flush();
    self.state.changed_default_bg = true;
}

/// Set the terminal cursor color
pub fn setTerminalCursorColor(self: *Vaxis, tty: *std.Io.Writer, rgb: [3]u8) !void {
    try tty.print(ctlseqs.osc12_set, .{ rgb[0], rgb[0], rgb[1], rgb[1], rgb[2], rgb[2] });
    try tty.flush();
    self.state.changed_cursor_color = true;
}

/// Set the terminal secondary cursor color
pub fn setTerminalCursorSecondaryColor(self: *Vaxis, tty: *std.Io.Writer, rgb: [3]u8) error{WriteFailed}!void {
    if (self.caps.multi_cursor) {
        try tty.print(ctlseqs.secondary_cursors_rgb, .{ rgb[0], rgb[1], rgb[2] });
        try tty.flush();
        self.state.changed_cursor_color = true;
    }
}

pub fn resetAllTerminalSecondaryCursors(self: *Vaxis, alloc: std.mem.Allocator) error{OutOfMemory}!void {
    if (self.state.prev_cursor_secondary.ptr != self.state.cursor_secondary.ptr) {
        alloc.free(self.state.prev_cursor_secondary);
        self.state.prev_cursor_secondary = &.{};
    }
    if (self.screen.cursor_secondary.ptr != self.state.cursor_secondary.ptr)
        alloc.free(self.screen.cursor_secondary);
    self.screen.cursor_secondary = &.{};
}

pub fn addTerminalSecondaryCursor(self: *Vaxis, alloc: std.mem.Allocator, y: u16, x: u16) error{OutOfMemory}!void {
    if (self.state.prev_cursor_secondary.ptr != self.state.cursor_secondary.ptr) {
        alloc.free(self.state.prev_cursor_secondary);
        self.state.prev_cursor_secondary = &.{};
    }
    var cursors: std.ArrayList(Screen.Cursor) = if (self.screen.cursor_secondary.ptr == self.state.cursor_secondary.ptr)
        .fromOwnedSlice(try alloc.dupe(Cursor, self.screen.cursor_secondary))
    else
        .fromOwnedSlice(self.screen.cursor_secondary);

    (try cursors.addOne(alloc)).* = .{ .row = y, .col = x };
    self.screen.cursor_secondary = try cursors.toOwnedSlice(alloc);
}

/// Request a color report from the terminal. Note: not all terminals support
/// reporting colors. It is always safe to try, but you may not receive a
/// response.
pub fn queryColor(_: Vaxis, tty: *std.Io.Writer, kind: Cell.Color.Kind) !void {
    switch (kind) {
        .fg => try tty.writeAll(ctlseqs.osc10_query),
        .bg => try tty.writeAll(ctlseqs.osc11_query),
        .cursor => try tty.writeAll(ctlseqs.osc12_query),
        .index => |idx| try tty.print(ctlseqs.osc4_query, .{idx}),
    }
    try tty.flush();
}

/// Subscribe to color theme updates. A `color_scheme: Color.Scheme` tag must
/// exist on your Event type to receive the response. This is a queried
/// capability. Support can be detected by checking the value of
/// vaxis.caps.color_scheme_updates. The initial scheme will be reported when
/// subscribing.
pub fn subscribeToColorSchemeUpdates(self: *Vaxis, tty: *std.Io.Writer) !void {
    try tty.writeAll(ctlseqs.color_scheme_request);
    try tty.writeAll(ctlseqs.color_scheme_set);
    try tty.flush();
    self.state.color_scheme_updates = true;
}

pub fn deviceStatusReport(_: Vaxis, tty: *std.Io.Writer) !void {
    try tty.writeAll(ctlseqs.device_status_report);
    try tty.flush();
}

/// prettyPrint is used to print the contents of the Screen to the tty. The state is not stored, and
/// the cursor will be put on the next line after the last line is printed. This is useful to
/// sequentially print data in a styled format to eg. stdout. This function returns an error if you
/// are not in the alt screen. The cursor is always hidden, and mouse shapes are not available
pub fn prettyPrint(self: *Vaxis, tty: *std.Io.Writer) !void {
    if (self.state.alt_screen) return error.NotInPrimaryScreen;

    try tty.writeAll(ctlseqs.hide_cursor);
    try tty.writeAll(ctlseqs.sync_set);
    defer tty.writeAll(ctlseqs.sync_reset) catch {};
    try tty.writeAll(ctlseqs.sgr_reset);
    defer tty.writeAll(ctlseqs.sgr_reset) catch {};

    var reposition: bool = false;
    var row: u16 = 0;
    var col: u16 = 0;
    var cursor: Style = .{};
    var link: Hyperlink = .{};
    var cursor_pos: struct {
        row: u16 = 0,
        col: u16 = 0,
    } = .{};

    var i: u16 = 0;
    while (i < self.screen.buf.len) {
        const cell = self.screen.buf[i];
        const w = blk: {
            if (cell.char.width != 0) break :blk cell.char.width;

            const method: gwidth.Method = self.caps.unicode;
            const width = gwidth.gwidth(cell.char.grapheme, method);
            break :blk @max(1, width);
        };
        defer {
            // advance by the width of this char mod 1
            std.debug.assert(w > 0);
            var j = i + 1;
            while (j < i + w) : (j += 1) {
                if (j >= self.screen_last.buf.len) break;
                self.screen_last.buf[j].skipped = true;
            }
            col += w;
            i += w;
        }
        if (col >= self.screen.width) {
            row += 1;
            col = 0;
            // Rely on terminal wrapping to reposition into next row instead of forcing it
            if (!cell.wrapped)
                reposition = true;
        }
        if (cell.default) {
            reposition = true;
            continue;
        }
        defer {
            cursor = cell.style;
            link = cell.link;
        }

        // reposition the cursor, if needed
        if (reposition) {
            reposition = false;
            link = .{};
            if (cursor_pos.row == row) {
                const n = col - cursor_pos.col;
                if (n > 0)
                    try tty.print(ctlseqs.cuf, .{n});
            } else {
                const n = row - cursor_pos.row;
                for (0..n) |_| {
                    try tty.writeByte('\n');
                }
                try tty.writeByte('\r');
                if (col > 0)
                    try tty.print(ctlseqs.cuf, .{col});
            }
        }

        if (cell.image) |img| {
            try tty.print(
                ctlseqs.kitty_graphics_preamble,
                .{img.img_id},
            );
            if (img.options.pixel_offset) |offset| {
                try tty.print(
                    ",X={d},Y={d}",
                    .{ offset.x, offset.y },
                );
            }
            if (img.options.clip_region) |clip| {
                if (clip.x) |x|
                    try tty.print(",x={d}", .{x});
                if (clip.y) |y|
                    try tty.print(",y={d}", .{y});
                if (clip.width) |width|
                    try tty.print(",w={d}", .{width});
                if (clip.height) |height|
                    try tty.print(",h={d}", .{height});
            }
            if (img.options.size) |size| {
                if (size.rows) |rows|
                    try tty.print(",r={d}", .{rows});
                if (size.cols) |cols|
                    try tty.print(",c={d}", .{cols});
            }
            if (img.options.z_index) |z| {
                try tty.print(",z={d}", .{z});
            }
            try tty.writeAll(ctlseqs.kitty_graphics_closing);
        }

        // something is different, so let's loop through everything and
        // find out what

        // foreground
        if (!self.caps.no_color and !Cell.Color.eql(cursor.fg, cell.style.fg)) {
            switch (cell.style.fg) {
                .default => try tty.writeAll(ctlseqs.fg_reset),
                .index => |idx| {
                    switch (idx) {
                        0...7 => try tty.print(ctlseqs.fg_base, .{idx}),
                        8...15 => try tty.print(ctlseqs.fg_bright, .{idx - 8}),
                        else => {
                            switch (self.sgr) {
                                .standard => try tty.print(ctlseqs.fg_indexed, .{idx}),
                                .legacy => try tty.print(ctlseqs.fg_indexed_legacy, .{idx}),
                            }
                        },
                    }
                },
                .rgb => |rgb| {
                    switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.fg_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => try tty.print(ctlseqs.fg_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
                    }
                },
            }
        }
        // background
        if (!self.caps.no_color and !Cell.Color.eql(cursor.bg, cell.style.bg)) {
            switch (cell.style.bg) {
                .default => try tty.writeAll(ctlseqs.bg_reset),
                .index => |idx| {
                    switch (idx) {
                        0...7 => try tty.print(ctlseqs.bg_base, .{idx}),
                        8...15 => try tty.print(ctlseqs.bg_bright, .{idx - 8}),
                        else => {
                            switch (self.sgr) {
                                .standard => try tty.print(ctlseqs.bg_indexed, .{idx}),
                                .legacy => try tty.print(ctlseqs.bg_indexed_legacy, .{idx}),
                            }
                        },
                    }
                },
                .rgb => |rgb| {
                    switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.bg_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => try tty.print(ctlseqs.bg_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] }),
                    }
                },
            }
        }
        // underline color
        if (!self.caps.no_color and !Cell.Color.eql(cursor.ul, cell.style.ul)) {
            switch (cell.style.ul) {
                .default => try tty.writeAll(ctlseqs.ul_reset),
                .index => |idx| {
                    switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.ul_indexed, .{idx}),
                        .legacy => try tty.print(ctlseqs.ul_indexed_legacy, .{idx}),
                    }
                },
                .rgb => |rgb| {
                    if (self.enable_workarounds)
                        try tty.print(ctlseqs.ul_rgb_conpty, .{ rgb[0], rgb[1], rgb[2] })
                    else switch (self.sgr) {
                        .standard => try tty.print(ctlseqs.ul_rgb, .{ rgb[0], rgb[1], rgb[2] }),
                        .legacy => {
                            try tty.print(ctlseqs.ul_rgb_legacy, .{ rgb[0], rgb[1], rgb[2] });
                        },
                    }
                },
            }
        }
        // underline style
        if (cursor.ul_style != cell.style.ul_style) {
            const seq = switch (cell.style.ul_style) {
                .off => ctlseqs.ul_off,
                .single => ctlseqs.ul_single,
                .double => ctlseqs.ul_double,
                .curly => ctlseqs.ul_curly,
                .dotted => ctlseqs.ul_dotted,
                .dashed => ctlseqs.ul_dashed,
            };
            try tty.writeAll(seq);
        }
        // bold
        if (cursor.bold != cell.style.bold) {
            const seq = switch (cell.style.bold) {
                true => ctlseqs.bold_set,
                false => ctlseqs.bold_dim_reset,
            };
            try tty.writeAll(seq);
            if (cell.style.dim) {
                try tty.writeAll(ctlseqs.dim_set);
            }
        }
        // dim
        if (cursor.dim != cell.style.dim) {
            const seq = switch (cell.style.dim) {
                true => ctlseqs.dim_set,
                false => ctlseqs.bold_dim_reset,
            };
            try tty.writeAll(seq);
            if (cell.style.bold) {
                try tty.writeAll(ctlseqs.bold_set);
            }
        }
        // dim
        if (cursor.italic != cell.style.italic) {
            const seq = switch (cell.style.italic) {
                true => ctlseqs.italic_set,
                false => ctlseqs.italic_reset,
            };
            try tty.writeAll(seq);
        }
        // dim
        if (cursor.blink != cell.style.blink) {
            const seq = switch (cell.style.blink) {
                true => ctlseqs.blink_set,
                false => ctlseqs.blink_reset,
            };
            try tty.writeAll(seq);
        }
        // reverse
        if (cursor.reverse != cell.style.reverse) {
            const seq = switch (cell.style.reverse) {
                true => ctlseqs.reverse_set,
                false => ctlseqs.reverse_reset,
            };
            try tty.writeAll(seq);
        }
        // invisible
        if (cursor.invisible != cell.style.invisible) {
            const seq = switch (cell.style.invisible) {
                true => ctlseqs.invisible_set,
                false => ctlseqs.invisible_reset,
            };
            try tty.writeAll(seq);
        }
        // strikethrough
        if (cursor.strikethrough != cell.style.strikethrough) {
            const seq = switch (cell.style.strikethrough) {
                true => ctlseqs.strikethrough_set,
                false => ctlseqs.strikethrough_reset,
            };
            try tty.writeAll(seq);
        }

        // url
        if (!std.mem.eql(u8, link.uri, cell.link.uri)) {
            var ps = cell.link.params;
            if (cell.link.uri.len == 0) {
                // Empty out the params no matter what if we don't have
                // a url
                ps = "";
            }
            try tty.print(ctlseqs.osc8, .{ ps, cell.link.uri });
        }
        try tty.writeAll(cell.char.grapheme);
        cursor_pos.col = col + w;
        cursor_pos.row = row;
    }
    try tty.writeAll("\r\n");
    try tty.flush();
}

/// Set the terminal's current working directory
pub fn setTerminalWorkingDirectory(_: *Vaxis, tty: *std.Io.Writer, path: []const u8) !void {
    if (path.len == 0 or path[0] != '/')
        return error.InvalidAbsolutePath;
    const hostname = switch (builtin.os.tag) {
        .windows => null,
        else => std.posix.getenv("HOSTNAME"),
    } orelse "localhost";

    const uri: std.Uri = .{
        .scheme = "file",
        .host = .{ .raw = hostname },
        .path = .{ .raw = path },
    };
    try tty.print(ctlseqs.osc7, .{uri.fmt(.{ .scheme = true, .authority = true, .path = true })});
    try tty.flush();
}

test "render: no output when no changes" {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    var vx = try Vaxis.init(io, std.testing.allocator, &env_map, .{});
    var deinit_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer deinit_writer.deinit();
    defer vx.deinit(std.testing.allocator, &deinit_writer.writer);

    var render_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer render_writer.deinit();
    try vx.render(&render_writer.writer);
    const output = try render_writer.toOwnedSlice();
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, 0), output.len);
}

/// A Vaxis with a `cols` x `rows` screen, 10x20 pixel cells, and sixel
/// enabled.
fn testVaxisSixel(
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    tty: *std.Io.Writer,
    cols: u16,
    rows: u16,
) !Vaxis {
    var vx = try Vaxis.init(std.testing.io, gpa, env_map, .{});
    errdefer vx.deinit(gpa, tty);
    vx.caps.sixel_graphics = true;
    vx.sixel_geometry = .{ .width = 1000, .height = 1000 };
    try vx.resize(gpa, tty, .{
        .cols = cols,
        .rows = rows,
        .x_pixel = cols * 10,
        .y_pixel = rows * 20,
    });
    return vx;
}

/// Registers a solid raster directly, bypassing the decoder.
fn testLoadSolidSixel(vx: *Vaxis, gpa: std.mem.Allocator) !u32 {
    const w: u16 = 20;
    const h: u16 = 20;
    const indexed = try gpa.alloc(u8, @as(usize, w) * h);
    @memset(indexed, sixel.quantize(255, 0, 0));
    const id = vx.next_sixel_id;
    try vx.sixel_images.append(gpa, .{
        .id = id,
        .width = w,
        .height = h,
        .indexed = indexed,
    });
    vx.next_sixel_id += 1;
    vx.sixel_gpa = gpa;
    return id;
}

test "applyDa1 needs both the attribute and a geometry report" {
    const gpa = std.testing.allocator;
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();

    // The attribute alone is not support: a multiplexer can forward it while
    // swallowing the protocol.
    {
        var vx = try Vaxis.init(std.testing.io, gpa, &env_map, .{});
        defer vx.deinit(gpa, &w.writer);
        vx.applyDa1(.{ .sixel = true });
        try std.testing.expect(!vx.caps.sixel_graphics);
    }
    // A geometry report alone is not support either.
    {
        var vx = try Vaxis.init(std.testing.io, gpa, &env_map, .{});
        defer vx.deinit(gpa, &w.writer);
        vx.sixel_geometry = .{ .width = 800, .height = 480 };
        vx.applyDa1(.{});
        try std.testing.expect(!vx.caps.sixel_graphics);
    }
    // Both halves, from the terminal's own answers.
    {
        var vx = try Vaxis.init(std.testing.io, gpa, &env_map, .{});
        defer vx.deinit(gpa, &w.writer);
        vx.sixel_geometry = .{ .width = 800, .height = 480 };
        vx.applyDa1(.{ .sixel = true });
        try std.testing.expect(vx.caps.sixel_graphics);
    }
}

test "cellPixelSize refuses to guess when the terminal reports no pixels" {
    const gpa = std.testing.allocator;
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    var vx = try Vaxis.init(std.testing.io, gpa, &env_map, .{});
    defer vx.deinit(gpa, &w.writer);

    try vx.resize(gpa, &w.writer, .{ .cols = 80, .rows = 24, .x_pixel = 0, .y_pixel = 0 });
    try std.testing.expectEqual(@as(?@TypeOf(vx.cellPixelSize().?), null), vx.cellPixelSize());

    try vx.resize(gpa, &w.writer, .{ .cols = 80, .rows = 24, .x_pixel = 800, .y_pixel = 480 });
    const cell = vx.cellPixelSize().?;
    try std.testing.expectEqual(@as(u16, 10), cell.width);
    try std.testing.expectEqual(@as(u16, 20), cell.height);
}

test "render places a sixel payload bracketed by a cursor save and restore" {
    const gpa = std.testing.allocator;
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    var vx = try testVaxisSixel(gpa, &env_map, &w.writer, 20, 6);
    defer vx.deinit(gpa, &w.writer);
    const id = try testLoadSolidSixel(&vx, gpa);

    vx.screen.writeCell(3, 2, .{ .sixel = .{ .img_id = id, .cols = 2, .rows = 1 } });
    w.clearRetainingCapacity();
    try vx.render(&w.writer);
    const out = w.written();

    const dcs = std.mem.indexOf(u8, out, "\x1bP0;1;0q").?;
    const save = std.mem.indexOf(u8, out, ctlseqs.save_cursor).?;
    const restore = std.mem.lastIndexOf(u8, out, ctlseqs.restore_cursor).?;
    try std.testing.expect(save < dcs);
    try std.testing.expect(dcs < restore);
    // Positioned at the placement cell, 1-indexed.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[3;4H") != null);
    // The rectangle is erased before the payload.
    const erase = std.mem.indexOf(u8, out, "\x1b[2X").?;
    try std.testing.expect(erase < dcs);
    // Exactly one payload per frame.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1bP0;1;0q"));
}

test "render sends nothing when the terminal never earned the capability" {
    const gpa = std.testing.allocator;
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    var vx = try testVaxisSixel(gpa, &env_map, &w.writer, 20, 6);
    defer vx.deinit(gpa, &w.writer);
    const id = try testLoadSolidSixel(&vx, gpa);

    // Not one byte of image control data may reach an incapable terminal.
    vx.caps.sixel_graphics = false;
    vx.screen.writeCell(3, 2, .{ .sixel = .{ .img_id = id, .cols = 2, .rows = 1 } });
    w.clearRetainingCapacity();
    try vx.render(&w.writer);
    const out = w.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1bP") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2X") == null);
}

test "a raster that moves erases the rectangle it left behind" {
    const gpa = std.testing.allocator;
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    var vx = try testVaxisSixel(gpa, &env_map, &w.writer, 20, 6);
    defer vx.deinit(gpa, &w.writer);
    const id = try testLoadSolidSixel(&vx, gpa);

    vx.screen.writeCell(3, 2, .{ .sixel = .{ .img_id = id, .cols = 2, .rows = 1 } });
    try vx.render(&w.writer);
    try std.testing.expect(vx.sixel_last_rect != null);

    // One cell to the right on the next frame.
    vx.screen.clear();
    vx.screen.writeCell(4, 2, .{ .sixel = .{ .img_id = id, .cols = 2, .rows = 1 } });
    w.clearRetainingCapacity();
    try vx.render(&w.writer);
    const out = w.written();
    // The old rectangle is erased at its own position...
    const old_erase = std.mem.indexOf(u8, out, "\x1b[3;4H\x1b[2X").?;
    // ...before the new frame is drawn at the new one.
    const new_pos = std.mem.indexOf(u8, out, "\x1b[3;5H").?;
    try std.testing.expect(old_erase < new_pos);
    try std.testing.expectEqual(@as(u16, 4), vx.sixel_last_rect.?.col);

    // And when the placement disappears entirely, so do the pixels.
    vx.screen.clear();
    w.clearRetainingCapacity();
    try vx.render(&w.writer);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "\x1b[3;5H\x1b[2X") != null);
    try std.testing.expectEqual(@as(?Rect, null), vx.sixel_last_rect);
}

test "resize drops every loaded raster" {
    const gpa = std.testing.allocator;
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    var vx = try testVaxisSixel(gpa, &env_map, &w.writer, 20, 6);
    defer vx.deinit(gpa, &w.writer);
    _ = try testLoadSolidSixel(&vx, gpa);
    vx.sixel_last_rect = .{ .col = 1, .row = 1, .cols = 2, .rows = 1 };

    // A resize can change the pixel size of a cell, so a raster encoded for
    // the old geometry is stale rather than merely misplaced.
    try vx.resize(gpa, &w.writer, .{ .cols = 40, .rows = 10, .x_pixel = 320, .y_pixel = 170 });
    try std.testing.expectEqual(@as(usize, 0), vx.sixel_images.items.len);
    try std.testing.expectEqual(@as(?Rect, null), vx.sixel_last_rect);
}

test "loadSixelImage refuses geometry it cannot size a raster from" {
    const gpa = std.testing.allocator;
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    var vx = try Vaxis.init(std.testing.io, gpa, &env_map, .{});
    defer vx.deinit(gpa, &w.writer);

    // No capability: not even a decode is attempted.
    try std.testing.expectError(error.NoGraphicsCapability, vx.loadSixelImage(gpa, "", 2, 1));

    // Capability, but the terminal reports no pixel geometry.
    vx.caps.sixel_graphics = true;
    try vx.resize(gpa, &w.writer, .{ .cols = 20, .rows = 6, .x_pixel = 0, .y_pixel = 0 });
    try std.testing.expectError(sixel.Error.SixelGeometryUnusable, vx.loadSixelImage(gpa, "", 2, 1));

    // Geometry, but larger than the terminal said it would accept.
    try vx.resize(gpa, &w.writer, .{ .cols = 20, .rows = 6, .x_pixel = 200, .y_pixel = 120 });
    vx.sixel_geometry = .{ .width = 16, .height = 16 };
    try std.testing.expectError(sixel.Error.SixelRasterTooLarge, vx.loadSixelImage(gpa, "", 4, 4));
}

test "an unchanged raster is not streamed again" {
    const gpa = std.testing.allocator;
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    var vx = try testVaxisSixel(gpa, &env_map, &w.writer, 20, 6);
    defer vx.deinit(gpa, &w.writer);
    const id = try testLoadSolidSixel(&vx, gpa);

    const placement: sixel.Placement = .{ .img_id = id, .cols = 2, .rows = 1 };
    vx.screen.writeCell(3, 2, .{ .sixel = placement });
    try vx.render(&w.writer);

    // Same frame, same place: the terminal already has it.
    w.clearRetainingCapacity();
    try vx.render(&w.writer);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, w.written(), "\x1bP0;1;0q"));

    // A new frame is a new payload.
    vx.screen.writeCell(3, 2, .{ .sixel = .{ .img_id = id, .cols = 2, .rows = 1, .clip = .{ .x = 0, .width = 10 } } });
    w.clearRetainingCapacity();
    try vx.render(&w.writer);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.written(), "\x1bP0;1;0q"));
}

test "a cell painted over the raster makes it travel again" {
    const gpa = std.testing.allocator;
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    var vx = try testVaxisSixel(gpa, &env_map, &w.writer, 20, 6);
    defer vx.deinit(gpa, &w.writer);
    const id = try testLoadSolidSixel(&vx, gpa);

    const placement: sixel.Placement = .{ .img_id = id, .cols = 2, .rows = 1 };
    vx.screen.writeCell(3, 2, .{ .sixel = placement });
    try vx.render(&w.writer);

    // Text inside the rectangle wipes the pixels it covers, so the raster is
    // re-sent after the cells and ends up on top.
    vx.screen.writeCell(4, 2, .{ .char = .{ .grapheme = "x", .width = 1 } });
    w.clearRetainingCapacity();
    try vx.render(&w.writer);
    const out = w.written();
    const text = std.mem.indexOf(u8, out, "x").?;
    const dcs = std.mem.indexOf(u8, out, "\x1bP0;1;0q").?;
    try std.testing.expect(text < dcs);
}

test "a full refresh re-sends the raster" {
    const gpa = std.testing.allocator;
    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    var vx = try testVaxisSixel(gpa, &env_map, &w.writer, 20, 6);
    defer vx.deinit(gpa, &w.writer);
    const id = try testLoadSolidSixel(&vx, gpa);

    vx.screen.writeCell(3, 2, .{ .sixel = .{ .img_id = id, .cols = 2, .rows = 1 } });
    try vx.render(&w.writer);

    // A refresh clears the screen, images included, so the raster has to go
    // out again even though the placement did not change.
    vx.queueRefresh();
    w.clearRetainingCapacity();
    try vx.render(&w.writer);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.written(), "\x1bP0;1;0q"));
}

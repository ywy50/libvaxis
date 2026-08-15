pub const Key = @import("Key.zig");
pub const Mouse = @import("Mouse.zig");
pub const Color = @import("Cell.zig").Color;
pub const Winsize = @import("main.zig").Winsize;

/// Primary device attributes, reduced to the bits Vaxis acts on.
pub const Da1 = struct {
    /// Attribute 4: sixel graphics.
    sixel: bool = false,
};

/// The largest sixel raster the terminal reported, in pixels.
pub const SixelGeometry = struct {
    width: u16,
    height: u16,
};

/// The events that Vaxis emits internally
pub const Event = union(enum) {
    key_press: Key,
    key_release: Key,
    mouse: Mouse,
    mouse_leave,
    focus_in,
    focus_out,
    paste_start, // bracketed paste start
    paste_end, // bracketed paste end
    paste: []const u8, // osc 52 paste, caller must free
    color_report: Color.Report, // osc 4, 10, 11, 12 response
    color_scheme: Color.Scheme,
    winsize: Winsize,

    // these are delivered as discovered terminal capabilities
    cap_kitty_keyboard,
    cap_kitty_graphics,
    cap_rgb,
    cap_sgr_pixels,
    cap_unicode,
    /// The maximum sixel raster the terminal will accept, from XTSMGRAPHICS.
    cap_sixel_geometry: SixelGeometry,
    /// Primary device attributes, carrying the attribute bits Vaxis
    /// interprets.
    cap_da1: Da1,
    cap_color_scheme_updates,
    cap_multi_cursor,
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}

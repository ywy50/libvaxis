//! SIXEL raster graphics.
//!
//! SIXEL is a streamed protocol, not retained media: there is no image-id
//! placement contract like kitty's, so every displayed frame travels as its
//! own DCS payload. This module owns the payload -- decoding, palette
//! quantization, encoding and byte bounds -- and `Vaxis.render` owns when the
//! bytes reach the terminal. Applications place a `Placement` on a cell and
//! never write DCS themselves.
//!
//! Decoded dimensions, palette size and encoded bytes are all bounded, and
//! the encoder fails rather than truncating a half-written sequence.

const std = @import("std");
const zigimg = @import("zigimg");

const log = std.log.scoped(.vaxis);

/// Levels per channel in the fixed RGB cube the quantizer maps into. A fixed
/// cube is deterministic and its size is known up front: 6 levels is 216
/// registers, inside the 256 a conforming terminal must provide.
pub const cube_levels: u8 = 6;

/// Palette entries the cube spans. Registers are emitted as `cube_index + 1`.
pub const max_palette: u16 = @as(u16, cube_levels) * cube_levels * cube_levels;

/// Sentinel index for a pixel that is not drawn at all. Distinct from every
/// cube index, and never emitted as a register.
pub const transparent: u8 = 0xFF;

/// Alpha at or above which a pixel is drawn. Below it the pixel is skipped
/// and whatever is on the terminal shows through.
pub const alpha_threshold: u8 = 128;

/// Hard ceiling on a decoded raster, in pixels.
pub const max_raster_pixels: usize = 1 << 20;

/// Hard ceiling on one encoded payload. Exceeding it fails the encode instead
/// of writing a partial sequence.
pub const max_payload_bytes: usize = 64 * 1024;

pub const Error = error{
    /// The decoded image is larger than `max_raster_pixels`.
    SixelRasterTooLarge,
    /// The encoded payload would exceed `max_payload_bytes`.
    SixelPayloadTooLarge,
    /// A zero-width or zero-height raster was requested, which usually means
    /// the caller had no usable cell geometry to size it from.
    SixelGeometryUnusable,
    /// The referenced image id is not loaded.
    SixelNoSuchImage,
};

/// A column-wise clip of the raster, in raster pixels. Rows are never
/// clipped: callers clip against the screen's left and right edges.
pub const Clip = struct {
    x: u16 = 0,
    width: u16,
};

/// A request to display one image in a cell rectangle. Placed on a cell by the
/// application; consumed by `Vaxis.render`.
pub const Placement = struct {
    img_id: u32,
    /// Cell rectangle the raster occupies. The renderer erases exactly this
    /// rectangle before writing.
    cols: u16,
    rows: u16,
    clip: ?Clip = null,

    pub fn eql(a: Placement, b: Placement) bool {
        if (a.img_id != b.img_id or a.cols != b.cols or a.rows != b.rows) return false;
        if (a.clip == null and b.clip == null) return true;
        const ac = a.clip orelse return false;
        const bc = b.clip orelse return false;
        return ac.x == bc.x and ac.width == bc.width;
    }
};

/// A decoded, quantized raster held at its final display size. Pixels are
/// stored as palette indices: quantization happens once at load, so encoding
/// a frame is a single scan. The full-raster payload is encoded on first use
/// and reused; a clipped placement is encoded on demand.
pub const Image = struct {
    id: u32,
    /// Raster size in pixels, already multiplied out from cells.
    width: u16,
    height: u16,
    /// One palette index per pixel, row-major, `transparent` where nothing is
    /// drawn. Owned.
    indexed: []u8,
    /// Encoded full-raster payload, or null until something places it. Owned.
    payload: ?[]u8 = null,

    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.indexed);
        if (self.payload) |p| gpa.free(p);
        self.* = undefined;
    }
};

/// Decodes `bytes` and scales it to exactly `width` x `height` pixels,
/// quantizing into the fixed cube as it goes. The scale is a box filter:
/// dropping samples on a downscale loses small features that averaging
/// keeps.
pub fn decode(
    gpa: std.mem.Allocator,
    id: u32,
    bytes: []const u8,
    width: u16,
    height: u16,
) !Image {
    if (width == 0 or height == 0) return Error.SixelGeometryUnusable;
    const dst_pixels = @as(usize, width) * height;
    if (dst_pixels > max_raster_pixels) return Error.SixelRasterTooLarge;

    var img = try zigimg.Image.fromMemory(gpa, bytes);
    defer img.deinit(gpa);
    if (img.width == 0 or img.height == 0) return Error.SixelGeometryUnusable;
    if (img.width * img.height > max_raster_pixels) return Error.SixelRasterTooLarge;
    try img.convertNoFree(gpa, .rgba32);

    const src = img.rawBytes();
    const src_w: usize = img.width;
    const src_h: usize = img.height;

    const indexed = try gpa.alloc(u8, dst_pixels);
    errdefer gpa.free(indexed);

    for (0..height) |dy| {
        // Source band this destination row averages over. Computed from the
        // row edges so every source pixel lands in exactly one band, with no
        // gap or overlap at the seams.
        const y0 = dy * src_h / height;
        const y1 = @max(y0 + 1, (dy + 1) * src_h / height);
        for (0..width) |dx| {
            const x0 = dx * src_w / width;
            const x1 = @max(x0 + 1, (dx + 1) * src_w / width);

            // Alpha-weighted average, so a transparent source pixel does not
            // drag its neighbours toward black on anti-aliased edges.
            var r: usize = 0;
            var g: usize = 0;
            var b: usize = 0;
            var a_sum: usize = 0;
            var n: usize = 0;
            for (y0..y1) |sy| {
                for (x0..x1) |sx| {
                    const i = (sy * src_w + sx) * 4;
                    const a: usize = src[i + 3];
                    r += @as(usize, src[i]) * a;
                    g += @as(usize, src[i + 1]) * a;
                    b += @as(usize, src[i + 2]) * a;
                    a_sum += a;
                    n += 1;
                }
            }
            const di = dy * @as(usize, width) + dx;
            if (n == 0 or a_sum == 0 or a_sum / n < alpha_threshold) {
                indexed[di] = transparent;
                continue;
            }
            indexed[di] = quantize(
                @intCast(r / a_sum),
                @intCast(g / a_sum),
                @intCast(b / a_sum),
            );
        }
    }

    return .{
        .id = id,
        .width = width,
        .height = height,
        .indexed = indexed,
    };
}

/// Maps one opaque colour into the fixed cube.
pub fn quantize(r: u8, g: u8, b: u8) u8 {
    const level = struct {
        fn f(c: u8) usize {
            // Round to nearest level; truncating biases every channel dark.
            return (@as(usize, c) * (cube_levels - 1) + 127) / 255;
        }
    }.f;
    const ri = level(r);
    const gi = level(g);
    const bi = level(b);
    return @intCast((ri * cube_levels + gi) * cube_levels + bi);
}

/// The RGB a cube index stands for, as the 0..100 percentages SIXEL registers
/// are defined in.
pub fn registerColor(index: u8) struct { r: u8, g: u8, b: u8 } {
    const i: usize = index;
    const bi = i % cube_levels;
    const gi = (i / cube_levels) % cube_levels;
    const ri = i / (cube_levels * cube_levels);
    const pct = struct {
        fn f(v: usize) u8 {
            return @intCast(v * 100 / (cube_levels - 1));
        }
    }.f;
    return .{ .r = pct(ri), .g = pct(gi), .b = pct(bi) };
}

/// Encodes `img` (optionally clipped) as a complete DCS sequence: introducer,
/// raster attributes, only the registers this raster uses, the data, and the
/// string terminator. It defines nothing outside its own colour registers.
pub fn encodeAlloc(gpa: std.mem.Allocator, img: Image, clip: ?Clip) ![]u8 {
    const x0: usize = if (clip) |c| @min(c.x, img.width) else 0;
    const w: usize = if (clip) |c| @min(c.width, img.width - x0) else img.width;
    const h: usize = img.height;
    if (w == 0 or h == 0) return Error.SixelGeometryUnusable;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    // P1=0 (1:1 aspect), P2=1 (zero bits leave the pixel untouched, which is
    // how transparency survives), P3=0 (no horizontal grid).
    try out.appendSlice(gpa, "\x1bP0;1;0q");
    try out.print(gpa, "\"1;1;{d};{d}", .{ w, h });

    // `used` is indexed by cube index; the register written is one higher,
    // leaving register 0 alone.
    var used: [max_palette]bool = @splat(false);
    for (0..h) |y| {
        const row = img.indexed[y * img.width ..][x0..][0..w];
        for (row) |idx| {
            if (idx != transparent) used[idx] = true;
        }
    }
    for (used, 0..) |on, idx| {
        if (!on) continue;
        const c = registerColor(@intCast(idx));
        try out.print(gpa, "#{d};2;{d};{d};{d}", .{ idx + 1, c.r, c.g, c.b });
        if (out.items.len > max_payload_bytes) return Error.SixelPayloadTooLarge;
    }

    // One band per six pixel rows, one pass per colour present in the band.
    var band: usize = 0;
    while (band * 6 < h) : (band += 1) {
        var in_band: [max_palette]bool = @splat(false);
        const rows = @min(6, h - band * 6);
        for (0..rows) |k| {
            const y = band * 6 + k;
            const row = img.indexed[y * img.width ..][x0..][0..w];
            for (row) |idx| {
                if (idx != transparent) in_band[idx] = true;
            }
        }

        var first = true;
        for (in_band, 0..) |on, idx| {
            if (!on) continue;
            // `$` returns to the left edge for the next colour pass; the first
            // pass of a band is already there.
            if (!first) try out.append(gpa, '$');
            first = false;
            try out.print(gpa, "#{d}", .{idx + 1});

            var run_char: u8 = 0;
            var run_len: usize = 0;
            var pending: usize = 0; // trailing empty sixels, dropped at row end
            for (0..w) |x| {
                var bits: u8 = 0;
                for (0..rows) |k| {
                    const y = band * 6 + k;
                    if (img.indexed[y * img.width + x0 + x] == idx)
                        bits |= @as(u8, 1) << @intCast(k);
                }
                const ch: u8 = 0x3F + bits;
                if (run_len > 0 and ch == run_char) {
                    run_len += 1;
                    continue;
                }
                if (run_len > 0) {
                    if (run_char == 0x3F) {
                        // Held back: an empty run at the end of a row is
                        // dropped entirely.
                        pending += run_len;
                    } else {
                        try flushPending(gpa, &out, &pending);
                        try flushRun(gpa, &out, run_char, run_len);
                    }
                }
                run_char = ch;
                run_len = 1;
                if (out.items.len > max_payload_bytes) return Error.SixelPayloadTooLarge;
            }
            if (run_len > 0 and run_char != 0x3F) {
                try flushPending(gpa, &out, &pending);
                try flushRun(gpa, &out, run_char, run_len);
            }
        }
        // Graphics newline; a trailing `-` after the last band is harmless.
        try out.append(gpa, '-');
        if (out.items.len > max_payload_bytes) return Error.SixelPayloadTooLarge;
    }

    try out.appendSlice(gpa, "\x1b\\");
    if (out.items.len > max_payload_bytes) return Error.SixelPayloadTooLarge;
    return out.toOwnedSlice(gpa);
}

fn flushPending(gpa: std.mem.Allocator, out: *std.ArrayList(u8), pending: *usize) !void {
    if (pending.* == 0) return;
    try flushRun(gpa, out, 0x3F, pending.*);
    pending.* = 0;
}

fn flushRun(gpa: std.mem.Allocator, out: *std.ArrayList(u8), ch: u8, len: usize) !void {
    // The RLE introducer costs three bytes at minimum (`!` plus at least one
    // digit plus the character), so runs of three or fewer are cheaper literal.
    if (len > 3) {
        try out.print(gpa, "!{d}{c}", .{ len, ch });
    } else {
        try out.appendNTimes(gpa, ch, len);
    }
}

const testing = std.testing;

test "quantize maps the cube corners to the cube corners" {
    try testing.expectEqual(@as(u8, 0), quantize(0, 0, 0));
    const white = quantize(255, 255, 255);
    try testing.expectEqual(max_palette - 1, @as(u16, white));
    const c = registerColor(white);
    try testing.expectEqual(@as(u8, 100), c.r);
    try testing.expectEqual(@as(u8, 100), c.g);
    try testing.expectEqual(@as(u8, 100), c.b);
    // Every index the quantizer can produce is a real register.
    for ([_][3]u8{ .{ 1, 2, 3 }, .{ 128, 64, 200 }, .{ 254, 1, 127 } }) |rgb| {
        try testing.expect(quantize(rgb[0], rgb[1], rgb[2]) < max_palette);
    }
}

test "registerColor round-trips the channel order" {
    // (r * L + g) * L + b backwards would swap red and blue.
    const idx = quantize(255, 0, 0);
    const c = registerColor(idx);
    try testing.expectEqual(@as(u8, 100), c.r);
    try testing.expectEqual(@as(u8, 0), c.g);
    try testing.expectEqual(@as(u8, 0), c.b);
}

/// A 4x8 raster: a solid red left half, transparent right half.
fn testImage(gpa: std.mem.Allocator) !Image {
    const w: u16 = 4;
    const h: u16 = 8;
    const indexed = try gpa.alloc(u8, w * h);
    const red = quantize(255, 0, 0);
    for (0..h) |y| {
        for (0..w) |x| {
            indexed[y * w + x] = if (x < 2) red else transparent;
        }
    }
    return .{ .id = 1, .width = w, .height = h, .indexed = indexed };
}

test "encode wraps the payload in one complete DCS sequence" {
    const gpa = testing.allocator;
    var img = try testImage(gpa);
    defer img.deinit(gpa);
    const payload = try encodeAlloc(gpa, img, null);
    defer gpa.free(payload);

    // P2=1: zero bits leave the pixel untouched.
    try testing.expect(std.mem.startsWith(u8, payload, "\x1bP0;1;0q"));
    try testing.expect(std.mem.endsWith(u8, payload, "\x1b\\"));
    try testing.expect(std.mem.indexOf(u8, payload, "\"1;1;4;8") != null);
    // Two bands of six rows cover eight rows.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, payload, "-"));
}

/// Counts `#N;2;r;g;b` register definitions in a payload.
///
/// Not a plain substring count of `;2;`: the raster attributes (`"1;1;2;8`)
/// can contain that too, which makes the naive count depend on the raster's
/// width.
fn countRegisters(payload: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, payload, i, ";2;")) |at| {
        i = at + 3;
        var j = at;
        while (j > 0 and std.ascii.isDigit(payload[j - 1])) j -= 1;
        if (j == at) continue; // no digits before the marker
        if (j > 0 and payload[j - 1] == '#') n += 1;
    }
    return n;
}

test "encode defines only the registers the raster uses" {
    const gpa = testing.allocator;
    var img = try testImage(gpa);
    defer img.deinit(gpa);
    const payload = try encodeAlloc(gpa, img, null);
    defer gpa.free(payload);

    // One colour is present, so exactly one register is defined.
    try testing.expectEqual(@as(usize, 1), countRegisters(payload));
    const red = quantize(255, 0, 0);
    var buf: [16]u8 = undefined;
    const want = try std.fmt.bufPrint(&buf, "#{d};2;100;0;0", .{red + 1});
    try testing.expect(std.mem.indexOf(u8, payload, want) != null);
}

test "encode honours a column clip" {
    const gpa = testing.allocator;
    var img = try testImage(gpa);
    defer img.deinit(gpa);

    // The right half is transparent, so clipping to it leaves nothing drawn
    // and no register defined -- but still a well-formed sequence.
    const empty = try encodeAlloc(gpa, img, .{ .x = 2, .width = 2 });
    defer gpa.free(empty);
    try testing.expect(std.mem.indexOf(u8, empty, "\"1;1;2;8") != null);
    try testing.expectEqual(@as(usize, 0), countRegisters(empty));

    // Clipping to the drawn half keeps the colour and narrows the raster.
    const drawn = try encodeAlloc(gpa, img, .{ .x = 0, .width = 2 });
    defer gpa.free(drawn);
    try testing.expect(std.mem.indexOf(u8, drawn, "\"1;1;2;8") != null);
    try testing.expectEqual(@as(usize, 1), countRegisters(drawn));

    // A clip wider than the raster is clamped, not an error or a read past
    // the end of the row.
    const clamped = try encodeAlloc(gpa, img, .{ .x = 0, .width = 999 });
    defer gpa.free(clamped);
    try testing.expect(std.mem.indexOf(u8, clamped, "\"1;1;4;8") != null);
}

test "encode refuses a zero-width raster" {
    const gpa = testing.allocator;
    var img = try testImage(gpa);
    defer img.deinit(gpa);
    try testing.expectError(Error.SixelGeometryUnusable, encodeAlloc(gpa, img, .{ .x = 4, .width = 4 }));
}

test "decode refuses geometry it cannot size a raster from" {
    const gpa = testing.allocator;
    try testing.expectError(Error.SixelGeometryUnusable, decode(gpa, 1, "", 0, 10));
    try testing.expectError(Error.SixelGeometryUnusable, decode(gpa, 1, "", 10, 0));
}

test "decode refuses a raster past the pixel ceiling" {
    const gpa = testing.allocator;
    try testing.expectError(Error.SixelRasterTooLarge, decode(gpa, 1, "", 4096, 4096));
}

test "decode rejects a malformed asset without allocating a raster" {
    const gpa = testing.allocator;
    // Which error the decoder picks is its business; a corrupt asset must
    // fail cleanly with nothing leaked.
    for ([_][]const u8{ "not a png at all", "", "\x89PNG\r\n\x1a\n" }) |junk| {
        if (decode(gpa, 1, junk, 16, 16)) |_| {
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "a payload past the byte ceiling fails instead of writing a partial sequence" {
    const gpa = testing.allocator;
    // Alternating colours defeat the run-length encoder.
    const w: u16 = 512;
    const h: u16 = 512;
    const indexed = try gpa.alloc(u8, @as(usize, w) * h);
    for (indexed, 0..) |*p, i| p.* = @intCast((i * 7) % max_palette);
    var img: Image = .{ .id = 1, .width = w, .height = h, .indexed = indexed };
    defer img.deinit(gpa);
    try testing.expectError(Error.SixelPayloadTooLarge, encodeAlloc(gpa, img, null));
}

test {
    testing.refAllDecls(@This());
}

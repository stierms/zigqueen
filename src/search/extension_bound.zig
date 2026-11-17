//! Where extensions stop (roadmap #2, 2026-11-10).
//!
//! - A bound on the positive extension accumulated along one line, whatever
//!   rule granted it. An extension that fires at every ply of a line (LDSE's
//!   +2 in a won ending did) can otherwise keep the remaining depth from
//!   falling: 4 of 12 collected positions reached selective depth 100.
//! - The range of the unverified rules (LDSE, check extension): a largest
//!   node depth for each, and a largest alpha. Both rules read "static eval
//!   below alpha" as trouble; where alpha is already a won score for the side
//!   to move, that is true at every node of the winning line.
//!
//! root.zig holds the call sites. The release flavour resolves every
//! accessor to its default constant.

const std = @import("std");
const tunables = @import("tunables.zig");
const types = @import("../core/types.zig");

/// Largest positive extension a line may accumulate at this iteration depth;
/// null when unbounded.
pub inline fn cap(root_depth: u16) ?u16 {
    return capWith(root_depth, tunables.knob("ext_cap_base"), tunables.knob("ext_cap_pct"));
}

pub fn capWith(root_depth: u16, base: i32, pct: i32) ?u16 {
    if (base == 0 and pct == 0) return null;
    const plies = base + @divTrunc(@as(i32, root_depth) * pct, 100);
    return @intCast(std.math.clamp(plies, 0, 255));
}

/// The extension a move may take when the line above it already carries
/// `ext_sum` plies. Reductions pass through.
pub fn bounded(extension: i16, ext_sum: u8, limit: ?u16) i16 {
    if (extension <= 0) return extension;
    const most = limit orelse return extension;
    if (ext_sum >= most) return 0;
    return @min(extension, @as(i16, @intCast(most - ext_sum)));
}

/// The line's extension sum below a move that takes `extension`.
pub fn nextSum(ext_sum: u8, extension: i16) u8 {
    if (extension <= 0) return ext_sum;
    return @intCast(@min(@as(i32, ext_sum) + extension, 255));
}

pub inline fn ldseMaxDepth() u16 {
    return @intCast(tunables.knob("ldse_max_depth"));
}

pub inline fn checkExtMaxDepth() u16 {
    return @intCast(tunables.knob("check_ext_max_depth"));
}

/// The unverified rules (LDSE, check extension) act only below this alpha.
pub inline fn unverifiedAllowed(alpha: types.Score) bool {
    return alpha < tunables.knob("uext_alpha_max");
}

test "the cap is the iteration depth by default, grows with it and trims what exceeds it" {
    const defaults = tunables.Tunables{};
    try std.testing.expectEqual(@as(?u16, 12), capWith(12, defaults.ext_cap_base, defaults.ext_cap_pct));
    try std.testing.expectEqual(@as(?u16, null), capWith(12, 0, 0));
    try std.testing.expectEqual(@as(?u16, 10), capWith(10, 0, 100));
    try std.testing.expectEqual(@as(?u16, 9), capWith(10, 4, 50));
    try std.testing.expectEqual(@as(i16, 2), bounded(2, 3, null));
    try std.testing.expectEqual(@as(i16, 2), bounded(2, 3, 5));
    try std.testing.expectEqual(@as(i16, 1), bounded(2, 4, 5));
    try std.testing.expectEqual(@as(i16, 0), bounded(1, 5, 5));
    try std.testing.expectEqual(@as(i16, -2), bounded(-2, 9, 5));
    try std.testing.expectEqual(@as(u8, 5), nextSum(3, 2));
    try std.testing.expectEqual(@as(u8, 3), nextSum(3, -1));
    try std.testing.expectEqual(@as(u8, 255), nextSum(254, 2));
}

test "the unverified rules keep their 6.5.0 depth range and stop at a won alpha by default" {
    const defaults = tunables.Tunables{};
    try std.testing.expectEqual(@as(types.Score, 7), defaults.ldse_max_depth);
    try std.testing.expect(defaults.check_ext_max_depth >= 127);
    try std.testing.expectEqual(@as(types.Score, 300), defaults.uext_alpha_max);
}

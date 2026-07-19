const std = @import("std");
const types = @import("../core/types.zig");

pub const NodeContext = struct {
    pv_node: bool,
    cut_node: bool,

    pub fn fromWindow(alpha: types.Score, beta: types.Score, cut_node_hint: bool) NodeContext {
        const pv_node = beta - alpha > 1;
        return .{
            .pv_node = pv_node,
            .cut_node = if (pv_node) false else cut_node_hint,
        };
    }

    pub fn firstChild(self: NodeContext) NodeContext {
        if (self.pv_node) return .{ .pv_node = false, .cut_node = false };
        return .{ .pv_node = false, .cut_node = !self.cut_node };
    }

    pub fn scoutChild(self: NodeContext) NodeContext {
        if (self.pv_node) return .{ .pv_node = false, .cut_node = true };
        return .{ .pv_node = false, .cut_node = !self.cut_node };
    }

    pub fn nullMoveChild(self: NodeContext) NodeContext {
        std.debug.assert(!self.pv_node);
        return .{ .pv_node = false, .cut_node = !self.cut_node };
    }
};

test "node context derives pv and cut status from the search window" {
    const pv = NodeContext.fromWindow(-20, 20, true);
    try std.testing.expect(pv.pv_node);
    try std.testing.expect(!pv.cut_node);

    const cut = NodeContext.fromWindow(19, 20, true);
    try std.testing.expect(!cut.pv_node);
    try std.testing.expect(cut.cut_node);

    const all = NodeContext.fromWindow(19, 20, false);
    try std.testing.expect(!all.pv_node);
    try std.testing.expect(!all.cut_node);
}

test "node context child helpers preserve the intended pv cut and all mapping" {
    const pv = NodeContext.fromWindow(-20, 20, false);
    try std.testing.expectEqual(NodeContext{ .pv_node = false, .cut_node = false }, pv.firstChild());
    try std.testing.expectEqual(NodeContext{ .pv_node = false, .cut_node = true }, pv.scoutChild());

    const cut = NodeContext.fromWindow(19, 20, true);
    try std.testing.expectEqual(NodeContext{ .pv_node = false, .cut_node = false }, cut.firstChild());
    try std.testing.expectEqual(NodeContext{ .pv_node = false, .cut_node = false }, cut.scoutChild());
    try std.testing.expectEqual(NodeContext{ .pv_node = false, .cut_node = false }, cut.nullMoveChild());

    const all = NodeContext.fromWindow(19, 20, false);
    try std.testing.expectEqual(NodeContext{ .pv_node = false, .cut_node = true }, all.firstChild());
    try std.testing.expectEqual(NodeContext{ .pv_node = false, .cut_node = true }, all.scoutChild());
    try std.testing.expectEqual(NodeContext{ .pv_node = false, .cut_node = true }, all.nullMoveChild());
}

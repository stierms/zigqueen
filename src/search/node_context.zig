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
        if (self.pv_node) return .{ .pv_node = true, .cut_node = false };
        return .{ .pv_node = false, .cut_node = !self.cut_node };
    }

    pub fn scoutChild(self: NodeContext) NodeContext {
        if (self.pv_node) return .{ .pv_node = false, .cut_node = true };
        return .{ .pv_node = false, .cut_node = !self.cut_node };
    }

    /// Child of a late move's zero-window scout. When LMR reduced the move
    /// the parent expects it to fail low, so the reduced child is expected to
    /// fail high: CUT at every parent type (the convention the LMR cut-node
    /// term was ported with). An unreduced scout keeps scoutChild().
    pub fn reducedChild(self: NodeContext, reduction: u16) NodeContext {
        if (reduction == 0) return self.scoutChild();
        return .{ .pv_node = false, .cut_node = true };
    }

    pub fn nullMoveChild(self: NodeContext) NodeContext {
        std.debug.assert(!self.pv_node);
        return .{ .pv_node = false, .cut_node = !self.cut_node };
    }

    /// ProbCut's reduced confirmation of a capture: the child's expected role
    /// is the opposite of this node's. ProbCut runs only at non-PV nodes.
    pub fn probCutChild(self: NodeContext) NodeContext {
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
    try std.testing.expectEqual(NodeContext{ .pv_node = true, .cut_node = false }, pv.firstChild());
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

test "late-move and ProbCut children take the cut-node convention" {
    const pv = NodeContext.fromWindow(-20, 20, false);
    const cut = NodeContext.fromWindow(19, 20, true);
    const all = NodeContext.fromWindow(19, 20, false);
    const cut_child = NodeContext{ .pv_node = false, .cut_node = true };
    const all_child = NodeContext{ .pv_node = false, .cut_node = false };

    // A reduced late move's child is CUT at every parent type.
    try std.testing.expectEqual(cut_child, pv.reducedChild(1));
    try std.testing.expectEqual(cut_child, cut.reducedChild(1));
    try std.testing.expectEqual(cut_child, all.reducedChild(3));
    // reduction == 0 keeps the scout rule (!cut at non-PV parents).
    try std.testing.expectEqual(pv.scoutChild(), pv.reducedChild(0));
    try std.testing.expectEqual(all_child, cut.reducedChild(0));
    try std.testing.expectEqual(cut_child, all.reducedChild(0));

    // The ProbCut confirmation child is !cut of its (non-PV) parent.
    try std.testing.expectEqual(all_child, cut.probCutChild());
    try std.testing.expectEqual(cut_child, all.probCutChild());
}

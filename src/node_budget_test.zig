//! Standalone prerequisite tests; the production engine does not import this.
comptime {
    _ = @import("search/node_budget.zig");
    _ = @import("search/node_budget_stress.zig");
}

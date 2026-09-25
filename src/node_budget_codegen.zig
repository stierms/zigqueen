//! Standalone code-generation probe, never imported by the engine.
const credits = @import("search/node_budget.zig");

export fn zq_budget_count(account: *credits.Account) callconv(.c) u8 {
    return @intFromEnum(account.tryCount());
}

export fn zq_budget_finish(account: *credits.Account) callconv(.c) void {
    account.finish();
}

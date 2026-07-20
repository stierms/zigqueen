const std = @import("std");

pub fn build(b: *std.Build) void {
    // The default target query resolves to the NATIVE cpu, so the binary uses
    // every SIMD extension the build machine has — no explicit -Dcpu needed.
    // The fathom C unit compiles inside the same `zig build-exe` invocation and
    // inherits the same target (its -march matches; no separate flag required).
    var target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Portable release baselines. The default (option omitted) stays the NATIVE
    // build above — source builds are unchanged. For release packaging:
    //   -Dcpu-baseline=avx2    x86-64-v3 (AVX2/BMI2/POPCNT, no AVX-512) — the
    //                          compatibility floor; runs on Haswell/Zen1 and up.
    //   -Dcpu-baseline=avx512  x86-64-v4 + AVX512-VNNI (the vpdpbusd l1 matmul
    //                          kernel needs VNNI) — Ice Lake / Zen 4 and up.
    //                          Plain-v4-without-VNNI chips (Skylake-X) should
    //                          use the avx2 binary instead.
    // The NNUE eval is bit-exact across SIMD widths by design (@Vector
    // elementwise ops + overflow-free integer dots), so all variants produce
    // identical node counts; only speed differs.
    const CpuBaseline = enum { avx2, avx512 };
    const cpu_baseline = b.option(
        CpuBaseline,
        "cpu-baseline",
        "Portable x86_64 CPU baseline for release binaries (default: native).",
    );
    if (cpu_baseline) |baseline| {
        var query = target.query;
        query.cpu_arch = .x86_64;
        switch (baseline) {
            .avx2 => {
                query.cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 };
                query.cpu_features_add = .empty;
            },
            .avx512 => {
                query.cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v4 };
                query.cpu_features_add = std.Target.x86.featureSet(&.{.avx512vnni});
            },
        }
        query.cpu_features_sub = .empty;
        target = b.resolveTargetQuery(query);
    }
    // Baseline builds get a suffixed binary name so release variants can't be
    // confused with (or overwrite) a native build.
    const name_suffix: []const u8 = if (cpu_baseline) |baseline| switch (baseline) {
        .avx2 => "-x86_64-avx2",
        .avx512 => "-x86_64-avx512",
    } else "";

    // Semantic version `zigqueen X.Y.Z`, surfaced via UCI `id name`.
    // Bump policy: MINOR for an accepted strength gain (each promoted baseline),
    // PATCH for fixes/tooling/perf-neutral changes, MAJOR for architecture
    // milestones. Highest version == newest.
    const semver = "5.8.0";
    const version_override = b.option(
        []const u8,
        "version",
        "Version label exposed via UCI `id name`. Defaults to the semver above.",
    );
    const version = version_override orelse semver;

    // Diagnostic search counters (the ctx.note*() instrumentation): compiled out
    // of the release engine by default — they increment on every node/move.
    // Functional counters (node count/TM stop, seldepth, UCI info) are always
    // compiled. The always-installed `zigqueen-stats` twin binary is built with
    // stats ON so the instruments (search_profile & friends) keep working.
    const search_stats = b.option(
        bool,
        "search-stats",
        "Compile diagnostic search counters into the main binary (default: false).",
    ) orelse false;

    // SPSA runtime-tunables UCI exposure: compiled out of the release binary.
    // The tunables module itself (shipped defaults) is always compiled; this
    // only controls whether the parameters are advertised/settable over UCI.
    const tunables = b.option(
        bool,
        "tunables",
        "Expose SPSA runtime tunables as UCI options (default: false).",
    ) orelse false;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption(bool, "search_stats", search_stats);
    build_options.addOption(bool, "tunables", tunables);
    const build_options_module = build_options.createModule();

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("build_options", build_options_module);
    addFathom(b, root_module);

    const exe = b.addExecutable(.{
        .name = b.fmt("zigqueen{s}", .{name_suffix}),
        .root_module = root_module,
    });
    // Keep linker relocations in the output (--emit-relocs): required for
    // llvm-bolt post-link optimization (scripts/bolt-optimize.sh) to reorder
    // functions/blocks. Non-alloc sections only — zero runtime cost, ~2MB file
    // size. Codegen is unchanged; the binary is behavior-identical.
    // ELF-only (bolt is Linux-only anyway); COFF/PE links reject the flag.
    if (target.result.os.tag == .linux) exe.link_emit_relocs = true;
    // R10: cross-unit LTO — clean A/B (5-rep fixed-node): -2.5% opening,
    // -2.2% middle, -4.7% endgame wall-clock. One flag, node-identical.
    exe.want_lto = true;

    b.installArtifact(exe);

    // Stats-enabled twin (same modes, diagnostic counters compiled in): the
    // instrumentation binary for search_profile/search_report tooling.
    const stats_options = b.addOptions();
    stats_options.addOption([]const u8, "version", version);
    stats_options.addOption(bool, "search_stats", true);
    stats_options.addOption(bool, "tunables", tunables);
    const stats_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    stats_module.addImport("build_options", stats_options.createModule());
    addFathom(b, stats_module);
    const stats_exe = b.addExecutable(.{
        .name = b.fmt("zigqueen-stats{s}", .{name_suffix}),
        .root_module = stats_module,
    });
    b.installArtifact(stats_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zigqueen");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("build_options", build_options_module);
    addFathom(b, test_module);
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Fathom (Syzygy tablebase probing, deps/fathom, BSD): one C translation unit.
fn addFathom(b: *std.Build, module: *std.Build.Module) void {
    module.link_libc = true;
    module.addIncludePath(b.path("deps/fathom"));
    module.addCSourceFile(.{
        .file = b.path("deps/fathom/tbprobe.c"),
        .flags = &.{ "-std=gnu11", "-O2", "-DTB_NO_HW_POP_COUNT=0" },
    });
}

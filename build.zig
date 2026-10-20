const std = @import("std");

pub fn build(b: *std.Build) void {
    // CPU-target audit (perf-r6): the default query already resolves to the
    // NATIVE cpu (znver5-class here) — the release binary carries AVX-512
    // (vpopcntq/vpternlogq on zmm), so no explicit -Dcpu is needed. The engine
    // is pure Zig; only the test-only tb-oracle tool compiles C (Fathom).
    var target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Zig 0.15.2 compiles Debug x86-64 code with its self-hosted backend, which
    // rejects the engine's inline assembly (the "v" register constraint in
    // src/eval/fullthreats.zig). Debug builds use LLVM like every other mode;
    // release modes keep Zig's default (null), so their builds are unchanged.
    const use_llvm: ?bool = if (optimize == .Debug) true else null;

    // Portable release baselines. The default (option omitted) remains the
    // native target used for development. Release packages select one of:
    //   avx2            x86-64-v3 (AVX2/BMI2/POPCNT; no AVX-512)
    //   avx512          x86-64-v4 plus AVX512-VNNI
    //   armv8           generic AArch64/NEON
    //   armv8-dotprod   AArch64 plus dotprod/i8mm
    const CpuBaseline = enum { avx2, avx512, armv8, @"armv8-dotprod" };
    const cpu_baseline = b.option(
        CpuBaseline,
        "cpu-baseline",
        "Portable CPU baseline for release binaries (default: native).",
    );
    if (cpu_baseline) |baseline| {
        var query = target.query;
        switch (baseline) {
            .avx2 => {
                query.cpu_arch = .x86_64;
                query.cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 };
                query.cpu_features_add = .empty;
            },
            .avx512 => {
                query.cpu_arch = .x86_64;
                query.cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v4 };
                query.cpu_features_add = std.Target.x86.featureSet(&.{.avx512vnni});
            },
            .armv8, .@"armv8-dotprod" => {
                query.cpu_arch = .aarch64;
                query.cpu_model = .{ .explicit = &std.Target.aarch64.cpu.generic };
                query.cpu_features_add = if (baseline == .@"armv8-dotprod")
                    std.Target.aarch64.featureSet(&.{ .dotprod, .i8mm })
                else
                    .empty;
            },
        }
        query.cpu_features_sub = .empty;
        target = b.resolveTargetQuery(query);
    }
    const name_suffix: []const u8 = if (cpu_baseline) |baseline| switch (baseline) {
        .avx2 => "-x86_64-avx2",
        .avx512 => "-x86_64-avx512",
        .armv8 => "-aarch64-armv8",
        .@"armv8-dotprod" => "-aarch64-armv8-dotprod",
    } else "";

    // Semantic version `zigqueen X.Y.Z`, surfaced via UCI `id name`.
    // Bump policy: MINOR for an accepted strength gain (each promoted baseline),
    // PATCH for fixes/tooling/perf-neutral changes, MAJOR for architecture
    // milestones. Highest version == newest.
    const semver = "6.5.0";
    const version_override = b.option(
        []const u8,
        "version",
        "Version label exposed via UCI `id name`. Release ceremony passes the bare " ++
            "semver here; without it a build is labelled as a PRE-RELEASE (see below).",
    );
    // Pre-release labelling (2026-08-09): a build that does not explicitly pass
    // -Dversion is NOT a release, and must never claim to be one — it reports
    // `X.Y.Z-dev+<short sha>`. Semver orders `X.Y.Z-dev` BELOW `X.Y.Z`, which is
    // exactly right, and the sha makes any played/deployed build traceable to a
    // commit. The release ceremony strips the suffix by passing -Dversion.
    const version = version_override orelse devVersion(b, semver);

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

    // Runtime search-parameter UCI options are development-only. The release
    // binary keeps the same compiled-in search defaults but has no SPSA
    // setoption surface unless this flavour is requested explicitly.
    const tuning = b.option(
        bool,
        "tuning",
        "Compile runtime search-tuning UCI options (default: false).",
    ) orelse false;

    // Fail-soft cutoff returns (correction-history bundle, step 1). Off builds
    // return the window bounds exactly as before.
    const fail_soft = b.option(
        bool,
        "fail-soft",
        "Return fail-soft scores at RFP, null-move and quiescence fail-high cutoffs (default: true).",
    ) orelse true;
    // Quiescence fail lows: M > 0 = min(alpha, max(best, stand-pat + M))
    // outside check; 0 = hard (alpha). Only meaningful with fail-soft.
    const qs_fail_low_margin = b.option(
        i32,
        "qs-fail-low-margin",
        "Quiescence fail-low margin in cp; 0 keeps fail lows hard (default: 200).",
    ) orelse 200;
    // Correction history (bundle step 2). Off builds allocate no tables.
    const correction_history = b.option(
        bool,
        "correction-history",
        "Learn and apply static-eval correction history (default: true).",
    ) orelse true;
    // Which node results teach correction history (A3c): bound-consistent
    // scores ("bound") or exact scores only ("exact").
    const corr_learn = b.option(
        []const u8,
        "corr-learn",
        "Correction-history learning events: bound|exact (default: bound).",
    ) orelse "bound";
    const corr_qsearch = b.option(
        bool,
        "corr-qsearch",
        "Correct the quiescence stand-pat with correction history (default: false).",
    ) orelse false;

    // Syzygy tablebase storage of the engine's own prober (src/tb): budget =
    // MmapBudget (map every file unless a finite RLIMIT_AS caps the address
    // space; positioned reads for the rest; the default), mmap = MmapAll,
    // pread = Pread. Fathom is linked into the test-only tb-oracle tool alone.
    const tb_storage = b.option(
        []const u8,
        "tb-storage",
        "Syzygy storage: budget|mmap|pread (default: budget).",
    ) orelse "budget";
    if (!oneOf(tb_storage, &.{ "budget", "mmap", "pread" })) std.debug.panic("-Dtb-storage must be budget, mmap or pread, got '{s}'", .{tb_storage});

    // PGO reference dump (src/tools/pgo_dump.zig): main() writes the raw profile through the
    // LLVM profile runtime at exit. scripts/pgo-build.sh does not need it (it reads the counters
    // out of the live process); it gives the runtime's own profile to check that reader against
    // (scripts/pgo/profsnap.py --selftest). Links only with the runtime and
    // --lto-cs-profile-generate; Zig's __anon_N names differ from the normal build's.
    const pgo_dump = b.option(
        bool,
        "pgo-dump",
        "Dump the LLVM raw profile at exit; for the instrumented PGO relink only (default: false).",
    ) orelse false;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption([]const u8, "tb_storage", tb_storage);
    build_options.addOption(bool, "search_stats", search_stats);
    build_options.addOption(bool, "tuning", tuning);
    build_options.addOption(bool, "fail_soft", fail_soft);
    build_options.addOption(i32, "qs_fail_low_margin", qs_fail_low_margin);
    build_options.addOption(bool, "correction_history", correction_history);
    build_options.addOption([]const u8, "corr_learn", corr_learn);
    build_options.addOption(bool, "corr_qsearch", corr_qsearch);
    build_options.addOption(bool, "pgo_dump", pgo_dump);
    const build_options_module = build_options.createModule();

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("build_options", build_options_module);

    const exe = b.addExecutable(.{
        .name = b.fmt("zigqueen{s}", .{name_suffix}),
        .root_module = root_module,
        .use_llvm = use_llvm,
    });
    // Keep linker relocations in the output (--emit-relocs): required for
    // llvm-bolt post-link optimization (scripts/bolt-optimize.sh) to reorder
    // functions/blocks. Non-alloc sections only — zero runtime cost, ~2MB file
    // size. Codegen is unchanged; the binary is behavior-identical.
    if (target.result.os.tag == .linux) exe.link_emit_relocs = true;
    // R10: cross-unit LTO — clean A/B (5-rep fixed-node): -2.5% opening,
    // -2.2% middle, -4.7% endgame wall-clock. One flag, node-identical.
    // Not for Windows ReleaseSafe: zig 0.15.2 cannot link the safety panic
    // handler's thread-local state under LTO there (lld-link: undefined symbol
    // _tls_index; audit D, U-WIN-LTO). The shipping ReleaseFast builds keep it.
    exe.want_lto = !(target.result.os.tag == .windows and optimize == .ReleaseSafe);

    b.installArtifact(exe);

    // Stats-enabled twin (same modes, diagnostic counters compiled in): the
    // instrumentation binary for search_profile/search_report tooling.
    const stats_options = b.addOptions();
    stats_options.addOption([]const u8, "version", version);
    stats_options.addOption([]const u8, "tb_storage", tb_storage);
    stats_options.addOption(bool, "search_stats", true);
    stats_options.addOption(bool, "tuning", tuning);
    stats_options.addOption(bool, "fail_soft", fail_soft);
    stats_options.addOption(i32, "qs_fail_low_margin", qs_fail_low_margin);
    stats_options.addOption(bool, "correction_history", correction_history);
    stats_options.addOption([]const u8, "corr_learn", corr_learn);
    stats_options.addOption(bool, "corr_qsearch", corr_qsearch);
    stats_options.addOption(bool, "pgo_dump", pgo_dump);
    const stats_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    stats_module.addImport("build_options", stats_options.createModule());
    const stats_exe = b.addExecutable(.{
        .name = b.fmt("zigqueen-stats{s}", .{name_suffix}),
        .root_module = stats_module,
        .use_llvm = use_llvm,
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
    const unit_tests = b.addTest(.{
        .root_module = test_module,
        .use_llvm = use_llvm,
    });
    const run_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    // The same unit-test binary installed instead of run, for running it
    // natively on another OS (e.g. `-Dtarget=x86_64-windows`).
    const test_exe_step = b.step("test-exe", "Install the unit-test binary without running it");
    test_exe_step.dependOn(&b.addInstallArtifact(unit_tests, .{}).step);

    // Cold initialization must also be tested before any other test can warm
    // the process-global once state. One executable, fresh process per case.
    const init_module = b.createModule(.{
        .root_source_file = b.path("src/search_init_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    init_module.addImport("build_options", build_options_module);
    const init_tests = b.addExecutable(.{ .name = "search-init-test", .root_module = init_module, .use_llvm = use_llvm });
    const init_step = b.step("test-search-init", "Test search initialization in fresh processes");
    for ([_][]const u8{ "constructors", "tm-first", "tuning", "failure-retry" }) |mode| {
        const check = b.addRunArtifact(init_tests);
        check.addArg(mode);
        init_step.dependOn(&check.step);
    }
    test_step.dependOn(init_step);

    // Test-only Syzygy oracle tool (G0 census, G1 oracle, G3 micro-benchmark):
    // our prober against vendored Fathom in one process. The only binary that
    // links Fathom; never installed by default.
    const oracle_module = b.createModule(.{
        .root_source_file = b.path("src/tb_oracle.zig"),
        .target = target,
        .optimize = optimize,
    });
    oracle_module.addImport("build_options", build_options_module);
    addFathom(b, oracle_module);
    const oracle_exe = b.addExecutable(.{ .name = "zigqueen-tb-oracle", .root_module = oracle_module, .use_llvm = use_llvm });
    const oracle_step = b.step("tb-oracle", "Build the test-only Syzygy oracle tool (links Fathom)");
    oracle_step.dependOn(&b.addInstallArtifact(oracle_exe, .{}).step);
}

fn oneOf(value: []const u8, comptime options: []const []const u8) bool {
    inline for (options) |o| if (std.mem.eql(u8, value, o)) return true;
    return false;
}

/// Vendored Fathom plus the oracle's narrow public-API bridge.
fn addFathom(b: *std.Build, module: *std.Build.Module) void {
    module.link_libc = true;
    module.addIncludePath(b.path("deps/fathom"));
    module.addCSourceFile(.{
        .file = b.path("deps/fathom/tbprobe.c"),
        .flags = &.{ "-std=gnu11", "-O2", "-DTB_NO_HW_POP_COUNT=0" },
    });
    module.addCSourceFile(.{
        .file = b.path("src/tb_oracle_fathom.c"),
        .flags = &.{ "-std=gnu11", "-O2", "-DTB_NO_HW_POP_COUNT=0" },
    });
}

/// `X.Y.Z-dev+<short sha>` for non-release builds. Falls back to `X.Y.Z-dev`
/// when git is unavailable (source tarball, no repo) — never to a bare semver,
/// so a pre-release can never masquerade as a release.
fn devVersion(b: *std.Build, semver: []const u8) []const u8 {
    const res = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "git", "rev-parse", "--short=7", "HEAD" },
        .cwd = b.build_root.path orelse ".",
    }) catch return b.fmt("{s}-dev", .{semver});
    if (res.term != .Exited or res.term.Exited != 0) return b.fmt("{s}-dev", .{semver});
    const sha = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (sha.len == 0) return b.fmt("{s}-dev", .{semver});
    return b.fmt("{s}-dev+{s}", .{ semver, sha });
}

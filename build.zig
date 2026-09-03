const std = @import("std");

pub fn build(b: *std.Build) void {
    // CPU-target audit (perf-r6): the default query already resolves to the
    // NATIVE cpu (znver5-class here) — the release binary carries AVX-512
    // (vpopcntq/vpternlogq on zmm), so no explicit -Dcpu is needed. The fathom
    // C unit compiles inside the same `zig build-exe` invocation and inherits
    // the same native target (its -march matches; no separate flag required).
    var target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    const semver = "6.1.1";
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

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption(bool, "search_stats", search_stats);
    build_options.addOption(bool, "tuning", tuning);
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
    stats_options.addOption(bool, "tuning", tuning);
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

/// Fathom (Syzygy tablebase probing, deps/fathom, MIT): one C translation unit.
fn addFathom(b: *std.Build, module: *std.Build.Module) void {
    module.link_libc = true;
    module.addIncludePath(b.path("deps/fathom"));
    module.addCSourceFile(.{
        .file = b.path("deps/fathom/tbprobe.c"),
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

const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable(.{
        .name = "gup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const latest_stable = b.option(
        []const u8,
        "latest-stable",
        "Set default version to fetch",
    ) orelse "4.7.1";

    const options = b.addOptions();
    options.addOption([]const u8, "latest_stable", latest_stable);
    options.addOption([]const u8, "download_url", "https://downloads.godotengine.org/");
    exe.root_module.addOptions("godot_rev", options);

    b.installArtifact(exe);
}

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

    const options = b.addOptions();
    // this should be fetched at build time
    // or is this even a good idea at all?
    options.addOption([]const u8, "latest_stable", "4.6.2");
    options.addOption([]const u8, "download_url", "https://downloads.godotengine.org/");
    exe.root_module.addOptions("godot_rev", options);

    b.installArtifact(exe);
}

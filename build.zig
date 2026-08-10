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
    options.addOption([]const u8, "godotorg", "https://downloads.godotengine.org");
    options.addOption([]const u8, "github", "https://github.com/godotengine/godot/releases/download");
    exe.root_module.addOptions("download_urls", options);

    b.installArtifact(exe);
}

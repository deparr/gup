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

    const download_urls = b.addOptions();
    download_urls.addOption([]const u8, "godotorg", "https://downloads.godotengine.org");
    download_urls.addOption([]const u8, "github", "https://github.com/godotengine/godot/releases/download");
    exe.root_module.addOptions("download_urls", download_urls);

    const build_info = b.addOptions();
    if (optimize == .Debug) {
        build_info.addOption([]const u8, "git", "????");
    } else {
        const hash = runWithTrim(b, &.{ "git", "rev-parse", "--short", "HEAD" });
        const branch = runWithTrim(b, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD"});
        const dirty = runWithTrim(b, &.{ "git", "status", "--porcelain" }).len > 0;
        const rev = b.fmt("{s}+{s}{s}", .{ branch, hash, if (dirty) "*" else "" });
        build_info.addOption([]const u8, "git", rev);

    }
    exe.root_module.addOptions("build_info", build_info);

    b.installArtifact(exe);
}

fn runWithTrim(b: *std.Build, args: []const []const u8) []const u8 {
    const res = b.run(args);
    return std.mem.trim(u8, res, " \n\r");
}

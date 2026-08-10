const std = @import("std");
const builtin = @import("builtin");
const download_urls = @import("download_urls");

const Config = @import("Config.zig");
const cache = @import("cache.zig");
const fetch = @import("fetch.zig");
const installer = @import("installer.zig");
const progress = @import("progress.zig");

const log = std.log.default;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const environ = init.environ_map;
    if (builtin.os.tag == .windows) {
        var handle = std.os.windows.CONSOLE.USER_IO.SET_CP(.Output, 65001);
        const status = try handle.operate(io, null);
        if (status != .SUCCESS) {
            log.warn("unable to enable unicode code page, unicode might display incorrectly", .{});
        }
    }

    const args = try init.minimal.args.toSlice(arena);
    const config = try Config.parse(arena, environ, args[1..]);

    errdefer cache.deinit(io);
    switch (config.command) {
        .help => |usage| {
            try std.Io.File.stderr().writeStreamingAll(io, usage);
        },
        .install => |install_options| {
            try cache.init(io, environ, config.verbose);
            try installer.installPackage(io, arena, install_options, config.verbose, config.dry_run);
        },
        .fetch => |fetch_options| {
            try cache.init(io, environ, config.verbose);
            try fetch.fetchPackage(io, arena, fetch_options, config.verbose, config.dry_run);
        },
        .cache => |cache_options| {
            try cache.init(io, environ, config.verbose);
            try cache.command(io, arena, cache_options, config.verbose, config.dry_run);
        }
    }
    cache.deinit(io);
}

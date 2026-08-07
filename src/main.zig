const std = @import("std");
const builtin = @import("builtin");
const download_urls = @import("download_urls");
const Config = @import("Config.zig");
const cache = @import("cache.zig");
const assert = std.debug.assert;

const log = std.log.default;

fn likelyMainBinary(name: []const u8) bool {
    if (std.mem.endsWith(u8, name, &.{std.fs.path.sep})) return false;
    const ext = std.fs.path.extension(name);
    if (std.mem.eql(u8, ext, ".exe")) return true;
    if (std.mem.eql(u8, ext, ".x86_64")) return true;
    if (std.mem.eql(u8, ext, ".arm64")) return true;
    if (std.mem.find(u8, name, "console") != null) return true;
    return false;
}

fn fetchRemote(io: std.Io, arena: std.mem.Allocator, uri: []const u8, writer: *std.Io.Writer) !void {
    log.info("fetching remote: {s}", .{ uri });
    var client = std.http.Client{ .io = io, .allocator = arena };
    defer client.deinit();
    var res = try client.fetch(.{
        .method = .GET,
        .location = .{ .uri = try std.Uri.parse(uri) },
        .response_writer = writer,
        .keep_alive = false,
    });
    if (res.status != .ok) {
        log.err("http error: {t} {?s}", .{ res.status, res.status.phrase() });
        return error.FetchError;
    }
    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const environ = init.environ_map;

    // resolve the config from defaults -> environment -> cli args
    var config: Config = undefined;
    config.initDefault();
    config.initEnv(environ);
    {
        var it = try init.minimal.args.iterateAllocator(arena);
        try config.initCliArgs(&it);
    }
    try config.resolve(arena, environ);
    config.validate() catch |err| {
        var stderr = std.Io.File.stderr().writer(io, &.{});
        switch (err) {
            error.MissingVersion => try stderr.interface.print("error: Missing required option 'version'", .{}),
            error.InvalidPath => try stderr.interface.print("error: Invalid install path '{s}'", .{config.install_path}),
            else => try stderr.interface.print("error: {t}", .{err}),
        }
        try stderr.interface.writeAll("\n\ntry gup --help");
        std.process.exit(1);
    };

    if (config.verbose)
        log.info("resolved: {f}", .{config});

    if (config.dry_run) {
        if (config.from_zip) |zip_path| {
            log.info("would attempt to extract from local file: {s}", .{zip_path});
        } else {
            // todo im using stack space *liberally*, should do a bit of
            // analysis, if for nothing other than curiosity
            var buf: [256]u8 = undefined;
            log.info("would attempt to fetch from remote: {s}", .{try config.makeUri(&buf)});
        }
        return;
    }

    try cache.init(io, environ, &config);
    defer cache.deinit(io);

    const cwd = std.Io.Dir.cwd();
    var buf: [4096]u8 = undefined;
    var zip_file = blk: {
        if (config.from_zip) |local_zip_path| {
            log.info("unpacking from local zip: {s}", .{ local_zip_path });
            break :blk try cwd.openFile(io, local_zip_path, .{});
        }

        if (try cache.packageIsValid(io, config.version, config.flavor, config.slug().?)) {
            log.debug("cache hit {f}-{s}_{s}", .{ config.version, config.flavor, config.slug().? });
            break :blk try cache.getPackageFile(io, config.version, config.flavor, config.slug().?);
        }

        const cached_zip_file = try cache.createPackageFile(io, config.version, config.flavor, config.slug().?);

        var uri_buf: [1024]u8 = undefined;
        var uri_str = try config.makeUri(&uri_buf);

        var zip_file_writer = cached_zip_file.writer(io, &buf);
        try fetchRemote(io, arena, uri_str, &zip_file_writer.interface);

        // this is ass and a hack
        if (cache.getPackageFile(io, config.version, config.flavor, cache.hash_file_name)) |f| {
            f.close(io);
        } else |err| switch (err) {
            error.FileNotFound => {
                const hash_file = try cache.createPackageFile(io, config.version, config.flavor, cache.hash_file_name);
                defer hash_file.close(io);
                var hash_file_writer = hash_file.writer(io, &buf);
                uri_str = try std.fmt.bufPrint(&uri_buf, "{s}/{f}-{s}/SHA512-SUMS.txt", .{ download_urls.github, config.version, config.flavor });
                try fetchRemote(io, arena, uri_str, &hash_file_writer.interface);
            },
            else => {
                log.err("unable to create {f} hash file: {t}", .{ config.version, err });
            },
        }

        break :blk cached_zip_file;
    };
    errdefer zip_file.close(io);
    var zip_reader = zip_file.reader(io, &buf);
    try zip_reader.seekTo(0);

    const dest_dir = try std.Io.Dir.cwd().openDir(io, config.install_path, .{});
    errdefer dest_dir.close(io);
    log.info("extracting to {s}", .{config.install_path});
    {
        var filename_buf: [512]u8 = undefined;
        var it = try std.zip.Iterator.init(&zip_reader);
        while (try it.next()) |entry| {
            entry.extract(&zip_reader, .{}, &filename_buf, dest_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    log.info("{s} already exists, skipping", .{filename_buf[0..entry.filename_len]});
                    continue;
                },
                else => {
                    log.err("while extracting: {t}", .{err});
                    continue;
                },
            };
            const filename = filename_buf[0..entry.filename_len];
            if (config.verbose)
                log.info("extracted {s}", .{filename});

            const likely_main_bin = likelyMainBinary(filename);
            if (config.verbose and likely_main_bin)
                log.info("likely main bin {s}", .{filename});

            if (config.setup_links and likely_main_bin) {
                const console = if (std.mem.find(u8, filename, "console")) |_| "_console" else "";
                const ext = if (builtin.os.tag == .windows) ".exe" else "";

                var symlink_path_buf: [64]u8 = undefined;
                const symlink_path = try std.fmt.bufPrint(&symlink_path_buf, "{s}{s}{s}", .{ config.link_name, console, ext });

                const should_link = blk: {
                    if (dest_dir.statFile(io, symlink_path, .{ .follow_symlinks = false })) |stat| {
                        if (stat.kind != .sym_link) {
                            log.warn("won't remove non-symlink {s} to link to {s}", .{ symlink_path, filename });
                            break :blk false;
                        }
                        try dest_dir.deleteFile(io, symlink_path);
                        break :blk true;
                    } else |err| switch (err) {
                        error.FileNotFound => break :blk true,
                        else => {
                            log.warn("won't link due to stat error: {t}", .{err});
                            break :blk false;
                        },
                    }
                };

                if (should_link) {
                    dest_dir.symLink(io, filename, symlink_path, .{}) catch |err| {
                        log.err("unable to link {s} -> {s}: {t}", .{ symlink_path, filename, err });
                    };
                }
            }

            if (builtin.os.tag == .linux and likely_main_bin) {
                const file = try dest_dir.openFile(io, filename, .{ .mode = .write_only });
                try file.setPermissions(io, .fromMode(0o744));
                file.close(io);
            }
        }
    }

    if (config.setup_links) {
        log.info("symlinked binaries to {s}", .{config.link_name});
    }

    if (config.self_contained) {
        if (dest_dir.createFile(io, "_sc_", .{})) |sc| {
            sc.close(io);
            log.info("installed in self-contained mode, remove '_sc_' from install dir to revert", .{});
        } else |err| switch (err) {
            error.PathAlreadyExists => {},
            else => log.err("unable to create self contained marker: {t}", .{err}),
        }
    }

    zip_file.close(io);
    dest_dir.close(io);
}

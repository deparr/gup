const std = @import("std");
const builtin = @import("builtin");
const godot_rev = @import("godot_rev");
const Config = @import("Config.zig");
const assert = std.debug.assert;

const log = std.log.default;

fn openTempDir(io: std.Io, environ: *std.process.Environ.Map) !std.Io.Dir {
    const path = switch (builtin.os.tag) {
        .linux, .macos => "/tmp",
        .windows => blk: {
            if (environ.get("TEMP")) |temp| {
                break :blk temp;
            }
            if (environ.get("TMP")) |temp| {
                break :blk temp;
            }
            // use appdata, don't really likethis
            log.info("falling back to $APPDATA", .{});
            if (environ.get("APPDATA")) |temp| {
                break :blk temp;
            }
            @panic("why can't I break :blk unreachable");
        },
        else => unreachable,
    };

    return std.Io.Dir.openDirAbsolute(io, path, .{});
}

fn likelyMainBinary(name: []const u8) bool {
    if (std.mem.endsWith(u8, name, &.{std.fs.path.sep})) return false;
    const ext = std.fs.path.extension(name);
    if (std.mem.eql(u8, ext, ".exe")) return true;
    if (std.mem.eql(u8, ext, ".x86_64")) return true;
    if (std.mem.eql(u8, ext, ".arm64")) return true;
    if (std.mem.find(u8, name, "console") != null) return true;
    return false;
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
            error.InvalidPath => try stderr.interface.print("error: Invalid install path '{s}'", .{ config.install_path }),
        }
        try stderr.interface.writeAll("\n\ntry gup --help");
        std.process.exit(1);
    };

    if (config.verbose)
        log.info("resolved: {f}", .{config});

    const cwd = std.Io.Dir.cwd();
    var temp_dir = try openTempDir(io, environ);
    var buf: [4096]u8 = undefined;
    var zip_file = blk: {
        if (config.from_zip) |local_zip_path| {
            log.info("extracting from {s}...", .{ local_zip_path });
            if (config.dry_run) return;
            break :blk try cwd.openFile(io, local_zip_path, .{});
        }

        var uri_buf: [1024]u8 = undefined;
        const uri_str = try config.makeUri(&uri_buf);
        const uri = try std.Uri.parse(uri_str);
        log.info("attempting to fetch uri: {s}...", .{ uri_str });
        if (config.dry_run) return;

        const temp_file = try temp_dir.createFile(io, "gup-godot.zip", .{ .truncate = true, .read = true });
        var temp_file_writer = temp_file.writer(io, &buf);
        var client = std.http.Client{ .io = io, .allocator = arena };
        const res = try client.fetch(.{
            .method = .GET,
            .location = .{ .uri = uri },
            .response_writer = &temp_file_writer.interface,
        });
        client.deinit();

        if (res.status != .ok) {
            log.err("http error: {t} {?s}", .{ res.status, res.status.phrase() });
            return;
        }


        break :blk temp_file;
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
    temp_dir.close(io);
    dest_dir.close(io);
}

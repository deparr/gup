const std = @import("std");
const builtin = @import("builtin");
const cache = @import("cache.zig");
const fetch = @import("fetch.zig");
const Config = @import("Config.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.install);

const InstallOptions = Config.Command.Install;


pub fn installPackage(io: Io, arena: Allocator, options: InstallOptions, verbose: bool, dry_run: bool) !void {
    if (dry_run) {
        switch (options.install_source) {
            .local => |path| log.info("would attempt to extract from local file: {s}", .{path}),
            .remote => {
                var buf: [256]u8 = undefined;
                log.info("would attempt to fetch from remote: {s}", .{try fetch.uriFromSpec(&buf, options.spec)});
            },
        }
        return;
    }

    const pretty_print = std.Io.File.stdout().isTty(io) catch false;

    const spec = options.spec;

    const cwd = std.Io.Dir.cwd();
    var buf: [4096]u8 = undefined;
    var zip_file = blk: switch (options.install_source) {
        .local => |path| {
            log.info("unpacking local zip: {s}", .{path});
            break :blk try cwd.openFile(io, path, .{});
        },
        .remote => {
            if (try cache.packageIsValid(io, spec, .{ .skip_hash = spec.isStable() })) {
                log.debug("cache hit on {s}", .{spec.slug});
                break :blk try cache.getPackageFile(io, spec.version, spec.slug);
            }

            const cached_zip_file = try cache.createPackageFile(io, spec.version, spec.slug);

            var uri_buf: [1024]u8 = undefined;
            var uri_str = try fetch.uriFromSpec(&uri_buf, spec);

            var zip_file_writer = cached_zip_file.writer(io, &buf);
            try fetch.fetchRemote(io, arena, uri_str, &zip_file_writer.interface, pretty_print);

            // godot doesn't publish hashes for non-tagged releases
            if (spec.isStable()) {
                // this is ass and a hack
                if (cache.getPackageFile(io, spec.version, cache.hash_file_name)) |f| {
                    f.close(io);
                } else |err| switch (err) {
                    error.FileNotFound => {
                        const hash_file = try cache.createPackageFile(io, spec.version, cache.hash_file_name);
                        defer hash_file.close(io);
                        var hash_file_writer = hash_file.writer(io, &buf);
                        uri_str = try fetch.hashFileUri(&uri_buf, spec.version);
                        try fetch.fetchRemote(io, arena, uri_str, &hash_file_writer.interface, pretty_print);
                    },
                    else => {
                        log.err("unable to create {f} hash file {t}", .{ spec.version, err });
                    },
                }
            }

            break :blk cached_zip_file;
        },
    };

    errdefer zip_file.close(io);
    var zip_reader = zip_file.reader(io, &buf);
    try zip_reader.seekTo(0);

    const dest_dir = try std.Io.Dir.cwd().openDir(io, options.install_path, .{});
    errdefer dest_dir.close(io);
    log.info("extracting to {s}", .{options.install_path});
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
            if (verbose)
                log.info("extracted {s}", .{filename});

            const likely_main_bin = likelyMainBinary(filename);
            if (verbose and likely_main_bin)
                log.info("likely main bin {s}", .{filename});

            if (options.setup_links and likely_main_bin) {
                const console = if (std.mem.find(u8, filename, "console")) |_| "_console" else "";
                const ext = if (builtin.os.tag == .windows) ".exe" else "";

                var symlink_path_buf: [64]u8 = undefined;
                const symlink_path = try std.fmt.bufPrint(&symlink_path_buf, "{s}{s}{s}", .{ options.link_name, console, ext });

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

    if (options.setup_links) {
        log.info("symlinked binaries to {s}", .{options.link_name});
    }

    if (options.self_contained) {
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

fn likelyMainBinary(name: []const u8) bool {
    if (std.mem.endsWith(u8, name, &.{std.fs.path.sep})) return false;
    const ext = std.fs.path.extension(name);
    if (std.mem.eql(u8, ext, ".exe")) return true;
    if (std.mem.eql(u8, ext, ".x86_64")) return true;
    if (std.mem.eql(u8, ext, ".arm64")) return true;
    if (std.mem.find(u8, name, "console") != null) return true;
    return false;
}

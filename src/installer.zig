const std = @import("std");
const builtin = @import("builtin");
const cache = @import("cache.zig");
const fetch = @import("fetch.zig");
const Config = @import("Config.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.install);

const InstallOptions = Config.Command.Install;


pub fn installPackage(io: Io, gpa: Allocator, options: InstallOptions, verbose: bool, dry_run: bool) !void {
    if (dry_run) {
        switch (options.install_source) {
            .local => |path| log.info("would attempt to extract from local file: {s}", .{path}),
            .remote => {
                var buf: [256]u8 = undefined;
                log.info("would attempt to fetch from remote: {s}", .{try fetch.uriFromSpec(&buf, options.spec)});
            },
        }
        log.info("would attempt to extract to: {s}", .{ options.dir });
        return;
    }

    const spec = options.spec;

    const cwd = std.Io.Dir.cwd();
    var buf: [4096]u8 = undefined;
    var zip_file = blk: switch (options.install_source) {
        .local => |path| {
            log.info("unpacking local zip: {s}", .{path});
            break :blk try cwd.openFile(io, path, .{});
        },
        .remote => {
            if (!options.force_fetch and try cache.packageIsValid(io, spec, .{ .skip_hash = !spec.isStable() })) {
                log.debug("cache hit on {s}", .{spec.slug});
                break :blk try cache.getPackageFile(io, spec.version, spec.slug);
            }

            if (options.disallow_fetch) {
                log.err("need to fetch v{f}-{s}, but fetching was disallowed", .{ spec.version, spec.version.flavor });
                return error.FetchDisallowed;
            }

            try fetch.fetchPackage(io, gpa, spec, null);

            break :blk try cache.getPackageFile(io, spec.version, spec.slug);
        },
    };

    errdefer zip_file.close(io);
    var zip_reader = zip_file.reader(io, &buf);
    try zip_reader.seekTo(0);

    const dest_dir = try std.Io.Dir.cwd().openDir(io, options.dir, .{});
    errdefer dest_dir.close(io);
    log.info("extracting to {s}", .{options.dir});
    {
        var filename_buf: [512]u8 = undefined;
        var it = try std.zip.Iterator.init(&zip_reader);
        while (try it.next()) |entry| {
            entry.extract(&zip_reader, .{}, &filename_buf, dest_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    if (verbose)
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

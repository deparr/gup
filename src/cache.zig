const std = @import("std");
const builtin = @import("builtin");
const Config = @import("Config.zig");
const hex = @import("hex.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const PackageSpec = Config.PackageSpec;
const Version = Config.Version;
const CacheCommand = Config.Command.Cache;
const path = std.fs.path;
const assert = std.debug.assert;
const Sha512 = std.crypto.hash.sha2.Sha512;

const log = std.log.scoped(.cache);

pub const root_prefix = "gup";
pub const hash_file_name = "sha512-sums.txt";

var has_root: ?std.Io.Dir = null;

pub fn command(io: Io, gpa: Allocator, options: CacheCommand, verbose: bool, dry_run: bool) !void {
    switch (options.sub_command) {
        .list => try listCache(io, gpa, verbose),
        .clean => try cleanCache(io, gpa, verbose, dry_run),
    }
}

pub fn init(io: std.Io, environ: *std.process.Environ.Map, verbose: bool) !void {
    if (has_root) |_| return;
    const root_path = blk: {
        if (environ.get("GUP_CACHE_HOME")) |gup_cache| break :blk gup_cache;
        const joiner = joiner: switch (builtin.os.tag) {
            .windows => {
                if (environ.get("LOCALAPPDATA")) |local_app_data| break :joiner path.fmtJoin(&.{ local_app_data, root_prefix });
                return error.NoCacheDir;
            },
            else => {
                if (environ.get("XDG_CACHE_HOME")) |xdg_cache| break :joiner path.fmtJoin(&.{ xdg_cache, root_prefix });
                if (environ.get("HOME")) |home| break :joiner path.fmtJoin(&.{ home, ".cache", root_prefix });
                return error.NoCacheDir;
            },
        };
        var buf: [256]u8 = undefined;
        break :blk try std.fmt.bufPrint(&buf, "{f}", .{joiner});
    };

    has_root = std.Io.Dir.cwd().createDirPathOpen(io, root_path, .{ .open_options = .{ .follow_symlinks = true, .iterate = true } }) catch |err| {
        log.err("opening cache ({s}): {t}", .{ root_path, err });
        return error.CacheInit;
    };

    if (verbose)
        log.info("using cache dir {s}", .{root_path});
}

pub fn deinit(io: std.Io) void {
    if (has_root) |root| {
        root.close(io);
        has_root = null;
    }
}

pub const CacheCheckOptions = struct {
    skip_hash: bool = false,
};

pub fn packageIsValid(io: std.Io, spec: PackageSpec, options: CacheCheckOptions) !bool {
    const root = has_root orelse return error.NoCacheInit;

    var path_buf: [256]u8 = undefined;
    const version_dir_path = try std.fmt.bufPrint(&path_buf, "{f}-{s}", .{ spec.version, spec.version.flavor });
    const version_dir = root.openDir(io, version_dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer version_dir.close(io);

    const package_file = version_dir.openFile(io, spec.slug, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer package_file.close(io);

    if (options.skip_hash) return true;

    const hash_file = version_dir.openFile(io, hash_file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer hash_file.close(io);

    var package_digest: [Sha512.digest_length]u8 = undefined;
    var stream_buf: [1024 * 16]u8 = undefined;
    var package_reader = package_file.reader(io, &stream_buf);

    var hash_buf: [1024 * 16]u8 = undefined;
    var hashing = std.Io.Writer.Hashing(Sha512).init(&hash_buf);

    _ = try package_reader.interface.streamRemaining(&hashing.writer);
    try hashing.writer.flush();
    hashing.hasher.final(&package_digest);

    var reader = hash_file.reader(io, &stream_buf);
    while (try reader.interface.takeDelimiter('\n')) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        var iter = std.mem.tokenizeScalar(u8, trimmed, ' ');
        const true_digest = iter.next() orelse return false;
        const id = iter.next() orelse return false;

        if (std.mem.find(u8, id, spec.slug) == null) continue;

        const decoded_digest = hex.encode(&package_digest, Sha512.digest_length * 2);
        return std.ascii.eqlIgnoreCase(&decoded_digest, true_digest);
    }

    return false;
}

pub fn getPackageFile(io: std.Io, version: Version, sub_path: []const u8) !std.Io.File {
    const root = has_root orelse return error.NoCacheInit;
    var path_buf: [256]u8 = undefined;
    const package_path = try std.fmt.bufPrint(&path_buf, "{f}-{s}/{s}", .{ version, version.flavor, sub_path });
    return root.openFile(io, package_path, .{});
}

pub fn createPackageFile(io: std.Io, version: Version, sub_path: []const u8) !std.Io.File {
    const root = has_root orelse return error.NoCacheInit;
    var path_buf: [256]u8 = undefined;
    const version_path = try std.fmt.bufPrint(&path_buf, "{f}-{s}", .{ version, version.flavor });
    const version_dir = try root.createDirPathOpen(io, version_path, .{});
    defer version_dir.close(io);
    return version_dir.createFile(io, sub_path, .{ .read = true });
}

pub fn putPackage(io: std.Io, version: Version, sub_path: []const u8, data: []const u8) !void {
    const root = has_root orelse return error.NoCacheInit;
    var buf: [16 * 1024]u8 = undefined;
    const version_path = try std.fmt.bufPrint(&buf, "{f}-{s}", .{ version, version.flavor });
    const version_dir = try root.createDirPathOpen(io, version_path, .{});
    defer version_dir.close(io);

    const new_file = try version_dir.createFile(io, sub_path, .{ .truncate = true });
    defer new_file.close(io);
    try new_file.writer(io, &buf).interface.writeAll(data);
}

const CacheFileInfo = struct {
    path: []const u8,
    size: u64,
};

const CacheDirInfo = struct {
    path: []const u8,
    files: std.ArrayList(CacheFileInfo),

    fn deinit(self: *CacheDirInfo, gpa: Allocator) void {
        gpa.free(self.path);
        for (self.files.items) |f| gpa.free(f.path);
        self.files.deinit(gpa);
    }
};

const HumanSize = struct {
    count: usize,
    magnitude: enum {
        bytes,
        kilo,
        mega,
        giga,

        fn fromBytes(b: usize) @This() {
            return switch (b) {
                0...1023 => .bytes,
                1024...1048575 => .kilo,
                1048576...1073741823 => .mega,
                else => .giga,
            };
        }

        fn char(self: @This()) u8 {
            return switch (self) {
                .bytes => 'B',
                .kilo => 'K',
                .mega => 'M',
                .giga => 'G',
            };
        }
    },

    pub fn format(self: HumanSize, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("{d}{c}", .{ self.count, self.magnitude.char() });
    }
};

fn readableSize(size: usize) HumanSize {
    var power: usize = 1;
    while (size / (power * 1024) > 0) power *= 1024;
    return .{
        .count = size / power,
        .magnitude = .fromBytes(power),
    };
}

fn listCache(io: Io, gpa: Allocator, verbose: bool) !void {
    const max_depth = 10;
    _ = verbose;

    const root = has_root orelse return error.NoCacheInit;
    var root_path_buf: [256]u8 = undefined;
    // todo docs advise against Dir.realPath()
    const root_path_len = try root.realPath(io, &root_path_buf);

    var iter = try root.walkSelectively(gpa);
    defer iter.deinit();

    var root_info = try std.ArrayList(CacheDirInfo).initCapacity(gpa, 10);
    defer { for (root_info.items) |*d| d.deinit(gpa); root_info.deinit(gpa); }

    while (try iter.next(io)) |entry| {
        if (entry.depth() > max_depth) {
            log.warn("cache list max depth reached", .{});
            break;
        }

        switch (entry.kind) {
            .directory => {
                try iter.enter(io, entry);
                try root_info.append(gpa, .{
                    .path = try gpa.dupe(u8, entry.path),
                    .files = .empty,
                });
            },
            .file => {
                const dir = path.dirname(entry.path) orelse "";
                var dir_info = for (root_info.items) |*dir_info| {
                    if (std.mem.eql(u8, dir_info.path, dir)) break dir_info;
                } else unreachable;
                const stat = try entry.dir.statFile(io, entry.basename, .{});
                try dir_info.files.append(gpa, .{
                    .path = try gpa.dupe(u8, entry.basename),
                    .size = stat.size,
                });
            },
            else => {},
        }
    }

    var out_buf: [2048]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    var writer = &stdout.interface;

    try writer.print("gup cache '{s}':\n", .{root_path_buf[0..root_path_len]});
    var root_total_size: u64 = 0;
    for (root_info.items) |dir_info| {
        var dir_total_size: u64 = 0;
        var biggest_file_name_len: usize = 0;
        for (dir_info.files.items) |item| {
            dir_total_size += item.size;
            biggest_file_name_len = @max(item.path.len, biggest_file_name_len);
        }

        try writer.print("  {s}/", .{ dir_info.path });
        _ = try writer.splatByte(' ', biggest_file_name_len -| dir_info.path.len + 1);
        try writer.print("  {f}\n", .{ readableSize(dir_total_size) });

        for (dir_info.files.items, 0..) |item, i| {
            if (i < dir_info.files.items.len - 1)
                try writer.print("  ├ {s}", .{item.path})
            else
                try writer.print("  └ {s}", .{item.path});
            _ = try writer.splatByte(' ', biggest_file_name_len - item.path.len);
            try writer.print("  {f}\n", .{readableSize(item.size)});
        }

        try writer.writeByte('\n');
        root_total_size += dir_total_size;
    }
    try writer.print("total_size: {f}\n", .{readableSize(root_total_size)});
    try writer.flush();
}

// todo accept specific versions to delete
fn cleanCache(io: Io, gpa: Allocator, verbose: bool, dry_run: bool) !void {
    _ = gpa;

    const root = has_root orelse return error.NoCacheInit;

    var root_path_buf: [256]u8 = undefined;
    // todo docs advise against Dir.realPath()
    const root_path_len = try root.realPath(io, &root_path_buf);
    const root_path = root_path_buf[0..root_path_len];

    if (dry_run) {
        log.info("would attempt to recursively delete directory: {s}", .{ root_path });
        return;
    }

    var iter = root.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (verbose)
                    log.info("deleting {s}/{s}/* ...", .{ root_path, entry.name });
                try root.deleteTree(io, entry.name);
            },
            else => log.warn("skipping non directory from cache clean: {s}", .{ entry.name }),
        }
    }
}

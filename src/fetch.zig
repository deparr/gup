const std = @import("std");
const download_urls = @import("download_urls");
const Config = @import("Config.zig");
const progress = @import("progress.zig");
const cache = @import("cache.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const PackageSpec = Config.PackageSpec;
const SourceHost = Config.SourceHost;
const Version = Config.Version;
const FetchOptions = Config.Command.Fetch;

const log = std.log.scoped(.fetch);

pub fn fetchPackageOptions(io: Io, gpa: Allocator, options: FetchOptions, verbose: bool, dry_run: bool) !void {
    if (dry_run) {
        var uri_buf: [1024]u8 = undefined;
        const uri_str = try makeUri(&uri_buf, options.spec, options.source_host);
        log.info("would attempt to fetch from remote: {s}", .{uri_str});
        return;
    }

    if (!options.force and try cache.packageIsValid(io, options.spec, .{ .skip_hash = !options.spec.isStable() })) {
        if (verbose)
            log.debug("cache hit on {s}", .{options.spec.slug});
        return;
    }

    try fetchPackage(io, gpa, options.spec, options.source_host);
}

pub fn fetchPackage(io: Io, gpa: Allocator, spec: PackageSpec, source: ?SourceHost) !void {
    var uri_buf: [1024]u8 = undefined;
    var uri = if (source) |sh|
        try makeUri(&uri_buf, spec, sh)
    else
        try uriFromSpec(&uri_buf, spec);

    const pretty_print = Io.File.stdout().isTty(io) catch false;

    const cache_file = try cache.createPackageFile(io, spec.version, spec.slug);
    var io_buf: [2048]u8 = undefined;
    var cache_file_writer = cache_file.writer(io, &io_buf);

    try fetchRemote(io, gpa, uri, &cache_file_writer.interface, pretty_print);

    if (!spec.isStable()) {
        return;
    }

    // this is ass and a hack
    if (cache.getPackageFile(io, spec.version, cache.hash_file_name)) |f| {
        f.close(io);
    } else |err| switch (err) {
        error.FileNotFound => {
            const hash_file = try cache.createPackageFile(io, spec.version, cache.hash_file_name);
            defer hash_file.close(io);
            var hash_file_writer = hash_file.writer(io, &io_buf);
            uri = try hashFileUri(&uri_buf, spec.version);
            try fetchRemote(io, gpa, uri, &hash_file_writer.interface, pretty_print);
        },
        else => {
            log.err("unable to create {f} hash file {t}", .{ spec.version, err });
        },
    }
}

pub fn fetchRemote(io: Io, gpa: Allocator, uri: []const u8, writer: *std.Io.Writer, display_progress: bool) !void {
    log.info("fetching remote: {s}", .{uri});

    var client = std.http.Client{ .io = io, .allocator = gpa };
    defer client.deinit();

    var req = try client.request(.GET, try std.Uri.parse(uri), .{ .keep_alive = false });
    defer req.deinit();
    try req.sendBodiless();

    var head_buf: [8192]u8 = undefined;
    var res = try req.receiveHead(&head_buf);
    if (res.head.status != .ok) {
        log.err("http error: {t} {?s}", .{ res.head.status, res.head.status.phrase() });
        return error.FetchError;
    }

    log.debug("remote file has len: {?d}", .{res.head.content_length});

    var spinner: ?std.Io.Future(void) = null;
    if (display_progress) spinner = io.async(spin, .{io});
    defer if (spinner) |*f| f.cancel(io);

    var body_buf: [8192]u8 = undefined;
    var body_reader = res.reader(&body_buf);
    _ = try body_reader.streamRemaining(writer);
    try writer.flush();
}

pub fn makeUri(buf: []u8, spec: PackageSpec, source: SourceHost) ![]const u8 {
    return switch (source) {
        .github => makeGithubUri(buf, spec),
        .godotorg => makeGodotOrgUri(buf, spec),
    };
}

pub fn uriFromSpec(buf: []u8, spec: PackageSpec) ![]const u8 {
    return if (spec.isStable())
        makeGithubUri(buf, spec)
    else
        makeGodotOrgUri(buf, spec);
}

pub fn hashFileUri(buf: []u8, version: Version) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{s}/{f}-{s}/SHA512-SUMS.txt",
        .{ download_urls.github, version, version.flavor },
    );
}

pub fn makeGithubUri(buf: []u8, spec: PackageSpec) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{[url]s}/{[version]f}-{[flavor]s}/Godot_v{[version]f}-{[flavor]s}_{[slug]s}",
        .{ .url = download_urls.github, .version = spec.version, .flavor = spec.version.flavor, .slug = spec.slug },
    );
}

pub fn makeGodotOrgUri(buf: []u8, spec: PackageSpec) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{s}?version={f}&flavor={s}&slug={s}&platform={s}",
        .{ download_urls.godotorg, spec.version, spec.version.flavor, spec.slug, platformQuery(spec) },
    );
}

pub fn platformQuery(spec: PackageSpec) []const u8 {
    return switch (spec.platform) {
        .android => "android.apk",
        .pico => "android.picoos",
        .horizon => "android.horizonos",
        .web => "web",
        .windows => switch (spec.arch) {
            .x64 => "windows.64",
            .x32 => "windows.32",
            .arm64 => "windows.arm64",
            .arm32, .universal => unreachable,
        },
        .linux => switch (spec.arch) {
            .x64 => "linux.64",
            .x32 => "linux.32",
            .arm64 => "linux.arm64",
            .arm32 => "linux.arm32",
            .universal => unreachable,
        },
        .macos => "macos.universal",
    };
}

/// spins until canceled
// todo spinner that works with -fsingle-threaded
fn spin(io: Io) void {
    var spinner = progress.Spinner.init();
    var buf: [64]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);
    var w = &stdout.interface;

    w.print("\x1b[?25l", .{}) catch {}; // hide cursor
    while (io.sleep(.fromMilliseconds(100), .awake)) |_| {
        w.print("\x1b[2K\r downloading... {s}", .{spinner.next()}) catch {};
        w.flush() catch {};
    } else |_| {}
    w.print("\x1b[2K\r\x1b[?25h", .{}) catch {}; // show cursor
    w.flush() catch {};
}

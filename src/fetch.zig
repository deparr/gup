const std = @import("std");
const download_urls = @import("download_urls");
const Config = @import("Config.zig");
const progress = @import("progress.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const PackageSpec = Config.PackageSpec;
const SourceHost = Config.SourceHost;
const Version = Config.Version;
const FetchOptions = Config.Command.Fetch;

const log = std.log.scoped(.fetch);

pub fn fetchPackage(io: Io, arena: Allocator, options: FetchOptions, verbose: bool, dry_run: bool) !void {
    _ = io;
    _ = arena;
    _ = options;
    _ = verbose;
    _ = dry_run;
}

pub fn fetchRemote(io: Io, arena: Allocator, uri: []const u8, writer: *std.Io.Writer, display_progress: bool) !void {
    log.info("fetching remote: {s}", .{ uri });

    var client = std.http.Client{ .io = io, .allocator = arena };
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

    log.debug("remote file has len: {?d}", .{ res.head.content_length });

    var spinner: ?std.Io.Future(void) = null;
    if (display_progress) spinner = io.async(spin, .{ io });
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
fn spin(io: Io) void {
    var spinner = progress.Spinner.init();
    var buf: [64]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);
    var w = &stdout.interface;
    
    w.print("\x1b[?25l", .{}) catch {}; // hide cursor
    while (io.sleep(.fromMilliseconds(100), .awake)) |_| {
        w.print("\x1b[2K\r downloading... {s}", .{ spinner.next() }) catch {};
        w.flush() catch {};
    } else |_| {}
    w.print("\x1b[2K\r\x1b[?25h", .{}) catch {}; // show cursor
    w.flush() catch {};
}



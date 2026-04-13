const std = @import("std");
const builtin = @import("builtin");
const godot_rev = @import("godot_rev");

const log = std.log.scoped(.gup);

const usage =
\\gup [OPTIONS]
\\
\\  --help, -h   Show this menu
;

const Config = struct {
    platform: Platform,
    arch: Arch,
    script: Script,
    version: Version,
    flavor: []const u8,
    install_path: []const u8,
    bin_name: []const u8 = &.{},

    pub fn initDefault(self: *Config) void {
        self.* = .{
            .platform = switch (builtin.os.tag) {
                .windows => .windows,
                .linux => .linux,
                .macos => .macos,
                // default to windows
                else => .windows,
            },
            .arch = switch (builtin.cpu.arch) {
                .x86_64 => .x64,
                .x86 => .x32,
                .aarch64 => .arm64,
                .arm => .arm32,
                // default to x86_64
                else => .x64,
            },
            .script = .gdscript,
            .version = Version.parse(godot_rev.latest_stable) catch unreachable,
            .flavor = "stable",
            .install_path = if (builtin.os.tag == .windows) "~/AppData/Roaming" else "~/.local/bin",
        };
    }

    pub fn initEnv(self: *Config, env: std.process.EnvMap) void {
        if (env.get("GUP_PLATFORM")) |platform_str| {
            if (enumFromEnv(Platform, "GUP_PLATFORM", platform_str)) |platform| {
                self.platform = platform;
            }
        }
        if (env.get("GUP_ARCH")) |arch_str| {
            if (enumFromEnv(Arch, "GUP_ARCH", arch_str)) |arch| {
                self.arch = arch;
            }
        }
        if (env.get("GUP_SCRIPT")) |script_str| {
            if (enumFromEnv(Script, "GUP_SCRIPT", script_str)) |script| {
                self.script = script;
            }
        }
        if (env.get("GUP_VERSION")) |version_str| {
            if (Config.Version.parse(version_str)) |version| {
                self.version = version;
            } else |err| {
                log.warn("GUP_VERSION={s} failed to parse: {t}", .{ version_str, err });
            }
        }
        if (env.get("GUP_FLAVOR")) |flavor| {
            self.flavor = flavor;
        }
        if (env.get("GUP_INSTALL_PATH")) |install_path| {
            self.install_path = install_path;
        }
    }

    fn enumFromEnv(Tag: type, env_key: []const u8, env_value: []const u8) ?Tag {
        if (std.meta.stringToEnum(Tag, env_value)) |value| {
            return value;
        }

        log.warn("{s} exists but does not contain a valid value ({s}), falling back to default", .{ env_key, env_value });
        return null;
    }

    /// assumes caller frees `args`
    pub fn initCliArgs(self: *Config, args: *std.process.ArgIterator) !void {
        _ = args.skip();
        while (args.next()) |arg| {
            const kind = argKind(arg);
            const maybe_pair = switch (kind) {
                .short => arg[1..],
                .long => arg[2..],
                .positional => {
                    log.warn("ignoring positional arg: {s}", .{arg});
                    continue;
                },
            };

            var pair_it = std.mem.tokenizeScalar(u8, maybe_pair, '=');
            const key, const value = .{ pair_it.next().?, pair_it.rest() };

            if (strcmp(key, "platform") or strcmp(key, "p")) {
                if (std.meta.stringToEnum(Platform, value)) |platform| {
                    self.platform = platform;
                } else {
                    log.err("invalid platform: {s}", .{value});
                }
            } else if (strcmp(key, "arch") or strcmp(key, "a")) {
                if (std.meta.stringToEnum(Arch, value)) |arch| {
                    self.arch = arch;
                } else {
                    log.err("invalid arch: {s}", .{value});
                }
            } else if (strcmp(key, "version") or strcmp(key, "v")) {
                self.version = try Version.parse(value);
            } else if (strcmp(key, "flavor") or strcmp(key, "f")) {
                self.flavor = value;
            } else if (strcmp(key, "install-path") or strcmp(key, "i")) {
                self.install_path = value;
            } else if (strcmp(key, "help") or strcmp(key, "h")) {
                // todo properly write this to stderr
                std.debug.print("{s}\n", .{ usage });
                std.process.exit(0);
            } else {
                log.warn("ignoring unknown arg key: {s}", .{key});
            }
        }
    }

    fn argKind(arg: []const u8) enum { short, long, positional } {
        if (std.mem.startsWith(u8, arg, "--")) return .long;
        if (std.mem.startsWith(u8, arg, "-")) return .short;
        return .positional;
    }

    fn strcmp(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    pub fn slug(self: Config) ?[]const u8 {
        // these are so messy
        // there is next to no consistency between filenames
        // just hardcode them all, will be as brittle as trying to do it
        // more granularly
        return switch (self.platform) {
            .pico => "android_editor_picoos.apk",
            .horizon => "android_editor_horizonos.apk",
            .android => "android_editor.apk",
            .web => "web_editor.zip",
            .windows => switch (self.script) {
                .dotnet => switch (self.arch) {
                    .x64 => "mono_win64.zip",
                    .x32 => "mono_win32.zip",
                    .arm64 => "mono_windows_arm64.zip",
                    .arm32, .universal => null,
                },
                .gdscript => switch (self.arch) {
                    .x64 => "win64.exe.zip",
                    .x32 => "win32.exe.zip",
                    .arm64 => "windows_arm64.exe.zip",
                    .arm32, .universal => null,
                },
            },
            .linux => switch (self.script) {
                .dotnet => switch (self.arch) {
                    .x64 => "mono_linux_x86_64.zip",
                    .x32 => "mono_linux_x86_32.zip",
                    .arm64 => "mono_linux_arm64.zip",
                    .arm32 => "mono_linux_arm32.zip",
                    .universal => null,
                },
                .gdscript => switch (self.arch) {
                    .x64 => "linux.x86_64.zip",
                    .x32 => "linux.x86_32.zip",
                    .arm64 => "linux.arm64.zip",
                    .arm32 => "linux.arm32.zip",
                    .universal => null,
                },
            },
            .macos => switch (self.script) {
                .dotnet => "macos.universal.zip",
                .gdscript => "mono_macos.universal.zip",
            },
        };
    }

    pub fn platformQuery(self: Config) ?[]const u8 {
        return switch (self.platform) {
            .android => "android.apk",
            .pico => "android.picoos",
            .horizon => "android.horizonos",
            .web => "web",
            .windows => switch (self.arch) {
                .x64 => "windows.64",
                .x32 => "windows.32",
                .arm64 => "windows.arm64",
                .arm32, .universal => null,
            },
            .linux => switch (self.arch) {
                .x64 => "linux.64",
                .x32 => "linux.32",
                .arm64 => "linux.arm64",
                .arm32 => "linux.arm32",
                .universal => null,
            },
            .macos => "macos.universal",
        };
    }

    pub fn format(self: Config, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            \\Config{{
            \\  platform: {t}
            \\  arch: {t}
            \\  version: {f}
            \\  flavor: {s}
            \\}}
        ,
            .{ self.platform, self.arch, self.version, self.flavor },
        );
    }

    pub const Platform = enum {
        windows,
        linux,
        macos,
        web,
        android,
        horizon,
        pico,
    };

    pub const Arch = enum {
        x64,
        x32,
        arm64,
        arm32,
        universal,
    };

    pub const Script = enum {
        gdscript,
        dotnet,
    };

    pub const Version = struct {
        major: u32,
        minor: u32,
        patch: ?u32,

        pub fn parse(str: []const u8) !Version {
            var it = std.mem.splitScalar(u8, str, '.');
            return Version{
                .major = try parseNum(it.first()) orelse return error.InvalidVersion,
                .minor = try parseNum(it.next()) orelse return error.InvalidVersion,
                .patch = try parseNum(it.next()),
            };
        }

        pub fn format(self: Version, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{d}.{d}", .{ self.major, self.minor });
            if (self.patch) |p| {
                try writer.print(".{d}", .{p});
            }
        }

        fn parseNum(str: ?[]const u8) !?u32 {
            if (str == null) return null;

            return std.fmt.parseInt(u32, str.?, 10) catch |err| switch (err) {
                error.InvalidCharacter => error.InvalidVersion,
                error.Overflow => err,
            };
        }
    };
};

fn uriQueryFromConfig(config: Config, buf: []u8) !usize {
    var w = std.Io.Writer.fixed(buf);
    try w.print("?version={f}", .{ config.version });
    if (config.flavor.len > 0) {
        try w.print("&flavor={s}", .{ config.flavor });
    }
    if (config.slug()) |slug| {
        try w.print("&slug={s}", .{ slug });
    } else {
        return error.InvalidBuildConfig;
    }
    if (config.platformQuery()) |platform| {
        try w.print("&platform={s}", .{ platform });
    } else {
        return error.InvalidBuildConfig;
    }

    return w.buffered().len;
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    // resolve the config from defaults -> environment -> cli args
    var config: Config = undefined;
    config.initDefault();
    var environ = try std.process.getEnvMap(gpa);
    defer environ.deinit();
    config.initEnv(environ);
    {
        var it = try std.process.argsWithAllocator(gpa);
        try config.initCliArgs(&it);
        it.deinit();
    }

    log.info("resolved config: {f}", .{config});

    var buf: [4096]u8 = undefined;
    @memcpy(buf[0..].ptr, godot_rev.download_url);
    const query_str_len = try uriQueryFromConfig(config, buf[godot_rev.download_url.len..]);
    const uri_str = buf[0..godot_rev.download_url.len + query_str_len];
    const uri = try std.Uri.parse(uri_str);

    log.info("attempting to fetch uri: {s}", .{ uri_str });

    var res_writer = try std.Io.Writer.Allocating.initCapacity(gpa, 10 * 1024 * 1024);
    var client = std.http.Client{ .allocator = gpa };
    const res = try client.fetch(. {
        .method = .GET,
        .location = .{ .uri = uri },
        .response_writer = &res_writer.writer,
    });
    client.deinit();

    if (res.status != .ok) {
        log.err("http error status: {t} {?s}", .{ res.status, res.status.phrase() });
        return;
    }

    const zip_bytes = try res_writer.toOwnedSlice();
    log.info("zip len: {d}", .{ zip_bytes.len });
    gpa.free(zip_bytes);
}

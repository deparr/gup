const std = @import("std");
const builtin = @import("builtin");
const godot_rev = @import("godot_rev");
const assert = std.debug.assert;

const log = std.log.scoped(.gup);

const usage =
    \\gup [OPTIONS]
    \\
    \\  --platform=[V],       -p   Specify a platform [windows, linux, macos, web, android, horizon, pico] (host)
    \\  --arch=[V],           -a   Specify an architecture [x64, x32, arm64, arm32, universal] (host)
    \\  --script=[V],         -s   Specify script support [gdscript*, dotnet]
    \\  --flavor=[STR],       -f   Specify a build flavor (stable)
    \\  --install-path=[STR], -i   Specify binary location (win: ~/AppData/Roaming/gup, else: ~/.local/bin)
    \\  --setup-links=[bool], -l   Create flavor-delineated symlink to main binary. ie godot ->  Godot_4.6.2.win64.exe
    \\  --link-name=[STR],    -o   Base name for symlinks when --setup-links is true. (godot)
    \\  --help,               -h   Show this menu
;

const Config = struct {
    platform: Platform,
    arch: Arch,
    script: Script,
    version: Version,
    flavor: []const u8,
    install_path: []const u8,
    /// cli only option
    setup_links: bool,
    link_name: []const u8,
    dry_run: bool,

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
            .install_path = if (builtin.os.tag == .windows) "~/AppData/Roaming/gup" else "~/.local/bin",
            .setup_links = true,
            .link_name = "godot",
            .dry_run = false,
        };
    }

    pub fn initEnv(self: *Config, env: *std.process.Environ.Map) void {
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
        if (env.get("GUP_SETUP_LINKS")) |setup_links| {
            self.setup_links = readBoolOption(setup_links);
        }
        if (env.get("GUP_LINK_NAME")) |link_name| {
            self.link_name = link_name;
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
    pub fn initCliArgs(self: *Config, args: *std.process.Args.Iterator) !void {
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
            } else if (strcmp(key, "script") or strcmp(key, "s")) {
                if (std.meta.stringToEnum(Script, value)) |script| {
                    self.script = script;
                } else {
                    log.err("invalid script: {s}", .{value});
                }
            } else if (strcmp(key, "version") or strcmp(key, "v")) {
                self.version = try Version.parse(value);
            } else if (strcmp(key, "flavor") or strcmp(key, "f")) {
                self.flavor = value;
            } else if (strcmp(key, "install-path") or strcmp(key, "i")) {
                self.install_path = value;
            } else if (strcmp(key, "setup-links") or strcmp(key, "l")) {
                self.setup_links = readBoolOption(value);
            } else if (strcmp(key, "link-name") or strcmp(key, "o")) {
                self.link_name = value;
            } else if (strcmp(key, "dry-run") or strcmp(key, "n")) {
                self.dry_run = true;
            } else if (strcmp(key, "help") or strcmp(key, "h")) {
                // todo properly write this to stderr
                std.debug.print("{s}\n", .{usage});
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

    fn readBoolOption(value: []const u8) bool {
        return strcmp(value, "1") or
            std.ascii.eqlIgnoreCase(value, "yes") or
            std.ascii.eqlIgnoreCase(value, "true");
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

    pub fn resolve(self: *Config, arena: std.mem.Allocator, environ: *std.process.Environ.Map) !void {
        if (!std.fs.path.isAbsolute(self.install_path)) {
            const path = self.install_path;
            if (path.len < 1 or path[0] != '~') return error.NonAbsoluteInstallPath;
            const home = switch (builtin.os.tag) {
                .windows => environ.get("USERPROFILE"),
                else => environ.get("HOME"),
            } orelse return error.MissingHomeVar;

            self.install_path = try std.fs.path.join(arena, &.{ home, path[1..] });
        }
    }

    pub fn linkSuffix(self: *const Config) []const u8 {
        if (strcmp(self.flavor, "stable")) {
            return "";
        } else if (std.mem.find(u8, self.flavor, "dev")) |_| {
            return "-dev";
        } else if (std.mem.find(u8, self.flavor, "rc")) |_| {
            return "-rc";
        }
        return self.flavor;
    }

    pub fn format(self: Config, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            \\Config{{
            \\  platform: {t}
            \\  arch: {t}
            \\  script: {t}
            \\  version: {f}
            \\  flavor: {s}
            \\  install_path: {s}
            \\  setup_links: {}
            \\  link_name: {s}
            \\}}
        ,
            .{
                self.platform,
                self.arch,
                self.script,
                self.version,
                self.flavor,
                self.install_path,
                self.setup_links,
                self.link_name,
            },
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
    try w.print("?version={f}", .{config.version});
    if (config.flavor.len > 0) {
        try w.print("&flavor={s}", .{config.flavor});
    }
    if (config.slug()) |slug| {
        try w.print("&slug={s}", .{slug});
    } else {
        return error.InvalidBuildConfig;
    }
    if (config.platformQuery()) |platform| {
        try w.print("&platform={s}", .{platform});
    } else {
        return error.InvalidBuildConfig;
    }

    return w.buffered().len;
}

/// caller must close returned dir
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

fn resolveInstallPath(arena: std.mem.Allocator, path: []const u8, environ: std.process.EnvMap) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    if (path.len < 1 or path[0] != '~') return error.NonAbsoluteInstallpath;

    const home = switch (builtin.os.tag) {
        .windows => environ.get("USERPROFILE"),
        else => environ.get("HOME"),
    } orelse return error.MissingHomeVar;
    return std.fs.path.join(arena, &.{ home, path[1..] });
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

    log.debug("resolved config: {f}", .{config});

    var zip_bytes: []u8 = undefined;
    var buf: [4096]u8 = undefined;

    {
        @memcpy(buf[0..].ptr, godot_rev.download_url);
        const query_str_len = try uriQueryFromConfig(config, buf[godot_rev.download_url.len..]);
        const uri_str = buf[0 .. godot_rev.download_url.len + query_str_len];
        const uri = try std.Uri.parse(uri_str);

        log.info("attempting to fetch uri: {s}...", .{uri_str});

        if (config.dry_run) return;

        var res_writer = try std.Io.Writer.Allocating.initCapacity(arena, 10 * 1024 * 1024);
        var client = std.http.Client{ .io = io, .allocator = arena };
        const res = try client.fetch(.{
            .method = .GET,
            .location = .{ .uri = uri },
            .response_writer = &res_writer.writer,
        });
        client.deinit(); // this can leak if the fetch fails.

        if (res.status != .ok) {
            log.err("http error status: {t} {?s}", .{ res.status, res.status.phrase() });
            return;
        }

        zip_bytes = try res_writer.toOwnedSlice();
    }

    log.debug("zip_bytes len: {d}", .{zip_bytes.len});
    log.info("download complete", .{});

    var temp_dir = try openTempDir(io, environ);
    defer temp_dir.close(io);
    var zip_file = try temp_dir.createFile(io, "gup-godot.zip", .{ .truncate = true, .read = true });
    errdefer zip_file.close(io);
    try zip_file.writeStreamingAll(io, zip_bytes);
    var zip_reader = zip_file.reader(io, &buf);

    const dest_dir = try std.Io.Dir.openDirAbsolute(io, config.install_path, .{});
    defer dest_dir.close(io);
    log.info("extracting to {s}", .{config.install_path});
    {
        var filename_buf: [512]u8 = undefined;
        var it = try std.zip.Iterator.init(&zip_reader);
        while (try it.next()) |entry| {
            entry.extract(&zip_reader, .{}, &filename_buf, dest_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    log.info("{s} already exists, skipping", .{filename_buf[0..entry.filename_len]});
                },
                else => {
                    log.err("while extracting: {t}", .{err});
                    continue;
                },
            };
            const filename = filename_buf[0..entry.filename_len];
            log.info("extracted {s}", .{filename});

            // TODO better way to identify main binary
            if (config.setup_links) {
                const console = if (std.mem.find(u8, filename, "console")) |_| "-console" else "";
                const flavor = config.linkSuffix();
                const ext = if (builtin.os.tag == .windows) ".exe" else "";

                var symlink_path_buf: [64]u8 = undefined;
                const symlink_path = try std.fmt.bufPrint(&symlink_path_buf, "{s}{s}{s}{s}", .{ config.link_name, console, flavor, ext });

                // try this?
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
        }
    }

    if (config.setup_links) {
        log.info("symlinked binaries to {s}{s}", .{ config.link_name, config.linkSuffix() });
    }

    zip_file.close(io);
    temp_dir.close(io);
    dest_dir.close(io);
}

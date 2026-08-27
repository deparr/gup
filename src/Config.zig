const std = @import("std");
const builtin = @import("builtin");
const download_urls = @import("download_urls");

const log = std.log.scoped(.config);

const Config = @This();

const ParseError = error{
    InvalidVersion,
    InvalidPackageSpec,
    MissingHomeVar,
    MissingRequiredArg,
    UnknownCommand,
    UnknownArg,
} || std.mem.Allocator.Error;

command: Command,
verbose: bool,
dry_run: bool,

pub fn parse(arena: std.mem.Allocator, environ: *std.process.Environ.Map, cli_args: []const []const u8) ParseError!Config {
    var config: Config = .initDefault();
    config.initEnv(environ);
    const command_idx = config.initCli(cli_args);
    if (command_idx >= cli_args.len) {
        return config;
    }

    const command_str = cli_args[command_idx];
    const maybe_command = std.meta.stringToEnum(Command.Tag, command_str);
    if (maybe_command == null) {
        log.err("Unknown command: {s}, try 'gup --help'", .{command_str});
        return error.UnknownCommand;
    }
    const command_args = cli_args[command_idx + 1 ..];
    config.command = blk: switch (maybe_command.?) {
        .help => {
            if (command_args.len == 0) {
                break :blk .{ .help = Config.usage };
            }
            const command = command_args[0];
            if (strcmp(command, "install")) break :blk .{ .help = Command.Install.usage };
            if (strcmp(command, "fetch")) break :blk .{ .help = Command.Fetch.usage };
            if (strcmp(command, "cache")) break :blk .{ .help = Command.Cache.usage };
            break :blk .{ .help = Config.usage };
        },
        .install => .{ .install = try Command.Install.parse(arena, environ, command_args, &config) },
        .fetch => .{ .fetch = try Command.Fetch.parse(arena, environ, command_args, &config) },
        .cache => .{ .cache = try Command.Cache.parse(arena, environ, command_args, &config) },
    };

    return config;
}

fn initDefault() Config {
    return .{ .command = .{ .help = Config.usage }, .verbose = builtin.mode == .Debug, .dry_run = false };
}

fn initEnv(self: *Config, env: *std.process.Environ.Map) void {
    if (env.get("GUP_VERBOSE")) |verbose| {
        self.verbose = readBoolOption(verbose);
    }
    if (env.get("GUP_DRY_RUN")) |dry_run| {
        self.dry_run = readBoolOption(dry_run);
    }
}

fn initCli(self: *Config, args: []const []const u8) usize {
    const command_index = for (0.., args) |i, arg| {
        const kind = argKind(arg);
        const key = switch (kind) {
            .short => arg[1..],
            .long => arg[2..],
            .positional => break i,
        };

        // var pair_it = std.mem.tokenizeScalar(u8, maybe_pair, '=');
        // const key, const value = .{ pair_it.next().?, pair_it.rest() };

        if (strcmp(key, "verbose") or strcmp(key, "V")) {
            self.verbose = true;
        } else if (strcmp(key, "dry-run") or strcmp(key, "n")) {
            self.dry_run = true;
        } else if (strcmp(key, "help") or strcmp(key, "h")) {
            self.command = .{ .help = Config.usage };
            break args.len;
        }
    } else args.len;
    return command_index;
}

pub const usage = std.fmt.comptimePrint(
    \\Usage: gup [OPTIONS] COMMAND [COMMAND_OPTIONS]
    \\
    \\options:
    \\   --verbose, -V  Be more verbose
    \\   --dry-run, -n  Print actions that would be taken, but do not take them
    \\
    \\commands:
    \\  help     Print this menu and command options
    \\  install  Unpack a godot package on this machine, fetching it if needed
    \\  fetch    Fetch a godot package and store it in the package cache
    \\  cache    Manage the gup package cache
    \\
    \\Use 'gup help [command]' to see command options
    \\
    \\build:{t}
    \\
, .{builtin.mode});

pub const Command = union(Tag) {
    install: Install,
    fetch: Fetch,
    help: []const u8,
    cache: Cache,

    pub const Tag = enum {
        install,
        fetch,
        help,
        cache,
    };

    pub const Install = struct {
        spec: PackageSpec,
        install_source: Location,
        dir: []const u8,
        link_name: []const u8,
        self_contained: bool,
        setup_links: bool,
        disallow_fetch: bool,
        force_fetch: bool,

        pub const Location = union(enum) {
            local: []const u8,
            remote: void,
        };

        fn parse(arena: std.mem.Allocator, env: *std.process.Environ.Map, cli_args: []const []const u8, core: *Config) !Install {
            var install = Install.initDefault();
            install.initEnv(env);
            try install.initCli(cli_args, core);

            if (install.spec.version.equal(.empty)) {
                requiredArgLog("VERSION", "install");
                return error.MissingRequiredArg;
            }

            try install.spec.setSlug();
            install.dir = try expandHome(install.dir, arena, env);
            switch (install.install_source) {
                .local => |path| install.install_source = .{ .local = try expandHome(path, arena, env) },
                else => {},
            }

            return install;
        }

        fn initDefault() Install {
            return .{
                .spec = .default,
                .install_source = .{ .remote = {} },
                .dir = if (builtin.os.tag == .windows) "~/Appdata/local/gup" else "~/.local/bin",
                .link_name = "godot",
                .setup_links = true,
                .self_contained = false,
                .disallow_fetch = false,
                .force_fetch = false,
            };
        }

        fn initEnv(self: *Install, env: *std.process.Environ.Map) void {
            self.spec.initEnv(env);
            if (env.get("GUP_INSTALL_DIR")) |install_dir| {
                self.dir = install_dir;
            }
            if (env.get("GUP_LINK_NAME")) |link_name| {
                self.link_name = link_name;
            }
            if (env.get("GUP_SETUP_LINKS")) |setup_links| {
                self.setup_links = readBoolOption(setup_links);
            }
            if (env.get("GUP_SELF_CONTAINED")) |self_contained| {
                self.self_contained = readBoolOption(self_contained);
            }
            if (env.get("GUP_DISALLOW_FETCH")) |disallow_fetch| {
                self.disallow_fetch = readBoolOption(disallow_fetch);
            }
            if (env.get("GUP_FORCE_FETCH")) |force_fetch| {
                self.force_fetch = readBoolOption(force_fetch);
            }
        }

        fn initCli(self: *Install, args: []const []const u8, core: *Config) !void {
            var found_version_arg = false;
            for (args) |arg| {
                const kind = argKind(arg);
                const maybe_pair = switch (kind) {
                    .short => arg[1..],
                    .long => arg[2..],
                    .positional => {
                        if (found_version_arg) {
                            log.warn("ignoring extra positional arg: {s}", .{arg});
                        } else {
                            found_version_arg = true;
                            self.spec.version = try .parse(arg);
                        }
                        continue;
                    },
                };

                var pair_it = std.mem.tokenizeScalar(u8, maybe_pair, '=');
                const key, const value = .{ pair_it.next().?, pair_it.rest() };

                if (strcmp(key, "platform") or strcmp(key, "p")) {
                    if (std.meta.stringToEnum(Platform, value)) |platform| {
                        self.spec.platform = platform;
                    } else {
                        log.warn("ignoring invalid platform: {s}", .{value});
                    }
                } else if (strcmp(key, "arch") or strcmp(key, "a")) {
                    if (std.meta.stringToEnum(Arch, value)) |arch| {
                        self.spec.arch = arch;
                    } else {
                        log.warn("ignoring invalid arch: {s}", .{value});
                    }
                } else if (strcmp(key, "script") or strcmp(key, "s")) {
                    if (std.meta.stringToEnum(Script, value)) |script| {
                        self.spec.script = script;
                    } else {
                        log.err("ignoring invalid script: {s}", .{value});
                    }
                } else if (strcmp(key, "link-name") or strcmp(key, "o")) {
                    self.link_name = value;
                } else if (strcmp(key, "dir") or strcmp(key, "d")) {
                    self.dir = value;
                } else if (strcmp(key, "from-zip") or strcmp(key, "z")) {
                    self.install_source = .{ .local = value };
                } else if (strcmp(key, "setup-links") or strcmp(key, "l")) {
                    self.setup_links = readBoolOption(value);
                } else if (strcmp(key, "self-contained") or strcmp(key, "S")) {
                    self.self_contained = true;
                } else if (strcmp(key, "disallow-fetch") or strcmp(key, "D")) {
                    self.disallow_fetch = true;
                } else if (strcmp(key, "force-fetch") or strcmp(key, "f")) {
                    self.force_fetch = true;
                } else if (strcmp(key, "dry-run") or strcmp(key, "n")) {
                    core.dry_run = true;
                } else {
                    unknownArgLog(arg, "install");
                    return error.UnknownArg;
                }
            }
        }

        pub const usage =
            \\Usage: gup install VERSION [OPTIONS]
            \\
            \\VERSION is a semantic version optionally followed by a tag:
            \\  4.7.1 OR 4.7.1-stable OR 4.8-dev3
            \\
            \\options:
            \\  --platform=[V],       -p  Specify a platform [windows, linux, macos, web, android, horizon, pico] (host)
            \\  --arch=[V],           -a  Specify an architecture [x64, x32, arm64, arm32, universal] (host)
            \\  --script=[V],         -s  Specify script support [gdscript*, dotnet]
            \\  --dir=[STR],          -d  Specify install location (win: ~/AppData/Local/gup, else: ~/.local/bin)
            \\  --setup-links=[BOOL], -l  Create symlinks to installed binaries
            \\  --link-name=[STR],    -o  Base name for symlinks when using --setup-links
            \\  --from-zip=[STR],     -z  Unpack a zip at [STR] instead of using gup's cache
            \\  --self-contained,     -S  Install godot in self-contained mode
            \\  --allow-fetch,        -D  Allow fetching from remote if specified package missing from the cache (true)
            \\  --force-fetch,        -f  Always attempt to fetch from remote, regardless of cache state
            \\  --dry-run,            -n  Print actions that would be taken, but do not take them
            \\
        ;
    };

    pub const Cache = struct {
        sub_command: SubCommand,
        versions: ?[]Version,

        fn parse(arena: std.mem.Allocator, env: *std.process.Environ.Map, args: []const []const u8, core: *Config) !Cache {
            var cache = Cache.initDefault();
            cache.initEnv(env);
            try cache.initCli(arena, args, core);
            return cache;
        }

        fn initDefault() Cache {
            return .{ .sub_command = .list, .versions = null };
        }

        fn initEnv(self: *Cache, env: *std.process.Environ.Map) void {
            _ = self;
            _ = env;
        }

        fn initCli(self: *Cache, arena: std.mem.Allocator, args: []const []const u8, core: *Config) !void {
            var versions = std.ArrayList(Version).empty;
            for (args, 0..) |arg, i| {
                const kind = argKind(arg);
                const maybe_pair = switch (kind) {
                    .short => arg[1..],
                    .long => arg[2..],
                    .positional => {
                        if (i == 0) {
                            if (std.meta.stringToEnum(SubCommand, arg)) |sc| {
                                self.sub_command = sc;
                                continue;
                            }
                        }
                        const version = Version.parse(arg) catch {
                            log.err("Unable to parse arg as version: '{s}'", .{arg});
                            return error.InvalidVersion;
                        };
                        try versions.append(arena, version);
                        continue;
                    },
                };

                var pair_it = std.mem.tokenizeScalar(u8, maybe_pair, '=');
                const key, const value = .{ pair_it.next().?, pair_it.rest() };
                _ = value;

                if (strcmp(key, "dir") or strcmp(key, "d")) {
                } else if (strcmp(key, "dry-run") or strcmp(key, "n")) {
                    core.dry_run = true;
                } else {
                    unknownArgLog(arg, "cache");
                    return error.UnknownArg;
                }
            }
            if (versions.items.len > 0)
                self.versions = try versions.toOwnedSlice(arena);
        }

        pub const usage =
            \\Usage: gup cache [OPTIONS] [COMMAND]
            \\
            \\options: 
            \\  --dir=[STR], -d  Use [STR] as the cache root directory
            \\  --dry-run,   -n  Print actions that would be taken, but do not take them
            \\
            \\commands:
            \\  list*  Print cache tree and usage
            \\  clean  Remove cache tree
            \\
        ;

        pub const SubCommand = enum { list, clean };
    };

    pub const Fetch = struct {
        spec: PackageSpec,
        source_host: SourceHost,
        force: bool,

        fn parse(arena: std.mem.Allocator, env: *std.process.Environ.Map, args: []const []const u8, core: *Config) !Fetch {
            _ = arena;

            var fetch = Fetch.initDefault();
            fetch.initEnv(env);
            try fetch.initCli(args, core);

            if (fetch.spec.version.equal(.empty)) {
                requiredArgLog("VERSION", "fetch");
                return error.MissingRequiredArg;
            }

            try fetch.spec.setSlug();
            if (!fetch.spec.isStable() and fetch.source_host != .godotorg) {
                fetch.source_host = .godotorg;
            }

            return fetch;
        }

        fn initDefault() Fetch {
            return .{
                .spec = .default,
                .source_host = .github,
                .force = false,
            };
        }

        fn initEnv(self: *Fetch, env: *std.process.Environ.Map) void {
            self.spec.initEnv(env);
            if (env.get("GUP_SOURCE_HOST")) |sh_str| {
                if (enumFromEnv(SourceHost, "GUP_SOURCE_HOST", sh_str)) |sh| {
                    self.source_host = sh;
                }
            }

            if (env.get("GUP_FORCE_FETCH")) |force| {
                self.force = readBoolOption(force);
            }
        }

        fn initCli(self: *Fetch, args: []const []const u8, core: *Config) !void {
            var found_version_arg = false;
            for (args) |arg| {
                const kind = argKind(arg);
                const maybe_pair = switch (kind) {
                    .short => arg[1..],
                    .long => arg[2..],
                    .positional => {
                        if (found_version_arg) {
                            log.warn("ignoring extra positional arg: {s}", .{arg});
                        } else {
                            found_version_arg = true;
                            self.spec.version = try .parse(arg);
                        }
                        continue;
                    },
                };

                var pair_it = std.mem.tokenizeScalar(u8, maybe_pair, '=');
                const key, const value = .{ pair_it.next().?, pair_it.rest() };

                if (strcmp(key, "platform") or strcmp(key, "p")) {
                    if (std.meta.stringToEnum(Platform, value)) |platform| {
                        self.spec.platform = platform;
                    } else {
                        log.warn("ignoring invalid platform: {s}", .{value});
                    }
                } else if (strcmp(key, "arch") or strcmp(key, "a")) {
                    if (std.meta.stringToEnum(Arch, value)) |arch| {
                        self.spec.arch = arch;
                    } else {
                        log.warn("ignoring invalid arch: {s}", .{value});
                    }
                } else if (strcmp(key, "script") or strcmp(key, "s")) {
                    if (std.meta.stringToEnum(Script, value)) |script| {
                        self.spec.script = script;
                    } else {
                        log.err("ignoring invalid script: {s}", .{value});
                    }
                } else if (strcmp(key, "force") or strcmp(key, "f")) {
                    self.force = true;
                } else if (strcmp(key, "dry-run") or strcmp(key, "n")) {
                    core.dry_run = true;
                } else {
                    unknownArgLog(arg, "fetch");
                    return error.UnknownArg;
                }
            }
        }

        pub const usage =
            \\Usage: gup fetch VERSION [OPTIONS]
            \\
            \\VERSION is a semantic version optionally followed by a tag:
            \\  gup install 4.7.1 OR gup install 4.8-dev3
            \\
            \\options:
            \\  --platform=[V], -p  Specify a platform [windows, linux, macos, web, android, horizon, pico] (host)
            \\  --arch=[V],     -a  Specify an architecture [x64, x32, arm64, arm32, universal] (host)
            \\  --script=[V],   -s  Specify script support [gdscript*, dotnet]
            \\  --source=[V]    -u  Which source to download packages from [github*, godotorg]
            \\  --cache=[STR],  -d  Use [STR] as the gup cache dir
            \\  --force,        -f  Always fetch and overwrite any cached packages
            \\  --dry-run,      -n  Print actions that would be taken, but do not take them
            \\
        ;
    };
};

pub const PackageSpec = struct {
    version: Version,
    arch: Arch,
    platform: Platform,
    script: Script,
    slug: []const u8,

    const default: PackageSpec = .{
        .version = .empty,
        .arch = switch (builtin.cpu.arch) {
            .x86_64 => .x64,
            .x86 => .x32,
            .aarch64 => .arm64,
            .arm => .arm32,
            else => .x64,
        },
        .platform = switch (builtin.os.tag) {
            .windows => .windows,
            .linux => .linux,
            .macos => .macos,
            else => .windows,
        },
        .script = .gdscript,
        .slug = "",
    };

    fn initEnv(self: *PackageSpec, env: *std.process.Environ.Map) void {
        if (env.get("GUP_VERSION")) |version_str| {
            if (Version.parse(version_str)) |version| {
                self.version = version;
            } else |err| {
                log.warn("GUP_VERSION={s} failed to parse: {t}", .{ version_str, err });
            }
        }
        if (env.get("GUP_ARCH")) |arch_str| {
            if (enumFromEnv(Arch, "GUP_ARCH", arch_str)) |arch| {
                self.arch = arch;
            }
        }
        if (env.get("GUP_PLATFORM")) |platform_str| {
            if (enumFromEnv(Platform, "GUP_PLATFORM", platform_str)) |platform| {
                self.platform = platform;
            }
        }
        if (env.get("GUP_SCRIPT")) |script_str| {
            if (enumFromEnv(Script, "GUP_SCRIPT", script_str)) |script| {
                self.script = script;
            }
        }
    }

    fn setSlug(self: *PackageSpec) !void {
        // these are so messy
        // there is next to no consistency between filenames
        // just hardcode them all, will be as brittle as trying to do it
        // more granularly
        const maybe_slug = switch (self.platform) {
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

        if (maybe_slug == null) {
            log.err("unable to make slug from spec: {f}-{s}_{t}_{t}_{t}", .{
                self.version,
                self.version.flavor,
                self.script,
                self.platform,
                self.arch,
            });
            return error.InvalidPackageSpec;
        }

        self.slug = maybe_slug.?;
    }

    pub fn isStable(self: *const PackageSpec) bool {
        return std.mem.eql(u8, self.version.flavor, "stable");
    }
};

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

pub const SourceHost = enum {
    github,
    godotorg,
};

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: ?u32,
    flavor: []const u8,

    pub const empty: Version = .{ .major = 0, .minor = 0, .patch = 0, .flavor = "" };

    // todo string lifetimes, right now this parses from env and clis
    // so should be fine to just ignore them
    // todo handle *extra* numbers in version string
    pub fn parse(str: []const u8) !Version {
        var flavor: []const u8 = "stable";
        var nums: []const u8 = str;
        if (std.mem.findScalar(u8, str, '-')) |dash| {
            flavor = str[dash + 1 ..];
            nums = str[0..dash];
        }
        if (flavor.len == 0) return error.InvalidVersion;
        var it = std.mem.splitScalar(u8, nums, '.');
        return Version{
            .major = try parseNum(it.first()) orelse return error.InvalidVersion,
            .minor = try parseNum(it.next()) orelse return error.InvalidVersion,
            .patch = try parseNum(it.next()),
            .flavor = flavor,
        };
    }

    pub fn format(self: Version, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d}", .{ self.major, self.minor });
        if (self.patch) |p| {
            try writer.print(".{d}", .{p});
        }
    }

    pub fn formatFlavor(self: Version, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d}", .{ self.major, self.minor });
        if (self.patch) |p| {
            try writer.print(".{d}", .{p});
        }
        try writer.print("-{s}", .{self.flavor});
    }

    pub fn equal(self: Version, other: Version) bool {
        return self.major == other.major and
            self.minor == other.minor and
            self.patch == other.patch and
            strcmp(self.flavor, other.flavor);
    }

    fn parseNum(str: ?[]const u8) !?u32 {
        if (str == null) return null;

        return std.fmt.parseInt(u32, str.?, 10) catch error.InvalidVersion;
    }
};

fn enumFromEnv(Tag: type, env_key: []const u8, env_value: []const u8) ?Tag {
    if (std.meta.stringToEnum(Tag, env_value)) |value| {
        return value;
    }
    log.warn("{s} exists but does not contain a valid value ({s}), falling back to default", .{ env_key, env_value });
    return null;
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

fn expandHome(path: []const u8, arena: std.mem.Allocator, environ: *std.process.Environ.Map) ![]const u8 {
    if (std.fs.path.isAbsolute(path) or path.len < 1 or path[0] != '~') {
        return path;
    }

    const home = switch (builtin.os.tag) {
        .windows => environ.get("USERPROFILE"),
        else => environ.get("HOME"),
    } orelse return error.MissingHomeVar;

    return std.fs.path.join(arena, &.{ home, path[1..] });
}

fn requiredArgLog(arg: []const u8, command: []const u8) void {
    log.err("missing required arg {s}, try 'gup help {s}'", .{ arg, command });
}

fn unknownArgLog(arg: []const u8, command: []const u8) void {
    log.err("unknown {s} arg: {s}", .{ command, arg });
}

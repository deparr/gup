const std = @import("std");
const builtin = @import("builtin");
const download_urls = @import("download_urls");

const Config = @This();

const log = std.log.scoped(.config);

pub const usage = std.fmt.comptimePrint(
    \\gup [OPTIONS]
    \\
    \\  --version=[STR],      -v   Specify a version. *Required*
    \\  --platform=[V],       -p   Specify a platform [windows, linux, macos, web, android, horizon, pico] (host)
    \\  --arch=[V],           -a   Specify an architecture [x64, x32, arm64, arm32, universal] (host)
    \\  --script=[V],         -s   Specify script support [gdscript*, dotnet]
    \\  --flavor=[STR],       -f   Specify a build flavor (stable)
    \\  --install-path=[STR], -i   Specify binary location (win: ~/AppData/Roaming/gup, else: ~/.local/bin)
    \\  --setup-links=[bool], -l   Create flavor-delineated symlink to main binary. ie godot ->  Godot_4.6.2.win64.exe
    \\  --link-name=[STR],    -o   Base name for symlinks when --setup-links is true (godot)
    \\  --from-zip=[STR],     -z   Unpack zip at [STR] instead of downloading a release from godotengine.org
    \\  --source=[V]          -u   Which source to download packages from [github*, godotorg]
    \\  --self-contained,     -S   Install Godot in self-contained mode, creating a portable installtion
    \\  --verbose,            -V   Be more verbose
    \\  --dry-run,            -n   Print the url that would be fetched, but do not fetch anything.
    \\  --help,               -h   Show this menu
    \\
    \\  build: {t}
, .{builtin.mode});

platform: Platform,
arch: Arch,
script: Script,
version: Version,
flavor: []const u8,
install_path: []const u8,
setup_links: bool,
link_name: []const u8,
from_zip: ?[]const u8,
source: SourceHost,
verbose: bool,
dry_run: bool,
self_contained: bool,

pub fn initDefault(self: *Config) void {
    self.* = .{
        .platform = switch (builtin.os.tag) {
            .windows => .windows,
            .linux => .linux,
            .macos => .macos,
            else => .windows,
        },
        .arch = switch (builtin.cpu.arch) {
            .x86_64 => .x64,
            .x86 => .x32,
            .aarch64 => .arm64,
            .arm => .arm32,
            else => .x64,
        },
        .script = .gdscript,
        .version = .empty,
        .flavor = "stable",
        .install_path = if (builtin.os.tag == .windows) "~/AppData/Roaming/gup" else "~/.local/bin",
        .setup_links = true,
        .link_name = "godot",
        .from_zip = null,
        .source = .github,
        .verbose = builtin.mode == .Debug,
        .dry_run = false,
        .self_contained = false,
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
    if (env.get("GUP_FROM_ZIP")) |from_zip| {
        self.from_zip = from_zip;
    }
    if (env.get("GUP_SOURCE")) |source_str| {
        if (enumFromEnv(SourceHost, "GUP_SOURCE", source_str)) |source| {
            self.source = source;
        }
    }
    if (env.get("GUP_VERBOSE")) |verbose| {
        self.verbose = readBoolOption(verbose);
    }
    if (env.get("GUP_SELF_CONTAINED")) |sc_mode| {
        self.self_contained = readBoolOption(sc_mode);
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
        } else if (strcmp(key, "from-zip") or strcmp(key, "z")) {
            self.from_zip = value;
        } else if (strcmp(key, "source") or strcmp(key, "u")) {
            if (std.meta.stringToEnum(SourceHost, value)) |source| {
                self.source = source;
            } else {
                log.err("invalid source host: {s}", .{value});
            }
        } else if (strcmp(key, "self-contained") or strcmp(key, "S")) {
            self.self_contained = true;
        } else if (strcmp(key, "verbose") or strcmp(key, "V")) {
            self.verbose = true;
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

pub fn makeUri(self: *const Config, buf: []u8) ![]const u8 {
    return switch (self.source) {
        .github => self.makeGithubUri(buf),
        .godotorg => self.makeGodotOrgUri(buf),
    };
}

fn makeGithubUri(self: *const Config, buf: []u8) ![]const u8 {
    const slug_ = self.slug() orelse return error.InvalidBuildConfig;
    return std.fmt.bufPrint(
        buf,
        "{[url]s}/{[version]f}-{[flavor]s}/Godot_v{[version]f}-{[flavor]s}_{[slug]s}",
        .{ .url = download_urls.github, .version = self.version, .flavor = self.flavor, .slug = slug_ },
    );
}

fn makeGodotOrgUri(self: *const Config, buf: []u8) ![]const u8 {
    const platform = self.platformQuery() orelse return error.InvalidBuildConfig;
    const slug_ = self.slug() orelse return error.InvalidBuildConfig;
    return std.fmt.bufPrint(
        buf,
        "{s}?version={f}&flavor={s}&slug={s}&platform={s}",
        .{ download_urls.godotorg, self.version, self.flavor, slug_, platform },
    );
}

fn platformQuery(self: Config) ?[]const u8 {
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

pub fn validate(self: *Config) !void {
    if (self.version.equal(.empty)) return error.MissingVersion;
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
        \\  from_zip: {?s}
        \\  source: {t}
        \\  verbose: {},
        \\  dry_run: {},
        \\  self_contained: {},
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
            self.from_zip,
            self.source,
            self.verbose,
            self.dry_run,
            self.self_contained,
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

    pub const empty: Version = .{ .major = 0, .minor = 0, .patch = 0 };

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

    pub fn equal(self: Version, other: Version) bool {
        return self.major == other.major and
            self.minor == other.minor and
            self.patch == other.patch;
    }

    fn parseNum(str: ?[]const u8) !?u32 {
        if (str == null) return null;

        return std.fmt.parseInt(u32, str.?, 10) catch |err| switch (err) {
            error.InvalidCharacter => error.InvalidVersion,
            error.Overflow => err,
        };
    }
};

pub const SourceHost = enum {
    github,
    godotorg,
};

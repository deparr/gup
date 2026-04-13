const std = @import("std");
const builtin = @import("builtin");

const Config = struct {
    platform: Platform,
    arch: Arch,
    script: Script,
    version: Version,
    flavor: ?[]const u8 = null,
    install_path: []const u8,

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
            .version = Version.parse(@import("godot_rev").latest_stable) catch unreachable,
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
                std.log.warn("GUP_VERSION={s} failed to parse: {t}", .{ version_str, err });
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

        std.log.warn("{s} exists but does not contain a valid value ({s}), falling back to default", .{ env_key, env_value });
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
                    std.log.warn("ignoring positional arg: {s}", .{arg});
                    continue;
                },
            };

            var pair_it = std.mem.tokenizeScalar(u8, maybe_pair, '=');
            const key, const value = .{ pair_it.next().?, pair_it.rest() };
            if (value.len == 0) {
                std.log.err("arg value with len 0", .{});
            }

            if (strcmp(key, "platform") or strcmp(key, "p")) {
                if (std.meta.stringToEnum(Platform, value)) |platform| {
                    self.platform = platform;
                } else {
                    std.log.err("invalid platform: {s}", .{value});
                }
            } else if (strcmp(key, "arch") or strcmp(key, "a")) {
                if (std.meta.stringToEnum(Arch, value)) |arch| {
                    self.arch = arch;
                } else {
                    std.log.err("invalid arch: {s}", .{value});
                }
            } else if (strcmp(key, "version") or strcmp(key, "v")) {
                self.version = try Version.parse(value);
            } else if (strcmp(key, "flavor") or strcmp(key, "f")) {
                self.flavor = value;
            } else if (strcmp(key, "install-path") or strcmp(key, "i")) {
                self.install_path = value;
            } else {
                std.log.warn("ignoring unknown arg key: {s}", .{key});
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

    pub fn format(self: Config, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            \\Config{{
            \\  platform: {t}
            \\  arch: {t}
            \\  version: {f}
            \\  flavor: {?s}
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

    std.log.info("using config: {f}", .{config});
}

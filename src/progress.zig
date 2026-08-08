const std = @import("std");
const Io = std.Io;


pub const Spinner = struct {
    pub const frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
    pub const frame1 = "⠋";
    pub const frame_count = frames.len / frame1.len;

    frame_idx: usize = 0,

    pub fn init() Spinner {
        return .{ .frame_idx = 0 };
    }

    pub fn frame(self: *const Spinner) []const u8 {
        return frames[self.frame_idx * frame1.len..][0..frame1.len];
    }

    pub fn next(self: *Spinner) void {
        self.frame_idx =  (self.frame_idx + 1) % frame_count;
    }
};

pub const Bar = struct {};

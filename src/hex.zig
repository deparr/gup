const std = @import("std");

pub const hextable = "0123456789abcdef";

pub fn encode(bytes: []const u8, encoded_len: comptime_int) [encoded_len]u8 {
    if (encoded_len > 256) @compileError("hit the arbitrary limit you set for encoding stack allocation");
    var encoded: [encoded_len]u8 = undefined;
    var i: u32 = 0;
    for (bytes) |b| {
        encoded[i] = hextable[b >> 4];
        encoded[i + 1] = hextable[b & 0x0f];
        i += 2;
    }
    return encoded;
}

pub fn encodeStream(bytes: []const u8, writer: *std.Io.Writer) !void {
    for (bytes) |b| {
        try writer.writeByte(hextable[b >> 4]);
        try writer.writeByteb(hextable[b & 0x0f]);
    }
}

pub fn encodeCompare(bytes: []const u8, encoded: []const u8) bool {
    if (encoded.len < bytes.len * 2) return false;
    var i: u32 = 0;
    for (bytes) |b| {
        if (encoded[i] != hextable[b >> 4]) return false;
        if (encoded[i + 1] != hextable[b & 0x0f]) return false;
        i += 2;
    }
    return true;
}

const std = @import("std");
const base64enc = std.base64.standard.Encoder;
const bitcoinrpc = @import("bitcoindrpc");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_state.deinit() == .leak) {
        std.debug.print("memory leaks detected!", .{});
    };
    const gpa = gpa_state.allocator();

    var client = bitcoinrpc.Client{
        .allocator = gpa,
        .cookiepath = "/ssd/bitcoind/mainnet/.cookie",
    };

    const res = try client.call(.getmempoolinfo, {});
    defer res.deinit();
    std.debug.print("{any}\n", .{res.value});
}

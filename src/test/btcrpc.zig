const std = @import("std");
const base64enc = std.base64.standard.Encoder;
const bitcoinrpc = @import("bitcoindrpc");

pub fn main() !void {
    //var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    //defer arena_state.deinit();
    //const arena = arena_state.allocator();
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_state.deinit()) {
        std.debug.print("!!!!!!!!!! memory leaks detected", .{});
    };
    const arena = gpa_state.allocator();

    var client = bitcoinrpc.Client{
        .allocator = arena,
        .cookiepath = "/ssd/bitcoind/mainnet/.cookie",
    };

    const hash = try client.call(.getblockhash, .{ .height = 0 });
    defer hash.free();
    std.debug.print("hash of 1001: {s}\n", .{hash.result});

    const bcinfo = try client.call(.getblockchaininfo, {});
    defer bcinfo.free();
    std.debug.print("{any}\n", .{bcinfo.result});

    const netinfo = try client.call(.getnetworkinfo, {});
    defer netinfo.free();
    std.debug.print("{any}\n", .{netinfo.result});
}

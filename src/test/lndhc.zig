const std = @import("std");
const lndhttp = @import("lightning").lndhttp;

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_state.deinit() == .leak) {
        std.debug.print("memory leaks detected!", .{});
    };
    const gpa = gpa_state.allocator();

    var client = try lndhttp.Client.init(.{
        .allocator = gpa,
        .port = 10010,
        .tlscert_path = "/home/lnd/.lnd/tls.cert",
        .macaroon_ro_path = "/ssd/lnd/data/chain/bitcoin/mainnet/readonly.macaroon",
    });
    defer client.deinit();

    {
        const res = try client.call(.walletstatus, {});
        defer res.deinit();
        std.debug.print("{}\n", .{res.value.state});

        if (res.value.state == .LOCKED) {
            const res2 = try client.call(.unlockwallet, .{ .unlock_password = "45b08eb7bfcf1a7f" });
            defer res2.deinit();
        }
    }
    {
        const res = try client.call(.getinfo, {});
        defer res.deinit();
        std.debug.print("{any}\n", .{res.value});
    }
    //{
    //    const res = try client.call(.getnetworkinfo, {});
    //    defer res.deinit();
    //    std.debug.print("{any}\n", .{res.value});
    //}
    //{
    //    const res = try client.call(.listchannels, .{ .peer_alias_lookup = false });
    //    defer res.deinit();
    //    std.debug.print("{any}\n", .{res.value.channels});
    //}
    //{
    //    const res = try client.call(.feereport, {});
    //    defer res.deinit();
    //    std.debug.print("{any}\n", .{res.value});
    //}
    {
        const res = try client.call(.genseed, {});
        defer res.deinit();
        std.debug.print("{s}\n", .{res.value.cipher_seed_mnemonic});
    }
}

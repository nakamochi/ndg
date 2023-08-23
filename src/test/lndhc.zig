const std = @import("std");
const lndhttp = @import("lndhttp");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa_state.deinit() == .leak) {
        std.debug.print("memory leaks detected!", .{});
    };
    const gpa = gpa_state.allocator();

    var client = try lndhttp.Client.init(.{
        .allocator = gpa,
        .tlscert_path = "/home/lnd/.lnd/tls.cert",
        .macaroon_ro_path = "/ssd/lnd/data/chain/bitcoin/mainnet/readonly.macaroon",
    });
    defer client.deinit();

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
    //    const res = try client.call(.walletstatus, {});
    //    defer res.deinit();
    //    std.debug.print("{s}\n", .{@tagName(res.value.state)});
    //}
    //{
    //    const res = try client.call(.feereport, {});
    //    defer res.deinit();
    //    std.debug.print("{any}\n", .{res.value});
    //}
}

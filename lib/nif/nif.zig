const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;

pub const wpa = @import("wpa.zig");

const IFF_UP = 1 << 0; //0b1;
const IFF_LOOPBACK = 1 << 3; //0b1000;

const ifaddrs = extern struct {
    next: ?*ifaddrs,
    name: [*:0]const u8,
    flags: c_uint, // see IFF_xxx SIOCGIFFLAGS in netdevice(7)
    addr: ?*std.os.sockaddr,
    netmask: ?*std.os.sockaddr,
    ifu: extern union {
        broad: *os.sockaddr, // flags & IFF_BROADCAST
        dst: *os.sockaddr, // flags & IFF_POINTOPOINT
    },
    data: ?*anyopaque,
};

extern "c" fn getifaddrs(ptrp: **ifaddrs) c_int;
extern "c" fn freeifaddrs(ptr: *ifaddrs) void;

/// retrieves a list of all public IP addresses assigned to the network interfaces,
/// optionally filtering by the interface name.
/// caller owns the returned value.
pub fn pubAddresses(allocator: mem.Allocator, ifname: ?[]const u8) ![]net.Address {
    var res: *ifaddrs = undefined;
    if (getifaddrs(&res) != 0) {
        return error.Getifaddrs;
    }
    defer freeifaddrs(res);

    var list = std.ArrayList(net.Address).init(allocator);
    var it: ?*ifaddrs = res;
    while (it) |ifa| : (it = ifa.next) {
        const sa: *os.sockaddr = ifa.addr orelse continue;
        if (sa.family != os.AF.INET and sa.family != os.AF.INET6) {
            // not an IP address
            continue;
        }
        if (ifa.flags & IFF_UP == 0 or ifa.flags & IFF_LOOPBACK != 0) {
            // skip loopbacks and those which are not "up"
            continue;
        }
        const ipaddr = net.Address.initPosix(@alignCast(4, sa)); // initPosix makes a copy
        if (ipaddr.any.family == os.AF.INET6 and ipaddr.in6.sa.scope_id > 0) {
            // want only global, with 0 scope
            // non-zero scopes make sense for link-local addr only.
            continue;
        }
        if (ifname) |name| {
            if (!mem.eql(u8, name, mem.sliceTo(ifa.name, 0))) {
                continue;
            }
        }
        try list.append(ipaddr);
    }
    return list.toOwnedSlice();
}

const builtin = @import("builtin");
const std = @import("std");
const nif = @import("nif");

const tt = @import("test.zig");

pub usingnamespace if (builtin.is_test) struct {
    // stubs, mocks, overrides for testing.
    pub const Timer = tt.TestTimer;
    pub const ChildProcess = tt.TestChildProcess;
    pub const WpaControl = tt.TestWpaControl;
} else struct {
    // regular types for production code.
    pub const Timer = std.time.Timer;
    pub const ChildProcess = std.ChildProcess;
    pub const WpaControl = nif.wpa.Control;
};

/// prefer this type over the std.ArrayList(u8) just to ensure consistency
/// and potential regressions. For example, comm module uses it for read/write.
pub const ByteArrayList = std.ArrayList(u8);

/// an OS-based I/O pipe; see man(2) pipe.
pub const IoPipe = struct {
    r: std.fs.File,
    w: std.fs.File,

    /// a pipe must be close'ed when done.
    pub fn create() std.os.PipeError!IoPipe {
        const fds = try std.os.pipe();
        return .{
            .r = std.fs.File{ .handle = fds[0] },
            .w = std.fs.File{ .handle = fds[1] },
        };
    }

    pub fn close(self: IoPipe) void {
        self.w.close();
        self.r.close();
    }

    pub fn reader(self: IoPipe) std.fs.File.Reader {
        return self.r.reader();
    }

    pub fn writer(self: IoPipe) std.fs.File.Writer {
        return self.w.writer();
    }
};

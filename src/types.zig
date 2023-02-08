const std = @import("std");
const builtin = @import("builtin");

/// prefer this type over the std.ArrayList(u8) just to ensure consistency
/// and potential regressions. For example, comm module uses it for read/write.
pub const ByteArrayList = std.ArrayList(u8);

pub const Timer = if (builtin.is_test) TestTimer else std.time.Timer;

/// TestTimer always reports the same fixed value.
pub const TestTimer = if (!builtin.is_test) @compileError("TestTimer is for tests only") else struct {
    value: u64,

    pub fn read(self: *Timer) u64 {
        return self.value;
    }
};

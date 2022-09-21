build for rpi:

    zig build -Dtarget=aarch64-linux-musl -Ddriver=fbev -Drelease-safe -Dstrip

otherwise just `zig build` on dev host

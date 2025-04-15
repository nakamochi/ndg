# nakamochi daemon and gui (ndg)

release build for linux/aarch64, a raspberry pi 4:

    zig build -Dtarget=aarch64-linux-musl -Ddriver=fbev -Doptimize=ReleaseSafe -Dstrip

a dev build for a native arch linux host running Xorg can be compiled simply
with `zig build`. otherwise, for macOS or non-X11 platforms use SDL2:

    zig build -Ddriver=sdl2

## local development

you'll need [zig v0.14.x](https://ziglang.org/download/).
if working on the gui using sdl2 driver, also [SDL2](https://www.libsdl.org/).

note that compiling the daemon on macOS is currently unsupported since
it requires some linux primitives.

compiling is expected to be as easy as

    # only gui
    zig build ngui
    # only daemon
    zig build nd
    # everything at once
    zig build

the output is placed in `./zig-out/bin` directory. for example, to run the gui,
simply execute `./zig-out/bin/ngui`.

the build script has a few project-specific options. list them all with
a `zig build --help` command. for instance, to reduce LVGL logging verbosity in
debug build mode, one can set this extra build flag:

    zig build ngui -Dlvgl_loglevel=warn

run all tests with

    zig build test

or a filtered subset using `test-filter`:

    zig build test -Dtest-filter=xxx

significant contributors may find adding [.git-blame-ignore-revs](.git-blame-ignore-revs)
file to their git config useful, to skip very likely irrelevant commits
when browsing `git blame`:

    git config blame.ignoreRevsFile .git-blame-ignore-revs

see also the [contributing](#contributing) section.

## CI automated checks

the CI runs code format checks, tests and builds for fbdev+evdev on aarch64
and SDL2. it requires a container image with zig and clang tools such as
clang-format.

there is now support for GitHub Actions, it's described in the
[.github/workflows/ci.yml](.github/workflows/ci.yml) file.

## contributing

to contribute, create a pull request.

before sending a change, please make sure tests pass:

    zig build test

and all code is formatted: zig code with `zig fmt` and C according to the
style described by [.clang-format](.clang-format) file. if `clang-format` tool
is installed, all formatting can be checked with:

    ./tools/fmt-check.sh

note that only C files in `src/` are formatted.
leave third party libraries as is - it is easier to update and upgrade when
the original style is preserved, even if it doesn't match this project.

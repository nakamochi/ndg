# nakamochi daemon and gui (ndg)

build for rpi:

    zig build -Dtarget=aarch64-linux-musl -Ddriver=fbev -Drelease-safe -Dstrip

otherwise just `zig build` on dev host

## local development

you'll need [zig v0.10.x](https://ziglang.org/download/).
if working on the gui, also [SDL2](https://www.libsdl.org/).

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

to make a new image and switch the CI to use it, first modify the
[ci-containerfile](tools/ci-containerfile) and produce the image locally:

    podman build --rm -t ndg-ci -f ./tools/ci-containerfile \
      --build-arg ZIGURL=https://ziglang.org/download/0.10.1/zig-linux-x86_64-0.10.1.tar.xz

then tag it with the target URL, for example:

    podman tag localhost/ndg-ci git.qcode.ch/nakamochi/ci-zig0.10.1:v1

generate an [access token](https://git.qcode.ch/user/settings/applications),
login to the container registry and push the image to remote:

    podman login git.qcode.ch
    podman push git.qcode.ch/nakamochi/ci-zig0.10.1:v1

the image will be available at
https://git.qcode.ch/nakamochi/-/packages/

finally, delete the access token from
https://git.qcode.ch/user/settings/applications

what's left is to update the CI [build pipeline](.woodpecker.yml) and delete
the older version of the image.

## contributing

to contribute, create a pull request or send a patch with
[git send-mail](https://git-scm.com/docs/git-send-email) to alex-dot-cloudware.io.

before sending a change, please make sure tests pass:

    zig build test

and all code is formatted: zig code with `zig fmt` and C according to the
style described by [.clang-format](.clang-format) file. if `clang-format` tool
is installed, all formatting can be checked with:

    ./tools/fmt-check.sh

note that only C files in `src/` are formatted.
leave third party libraries as is - it is easier to update and upgrade when
the original style is preserved, even if it doesn't match this project.

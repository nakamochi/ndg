#!/usr/bin/env bash
set -e
zig fmt --check .
readarray -t C_FILES <<<"$(find ./src -type f -name '*.c' ! -name 'lv_font*')"
clang-format -style=file -dry-run -Werror "${C_FILES[@]}"

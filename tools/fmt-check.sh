#!/bin/sh
set -e
zig fmt --check .
C_FILES=$(find ./src -type f -name '*.c' ! -name 'lv_font*')
clang-format -style=file -dry-run -verbose -Werror $C_FILES

the trouble is fontawesome now supplies multiple files,
fa-brands-400.woff2, fa-regular-400.woff2 and fa-solid-900.woff2.
don't know which symbol is in which file.

list all defined symbols into a file:

    grep 0x ../ngui/lib/lvgl/src/font/lv_symbol_def.h | grep -v 0x2022 | \
      cut -d, -f2 | cut -c4-7 | tr 'A-F' 'a-f' \
      > /tmp/sym.txt

download and unzip fontawesome. expect to find metadata/icons.yml file.
grep metadata to find out which set each icon is in:

    for c in $(cat /tmp/sym.txt); do
      t=$(grep -B3 "unicode: $c" metadata/icons.yml | grep -- '- ' | head -n1 | tr -d ' -')
      echo "$c\t$t"
    done

some icons are in multiple styles. search for the code on https://fontawesome.com/icons/
and compare to the image on https://docs.lvgl.io/8.3/overview/font.html.
the command above takes the first one listed in icons.yml, which is usually "solid".
when searching on fontawesome, make sure it's a free icon, as opposed to their pro version.

not all icons might be present. at the time of writing, the following codes are amiss:

- 0xf067 `LV_SYMBOL_PLUS`; actually exists but listed as unicode:2b in icons.yml 
- 0xf8a2 `LV_SYMBOL_NEW_LINE`; looks like fontawesome removed `level-down-alt` from v6
so i picked an alternative 0xf177 `arrow-left-long`

dump previous command output into an fa-icon-style.txt file. add missing "solid" style
in the second column and replace f8a2 with `f177=>0xf8a2` mapping. the latter is
the syntax for when running [lvgl font convertion tool](https://github.com/lvgl/lv_font_conv).

while there, add more codes to the file, separating columns with a single tab:

- 0xf379 brands (bitcoin)
- 0xe0b4 solid (bitcoin-sign)
- 0xf0e7 solid (lightning bolt)

split the previously generated fa-icon-style.txt file into chunks suitable for
constructing lvgl's font converter arguments.

first, check which styles are present. at the moment, only "brands" and "solid"
are used:

    $ cut -f2 fa-icon-style.txt | sort | uniq -c
          3 brands
         61 solid

then split the file, for each style from the previous command. example for "solid":

    grep solid fa-icon-style.txt | cut -f1 | tr 'a-f' 'A-F' | \
      while IFS= read -r line; do printf "0x$line\n"; done | \
      paste -s -d, | tr -d '\n' > fa-solid.txt

typically, you'll want to bundle the symbols from fontawesome with a regular font.
i'll use [courier prime code](https://github.com/quoteunquoteapps/courierprimecode)
as an example.

install the font converter tool; requires nodejs:

    npm i lvgl/lv_font_conv

finally, convert and bundle all fonts, for 14px size as an example:

    ./node_modules/.bin/lv_font_conv --no-compress --no-prefilter --bpp 4 --size 14 \
      --font courier-prime-code.ttf -r 0x20-0x7F,0xB0,0x2022 \
      --font fa-brands-400.ttf -r $(cat fa-brands.txt) \
      --font fa-solid-900.ttf -r $(cat fa-solid.txt) \
      --format lvgl --force-fast-kern-format \
      -o lv_font_courierprimecode_14.c 

the arguments are similar to those in the header of any LVGL font in `lib/lvgl/src/font/lv_font/xxx.c`.

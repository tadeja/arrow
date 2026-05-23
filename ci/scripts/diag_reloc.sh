#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# GH-49767: locate the relocation that crashes _dl_relocate_object near
# envoy_annotations_deprecated_at_minor_version_enum_ext.
#
# The crash backtrace shows reloc_addr_arg = <SYM+16>. Identify which RELA
# entry has that offset, its type, and whether the offset is within
# the .data.rel.ro / .data / .bss segments. Together these
# point candidate causes: section overrun vs RELRO timing vs ODR.

set +e
BUILD=${1:-/build}
SYM=envoy_annotations_deprecated_at_minor_version_enum_ext

echo "=== reloc diagnostic ==="

for bin in arrow-flight-test arrow-flight-sql-test; do
  BIN=$BUILD/cpp/release/$bin
  [ -e "$BIN" ] || continue
  echo "================================"
  echo "$BIN"
  echo "================================"

  echo "--- symbol in .symtab ---"
  nm "$BIN" 2>/dev/null | grep "$SYM" || echo "(symbol not in static symtab)"

  VA_HEX=$(nm "$BIN" 2>/dev/null | awk -v s="$SYM" '$3 == s { print $1 }')
  if [ -n "$VA_HEX" ]; then
    VA=$((16#$VA_HEX))
    TARGET=$(printf '%016x' $((VA + 16)))
    echo "--- reloc at offset $TARGET (= VA+16) ---"
    readelf -rW "$BIN" | awk -v t="$TARGET" '
      $1 == t { print; found=1 }
      END { if (!found) print "(no reloc at this offset)" }'

    echo "--- relocations in first 256 bytes of symbol ---"
    HI=$((VA + 256))
    readelf -rW "$BIN" | awk -v lo="$VA" -v hi="$HI" '
      function h2d(s,    n, i, c, v) {
        n = 0
        for (i = 1; i <= length(s); i++) {
          c = tolower(substr(s, i, 1))
          v = index("0123456789abcdef", c) - 1
          if (v < 0) return -1
          n = n * 16 + v
        }
        return n
      }
      $1 ~ /^[0-9a-f]{16}$/ {
        o = h2d($1)
        if (o >= lo && o < hi) print
      }' | head -20
  else
    echo "(could not extract VA from nm output; skipping reloc lookup)"
  fi

  echo "--- section layout (.data*, .bss*) ---"
  readelf -SW "$BIN" | awk '
    function h2d(s,    n, i, c, v) {
      n = 0
      for (i = 1; i <= length(s); i++) {
        c = tolower(substr(s, i, 1))
        v = index("0123456789abcdef", c) - 1
        if (v < 0) return -1
        n = n * 16 + v
      }
      return n
    }
    $2 ~ /^\.(data|bss)/ {
      addr = h2d($4); size = h2d($6);
      printf "  %-24s Addr=%s  Size=%s  End=%016x\n", $2, $4, $6, addr+size
    }'

  echo "--- PT_LOAD program headers (writable? contains symbol?) ---"
  readelf -lW "$BIN" | awk '/LOAD/ { print "  " $0 }'

  echo "--- DT_TEXTREL / DT_FLAGS in dynamic section ---"
  readelf -d "$BIN" | grep -E "TEXTREL|FLAGS" || echo "(no TEXTREL / FLAGS entries)"
done

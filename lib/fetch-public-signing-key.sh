#!/usr/bin/env bash

set -eo pipefail

tmpdir="$(mktemp -d)"
fifo="$tmpdir/fifo"
sig="$tmpdir/sig"
mkfifo "$fifo"

function cleanup() {
  test -d "$tmpdir" && rm -rf "$tmpdir"
}

trap cleanup EXIT

(echo "show public-signing-key"; egrep -m1 "nixbuild.net/[^:]+:" "$fifo" | sed "s/.*nixbuild.net> //" > "$sig") | \
  ssh eu.nixbuild.net shell 2> "$fifo"

cat "$sig"

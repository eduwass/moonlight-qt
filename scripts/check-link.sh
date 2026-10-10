#!/bin/bash
# check-link: what Settings > Check Link finds for an address, from a terminal
# (the self-check at the end of doctor_mac.mm). Needs a Mac.
#   scripts/check-link.sh <address>
cd "$(dirname "$0")/.." || exit 1
out=$(mktemp -d)
clang++ -x objective-c++ -std=c++17 -fno-objc-arc -w -DDOCTOR_SELFTEST -I app app/doctor_mac.mm \
  -framework Cocoa -framework CoreWLAN -o "$out/selftest" || { rm -rf "$out"; exit 1; }
"$out/selftest" "$@"; status=$?
rm -rf "$out"
exit $status

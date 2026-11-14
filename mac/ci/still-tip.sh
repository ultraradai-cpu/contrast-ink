#!/bin/sh
# Publish the mac-latest release only from the newest commit on main: an older build finishing late (runs overlap)
# must not replace a newer one. Usage: still-tip.sh <this build's commit> <main's tip now>
# Exit 0: this build is the tip, publish it. Exit 1: main has moved on, skip.
built="$1"
tip="$2"
if [ -z "$built" ] || [ -z "$tip" ]; then
  echo "still-tip: missing commit (built '$built', tip '$tip'): not publishing"
  exit 1
fi
if [ "$built" = "$tip" ]; then
  exit 0
fi
echo "main has moved on to $(echo "$tip" | cut -c1-7): not publishing $(echo "$built" | cut -c1-7)"
exit 1

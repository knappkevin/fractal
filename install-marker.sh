#!/bin/bash
# Seed the image that makes the plugin selectable in Omarchy's background picker.
#
# This is a last resort, not the normal path. The plugin regenerates the image
# from the point and theme in use, and drops the result straight into the theme's
# backgrounds directory. This script only exists for the case where that render
# cannot run at all -- no python3 -- and it must never overwrite a
# rendered image with the still shipped in the repository.

set -u

PATH=/usr/bin:/bin
export PATH

src="${2:-$(cd -- "$(dirname -- "$0")" && pwd)}"
dest="$HOME/.local/state/omarchy/current/theme/backgrounds"
action="${1:-install}"
marker="fractal-zoom.png"

fail() { echo "fractal-marker: $*" >&2; exit 1; }

[ "$action" = install ] || fail "unknown action: $action"

state_root="$HOME/.local/state/omarchy"

# Refuse to write through anything that is not a plain directory we own.
[ -d "$state_root" ] || fail "$state_root does not exist"
[ ! -L "$state_root" ] || fail "$state_root is a symlink"
[ ! -L "$state_root/current" ] || fail "$state_root/current is a symlink"
[ ! -L "$state_root/current/theme" ] || fail "$state_root/current/theme is a symlink"
[ ! -L "$dest" ] || fail "$dest is a symlink"

mkdir -p -- "$dest" 2>/dev/null || fail "cannot create $dest"
[ -O "$dest" ] || fail "$dest is not ours"

# Seeding only. A rendered image is current; this one is a picture of some other
# theme and would replace it with something wrong.
if [ -e "$dest/$marker" ]; then
  exit 0
fi

# Copied to an unpredictable name in the destination's own directory and renamed
# into place, the way the other plugins write their state. Copying straight to
# the destination would let anything running as this user plant a symlink there
# for the copy to follow; rename replaces the entry itself, so it cannot. That
# also leaves the existence check above as a fast path rather than a guarantee.
tmp=$(mktemp -- "$dest/.$marker.XXXXXX.tmp") || fail "cannot create a temporary file in $dest"
cp -- "$src/assets/$marker" "$tmp" || { rm -f -- "$tmp"; fail "could not copy $marker"; }
mv -- "$tmp" "$dest/$marker" || { rm -f -- "$tmp"; fail "could not install $marker"; }

exit 0

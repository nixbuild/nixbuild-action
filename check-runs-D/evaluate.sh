#!/bin/bash

set -e

# Parse Nix args
nix_args=()
if [ -n "$1" ]; then
  IFS='\n'
  while read l; do
    readarray -d ' ' -O "${#nix_args[@]}" -t nix_args < <(echo -n "$l")
  done < <(echo "$1")
fi
shift

# Collect installables from the JSON objects passed as args
nix_installables=()
for x; do
  nix_installables+=(
    "$(jq -nr --argjson x "$x" '"\(env.FLAKE_URL)#\(env.FLAKE_ATTR).\($x.attr)"')"
  )
done

# Use a dedicated eval cache for the given set of installables to work around
# non-thread-safe Nix eval cache.
cache_dir="$XDG_CACHE_HOME/$(echo "${nix_installables[@]}" | md5sum | cut -b-8)"

# Evaluate the installables in one go. This enables eval sharing within Nix.
XDG_CACHE_HOME="$cache_dir" nix path-info \
  --derivation "${nix_args[@]}" "${nix_installables[@]}" >/dev/null

# Loop through the (now evaluated) installables one at a time. This is so we
# can match the installable with its resulting drv-file
for x; do
  nix_installable+=(
    "$(jq -nr --argjson x "$x" '"\(env.FLAKE_URL)#\(env.FLAKE_ATTR).\($x.attr)"')"
  )
  name="$(jq -nr --argjson x "$x" '.label')"
  title="Build $(jq -nr --argjson x "$x" '"\(env.FLAKE_ATTR).\($x.attr)"')"

  # Retrieve the drv path from the attribute
  drv="$(XDG_CACHE_HOME="$cache_dir" nix path-info \
    --derivation "${nix_args[@]}" "$nix_installable"
  )"

  # Grab output log to avoid intermingled lines
  flock 9 jq -cn \
    --arg name "$name" \
    --arg title "$title" \
    --arg drv "$drv" \
    --arg cache_dir "$cache_dir" '
      { name: $name
      , title: $title
      , drv: $drv
      , cache_dir: $cache_dir
      }
    '
done

#!/bin/bash

set -e

nix_args=()
if [ -n "$1" ]; then
  IFS='\n'
  while read l; do
    readarray -d ' ' -O "${#nix_args[@]}" -t nix_args < <(echo -n "$l")
  done < <(echo "$1")
fi
shift

PROCESS_DIR="$1"
shift

export FLAKE_ATTR="$1"
shift

# TODO Support multiple installables
nix_installable="$(echo "$1" | \
  jq -r '. as $x | "\(env.FLAKE_URL)#\(env.FLAKE_ATTR).\($x.attr)"'
)"
name="$(echo "$1" | jq -r '.label')"
title="Build $(echo "$1" | jq -r  '. as $x | "\(env.FLAKE_ATTR).\($x.attr)"')"
shift

# Use a different eval cache per installable to allow for concurrent evaluation
export XDG_CACHE_HOME="$XDG_CACHE_HOME/$(echo "$nix_installable" | md5sum | cut -d' ' -f1)"

# Retrieve the drv path from the attribute
drv="$(nix path-info --derivation "${nix_args[@]}" "$nix_installable")"

# Register a GC root for the drv. This mean we can garbage collect the store
# before saving the cache, pruning any things not used since last cache restore
# We don't cache the GC roots themselves though, which means that next time
# this drv could be removed if it is no longer used.
# Note that we are not appending '^*' or '^out' to the call below, this means
# we just "builds" the .drv-file. Effectively, we are just registering a GC
# root to the .drv-file.
nix build --out-link "$(mktemp -u)" "$drv"

base_url="$NIXBUILDNET_HTTP_API_SCHEME://$NIXBUILDNET_HTTP_API_HOST:$NIXBUILDNET_HTTP_API_PORT$NIXBUILDNET_HTTP_API_SUBPATH"

jq -cn \
  --arg name "$name" \
  --arg title "$title" \
  --arg installable "$drv^*" '
  [
    {
      "installable": $installable,
      "attributes": [
        [ "NIXBUILDNET_HOOK_GITHUB_CHECK_RUN", "" ],
        [ "NIXBUILDNET_GITHUB_CHECK_RUN_NAME", "\($name)" ],
        [ "NIXBUILDNET_GITHUB_CHECK_RUN_TITLE", "\($title)" ]
      ]
    }
  ]
  ' | \
  curl "$base_url/processes" \
    -sL \
    --fail-with-body \
    --json "@-" \
    -o "$PROCESS_DIR/$RANDOM$RANDOM.json" \
    -H "Authorization: Bearer $NIXBUILDNET_TOKEN" \
    -H "NIXBUILDNET-OIDC-ID-TOKEN: $NIXBUILDNET_OIDC_ID_TOKEN"

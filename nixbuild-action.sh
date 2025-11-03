#!/usr/bin/env bash

set -eu
set -o pipefail

export INPUTS_JSON="$1"

nixbuildnet_env=""
function add_env() {
  local key="$1"
  local val="$2"
  # Trim existing " or ' quotes
  val="${val%\"}"
  val="${val#\"}"
  val="${val%\'}"
  val="${val#\'}"
  nixbuildnet_env="$nixbuildnet_env $key=\"$val\""
}

function get_input() {
  printenv INPUTS_JSON | jq -r ".\"$1\""
}

# Create a unique invocation id, since there is no way to separate different
# instances of the same job (created with a build matrix). GitHub should really
# expose a "step id" in addition to their run id.
export INVOCATION_ID="$(od -x /dev/urandom | head -1 | awk '{OFS="-"; srand($6); sub(/./,"4",$5); sub(/./,substr("89ab",rand()*4,1),$6); print $2$3,$4,$5,$6,$7$8$9}')"
echo -n "$INVOCATION_ID" > "$HOME/__nixbuildnet_invocation_id"


# Export the HTTP API address
NIXBUILDNET_HTTP_API_HOST=$(get_input HTTP_API_HOST)
NIXBUILDNET_HTTP_API_SCHEME=$(get_input HTTP_API_SCHEME)
NIXBUILDNET_HTTP_API_PORT=$(get_input HTTP_API_PORT)
NIXBUILDNET_HTTP_API_SUBPATH=$(get_input HTTP_API_SUBPATH)
echo "NIXBUILDNET_HTTP_API_HOST=$NIXBUILDNET_HTTP_API_HOST" >> "$GITHUB_ENV"
echo "NIXBUILDNET_HTTP_API_SCHEME=$NIXBUILDNET_HTTP_API_SCHEME" >> "$GITHUB_ENV"
echo "NIXBUILDNET_HTTP_API_PORT=$NIXBUILDNET_HTTP_API_PORT" >> "$GITHUB_ENV"
echo "NIXBUILDNET_HTTP_API_SUBPATH=$NIXBUILDNET_HTTP_API_SUBPATH" >> "$GITHUB_ENV"

# Setup known_hosts
SSH_KNOWN_HOSTS_FILE="$(mktemp)"
echo >"$SSH_KNOWN_HOSTS_FILE" nixbuild "$(get_input SSH_PUBLIC_HOST_KEY)"


# Create ssh config
SSH_CONFIG_FILE="$(mktemp)"
cat >"$SSH_CONFIG_FILE" <<EOF
Host nixbuild "$(get_input SSH_ADDRESS)"
Hostname "$(get_input SSH_ADDRESS)"
Port "$(get_input SSH_PORT)"
HostKeyAlias nixbuild
LogLevel ERROR
StrictHostKeyChecking yes
UserKnownHostsFile "$SSH_KNOWN_HOSTS_FILE"
ControlPath none
ServerAliveInterval 60
IPQoS throughput
PreferredAuthentications none
User authtoken
SendEnv NIXBUILDNET_OIDC_ID_TOKEN
SendEnv NIXBUILDNET_TOKEN
EOF


# Check that we have a non-empty auth token
if [ -z "${NIXBUILDNET_TOKEN+x}" ]; then
  echo -e >&2 \
    "It seems you have not configured the 'nixbuild_token' setting, so" \
    "nixbuild.net access is not possible."
  exit 1
else
  # TODO Remove once NIXBUILDNET_TOKEN is properly accepted by nixbuild.net
  add_env "token" "$NIXBUILDNET_TOKEN"
fi


# Fetch OIDC ID Token
if [ "$(printenv INPUTS_JSON | jq -r .OIDC)" = "true" ]; then
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN+x}" ]; then
    echo >&2 \
      "OIDC ID Token retrieval requested, but it seems your job lacks the" \
      "'id-token: write' permission."
    exit 1
  else
    NIXBUILDNET_OIDC_ID_TOKEN="$(curl -sSL \
      -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=nixbuild.net" | \
      jq -j .value
    )"
    if [ -z "${NIXBUILDNET_OIDC_ID_TOKEN+x}" ]; then
      echo >&2 "Failed retrieving OIDC ID Token from GitHub"
      exit 1
    else
      echo "NIXBUILDNET_OIDC_ID_TOKEN=$NIXBUILDNET_OIDC_ID_TOKEN" >> "$GITHUB_ENV"
      if [ "$(printenv INPUTS_JSON | jq -r .OIDC_TOKEN_EXCHANGE)" = "true" ]; then
        base_url="$NIXBUILDNET_HTTP_API_SCHEME://$NIXBUILDNET_HTTP_API_HOST:$NIXBUILDNET_HTTP_API_PORT$NIXBUILDNET_HTTP_API_SUBPATH"
        NEW_NIXBUILDNET_TOKEN="$(curl --fail-with-body -L \
          "$base_url/auth/oidc-token-exchange" \
          -H "Authorization: Bearer $NIXBUILDNET_TOKEN" \
          -H "NIXBUILDNET-OIDC-ID-TOKEN: $NIXBUILDNET_OIDC_ID_TOKEN" \
          -H "Content-Type: application/json" | \
          jq -j .token
        )"
        if [ -z "${NEW_NIXBUILDNET_OIDC_ID_TOKEN+x}" ]; then
          echo >&2 "Failed to exchange OIDC token. Keeping the old nixbuild token."
        else
          NIXBUILDNET_TOKEN="$NEW_NIXBUILDNET_TOKEN"
          echo >&2 "Token exchange successful."
        fi
      fi
    fi
  fi
fi


# Setup nixbuild.net settings
for setting in \
  caches \
  reuse-build-failures \
  reuse-build-timeouts \
  keep-builds-running
do
  val="$(printenv INPUTS_JSON | jq -r ".\"$setting\"")"
  if [ -n "$val" ] && [ "$val" != "null" ]; then
    add_env "NIXBUILDNET_$(echo "$setting" | tr a-z- A-Z_)" "$val"
  fi
done


# Propagate selected GitHub Actions environment variables as nixbuild.net tags
# https://docs.github.com/en/actions/reference/environment-variables#default-environment-variables
for tag in \
  GITHUB_ACTOR \
  GITHUB_JOB \
  GITHUB_REF \
  GITHUB_REPOSITORY \
  GITHUB_RUN_ATTEMPT \
  GITHUB_RUN_ID \
  GITHUB_RUN_NUMBER \
  GITHUB_SHA \
  GITHUB_WORKFLOW
do
  add_env "NIXBUILDNET_TAG_$tag" "$(printenv $tag)"
done
add_env "NIXBUILDNET_TAG_GITHUB_INVOCATION_ID" "$(basename "$INVOCATION_ID")"


# Write ssh env to config
echo "SetEnv$nixbuildnet_env" >> "$SSH_CONFIG_FILE"


# Instruct Nix to use our SSH config
echo "NIX_SSHOPTS=-F$SSH_CONFIG_FILE" >> "$GITHUB_ENV"


# Setup Nix builders
NIX_BUILDERS_FILE="$(mktemp)"
cat >"$NIX_BUILDERS_FILE" <<EOF
nixbuild x86_64-linux - 200 1 big-parallel,benchmark,kvm,nixos-test
nixbuild aarch64-linux - 200 1 big-parallel,benchmark
EOF


# Setup Nix config
NIX_CONF_FILE="$(mktemp)"
NIXBUILD_SUBSTITUTER="ssh://nixbuild?priority=100"
NIXBUILD_SUBSTITUTER_PUBKEY="$(
  ssh -F"$SSH_CONFIG_FILE" \
    nixbuild api settings signing-key-for-builds --show | \
      jq -r '"\(.keyName):\(.publicKey)"'
)"

cat >>"$NIX_CONF_FILE" <<EOF
${NIX_CONFIG:-}
extra-substituters = $NIXBUILD_SUBSTITUTER
extra-trusted-public-keys = $NIXBUILD_SUBSTITUTER_PUBKEY
max-jobs = 0
builders = @$NIX_BUILDERS_FILE
builders-use-substitutes = true
require-sigs = true
EOF

echo "NIX_CONFIG=include $NIX_CONF_FILE" >> "$GITHUB_ENV"

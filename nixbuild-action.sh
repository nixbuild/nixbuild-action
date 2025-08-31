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

# Create a unique invocation id, since there is no way to separate different
# instances of the same job (created with a build matrix). GitHub should really
# expose a "step id" in addition to their run id.
export INVOCATION_ID="$(od -x /dev/urandom | head -1 | awk '{OFS="-"; srand($6); sub(/./,"4",$5); sub(/./,substr("89ab",rand()*4,1),$6); print $2$3,$4,$5,$6,$7$8$9}')"
echo -n "$INVOCATION_ID" > "$HOME/__nixbuildnet_invocation_id"


# Setup known_hosts
SSH_KNOWN_HOSTS_FILE="$(mktemp)"
echo >"$SSH_KNOWN_HOSTS_FILE" \
  eu.nixbuild.net \
  ssh-ed25519 \
  AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM


# Create ssh config
SSH_CONFIG_FILE="$(mktemp)"
cat >"$SSH_CONFIG_FILE" <<EOF
Host eu.nixbuild.net
HostName eu.nixbuild.net
LogLevel ERROR
StrictHostKeyChecking yes
UserKnownHostsFile $SSH_KNOWN_HOSTS_FILE
ControlPath none
ServerAliveInterval 60
IPQoS throughput
SendEnv NIXBUILDNET_OIDC_ID_TOKEN
EOF


# Setup auth
if [ -n "$NIXBUILD_TOKEN" ]; then # Token authentication
  echo "PreferredAuthentications none" >> "$SSH_CONFIG_FILE"
  echo "User authtoken" >> "$SSH_CONFIG_FILE"
  add_env "token" "$NIXBUILD_TOKEN"
else # Invalid auth config
  echo -e >&2 \
"It seems you have not configured the 'nixbuild_token' setting, so\n"\
"nixbuild.net access is not possible."
  exit 1
fi


# Fetch OIDC ID Token
if [ -n "$OIDC" ] && [ "$OIDC" = "1" ]; then
  echo "NIXBUILDNET_OIDC_ID_TOKEN=$(curl -sSL \
    -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=nixbuild.net" | \
    jq -j .value
  )" >> "$GITHUB_ENV"
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
eu.nixbuild.net x86_64-linux - 200 1 big-parallel,benchmark,kvm,nixos-test
eu.nixbuild.net aarch64-linux - 200 1 big-parallel,benchmark
EOF


# Setup Nix config
NIX_CONF_FILE="$(mktemp)"
NIXBUILD_SUBSTITUTER="ssh://eu.nixbuild.net?priority=100"
NIXBUILD_SUBSTITUTER_PUBKEY="$(
  ssh -F"$SSH_CONFIG_FILE" \
    eu.nixbuild.net api settings signing-key-for-builds --show | \
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

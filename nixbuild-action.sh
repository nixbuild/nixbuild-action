#!/usr/bin/env bash

set -eu
set -o pipefail


# Setup known_hosts
SSH_KNOWN_HOSTS_FILE="$(mktemp)"
echo >"$SSH_KNOWN_HOSTS_FILE" \
  eu.nixbuild.net \
  ssh-ed25519 \
  AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM


# Start ssh-agent
eval $(ssh-agent)


# Add ssh key
printenv NIXBUILD_SSH_KEY | ssh-add -q -


# Write ssh config
SSH_CONFIG_FILE="$(mktemp)"
cat >"$SSH_CONFIG_FILE" <<EOF
Host eu.nixbuild.net
  HostName eu.nixbuild.net
  PubkeyAcceptedKeyTypes ssh-ed25519
  IdentityAgent $SSH_AUTH_SOCK
  LogLevel ERROR
  StrictHostKeyChecking yes
  UserKnownHostsFile $SSH_KNOWN_HOSTS_FILE
  ControlPath none
EOF


# Setup nixbuild.net environment

nixbuildnet_env=""

for setting in \
  allow-override \
  always-substitute \
  cache-build-failures \
  cache-build-timeouts \
  keep-builds-running \
  never-substitute
do
  val="$(printenv INPUTS_JSON | jq -r ".\"$setting\"")"
  val="${val/\'/\\\'}"
  if [ -n "$val" ]; then
    nixbuildnet_env="$nixbuildnet_env NIXBUILDNET_$(echo "$setting" | tr a-z- A-Z_)='$val'"
  fi
done

# Propagate selected GitHub Actions environment variables as nixbuild.net tags
# https://docs.github.com/en/actions/reference/environment-variables#default-environment-variables
for tag in \
  GITHUB_WORKFLOW \
  GITHUB_RUN_ID \
  GITHUB_RUN_NUMBER \
  GITHUB_ACTION \
  GITHUB_ACTIONS \
  GITHUB_REPOSITORY \
  GITHUB_SHA
do
  val="$(printenv $tag)"
  val="${val/\'/\\\'}"
  nixbuildnet_env="$nixbuildnet_env NIXBUILDNET_TAG_$tag='$val'"
done

echo "  SetEnv$nixbuildnet_env" >> "$SSH_CONFIG_FILE"


# Append ssh config to system config
sudo mkdir -p /etc/ssh
sudo touch /etc/ssh/ssh_config
sudo tee -a /etc/ssh/ssh_config < "$SSH_CONFIG_FILE" >/dev/null


# Setup Nix builders
NIX_BUILDERS_FILE="$(mktemp)"
cat >"$NIX_BUILDERS_FILE" <<EOF
eu.nixbuild.net x86_64-linux - 200 1 big-parallel,benchmark,kvm,nixos-test
eu.nixbuild.net aarch64-linux - 200 1 big-parallel,benchmark
EOF


# Setup nix config (TODO: proper parser)
NIXOS_CACHE="http://cache.nixos.org"
NIXOS_CACHE_PUBKEY="cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
NIXBUILD_CACHE="ssh://eu.nixbuild.net?priority=100"
NIXBUILD_CACHE_PUBKEY="$(ssh eu.nixbuild.net api show public-signing-key | jq -r '"\(.keyName):\(.publicKey)"')"

NIX_CONF_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf"
mkdir -p "$(dirname "$NIX_CONF_FILE")"
touch "$NIX_CONF_FILE"

prev_substituters="$(echo "substituters = $NIXOS_CACHE" | cat "$NIX_CONF_FILE" - | egrep -m1 '^substituters =')"
substituters="$prev_substituters $NIXBUILD_CACHE"

prev_public_keys="$(echo "trusted-public-keys = $NIXOS_CACHE_PUBKEY" | cat "$NIX_CONF_FILE" - | egrep -m1 '^trusted-public-keys =')"
public_keys="$prev_public_keys $NIXBUILD_CACHE_PUBKEY"

egrep -v "substituters =|trusted-public-keys =" "$NIX_CONF_FILE" >"$NIX_CONF_FILE.tmp" || true

cat >>"$NIX_CONF_FILE.tmp" <<EOF
$substituters
$public_keys
max-jobs = 0
builders = @$NIX_BUILDERS_FILE
builders-use-substitutes = true
require-sigs = true
EOF

mv "$NIX_CONF_FILE.tmp" "$NIX_CONF_FILE"

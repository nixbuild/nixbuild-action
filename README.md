# nixbuild.net Action

This GitHub Action sets up [Nix](https://nixos.org/nix/) to use the
[nixbuild.net](https://nixbuild.net) service. It supports the **ubuntu-20.04**
and **macos-latest** platforms.

You need a [nixbuild.net](https://nixbuild.net) account to make use of this
action.

The configuration needed for this action is simple &ndash; you only need to
specify the ssh key used to authenticate your nixbuild.net account. You will
then automatically reap the benefits that nixbuild.net provides:

* Instead of having all Nix builds for a single GitHub job share the same two
  vCPUs, every Nix build will _each_ get [up to 16 vCPUs](https://blog.nixbuild.net/posts/2020-06-25-automatic-resource-optimization.html).
  It doesn't matter how many concurrent Nix builds a job triggers, nixbuild.net
  will scale up automatically to avoid any slowdown.

* Every Nix build that is built for your nixbuild.net account shares all
  build results with each other. So, if you have multiple workflows triggering
  the same builds, each derivation will only be built once on nixbuild.net.
  This works automatically, there is no need for configuring any binary caches,
  and you save time by not having to upload build results.

* Build result sharing also works outside GitHub Actions. You can use
  nixbuild.net from your development machine so that builds performed by your
  GitHub workflows is fetched locally, or the other way around. Again, no extra
  configuration or binary caches are needed for this, just a
  [nixbuild.net account](https://docs.nixbuild.net/getting-started/)

* Builds that runs on nixbuild.net works just as ordinary Nix builds, so you
  can still do whatever you want with the build results, like uploading to a
  separate binary cache.

See the nixbuild.net [FAQ](https://nixbuild.net/#faq) for more information
about the nixbuild.net service.

## Usage

1. Register for a [nixbuild.net account](https://nixbuild.net/#register). Every
   account includes free build hours, so you can try this action out for free.

2. It is highly advisable to create a new ssh key specifically for GitHub's
   access to your nixbuild.net account. That way you can revoke GitHub's access
   at any time while still being able to manage your account with your main ssh
   key. You can add and remove ssh keys to your nixbuild.net account with the
   [nixbuild.net shell](https://docs.nixbuild.net/getting-started/#add-an-ssh-key).

   ```text
   $ ssh-keygen -t ed25519 -N "" -C "github" -f github-nixbuild-key

   $ cat github-nixbuild-key.pub
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMTOsCkG3Y/zZjSDPKflA5opCHEDBrGySTxK9SqbU979 github

   $ ssh eu.nixbuild.net shell
   nixbuild.net> ssh-keys add ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMTOsCkG3Y/zZjSDPKflA5opCHEDBrGySTxK9SqbU979 github
   Key added to account
   ```

   If there is any chance that less trusted users can submit commits or PRs that
   are able to change your GitHub Actions workflow, it is **strongly recommended**
   that you [lock down your nixbuild.net settings](/#nixbuildnet-settings). Users
   might otherwise be able to change settings, possibly incurring unexpected
   nixbuild.net charges.

3. Configure your secret ssh key as a [GitHub Secret](https://docs.github.com/en/actions/reference/encrypted-secrets)

4. Use `nixbuild/nixbuild-action` in your workflows. You don't need to configure
   anything else than your ssh key:

   ```yaml
   name: Examples
   on: push
   jobs:
     minimal:
       runs-on: ubuntu-20.04
       steps:
         - uses: actions/checkout@v2
         - uses: nixbuild/nix-quick-install-action@v4
         - uses: nixbuild/nixbuild-action@v2
           with:
             nixbuild_ssh_key: ${{ secrets.nixbuild_ssh_key }}
         - run: nix-build
   ```

   All builds performed by Nix will now run in nixbuild.net.

   Note that you can use either
   [nixbuild/nix-quick-install-action](https://github.com/marketplace/actions/nix-quick-install)
   or
   [cachix/install-nix-action](https://github.com/marketplace/actions/install-nix)
   to install Nix, just make sure that you put the Nix installer action before
   this action.

### nixbuild.net Settings

Optionally, you can configure [nixbuild.net
settings](https://docs.nixbuild.net/settings/) that you want your builds to
use. Most settings are available directly as [inputs](action.yml) of this
action. Some settings, like
[max-cpu-hours-per-month](https://docs.nixbuild.net/settings/#max-cpu-hours-per-month),
can only be configured through the [nixbuild.net
shell](http://docs.nixbuild.net/nixbuild-shell/#configure-settings).

The settings configured for this action is communicated to nixbuild.net through
the [SSH environment](https://docs.nixbuild.net/settings/#ssh-environment).
This means that any setting you set here will override your
[account](https://docs.nixbuild.net/settings/#account) and [SSH
key](https://docs.nixbuild.net/settings/#ssh-key) settings.

If you want to disable the possibility to change any nixbuild.net settings
through GitHub Actions, you can set the
[allow-override](https://docs.nixbuild.net/settings/#allow-override) setting to
`false`, either on the account level or the SSH key level. You need to change
this setting from within the [nixbuild.net
shell](http://docs.nixbuild.net/nixbuild-shell/#configure-settings). If you do
that, any nixbuild.net setting configured for the action will be ignored. Only
settings condfigured for your account or the specific SSH key used by your
GitHub Actions workflow will then be used.

If there is any chance that less trusted users can submit commits or PRs that
are able to change your GitHub Actions workflow, it is **strongly recommended**
that you lock down the nixbuild.net settings as described above.

An example workflow that turns on the
[cache-build-timeouts](https://docs.nixbuild.net/settings/#cache-build-timeouts)
setting:

```yaml
name: Examples
on: push
jobs:
  minimal:
    runs-on: ubuntu-20.04
    steps:
      - uses: actions/checkout@v2
      - uses: nixbuild/nix-quick-install-action@v4
      - uses: nixbuild/nixbuild-action@v2
        with:
          nixbuild_ssh_key: ${{ secrets.nixbuild_ssh_key }}
          cache-build-timeouts: true
      - run: nix-build
```

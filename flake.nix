{
  description = "nixbuild-action";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "nixpkgs/nixos-unstable-small";
  };

  outputs = {
    self, flake-utils, nixpkgs
  }: flake-utils.lib.eachSystem ["x86_64-linux"] (system:

    let

      inherit (nixpkgs) lib;

      preferRemoteBuild = drv: drv.overrideAttrs (_: {
        preferLocalBuild = false;
        allowSubstitutes = true;
      });

      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          (self: super: super.prefer-remote-fetch self super)
        ];
      };

    in rec {
      defaultApp = apps.release;

      apps.release = flake-utils.lib.mkApp { drv = packages.release; };

      packages = {
        simple-test-build = preferRemoteBuild (
          pkgs.runCommand "simple-test-build" {} ''
            mkdir $out
            echo __SIMPLE_TEST_BUILD__ > $out/done
          ''
        );

        release = preferRemoteBuild (pkgs.writeShellScript "release" ''
          PATH="${lib.makeBinPath (with pkgs; [
            coreutils gitMinimal github-cli gnugrep
          ])}"

          if [ "$GITHUB_ACTIONS" != "true" ]; then
            echo >&2 "not running in GitHub, exiting"
            exit 1
          fi

          set -euo pipefail

          release_file="$1"
          release="$(head -n1 "$release_file")"
          prev_release="$(gh release list -L 1 | cut -f 3)"

          ci_workflow_file="$(dirname "$release_file")/.github/workflows/ci-workflow.yml"
          if ! grep -q "nixbuild/nixbuild-action@$release" "$ci_workflow_file"; then
            echo >&2 "ci-workflow.yml is missing correct version of nixbuild-action"
            exit 1
          fi

          if [ "$release" = "$prev_release" ]; then
            echo >&2 "Release tag not updated ($release)"
            exit
          else
            release_notes="$(mktemp)"
            tail -n+2 "$release_file" > "$release_notes"

            echo >&2 "New release: $prev_release -> $release"
            gh release create "$release" \
              --title "$GITHUB_REPOSITORY@$release" \
              --notes-file "$release_notes"
          fi
        '');
      };
    }
  );
}

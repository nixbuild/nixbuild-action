{
  description = "Demonstrating usage of the CI Workflow";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/master";
  };

  outputs = { self, nixpkgs }: let

    # some helpers from nixpkgs we use
    inherit (nixpkgs.lib) genAttrs optionalAttrs;

    # imports the nixpkgs package set for a given system
    pkgsForSystem = system: import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };

    # these are the systems we are interested in
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];

  in {

    # Here we list the packages we want our CI to build. By default the CI
    # Workflow builds everything in the `checks` attribute. You can adopt it by
    # filtering builds, and also make it build derivations from the `packages`
    # attribute.

    # Look in ../../.github/workflows/ci-example.yml to see how we configure
    # the CI Workflow for this flake.

    checks = genAttrs systems (system: with pkgsForSystem system;
      {
        inherit firefox hello;

        hello-fail = hello.overrideAttrs (_: {
          postInstall = "exit 1";
        });
      }
      // optionalAttrs stdenv.isx86_64
      {
        inherit minecraft;
      }
    );

  };
}

{
  # The LibreLane toolchain (librelane + openroad + magic + yosys + ciel) is distributed via Nix,
  # not a container -- this devshell is what the DCO SPICE CI (`make dco-spice`) and a local
  # `nix develop` use. The fossi-foundation binary cache means CI pulls prebuilt tools instead of
  # compiling them.
  nixConfig = {
    extra-substituters = [ "https://nix-cache.fossi-foundation.org" ];
    extra-trusted-public-keys = [ "nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs=" ];
  };

  inputs = {
    # Pinned to the same rev the consuming project uses, so the fossi-foundation cache has the
    # devshell prebuilt (a floating dev rev would force a from-source build in CI).
    librelane.url = "github:librelane/librelane/3131cc551528fb4b06ce30aa7219a2a3718c333e";
  };

  outputs =
    { self, librelane, ... }:
    let
      nix-eda = librelane.inputs.nix-eda;
      devshell = librelane.inputs.devshell;
      nixpkgs = nix-eda.inputs.nixpkgs;
    in
    {
      devShells = nix-eda.forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              nix-eda.overlays.default
              devshell.overlays.default
              librelane.overlays.default
              # The pinned librelane rev isn't in the fossi cache, so CI builds it from source and runs
              # its pytest checkPhase -- which fails in the GitHub nix sandbox (test_tclstep.py::test_env
              # -> pyfakefs '/cwd' FileNotFoundError) even though the build itself is fine. Skip the check.
              (_: prev: { librelane = prev.librelane.overrideAttrs (_: { doCheck = false; }); })
            ];
          };
          # nixpkgs ships iverilog 12.0, which predates libvvp. Build iverilog from git master with
          # --enable-libvvp so libvvp.so is installed: ngspice's d_cosim "ivlng" Verilog co-sim shim
          # (the cosim/ gate-level flow) dlopens it at runtime. Pinned to the validated master rev.
          iverilog-libvvp = pkgs.iverilog.overrideAttrs (old: {
            version = "14.0-pre-libvvp-78750c5";
            src = pkgs.fetchFromGitHub {
              owner = "steveicarus";
              repo = "iverilog";
              rev = "78750c51d0065d29cc493669344175f72c5de95f";
              hash = "sha256-y0/CCq/r3dkMocssSjMYDgT0EpSDQrUzj26r/ex5Pnk=";
            };
            patches = [ ];                       # 12.0's format-security patch doesn't apply to master
            preConfigure = "sh autoconf.sh";     # master ships configure.ac, not a generated configure
            configureFlags = (old.configureFlags or [ ]) ++ [ "--enable-libvvp" ];
            doInstallCheck = false;              # 12.0's installCheck runs .github/test.sh, absent in master
          });
        in
        {
          default = pkgs.librelane-shell.override {
            extra-packages = (with pkgs; [
              gnumake          # the dco-spice target
              gnugrep
              gawk
              verilator
              ngspice          # >=42 for the gf180 BSIM4 models; drives the DCO freq sweep
            ]) ++ [
              # hiPrio: win the buildEnv collision against the iverilog librelane-shell bundles, so the
              # devshell's iverilog/vvp is this libvvp-enabled build. Used by the sims + the cosim's ivlng.
              (pkgs.lib.hiPrio iverilog-libvvp)
            ];
          };
        }
      );
    };
}

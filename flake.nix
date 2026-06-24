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
    librelane.url = "github:librelane/librelane/dev";
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
            ];
          };
        in
        {
          default = pkgs.librelane-shell.override {
            extra-packages = with pkgs; [
              gnumake          # the dco-spice target
              gnugrep
              gawk
              iverilog         # the digital sims (matrix / phase / csr)
              verilator
              ngspice          # >=42 for the gf180 BSIM4 models; drives the DCO freq sweep
            ];
          };
        }
      );
    };
}

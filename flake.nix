{
  description = "SQL formatter for BigQuery + Dbt";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };

      squelch = pkgs.buildDubPackage {
        pname = "squelch";
        version = "0.3.3";
        src = self;
        dubLock = {
          dependencies = {
            ae = {
              version = "0.0.3363";
              sha256 = "2defd08ae2fd2fe5a57b9c28919991c07a771181986b7dc28d8cc152244222e7";
            };
          };
        };
        compiler = pkgs.dmd;
        buildInputs = [ pkgs.zlib ];

        doCheck = true;
        checkPhase = ''
          runHook preCheck

          for dialect in $(ls test); do
            dir="$NIX_BUILD_TOP/check-$dialect"
            mkdir -p "$dir"
            cp -r "test/$dialect/." "$dir/"
            ./squelch --dialect="$dialect" "$dir"/*.sql
            diff -r "test/$dialect" "$dir"
          done

          runHook postCheck
        '';

        installPhase = ''
          install -Dm755 squelch "$out"/bin/squelch
        '';

        meta = {
          description = "SQL formatter for BigQuery + Dbt";
          homepage = "https://github.com/CyberShadow/squelch";
          license = pkgs.lib.licenses.boost;
        };
      };
    in
    {
      packages.x86_64-linux.default = squelch;
      defaultPackage.x86_64-linux = squelch;
    };
}

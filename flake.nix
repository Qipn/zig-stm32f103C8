{
  description = "STM32 Zig 开发环境 (Zig 0.17 + microzig)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Zig 0.17.0 —— nixpkgs 尚未收录（只有 0.16），故用官方预编译包。
      zig = pkgs.stdenvNoCC.mkDerivation rec {
        pname = "zig";
        version = "0.17.0";

        src = pkgs.fetchurl {
          url = "https://ziglang.org/download/${version}/zig-x86_64-linux-${version}.tar.xz";
          sha256 = "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026";
        };

        nativeBuildInputs = [ pkgs.xz ];
        dontConfigure = true;
        dontBuild = true;

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          # unpackPhase 已将当前目录切到 sourceRoot (zig-x86_64-linux-<ver>/)
          cp -r ./* $out/
          # 官方 tarball 为扁平布局: zig 二进制在根目录, 链接到 bin/zig
          if [ ! -f $out/bin/zig ] && [ -f $out/zig ]; then
            mkdir -p $out/bin
            ln -s $out/zig $out/bin/zig
          fi
          runHook postInstall
        '';
      };

      # zig 在 socks 代理下的封装：zig 0.17 不认 "socks://"，
      # 必须是 "socks5://"。这里统一修正 ALL_PROXY。
      zigWrapped = pkgs.writeShellScriptBin "zig" ''
        unset HTTPS_PROXY https_proxy HTTP_PROXY http_proxy
        case "''${ALL_PROXY:-}" in
          socks://*) export ALL_PROXY="socks5://''${ALL_PROXY#socks://}" ;;
        esac
        exec ${zig}/bin/zig "$@"
      '';

      # 开发环境: zig + openocd + stlink, 并自动修正代理
      devEnv = pkgs.mkShell {
        packages = [ zigWrapped pkgs.openocd pkgs.stlink ];

        shellHook = ''
          case "''${ALL_PROXY:-}" in
            socks://*) export ALL_PROXY="socks5://''${ALL_PROXY#socks://}" ;;
          esac
          echo "STM32 Zig 环境: $(zig version)"
          echo "  构建: zig build       烧录: zig build flash"
        '';
      };
    in
    {
      packages.${system} = {
        inherit zig zigWrapped;
        default = zig;
      };

      devShells.${system}.default = devEnv;
    };
}

{ buildPackages, runCommand, nettools, bc, bison, flex, perl, gmp, libmpc, mpfr, openssl
, ncurses
, libelf
, utillinux
, writeTextFile, ubootTools
, callPackage
, overrideCC, gcc7
}:

{ stdenv, buildPackages, perl, buildLinux

, # Allow really overriding even our gcc7 default.
  # We want gcc >= 7.3 to enable the "retpoline" mitigation of security problems.
  stdenvNoOverride ? overrideCC stdenv gcc7

, # The kernel source tarball.
  src

, # The kernel version.
  version

, # Overrides to the kernel config.
  extraConfig ? ""

, # The version number used for the module directory
  modDirVersion ? version

, # An attribute set whose attributes express the availability of
  # certain features in this kernel.  E.g. `{iwlwifi = true;}'
  # indicates a kernel that provides Intel wireless support.  Used in
  # NixOS to implement kernel-specific behaviour.
  features ? {}

, # A list of patches to apply to the kernel.  Each element of this list
  # should be an attribute set {name, patch} where `name' is a
  # symbolic name and `patch' is the actual patch.  The patch may
  # optionally be compressed with gzip or bzip2.
  kernelPatches ? []
, ignoreConfigErrors ? hostPlatform.platform.name != "pc" ||
                       hostPlatform != stdenvNoOverride.buildPlatform
, extraMeta ? {}
, hostPlatform
, ...
} @ args:

let stdenv = stdenvNoOverride; in # finish the rename

assert stdenv.isLinux;

let

  lib = stdenv.lib;

  # Combine the `features' attribute sets of all the kernel patches.
  kernelFeatures = lib.fold (x: y: (x.features or {}) // y) ({
    iwlwifi = true;
    efiBootStub = true;
    needsCifsUtils = true;
    netfilterRPFilter = true;
  } // features) kernelPatches;

  config = import ./common-config.nix {
    inherit stdenv version ;
    # append extraConfig for backwards compatibility but also means the user can't override the kernelExtraConfig part
    extraConfig = extraConfig + lib.optionalString (hostPlatform.platform ? kernelExtraConfig) hostPlatform.platform.kernelExtraConfig;

    features = kernelFeatures; # Ensure we know of all extra patches, etc.
  };

  kernelConfigFun = baseConfig:
    let
      configFromPatches =
        map ({extraConfig ? "", ...}: extraConfig) kernelPatches;
    in lib.concatStringsSep "\n" ([baseConfig] ++ configFromPatches);

  configfile = stdenv.mkDerivation {
    inherit ignoreConfigErrors;
    name = "linux-config-${version}";

    generateConfig = ./generate-config.pl;

    kernelConfig = kernelConfigFun config;

    depsBuildBuild = [ buildPackages.stdenv.cc ];
    nativeBuildInputs = [ perl ]
      ++ lib.optionals (stdenv.lib.versionAtLeast version "4.16") [ bison flex ];

    platformName = hostPlatform.platform.name;
    # e.g. "defconfig"
    kernelBaseConfig = hostPlatform.platform.kernelBaseConfig;
    # e.g. "bzImage"
    kernelTarget = hostPlatform.platform.kernelTarget;
    autoModules = hostPlatform.platform.kernelAutoModules;
    preferBuiltin = hostPlatform.platform.kernelPreferBuiltin or false;
    arch = hostPlatform.platform.kernelArch;

    prePatch = kernel.prePatch + ''
      # Patch kconfig to print "###" after every question so that
      # generate-config.pl from the generic builder can answer them.
      sed -e '/fflush(stdout);/i\printf("###");' -i scripts/kconfig/conf.c
    '';

    inherit (kernel) src patches preUnpack;

    buildPhase = ''
      export buildRoot="''${buildRoot:-build}"

      # Get a basic config file for later refinement with $generateConfig.
      make HOSTCC=${buildPackages.stdenv.cc.targetPrefix}gcc -C . O="$buildRoot" $kernelBaseConfig ARCH=$arch

      # Create the config file.
      echo "generating kernel configuration..."
      echo "$kernelConfig" > "$buildRoot/kernel-config"
      DEBUG=1 ARCH=$arch KERNEL_CONFIG="$buildRoot/kernel-config" AUTO_MODULES=$autoModules \
           PREFER_BUILTIN=$preferBuiltin BUILD_ROOT="$buildRoot" SRC=. perl -w $generateConfig
    '';

    installPhase = "mv $buildRoot/.config $out";

    enableParallelBuilding = true;
  };

  kernel = (callPackage ./manual-config.nix {}) {
    inherit version modDirVersion src kernelPatches stdenv extraMeta configfile hostPlatform;

    config = { CONFIG_MODULES = "y"; CONFIG_FW_LOADER = "m"; };
  };

  passthru = {
    features = kernelFeatures;
    passthru = kernel.passthru // (removeAttrs passthru [ "passthru" ]);
  };

in lib.extendDerivation true passthru kernel

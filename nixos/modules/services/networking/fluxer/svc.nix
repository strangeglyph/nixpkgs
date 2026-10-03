{
  settingsToEnvVars,
  loadCredential,
  assignSecretsSnippet,
}:
{
  name,
  description,
  needsPostgres ? false,
  defaultPort ? 8090,
}:
{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (lib) mkIf;
  cfg = config.services.fluxer;
  hasFluxerUserDef = cfg.${name}.shard ? user && cfg.${name}.shard.user == "fluxer";
  hasUserDef = cfg.${name}.shard ? user && cfg.${name}.shard.user != null;
in
{
  config = {
    services.fluxer.${name} = {
      settings = {
        svc.name = name;
      };
      router.settings = {
        svc.mode = "router";
        svc.port = lib.mkDefault defaultPort;
      };
      router.mergedSettings = lib.mkMerge [
        config.services.fluxer.settings
        config.services.fluxer.${name}.settings
        config.services.fluxer.${name}.router.settings
      ];
      shard.settings = {
        svc.mode = "shard";
        svc.shard_id = 0;
        svc.port = lib.mkDefault (defaultPort + 1);
      };
      shard.mergedSettings = lib.mkMerge [
        config.services.fluxer.settings
        config.services.fluxer.${name}.settings
        config.services.fluxer.${name}.shard.settings
      ];
    };

    users = mkIf hasFluxerUserDef {
      users.fluxer = {
        isSystemUser = true;
        group = "fluxer";
        description = "fluxer service account";
      };
      groups.fluxer = { };
    };

    systemd.services."fluxer-${name}-router" = mkIf (cfg.enable && cfg.${name}.router.enable) {
      enable = true;
      description = "Router for the Fluxer ${description} shards";

      confinement = {
        enable = true;
      };

      wantedBy = [ "fluxer.target" ];
      partOf = [ "fluxer.target" ];
      after = [ "nats.service" ];
      requires = lib.optional cfg.aux.nats.enable "nats.service";

      script = ''
        ${assignSecretsSnippet cfg.${name}.router.mergedSettings}

        ${lib.getExe pkgs.fluxer-server.${name}}
      '';

      environment = settingsToEnvVars cfg.${name}.router.mergedSettings;

      serviceConfig = {
        Type = "simple";
        BindReadOnlyPaths = [ "/etc/resolv.conf" ];
        LoadCredential = loadCredential cfg.${name}.router.mergedSettings;
        ProtectHome = true;
        ProtectSystem = "full";
        ProtectProc = "invisible";
        PrivateTmp = true;
        DynamicUser = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "~" ];
        PrivateDevices = true;
        ProtectHostname = true;
        ProtectClock = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = "strict";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RemoveIPC = true;
        PrivateMounts = true;
        SystemCallFilter = [
          "~@cpu-emulation @debug @keyring @mount @obsolete @privileged @setuid"
        ];
        SystemCallErrorNumber = "EPERM";
        SystemCallArchitectures = "native";
      };
    };

    systemd.services."fluxer-${name}-shard" = mkIf (cfg.enable && cfg.${name}.shard.enable) {
      enable = true;
      description = "Shard of the Fluxer ${description}";

      wantedBy = [ "fluxer.target" ];
      partOf = [ "fluxer.target" ];
      after = [ "nats.service" ] ++ (lib.optional needsPostgres "postgresql.service");
      requires =
        (lib.optional cfg.aux.nats.enable "nats.service")
        ++ (lib.optional (needsPostgres && cfg.aux.pgsql.enable) "postgresql.service");

      script = ''
        ${assignSecretsSnippet cfg.${name}.shard.mergedSettings}

        ${lib.getExe pkgs.fluxer-server.${name}}
      '';

      confinement = {
        enable = true;
      };

      environment = settingsToEnvVars cfg.${name}.shard.mergedSettings;

      serviceConfig = {
        Type = "simple";
        BindReadOnlyPaths = [
          "/etc/resolv.conf"
          "/etc/ssl/certs"
        ]
        ++ (lib.optionals (needsPostgres && cfg.aux.pgsql.enable) [
          "/run/postgresql/"
        ]);
        LoadCredential = loadCredential cfg.${name}.shard.mergedSettings;
        ProtectHome = true;
        ProtectSystem = "full";
        ProtectProc = "invisible";
        PrivateTmp = true;
        User = mkIf hasUserDef cfg.${name}.shard.user;
        DynamicUser = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "~" ];
        PrivateDevices = true;
        ProtectHostname = true;
        ProtectClock = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = "strict";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RemoveIPC = true;
        PrivateMounts = true;
        SystemCallFilter = [
          "~@cpu-emulation @debug @keyring @mount @obsolete @privileged @setuid"
        ];
        SystemCallErrorNumber = "EPERM";
        SystemCallArchitectures = "native";
      };
    };
  };
}

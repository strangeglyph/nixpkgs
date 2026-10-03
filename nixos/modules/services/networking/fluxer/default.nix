{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (lib)
    mkIf
    mkOption
    types
    toUpper
    join
    ;
  cfg = config.services.fluxer;
  mkPartEnableOption =
    name:
    lib.mkOption {
      description = "Configure ${name} for use with fluxer";
      type = types.bool;
      default = cfg.enable;
      defaultText = "config.services.fluxer.enable";
    };
  mkPartSettingsOptions =
    name:
    lib.mkOption {
      description = ''
        Configuration for ${name}. See https://docs.fluxer.app/operator/configuration/
        for supported values.

        Values configured here will be converted to environment variables by
        - converting their name to upper case
        - concatenating nested options with _
        - prefixing them with FLUXER_
        and passed to ${name}.

        For example, `svc.port` becomes `FLUXER_SVC_PORT`.

        For global configuration, consider `config.services.fluxer.settings`.
      '';
      type = types.attrsOf types.anything;
      default = { };
    };
  mkSvcOptions = name: {
    settings = mkPartSettingsOptions name;
    router = {
      enable = mkPartEnableOption "fluxer-${name} router";
      settings = mkPartSettingsOptions "fluxer-${name} router";
      mergedSettings = mkOption { internal = true; };
    };
    shard = {
      enable = mkPartEnableOption "fluxer-${name} shard";
      settings = mkPartSettingsOptions "fluxer-${name} shard";
      mergedSettings = mkOption { internal = true; };
    };
  };
  mkSvcOptionsWithUser = name: {
    settings = mkPartSettingsOptions name;
    router = {
      enable = mkPartEnableOption "${name} router";
      settings = mkPartSettingsOptions "${name} router";
      mergedSettings = mkOption { internal = true; };
    };
    shard = {
      enable = mkPartEnableOption "${name} shard";
      settings = mkPartSettingsOptions "${name} shard";
      mergedSettings = mkOption { internal = true; };
      user = mkOption {
        description = ''
          The user to run the fluxer-messages shard service as.
          Set to null to run as dynamic user.
        '';
        type = types.nullOr types.str;
        default = if cfg.aux.pgsql.enable then "fluxer" else null;
        defaultText = "'fluxer', if automatic postgres is enabled, otherwise null";
      };
    };
  };

  # Config massage
  pathToEnvVar = path: toUpper (join "_" ([ "fluxer" ] ++ path));
  isSecret = value: builtins.isAttrs value && value ? _secret;

  settingsToEnvVars =
    attrs:
    let
      nonSecretAttrs = lib.filterAttrsRecursive (n: v: !isSecret v) attrs;
    in
    lib.listToAttrs (
      lib.mapAttrsToListRecursiveCond (n: v: !lib.isDerivation v) (
        path: value: lib.nameValuePair (pathToEnvVar path) (toString value)
      ) nonSecretAttrs
    );
  collectSecrets =
    pathSoFar: value:
    if lib.isDerivation value || !builtins.isAttrs value then
      [ ]
    else if value ? _secret then
      {
        path = pathSoFar;
        value = value._secret;
      }
    else
      lib.flatten (lib.mapAttrsToList (name: inner: collectSecrets (pathSoFar ++ [ name ]) inner) value);
  loadCredential =
    attrs:
    let
      secrets = collectSecrets [ ] attrs;
    in
    map ({ path, value }: "${pathToEnvVar path}:${value}") secrets;
  assignSecretsSnippet =
    attrs:
    let
      secrets = collectSecrets [ ] attrs;
    in
    join "\n" (
      map (
        { path, ... }:
        "export ${pathToEnvVar path}=$(${pkgs.coreutils}/bin/cat $CREDENTIALS_DIRECTORY/${pathToEnvVar path})"
      ) secrets
    );

  mkSvc = import ./svc.nix { inherit settingsToEnvVars loadCredential assignSecretsSnippet; };
in
{
  imports = [
    (mkSvc {
      name = "gifs";
      description = "gif search and proxy service";
      defaultPort = 8090;
    })
    (mkSvc {
      name = "messages";
      description = "message storage service";
      defaultPort = 8092;
      needsPostgres = true;
    })
    (mkSvc {
      name = "snowflakes";
      description = "snowflake service";
      defaultPort = 8094;
    })
    (mkSvc {
      name = "unfurl";
      description = "link unfurling/embedding service";
      defaultPort = 8096;
    })
    (mkSvc {
      name = "users";
      description = "user storage service";
      defaultPort = 8098;
      needsPostgres = true;
    })
  ];

  options.services.fluxer = {
    enable = lib.mkEnableOption "Fluxer Instant Messaging and VoIP Platform";
    settings = lib.mkOption {
      description = ''
        Configuration for all fluxer services. See https://docs.fluxer.app/operator/configuration/
        for supported values.

        Values configured here will be converted to environment variables by
        - converting their name to upper case
        - concatenating nested options with _
        - prefixing them with FLUXER_
        and passed to all services.

        For example, `svc.port` becomes `FLUXER_SVC_PORT`.
      '';
      type = types.attrsOf types.anything;
      default = { };
    };
    api.enable = mkPartEnableOption "fluxer-api";

    gifs = mkSvcOptions "gifs";
    messages = mkSvcOptionsWithUser "messages";
    snowflakes = mkSvcOptions "snowflakes";
    unfurl = mkSvcOptions "unfurl";
    users = mkSvcOptionsWithUser "users";

    aux = {
      nats.enable = lib.mkEnableOption "Nats for use with fluxer";
      pgsql.enable = lib.mkEnableOption ''
        Postgres for use with fluxer.

        If postgres is enabled, then local services will attempt
        to connect via unix socket using peer authentication. If
        you would like to deviate from this, please configure
        postgres manually.  
      '';
      valkey.enable = lib.mkEnableOption ''
        Valkey for use with fluxer.

        This internally uses the redis module with a package override
        for valkey. If you have other redis instances running, consider
        leaving this option disabled and configuring valkey manually.
      '';
      meilisearch = {
        enable = lib.mkEnableOption "Meilisearch for use with fluxer.";
        masterKeyFile = mkOption {
          description = "Path to a file containing the authentication key for meilisearch.";
          type = types.path;
        };
      };
    };
  };

  config = {
    systemd.targets."fluxer" = {
      enable = cfg.enable;
      wantedBy = lib.optional cfg.enable "network-online.target";
    };

    services.nats = mkIf (cfg.enable && cfg.aux.nats.enable) {
      enable = true;
      jetstream = true;
      settings.host = "localhost";
    };

    services.postgresql = mkIf (cfg.enable && cfg.aux.pgsql.enable) {
      enable = true;
      ensureDatabases = [ "fluxer" ];
      ensureUsers = [
        {
          name = "fluxer";
          ensureDBOwnership = true;
        }
      ];
    };

    services.redis = mkIf (cfg.enable && cfg.aux.valkey.enable) {
      package = pkgs.valkey;
      servers.fluxer = {
        enable = true;
        appendOnly = true;
      };
    };

    services.meilisearch = mkIf (cfg.enable && cfg.aux.meilisearch.enable) {
      enable = true;
      masterKeyFile = cfg.aux.meilisearch.masterKeyFile;
      settings = {
        experimental_dumpless_upgrade = true;
        # upgrade_db = true; # TODO for 26.11 and later
        no_analytics = true;
        env = "production";
      };
    };

    services.fluxer.settings = {
      nats = mkIf cfg.aux.nats.enable {
        url = "nats://localhost:${toString config.services.nats.port}";
        jetstream.url = "nats://localhost:${toString config.services.nats.port}";
      };
      database = {
        backend = lib.mkDefault "postgres";
      };
      postgres = mkIf cfg.aux.pgsql.enable {
        url = "host=/run/postgresql user=fluxer sslmode=disable";
        ssl = "false";
      };
      kv = mkIf cfg.aux.valkey.enable {
        url = "redis://${config.services.redis.servers.fluxer.unixSocket}";
      };
      search = mkIf cfg.aux.meilisearch.enable {
        engine = "meilisearch";
        url = "http://localhost:${toString config.services.meilisearch.listenPort}";
        api_key._secret = cfg.aux.meilisearch.masterKeyFile;
      };
      svc = {
        shard_count = 1;
        listen_host = "127.0.0.1";
        nats.url = mkIf cfg.aux.nats.enable "nats://localhost:${toString config.services.nats.port}";
      };
    };
  };
}

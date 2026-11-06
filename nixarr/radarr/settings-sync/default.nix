{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    types
    mkOption
    getExe
    mkIf
    ;

  inherit
    (pkgs.writers)
    writeJSON
    writePython3Bin
    ;

  nixarr = config.nixarr;
  globals = config.util-nixarr.globals;
  cfg = nixarr.radarr.settings-sync;

  nixarr-utils = import ../../lib/utils.nix {inherit pkgs lib config;};
  inherit (nixarr-utils) arrDownloadClientConfigType arrDownloadClientConfigModule;

  sync-settings = writePython3Bin "nixarr-sync-radarr-settings" {
    libraries = [nixarr.nixarr-py.package];
    flakeIgnore = [
      "E501" # Line too long
    ];
  } (builtins.readFile ./sync_settings.py);

  wantedServices = ["radarr-api.service"];
in {
  options = {
    nixarr.radarr.settings-sync = {
      mediaManagement = mkOption {
        type = with types; attrsOf (oneOf [bool int str]);
        default = {};
        example = {
          importExtraFiles = true;
          extraFileExtensions = "srt,ass,ssa,sub,idx,vtt,sup";
        };
        description = ''
          Media management settings to set in Radarr, by their API name (the
          keys of `GET /api/v3/config/mediamanagement`). Settings not listed
          are left as they are. The sync fails if Radarr returns a setting
          the bundled API client does not know, rather than risk resetting it.
        '';
      };

      downloadClients = mkOption {
        type = types.listOf (arrDownloadClientConfigType "radarr");
        default = [];
        description = ''
          List of download clients to configure in Radarr.

          To see available top-level properties and `fields` members for each
          download client, run `nixarr show-radarr-schemas download_client | jq
          '.'` as root.
        '';
      };

      transmission = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Automatically configure Transmission as a download client in Radarr.
          '';
        };
        config = mkOption {
          type = types.submodule [
            (arrDownloadClientConfigModule "radarr")
            {
              config = {
                name = "Transmission";
                implementation = "Transmission";
                enable = true;
                fields = {
                  # We can use localhost even if Sonarr or Transmission are in
                  # the VPN because nginx proxies the Transmission port when
                  # needed.
                  host = "localhost";
                  port = nixarr.transmission.uiPort;
                  useSsl = false;
                };
              };
            }
          ];
          default = {};
          defaultText = lib.literalExpression ''
            {
              name = "Transmission";
                implementation = "Transmission";
                enable = true;
                fields = {
                  host = "localhost";
                  port = nixarr.transmission.uiPort;
                  useSsl = false;
                };
              }
          '';
          description = ''
            Configuration for Transmission as a download client in Radarr.
          '';
        };
      };
    };
  };

  config = mkIf (nixarr.enable && nixarr.radarr.enable) {
    assertions = [
      {
        assertion = cfg.transmission.enable -> nixarr.transmission.enable;
        message = "nixarr.radarr.settings-sync.transmission.enable requires nixarr.transmission.enable to be true";
      }
    ];

    # Add Transmission config if enabled
    nixarr.radarr.settings-sync.downloadClients = mkIf cfg.transmission.enable [
      cfg.transmission.config
    ];

    users.users.radarr.extraGroups = ["radarr-api"];

    systemd.services.radarr-sync-config = {
      description = ''
        Sync Radarr configuration (download clients, media management)
      '';
      after = wantedServices;
      wants = wantedServices;
      wantedBy = ["radarr.service"];
      startLimitIntervalSec = 300;
      startLimitBurst = 5;
      serviceConfig = {
        Type = "oneshot";
        User = globals.radarr.user;
        Group = globals.radarr.group;
        RemainAfterExit = true;
        # The *arr API can briefly fail while the service is still starting
        # (e.g. "database is locked" from SQLite).
        Restart = "on-failure";
        RestartSec = "10s";
        ExecStart = let
          config-file = writeJSON "radarr-sync-config.json" {
            download_clients = cfg.downloadClients;
            media_management = cfg.mediaManagement;
          };
        in ''
          ${getExe sync-settings} --config-file ${config-file}
        '';
      };
    };
  };
}

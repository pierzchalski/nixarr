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
  cfg = nixarr.sonarr.settings-sync;

  nixarr-utils = import ../../lib/utils.nix {inherit pkgs lib config;};
  inherit (nixarr-utils) arrDownloadClientConfigType arrDownloadClientConfigModule;

  sync-settings = writePython3Bin "nixarr-sync-sonarr-settings" {
    libraries = [nixarr.nixarr-py.package];
    flakeIgnore = [
      "E501" # Line too long
    ];
  } (builtins.readFile ./sync_settings.py);

  wantedServices = ["sonarr-api.service"];
in {
  options = {
    nixarr.sonarr.settings-sync = {
      mediaManagement = mkOption {
        type = with types; attrsOf (oneOf [bool int str]);
        default = {};
        example = {
          importExtraFiles = true;
          extraFileExtensions = "srt,ass,ssa,sub,idx,vtt,sup";
        };
        description = ''
          Media management settings to set in Sonarr, by their API name (the
          keys of `GET /api/v3/config/mediamanagement`). Settings not listed
          are left as they are.
        '';
      };

      downloadClients = mkOption {
        type = types.listOf (arrDownloadClientConfigType "sonarr");
        default = [];
        description = ''
          List of download clients to configure in Sonarr.

          To see available top-level properties and `fields` members for each
          download client, run `nixarr show-sonarr-schemas download_client | jq '.'` as root.
        '';
      };

      transmission = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Automatically configure Transmission as a download client in Sonarr.
          '';
        };
        config = mkOption {
          type = types.submodule [
            (arrDownloadClientConfigModule "sonarr")
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
            Configuration for Transmission as a download client in Sonarr.
          '';
        };
      };
    };
  };

  config = mkIf (nixarr.enable && nixarr.sonarr.enable) {
    assertions = [
      {
        assertion = cfg.transmission.enable -> nixarr.transmission.enable;
        message = "nixarr.sonarr.settings-sync.transmission.enable requires nixarr.transmission.enable to be true";
      }
    ];

    # Add Transmission config if enabled
    nixarr.sonarr.settings-sync.downloadClients = mkIf cfg.transmission.enable [
      cfg.transmission.config
    ];

    users.users.sonarr.extraGroups = ["sonarr-api"];

    systemd.services.sonarr-sync-config = {
      description = ''
        Sync Sonarr configuration (download clients, media management)
      '';
      after = wantedServices;
      wants = wantedServices;
      wantedBy = ["sonarr.service"];
      startLimitIntervalSec = 300;
      startLimitBurst = 5;
      serviceConfig = {
        Type = "oneshot";
        User = globals.sonarr.user;
        Group = globals.sonarr.group;
        RemainAfterExit = true;
        # The *arr API can briefly fail while the service is still starting
        # (e.g. "database is locked" from SQLite).
        Restart = "on-failure";
        RestartSec = "10s";
        ExecStart = let
          config-file = writeJSON "sonarr-sync-config.json" {
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

{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    getExe
    literalExpression
    mkIf
    mkOption
    types
    ;

  inherit
    (pkgs.writers)
    writeJSON
    writePython3Bin
    ;

  nixarr = config.nixarr;
  globals = config.util-nixarr.globals;
  cfg = nixarr.bazarr.settings-sync;

  nixarr-utils = import ../../lib/utils.nix {inherit config lib pkgs;};
  inherit (nixarr-utils) arrFieldsType;

  sync-settings = writePython3Bin "nixarr-sync-bazarr-settings" {
    libraries = [nixarr.nixarr-py.package];
    flakeIgnore = [
      "E501" # Line too long
    ];
  } (builtins.readFile ./sync_settings.py);

  wantedServices =
    ["bazarr-api.service"]
    ++ (lib.optional cfg.sonarr.enable "sonarr-api.service")
    ++ (lib.optional cfg.radarr.enable "radarr-api.service");

  subtitlesDeclared =
    cfg.languages
    != []
    || cfg.languageProfiles != {}
    || cfg.defaultProfile.series != null
    || cfg.defaultProfile.movies != null
    || cfg.providers.enabled != null
    || cfg.providers.settings != {}
    || cfg.wantedSearchFrequency.series != null
    || cfg.wantedSearchFrequency.movies != null;

  syncEnabled = cfg.sonarr.enable || cfg.radarr.enable || subtitlesDeclared;

  profileItemModule = {
    options = {
      language = mkOption {
        type = types.str;
        example = "en";
        description = ''
          Bazarr language code (ISO 639-1 where one exists). Must also be
          listed in `nixarr.bazarr.settings-sync.languages`.
        '';
      };
      type = mkOption {
        type = types.enum ["normal" "hi" "nonHi" "forced"];
        default = "normal";
        description = ''
          Which subtitles satisfy this item, as in Bazarr's profile editor:
          - `normal`: normal or hearing-impaired (an existing HI/SDH subtitle counts)
          - `hi`: hearing-impaired required
          - `nonHi`: hearing-impaired excluded (Bazarr 1.6.1 or later)
          - `forced`: forced (foreign parts only)
        '';
      };
      search = mkOption {
        type = types.enum ["always" "audioMatches" "noAudioMatches"];
        default = "always";
        description = ''
          When Bazarr wants this item: always, only when an audio track is
          in this language, or only when no audio track is.
        '';
      };
    };
  };

  languageProfileModule = {
    options = {
      items = mkOption {
        type = types.listOf (types.submodule profileItemModule);
        description = "Languages this profile wants, in order.";
      };
      mustContain = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Release-name words a subtitle must contain.";
      };
      mustNotContain = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Release-name words a subtitle must not contain.";
      };
      originalFormat = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Keep subtitles in their original format instead of converting to SRT. `null` uses Bazarr's global setting.";
      };
      tag = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Sonarr/Radarr tag that selects this profile, when tag-based profiles are enabled in Bazarr.";
      };
    };
  };

  wantedSearchFrequencyType = types.nullOr (types.enum [6 12 24 168 876000]);

  sonarrConfigModule = {
    options = {
      ip = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "IP address or hostname of the Sonarr server.";
      };
      port = mkOption {
        type = types.port;
        default = nixarr.sonarr.port;
        defaultText = literalExpression "nixarr.sonarr.port";
        description = "Port of the Sonarr server.";
      };
      base_url = mkOption {
        type = types.str;
        default = config.services.sonarr.settings.server.urlBase or "";
        defaultText = literalExpression ''config.services.sonarr.settings.server.urlBase or ""'';
        description = "URL base of Sonarr, such as `/sonarr`. Bazarr adds a missing leading slash.";
      };
      ssl = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to use SSL when connecting to Sonarr.";
      };
      apiKeyFile = mkOption {
        type = types.path;
        default = "${nixarr.stateDir}/secrets/sonarr.api-key";
        defaultText = literalExpression ''"''${nixarr.stateDir}/secrets/sonarr.api-key"'';
        description = ''
          Path to file containing the API key for Sonarr.
        '';
      };
      sync_only_monitored_series = mkOption {
        type = types.bool;
        default = false;
        description = "Only sync monitored series from Sonarr.";
      };
      sync_only_monitored_episodes = mkOption {
        type = types.bool;
        default = false;
        description = "Only sync monitored episodes from Sonarr.";
      };
    };
  };

  radarrConfigModule = {
    options = {
      ip = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "IP address or hostname of the Radarr server.";
      };
      port = mkOption {
        type = types.port;
        default = nixarr.radarr.port;
        defaultText = literalExpression "nixarr.radarr.port";
        description = "Port of the Radarr server.";
      };
      base_url = mkOption {
        type = types.str;
        default = config.services.radarr.settings.server.urlBase or "";
        defaultText = literalExpression ''config.services.radarr.settings.server.urlBase or ""'';
        description = "URL base of Radarr, such as `/radarr`. Bazarr adds a missing leading slash.";
      };
      ssl = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to use SSL when connecting to Radarr.";
      };
      apiKeyFile = mkOption {
        type = types.path;
        default = "${nixarr.stateDir}/secrets/radarr.api-key";
        defaultText = literalExpression ''"''${nixarr.stateDir}/secrets/radarr.api-key"'';
        description = ''
          Path to file containing the API key for Radarr.
        '';
      };
      sync_only_monitored_movies = mkOption {
        type = types.bool;
        default = false;
        description = "Only sync monitored movies from Radarr.";
      };
    };
  };
in {
  options = {
    nixarr.bazarr.settings-sync = {
      sonarr = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Automatically configure Sonarr connection in Bazarr.
          '';
        };
        config = mkOption {
          type = types.submodule sonarrConfigModule;
          default = {};
          description = ''
            Configuration for Sonarr connection in Bazarr.
          '';
        };
      };

      radarr = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Automatically configure Radarr connection in Bazarr.
          '';
        };
        config = mkOption {
          type = types.submodule radarrConfigModule;
          default = {};
          description = ''
            Configuration for Radarr connection in Bazarr.
          '';
        };
      };

      languages = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["en"];
        description = ''
          Bazarr language codes to enable. When non-empty, these are exactly
          the enabled languages and every other language is disabled. When
          empty, Bazarr's enabled languages are left alone.
        '';
      };

      languageProfiles = mkOption {
        type = types.attrsOf (types.submodule languageProfileModule);
        default = {};
        example = literalExpression ''
          {
            English.items = [{language = "en";}];
          }
        '';
        description = ''
          Bazarr language profiles, keyed by profile name. A declared profile
          keeps the id of an existing profile with the same name, so items
          already using it keep it. Profiles created in the UI under other
          names are left alone, and so is a profile removed from this option:
          delete it in the UI. The sync fails if Bazarr has two profiles with
          a declared profile's name. Declared profiles have no cutoff, and the
          sync resets one set in the UI.
        '';
      };

      defaultProfile = {
        series = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "English";
          description = ''
            Name of a profile in `languageProfiles` that Bazarr gives to
            series the first time it syncs them from Sonarr. Bazarr only
            applies it to new series; see `assignDefaultProfileToUnassigned`
            for series it already knows about. `null` leaves Bazarr's setting
            alone.
          '';
        };
        movies = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "English";
          description = ''
            Like `defaultProfile.series`, for movies synced from Radarr.
          '';
        };
      };

      assignDefaultProfileToUnassigned = mkOption {
        type = types.bool;
        default = false;
        description = ''
          On every sync, give the default profile to each series and movie
          Bazarr already knows about that has no profile. Use this to bring
          an existing install in line; note that it also undoes a "no
          profile" choice made in the UI.
        '';
      };

      providers = {
        enabled = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          example = ["opensubtitlescom" "gestdown"];
          description = ''
            Subtitle providers to enable, by Bazarr's provider key. When set,
            this is the exact list. `null` leaves Bazarr's list alone.
          '';
        };
        settings = mkOption {
          type = types.attrsOf arrFieldsType;
          default = {};
          example = literalExpression ''
            {
              opensubtitlescom = {
                username.secret = "/run/secrets/opensubtitles/username";
                password.secret = "/run/secrets/opensubtitles/password";
                use_hash = true;
              };
            }
          '';
          description = ''
            Provider settings, keyed by provider and then by Bazarr setting
            name (the `<provider>.<key>` entries in Bazarr's `config.yaml`).
            Use `{ secret = "/path"; }` for credentials: the file is read at
            sync time and must be readable by the Bazarr user.
          '';
        };
      };

      wantedSearchFrequency = {
        series = mkOption {
          type = wantedSearchFrequencyType;
          default = null;
          example = 6;
          description = ''
            Hours between Bazarr's searches for missing episode subtitles.
            876000 (100 years) turns the search off, as Bazarr's UI does.
            `null` leaves Bazarr's setting alone (its default is 6).
          '';
        };
        movies = mkOption {
          type = wantedSearchFrequencyType;
          default = null;
          example = 6;
          description = ''
            Hours between Bazarr's searches for missing movie subtitles.
            876000 (100 years) turns the search off, as Bazarr's UI does.
            `null` leaves Bazarr's setting alone (its default is 6).
          '';
        };
      };
    };
  };

  config = mkIf (nixarr.enable && nixarr.bazarr.enable && syncEnabled) {
    assertions = let
      profileNames = lib.attrNames cfg.languageProfiles;
      profileLanguages = lib.unique (lib.concatMap (p: map (i: i.language) p.items) (lib.attrValues cfg.languageProfiles));
      checkDefault = kind: name: {
        assertion = name != null -> lib.elem name profileNames;
        message = "nixarr.bazarr.settings-sync.defaultProfile.${kind} is \"${toString name}\", which is not a key of nixarr.bazarr.settings-sync.languageProfiles";
      };
    in [
      (checkDefault "series" cfg.defaultProfile.series)
      (checkDefault "movies" cfg.defaultProfile.movies)
      {
        assertion = lib.all (l: lib.elem l cfg.languages) profileLanguages;
        message = "nixarr.bazarr.settings-sync.languageProfiles uses languages ${toString (lib.subtractLists cfg.languages profileLanguages)} that are not in nixarr.bazarr.settings-sync.languages";
      }
      {
        assertion =
          lib.any (p: lib.any (i: i.type == "nonHi") p.items) (lib.attrValues cfg.languageProfiles)
          -> lib.versionAtLeast nixarr.bazarr.package.version "1.6.1";
        message = "nixarr.bazarr.settings-sync.languageProfiles uses type = \"nonHi\", which needs Bazarr 1.6.1 or later; nixarr.bazarr.package is ${nixarr.bazarr.package.version}";
      }
      {
        assertion = lib.all (p: p.items != []) (lib.attrValues cfg.languageProfiles);
        message = "Every profile in nixarr.bazarr.settings-sync.languageProfiles needs at least one item";
      }
      {
        assertion = cfg.assignDefaultProfileToUnassigned -> (cfg.defaultProfile.series != null || cfg.defaultProfile.movies != null);
        message = "nixarr.bazarr.settings-sync.assignDefaultProfileToUnassigned needs defaultProfile.series or defaultProfile.movies";
      }
      {
        assertion = cfg.sonarr.enable -> nixarr.sonarr.enable;
        message = "nixarr.bazarr.settings-sync.sonarr.enable requires nixarr.sonarr.enable to be true";
      }
      {
        assertion = cfg.radarr.enable -> nixarr.radarr.enable;
        message = "nixarr.bazarr.settings-sync.radarr.enable requires nixarr.radarr.enable to be true";
      }
    ];

    users.users.${globals.bazarr.user}.extraGroups =
      ["bazarr-api"]
      ++ (lib.optional cfg.sonarr.enable "sonarr-api")
      ++ (lib.optional cfg.radarr.enable "radarr-api");

    systemd.services.bazarr-sync-config = {
      description = ''
        Sync Bazarr configuration (Sonarr/Radarr connections, languages, profiles, providers)
      '';
      after = wantedServices;
      wants = wantedServices;
      wantedBy = ["bazarr.service"];
      serviceConfig = {
        Type = "oneshot";
        User = globals.bazarr.user;
        Group = globals.bazarr.group;
        RemainAfterExit = true;
        ExecStart = let
          config-file = writeJSON "bazarr-sync-config.json" ({
              bazarr_base_url = "http://127.0.0.1:${toString nixarr.bazarr.port}";
              bazarr_api_key_file = "${nixarr.stateDir}/secrets/bazarr.api-key";
              languages = cfg.languages;
              language_profiles = lib.mapAttrsToList (name: p: p // {inherit name;}) cfg.languageProfiles;
              default_profile = cfg.defaultProfile;
              assign_default_profile_to_unassigned = cfg.assignDefaultProfileToUnassigned;
              enabled_providers = cfg.providers.enabled;
              provider_settings = cfg.providers.settings;
              wanted_search_frequency = cfg.wantedSearchFrequency;
            }
            // lib.optionalAttrs cfg.sonarr.enable {sonarr = cfg.sonarr.config;}
            // lib.optionalAttrs cfg.radarr.enable {radarr = cfg.radarr.config;});
        in ''
          ${getExe sync-settings} --config-file ${config-file}
        '';
      };
    };
  };
}

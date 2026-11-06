{
  pkgs,
  nixosModules,
}:
pkgs.testers.runNixOSTest {
  name = "bazarr-sync-test";

  nodes.machine = {
    config,
    pkgs,
    ...
  }: {
    imports = [nixosModules.default];

    networking.firewall.enable = false;

    virtualisation.cores = 4; # one per service plus one for luck
    virtualisation.memorySize = 3072;

    environment.systemPackages = [pkgs.curl pkgs.jq pkgs.sqlite];

    # Stand-ins for secret files, outside the Nix store.
    systemd.tmpfiles.rules = [
      "d /run/bazarr-test-secrets 0750 bazarr root - -"
      "f /run/bazarr-test-secrets/os-username 0400 bazarr root - test-os-user"
      "f /run/bazarr-test-secrets/os-password 0400 bazarr root - test-os-password"
    ];

    # Non-default URL bases, as when the *arrs sit behind a reverse proxy.
    services.sonarr.settings.server.urlBase = "/sonarr";
    services.radarr.settings.server.urlBase = "/radarr";

    nixarr = {
      enable = true;

      bazarr = {
        enable = true;
        settings-sync = {
          sonarr = {
            enable = true;
            config = {
              sync_only_monitored_series = true;
              sync_only_monitored_episodes = true;
            };
          };
          radarr = {
            enable = true;
            config.sync_only_monitored_movies = true;
          };
          languages = ["en"];
          languageProfiles.English.items = [{language = "en";}];
          defaultProfile = {
            series = "English";
            movies = "English";
          };
          assignDefaultProfileToUnassigned = true;
          providers = {
            enabled = ["opensubtitlescom" "gestdown" "yifysubtitles"];
            settings.opensubtitlescom = {
              username.secret = "/run/bazarr-test-secrets/os-username";
              password.secret = "/run/bazarr-test-secrets/os-password";
              use_hash = true;
            };
          };
          wantedSearchFrequency = {
            series = 12;
            movies = 24;
          };
        };
      };

      sonarr = {
        enable = true;
        settings-sync.mediaManagement = {
          importExtraFiles = true;
          extraFileExtensions = "srt,ass,ssa,sub,idx,vtt,sup";
        };
      };

      radarr = {
        enable = true;
        settings-sync.mediaManagement = {
          importExtraFiles = true;
          extraFileExtensions = "srt,ass,ssa,sub,idx,vtt,sup";
        };
      };
    };
  };

  testScript = {nodes, ...}: let
    secretsDir = "${nodes.machine.nixarr.stateDir}/secrets";
  in ''
    import json

    machine.wait_for_unit("multi-user.target")

    machine.succeed("systemctl is-active bazarr")
    machine.succeed("systemctl is-active sonarr")
    machine.succeed("systemctl is-active radarr")

    machine.wait_for_unit("bazarr-api.service")
    machine.wait_for_unit("sonarr-api.service")
    machine.wait_for_unit("radarr-api.service")

    machine.wait_for_unit("bazarr-sync-config.service", timeout=120)
    machine.wait_for_unit("sonarr-sync-config.service", timeout=120)
    machine.wait_for_unit("radarr-sync-config.service", timeout=120)

    bazarr_key = machine.succeed("cat ${secretsDir}/bazarr.api-key").strip()
    sonarr_key = machine.succeed("cat ${secretsDir}/sonarr.api-key").strip()
    radarr_key = machine.succeed("cat ${secretsDir}/radarr.api-key").strip()

    def bazarr(path, method="GET", data=None):
        cmd = f"curl -sf -X {method} -H 'X-API-KEY: {bazarr_key}' 'http://127.0.0.1:6767/api{path}'"
        if data is not None:
            cmd += f" --data '{data}'"
        out = machine.succeed(cmd)
        return json.loads(out) if out.strip() else None

    def arr(base, key, path, method="GET", body=None):
        cmd = f"curl -sf -X {method} -H 'X-Api-Key: {key}' -H 'Content-Type: application/json' 'http://127.0.0.1:{base}/api/v3{path}'"
        if body is not None:
            cmd += f" --data '{json.dumps(body)}'"
        out = machine.succeed(cmd)
        return json.loads(out) if out.strip() else None

    with subtest("Bazarr settings were applied"):
        settings = bazarr("/system/settings")
        general = settings["general"]
        assert general["use_sonarr"] is True, general["use_sonarr"]
        assert general["use_radarr"] is True, general["use_radarr"]
        assert settings["sonarr"]["base_url"] == "/sonarr", settings["sonarr"]["base_url"]
        assert settings["radarr"]["base_url"] == "/radarr", settings["radarr"]["base_url"]
        assert settings["sonarr"]["apikey"] == sonarr_key
        assert settings["radarr"]["apikey"] == radarr_key
        assert sorted(general["enabled_providers"]) == ["gestdown", "opensubtitlescom", "yifysubtitles"], general["enabled_providers"]
        assert settings["opensubtitlescom"]["username"] == "test-os-user"
        assert settings["opensubtitlescom"]["password"] == "test-os-password"
        assert settings["opensubtitlescom"]["use_hash"] is True
        assert general["wanted_search_frequency"] == 12, general["wanted_search_frequency"]
        assert general["wanted_search_frequency_movie"] == 24, general["wanted_search_frequency_movie"]
        assert settings["sonarr"]["sync_only_monitored_series"] is True
        assert settings["sonarr"]["sync_only_monitored_episodes"] is True
        assert settings["radarr"]["sync_only_monitored_movies"] is True
        # A different setting (which items count as wanted), left at Bazarr's default.
        assert settings["sonarr"]["only_monitored"] is False
        assert settings["radarr"]["only_monitored"] is False

    with subtest("Languages and profiles"):
        enabled = [l["code2"] for l in bazarr("/system/languages") if l["enabled"]]
        assert enabled == ["en"], enabled
        profiles = bazarr("/system/languages/profiles")
        assert len(profiles) == 1, profiles
        english = profiles[0]
        assert english["name"] == "English"
        assert english["items"] == [{
            "id": 1, "language": "en", "hi": "False", "forced": "False",
            "audio_exclude": "False", "audio_only_include": "False",
        }], english["items"]
        general = bazarr("/system/settings")["general"]
        assert general["serie_default_enabled"] is True
        assert general["movie_default_enabled"] is True
        assert general["serie_default_profile"] == english["profileId"], general["serie_default_profile"]
        assert general["movie_default_profile"] == english["profileId"], general["movie_default_profile"]

    with subtest("Re-running the sync keeps the profile id and profiles made in the UI"):
        other = {
            "profileId": english["profileId"] + 1, "name": "Made in UI", "cutoff": None,
            "items": [{"id": 1, "language": "en", "hi": "True", "forced": "False",
                       "audio_exclude": "False", "audio_only_include": "False"}],
            "mustContain": ["foo"], "mustNotContain": [], "originalFormat": 1, "tag": None,
        }
        machine.succeed(
            f"curl -sf -X POST -H 'X-API-KEY: {bazarr_key}' 'http://127.0.0.1:6767/api/system/settings'"
            f" --data-urlencode 'languages-profiles={json.dumps([english, other])}'"
        )
        assert len(bazarr("/system/languages/profiles")) == 2
        machine.succeed("systemctl restart bazarr-sync-config.service")
        profiles = {p["name"]: p for p in bazarr("/system/languages/profiles")}
        assert sorted(profiles) == ["English", "Made in UI"], profiles
        assert profiles["English"] == english, profiles["English"]
        assert profiles["Made in UI"] == other, profiles["Made in UI"]
        machine.succeed(
            "journalctl -u bazarr-sync-config.service --since '-2min' | grep -q 'Language profiles unchanged'"
        )

    with subtest("Sonarr and Radarr import extra files"):
        for base, key in (("8989/sonarr", sonarr_key), ("7878/radarr", radarr_key)):
            mm = arr(base, key, "/config/mediamanagement")
            assert mm["importExtraFiles"] is True, (base, mm)
            assert mm["extraFileExtensions"] == "srt,ass,ssa,sub,idx,vtt,sup", (base, mm)

    with subtest("A series added to Sonarr afterwards gets the default profile"):
        # Adding a series through Sonarr's API needs its online metadata
        # service, which the test VM cannot reach, so write the row directly.
        machine.succeed("systemctl stop sonarr.service")
        machine.succeed(
            "sqlite3 ${nodes.machine.nixarr.sonarr.stateDir}/sonarr.db <<'EOF'\n"
            "INSERT INTO Series (TvdbId, TvRageId, Title, TitleSlug, CleanTitle, Status, Images, Path,"
            " Monitored, SeasonFolder, Runtime, SeriesType, UseSceneNumbering, Year, Seasons, Actors,"
            " Ratings, Genres, SortTitle, QualityProfileId, Tags, Added, TvMazeId, OriginalLanguage)"
            " VALUES (1, 0, 'Test Show', 'test-show', 'testshow', 0, '[]', '/srv/shows/Test Show',"
            " 1, 1, 0, 0, 0, 2020, '[]', '[]', '{\"votes\": 0, \"value\": 0}', '[]', 'test show',"
            " 1, '[]', '2026-01-01 00:00:00Z', 0, 1);\n"
            "EOF"
        )
        machine.succeed("systemctl start sonarr.service")
        sonarr_base = "8989/sonarr"
        machine.wait_until_succeeds(
            f"curl -sf -H 'X-Api-Key: {sonarr_key}' 'http://127.0.0.1:{sonarr_base}/api/v3/series' | jq -e 'length == 1'",
            timeout=180,
        )
        series = arr(sonarr_base, sonarr_key, "/series")
        sonarr_series_id = series[0]["id"]

        bazarr("/system/tasks", "POST", "taskid=update_series")
        machine.wait_until_succeeds(
            f"curl -sf -H 'X-API-KEY: {bazarr_key}' 'http://127.0.0.1:6767/api/series' | jq -e '.data | length == 1'",
            timeout=120,
        )
        bazarr_series = bazarr("/series")["data"]
        assert bazarr_series[0]["sonarrSeriesId"] == sonarr_series_id, bazarr_series
        assert bazarr_series[0]["profileId"] == english["profileId"], bazarr_series

    with subtest("assignDefaultProfileToUnassigned restores a removed profile"):
        bazarr("/series", "POST", f"seriesid={sonarr_series_id}&profileid=null")
        assert bazarr("/series")["data"][0]["profileId"] is None
        machine.succeed("systemctl restart bazarr-sync-config.service")
        assert bazarr("/series")["data"][0]["profileId"] == english["profileId"]

    print("\n=== Bazarr Sync Test Completed ===")
  '';
}

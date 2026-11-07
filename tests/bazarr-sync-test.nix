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
          rescanAfterDownload = true;
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
    import re
    import shlex

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
        assert general["use_postprocessing"] is True
        assert "nixarr-bazarr-rescan-arr" in general["postprocessing_cmd"], general["postprocessing_cmd"]
        assert general["use_postprocessing_threshold"] is False
        assert general["use_postprocessing_threshold_movie"] is False

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

    def run_like_bazarr(series_id, episode_id):
        # As Bazarr 1.6.1 does (utilities/post_processing.py, subtitles/post_processing.py):
        # substitute each placeholder with the value in double quotes, split
        # with shlex, run without a shell, with the Bazarr process's credentials.
        template = bazarr("/system/settings")["general"]["postprocessing_cmd"]
        command = re.sub(r"""['"]?{{series_id}}['"]?""", lambda m: f'"{series_id}"', template)
        command = re.sub(r"""['"]?{{episode_id}}['"]?""", lambda m: f'"{episode_id}"', command)
        pid = machine.succeed("systemctl show -p MainPID --value bazarr.service").strip()
        status = machine.succeed(f"cat /proc/{pid}/status")
        fields = dict(line.split(":", 1) for line in status.splitlines() if ":" in line)
        uid = fields["Uid"].split()[0]
        gid = fields["Gid"].split()[0]
        groups = fields["Groups"].split()
        return machine.succeed(
            f"setpriv --reuid={uid} --regid={gid} --groups={','.join(groups)} -- "
            + shlex.join(shlex.split(command))
        )

    with subtest("Bazarr runs with the Sonarr and Radarr key groups"):
        pid = machine.succeed("systemctl show -p MainPID --value bazarr.service").strip()
        groups = machine.succeed(f"grep ^Groups: /proc/{pid}/status").split()[1:]
        for group in ("sonarr-api", "radarr-api"):
            group_id = machine.succeed(f"getent group {group} | cut -d: -f3").strip()
            assert group_id in groups, (group, group_id, groups)

    with subtest("The post-processing command makes Sonarr adopt a new subtitle"):
        season = "/srv/shows/Test Show/Season 01"
        machine.succeed(f"mkdir -p '{season}' && head -c 1024 /dev/zero > '{season}/Test Show - S01E01.mkv'")
        # An episode with a file Sonarr already tracks; as above, written directly.
        machine.succeed("systemctl stop sonarr.service")
        machine.succeed(
            "sqlite3 ${nodes.machine.nixarr.sonarr.stateDir}/sonarr.db <<'EOF'\n"
            "INSERT INTO EpisodeFiles (SeriesId, Quality, Size, DateAdded, SeasonNumber, RelativePath, Languages)"
            f" VALUES ({sonarr_series_id}, '{{\"quality\": 1, \"revision\": {{\"version\": 1, \"real\": 0, \"isRepack\": false}}}}',"
            " 1024, '2026-01-01 00:00:00Z', 1, 'Season 01/Test Show - S01E01.mkv', '[1]');\n"
            "INSERT INTO Episodes (SeriesId, SeasonNumber, EpisodeNumber, Title, EpisodeFileId, Monitored,"
            " UnverifiedSceneNumbering, Runtime, AirDate, AirDateUtc)"
            f" VALUES ({sonarr_series_id}, 1, 1, 'Pilot', last_insert_rowid(), 1, 0, 0, '2020-01-01', '2020-01-01 00:00:00Z');\n"
            "EOF"
        )
        machine.succeed("systemctl start sonarr.service")
        machine.wait_until_succeeds(
            f"curl -sf -H 'X-Api-Key: {sonarr_key}' 'http://127.0.0.1:{sonarr_base}/api/v3/episodefile?seriesId={sonarr_series_id}' | jq -e 'length == 1'",
            timeout=180,
        )
        subtitle_rows = "sqlite3 ${nodes.machine.nixarr.sonarr.stateDir}/sonarr.db 'SELECT RelativePath, Language FROM SubtitleFiles'"
        assert machine.succeed(subtitle_rows).strip() == "", "Sonarr tracks a subtitle before the test wrote one"

        # What Bazarr would have just written.
        machine.succeed(f"printf '1\\n00:00:01,000 --> 00:00:02,000\\nHello\\n' > '{season}/Test Show - S01E01.en.srt'")
        out = run_like_bazarr(sonarr_series_id, 1)
        assert f"Sonarr RescanSeries {sonarr_series_id}: command" in out, out
        machine.wait_until_succeeds(f"{subtitle_rows} | grep -qx 'Season 01/Test Show - S01E01.en.srt|1'", timeout=60)

    with subtest("The post-processing command asks Radarr for a movie, and skips missing ids"):
        # Bazarr passes an empty series id and the Radarr id as episode id for a movie.
        out = run_like_bazarr("", 7)
        assert "Radarr RescanMovie 7: command" in out, out
        commands = arr("7878/radarr", radarr_key, "/command")
        assert any(c["name"] == "RescanMovie" and c["body"].get("movieId") == 7 for c in commands), commands
        # For a movie subtitle uploaded in the UI, the series id is "None".
        out = run_like_bazarr("None", "")
        assert "nothing to rescan" in out, out

    print("\n=== Bazarr Sync Test Completed ===")
  '';
}

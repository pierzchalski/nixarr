from typing import Any, Literal
import argparse
import json
import logging
import pathlib
import urllib.error
import urllib.parse
import urllib.request

import pydantic

from nixarr_py.utils import expand_secret


logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class SonarrConfig(pydantic.BaseModel):
    ip: str = "127.0.0.1"
    port: int = 8989
    base_url: str = ""
    ssl: bool = False
    apiKeyFile: str = ""
    sync_only_monitored_series: bool = False
    sync_only_monitored_episodes: bool = False

    model_config = pydantic.ConfigDict(extra="allow")


class RadarrConfig(pydantic.BaseModel):
    ip: str = "127.0.0.1"
    port: int = 7878
    base_url: str = ""
    ssl: bool = False
    apiKeyFile: str = ""
    sync_only_monitored_movies: bool = False

    model_config = pydantic.ConfigDict(extra="allow")


class LanguageProfileItem(pydantic.BaseModel):
    language: str
    type: Literal["normal", "hi", "nonHi", "forced"] = "normal"
    search: Literal["always", "audioMatches", "noAudioMatches"] = "always"

    model_config = pydantic.ConfigDict(extra="forbid")

    def to_bazarr(self, item_id: int) -> dict[str, Any]:
        # Bazarr stores these flags as the strings "True"/"False" (and "Excluded"
        # for hi), matching what its own profile editor submits.
        hi = {"normal": "False", "hi": "True", "nonHi": "Excluded", "forced": "False"}[
            self.type
        ]
        return {
            "id": item_id,
            "language": self.language,
            "hi": hi,
            "forced": "True" if self.type == "forced" else "False",
            "audio_exclude": "True" if self.search == "noAudioMatches" else "False",
            "audio_only_include": "True" if self.search == "audioMatches" else "False",
        }


class LanguageProfile(pydantic.BaseModel):
    name: str
    items: list[LanguageProfileItem]
    mustContain: list[str] = []
    mustNotContain: list[str] = []
    originalFormat: bool | None = None
    tag: str | None = None

    model_config = pydantic.ConfigDict(extra="forbid")


class DefaultProfile(pydantic.BaseModel):
    series: str | None = None
    movies: str | None = None

    model_config = pydantic.ConfigDict(extra="forbid")


class WantedSearchFrequency(pydantic.BaseModel):
    series: int | None = None
    movies: int | None = None

    model_config = pydantic.ConfigDict(extra="forbid")


class SettingsSyncConfig(pydantic.BaseModel):
    bazarr_base_url: str
    bazarr_api_key_file: str
    sonarr: SonarrConfig | None = None
    radarr: RadarrConfig | None = None
    languages: list[str] = []
    language_profiles: list[LanguageProfile] = []
    default_profile: DefaultProfile = DefaultProfile()
    assign_default_profile_to_unassigned: bool = False
    enabled_providers: list[str] | None = None
    provider_settings: dict[str, dict[str, Any]] = {}
    wanted_search_frequency: WantedSearchFrequency = WantedSearchFrequency()

    model_config = pydantic.ConfigDict(extra="forbid")


class BazarrApi:
    def __init__(self, base_url: str, api_key: str) -> None:
        self.base_url = base_url
        self.api_key = api_key

    def request(
        self,
        endpoint: str,
        method: str = "GET",
        form: list[tuple[str, str]] | None = None,
    ) -> Any:
        """Call the Bazarr API. Bazarr's write endpoints read form fields, not JSON."""
        url = f"{self.base_url}/api{endpoint}"
        headers = {"X-API-KEY": self.api_key}
        data = None
        if form is not None:
            data = urllib.parse.urlencode(form).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=600) as response:
                body = response.read().decode("utf-8")
                return json.loads(body) if body else None
        except urllib.error.HTTPError as e:
            error_body = e.read().decode("utf-8") if e.fp else ""
            raise RuntimeError(
                f"HTTP {e.code} from {method} {url}: {error_body}"
            ) from e


def form_value(value: Any) -> list[str]:
    """Encode a setting value the way Bazarr's settings form does."""
    value = expand_secret(value)
    if isinstance(value, bool):
        return ["true" if value else "false"]
    if isinstance(value, list):
        # Bazarr reads an array setting from repeated fields; a single empty
        # field means an empty list.
        return [str(v) for v in value] if value else [""]
    return [str(value)]


def add_setting(
    form: list[tuple[str, str]], section: str, key: str, value: Any
) -> None:
    for v in form_value(value):
        form.append((f"settings-{section}-{key}", v))


def read_key(path: str) -> str:
    with open(path, "r", encoding="utf-8") as f:
        return f.read().strip()


PROFILE_FIELDS = (
    "profileId",
    "name",
    "cutoff",
    "items",
    "mustContain",
    "mustNotContain",
    "originalFormat",
    "tag",
)


def build_profiles(
    declared: list[LanguageProfile], existing: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    """
    Merge declared profiles into Bazarr's existing list.

    Bazarr replaces its whole profile set with what is posted, so undeclared
    profiles are posted back unchanged. A declared profile reuses the id of an
    existing profile with the same name.
    """
    declared_names = {p.name for p in declared}
    existing_names = [p["name"] for p in existing]
    duplicated = sorted(
        {
            n
            for n in existing_names
            if n in declared_names and existing_names.count(n) > 1
        }
    )
    if duplicated:
        raise ValueError(
            f"Bazarr has more than one profile named {duplicated}; rename all but "
            "one in Bazarr so the declared profile has a single match."
        )
    ids_by_name = {p["name"]: p["profileId"] for p in existing}
    next_id = max([p["profileId"] for p in existing], default=0) + 1

    merged = [p for p in existing if p["name"] not in declared_names]
    for profile in declared:
        if profile.name not in ids_by_name:
            ids_by_name[profile.name] = next_id
            next_id += 1
        merged.append(
            {
                "profileId": ids_by_name[profile.name],
                "name": profile.name,
                "cutoff": None,
                "items": [
                    item.to_bazarr(i + 1) for i, item in enumerate(profile.items)
                ],
                "mustContain": profile.mustContain,
                "mustNotContain": profile.mustNotContain,
                "originalFormat": profile.originalFormat,
                "tag": profile.tag,
            }
        )
    return merged, ids_by_name


def profiles_differ(
    profiles: list[dict[str, Any]], existing: list[dict[str, Any]]
) -> bool:
    def normalize(profile: dict[str, Any]) -> dict[str, Any]:
        normalized = {k: profile.get(k) for k in PROFILE_FIELDS}
        # Bazarr stores originalFormat as an integer.
        if normalized["originalFormat"] is not None:
            normalized["originalFormat"] = int(normalized["originalFormat"])
        return normalized

    def key(profile_list: list[dict[str, Any]]) -> list[str]:
        return sorted(json.dumps(normalize(p), sort_keys=True) for p in profile_list)

    return key(profiles) != key(existing)


def build_settings_form(
    config: SettingsSyncConfig, api: BazarrApi
) -> tuple[list[tuple[str, str]], dict[str, int]]:
    form: list[tuple[str, str]] = []
    ids_by_name: dict[str, int] = {}

    if config.languages:
        known = {lang["code2"] for lang in api.request("/system/languages") or []}
        unknown = sorted(set(config.languages) - known)
        if unknown:
            raise ValueError(
                f"Bazarr does not know these language codes: {unknown}. "
                "Use the code2 values from GET /api/system/languages."
            )
    for code in config.languages:
        form.append(("languages-enabled", code))

    if config.language_profiles:
        existing = api.request("/system/languages/profiles") or []
        profiles, ids_by_name = build_profiles(config.language_profiles, existing)
        # Posting profiles makes Bazarr recompute missing subtitles for the
        # whole library before it answers, so skip it when nothing changed.
        if profiles_differ(profiles, existing):
            form.append(("languages-profiles", json.dumps(profiles)))
        else:
            logger.info("Language profiles unchanged")

    for kind, prefix in (("series", "serie"), ("movies", "movie")):
        name = getattr(config.default_profile, kind)
        if name is not None:
            add_setting(form, "general", f"{prefix}_default_enabled", True)
            add_setting(form, "general", f"{prefix}_default_profile", ids_by_name[name])

    if config.enabled_providers is not None:
        add_setting(form, "general", "enabled_providers", config.enabled_providers)

    for provider, settings in config.provider_settings.items():
        for key, value in settings.items():
            add_setting(form, provider, key, value)

    if config.wanted_search_frequency.series is not None:
        add_setting(
            form,
            "general",
            "wanted_search_frequency",
            config.wanted_search_frequency.series,
        )
    if config.wanted_search_frequency.movies is not None:
        add_setting(
            form,
            "general",
            "wanted_search_frequency_movie",
            config.wanted_search_frequency.movies,
        )

    # All of this goes in one request: Bazarr stores the profiles and default
    # profile before it reconnects to Sonarr/Radarr, and that reconnect starts
    # the first sync, which is the only time new items get the default profile.
    if config.sonarr is not None:
        sonarr = config.sonarr
        add_setting(form, "general", "use_sonarr", True)
        add_setting(form, "sonarr", "ip", sonarr.ip)
        add_setting(form, "sonarr", "port", sonarr.port)
        add_setting(form, "sonarr", "base_url", sonarr.base_url)
        add_setting(form, "sonarr", "ssl", sonarr.ssl)
        add_setting(
            form,
            "sonarr",
            "apikey",
            read_key(sonarr.apiKeyFile) if sonarr.apiKeyFile else "",
        )
        add_setting(
            form,
            "sonarr",
            "sync_only_monitored_series",
            sonarr.sync_only_monitored_series,
        )
        add_setting(
            form,
            "sonarr",
            "sync_only_monitored_episodes",
            sonarr.sync_only_monitored_episodes,
        )

    if config.radarr is not None:
        radarr = config.radarr
        add_setting(form, "general", "use_radarr", True)
        add_setting(form, "radarr", "ip", radarr.ip)
        add_setting(form, "radarr", "port", radarr.port)
        add_setting(form, "radarr", "base_url", radarr.base_url)
        add_setting(form, "radarr", "ssl", radarr.ssl)
        add_setting(
            form,
            "radarr",
            "apikey",
            read_key(radarr.apiKeyFile) if radarr.apiKeyFile else "",
        )
        add_setting(
            form,
            "radarr",
            "sync_only_monitored_movies",
            radarr.sync_only_monitored_movies,
        )

    return form, ids_by_name


def assign_default_profile(
    api: BazarrApi, endpoint: str, id_field: str, form_id_field: str, profile_id: int
) -> None:
    items = (api.request(f"{endpoint}?start=0&length=-1") or {}).get("data", [])
    unassigned = [item[id_field] for item in items if item.get("profileId") is None]
    if not unassigned:
        logger.info(f"No unassigned items at {endpoint}")
        return
    form: list[tuple[str, str]] = []
    for item_id in unassigned:
        form.append((form_id_field, str(item_id)))
        form.append(("profileid", str(profile_id)))
    api.request(endpoint, method="POST", form=form)
    logger.info(
        f"Gave profile {profile_id} to {len(unassigned)} unassigned items at {endpoint}"
    )


def main(config: SettingsSyncConfig) -> None:
    api = BazarrApi(config.bazarr_base_url, read_key(config.bazarr_api_key_file))

    form, ids_by_name = build_settings_form(config, api)
    logger.info("Posting settings: %s", sorted({k for k, _ in form}))
    api.request("/system/settings", method="POST", form=form)
    logger.info("Bazarr settings synced")

    if config.assign_default_profile_to_unassigned:
        if (config.default_profile.series is not None and config.sonarr is None) or (
            config.default_profile.movies is not None and config.radarr is None
        ):
            logger.info(
                "assignDefaultProfileToUnassigned covers only the Sonarr/Radarr "
                "connections this module declares"
            )
        if config.default_profile.series is not None and config.sonarr is not None:
            assign_default_profile(
                api,
                "/series",
                "sonarrSeriesId",
                "seriesid",
                ids_by_name[config.default_profile.series],
            )
        if config.default_profile.movies is not None and config.radarr is not None:
            assign_default_profile(
                api,
                "/movies",
                "radarrId",
                "radarrid",
                ids_by_name[config.default_profile.movies],
            )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Sync user-provided Nixarr settings to Bazarr"
    )
    parser.add_argument(
        "--config-file",
        type=pathlib.Path,
        required=True,
        help="Path to a config file containing the settings to sync. Must be a JSON file matching the SettingsSyncConfig schema.",
    )
    args = parser.parse_args()
    with open(args.config_file) as f:
        config_json = f.read()
    config = SettingsSyncConfig.model_validate_json(config_json)
    main(config)

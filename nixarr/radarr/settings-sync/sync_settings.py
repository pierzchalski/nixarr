from typing import Any
import argparse
import json
import radarr
import pydantic
import pathlib
import logging
from nixarr_py.clients import radarr_client
from nixarr_py.utils import apply_config


logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class DownloadClient(pydantic.BaseModel):
    name: str
    implementation: str
    enable: bool = True
    fields: dict[str, Any] = {}

    model_config = pydantic.ConfigDict(extra="allow")

    def extras(self) -> dict[str, Any]:
        return self.__pydantic_extra__ if self.__pydantic_extra__ is not None else {}


class SettingsSyncConfig(pydantic.BaseModel):
    download_clients: list[DownloadClient] = []
    media_management: dict[str, Any] = {}

    model_config = pydantic.ConfigDict(extra="forbid")


def sync_download_clients(
    download_client_configs: list[DownloadClient], api_client: radarr.ApiClient
) -> None:
    dc_api = radarr.DownloadClientApi(api_client)
    download_clients_by_name = {dc.name: dc for dc in dc_api.list_download_client()}
    schemas_by_implementation = {
        schema.implementation: schema for schema in dc_api.list_download_client_schema()
    }

    for user_cfg in download_client_configs:
        logger.info(f"Syncing download client '{user_cfg.name}'")
        if user_cfg.name in download_clients_by_name:
            insert_or_update = "update"
            dc = download_clients_by_name[user_cfg.name]
            assert dc.implementation == user_cfg.implementation, (
                f"Cannot change implementation of existing download client '{user_cfg.name}' from '{dc.implementation}' to '{user_cfg.implementation}'. Please delete the existing download client first."
            )
        else:
            insert_or_update = "insert"
            dc = schemas_by_implementation[user_cfg.implementation]

        user_dict = user_cfg.model_dump()
        arr_dict = dc.model_dump()
        apply_config(user_src=user_dict, arr_dst=arr_dict)
        dc = radarr.DownloadClientResource.model_validate(arr_dict)

        if insert_or_update == "insert":
            dc_api.create_download_client(download_client_resource=dc)
        else:
            dc_api.update_download_client(id=dc.id, download_client_resource=dc)


def sync_media_management(
    user_settings: dict[str, Any], api_client: radarr.ApiClient
) -> None:
    if not user_settings:
        return
    logger.info(f"Syncing media management settings {sorted(user_settings)}")
    mm_api = radarr.MediaManagementConfigApi(api_client)
    # Read the raw JSON: a settings key this client's model does not know
    # would be silently dropped by a model round trip and reset on PUT.
    response = mm_api.get_media_management_config_without_preload_content()
    if not 200 <= response.status <= 299:
        raise RuntimeError(
            f"GET /config/mediamanagement returned HTTP {response.status}: "
            f"{response.data[:500]!r}"
        )
    current = json.loads(response.data)
    known = {
        field.alias or name
        for name, field in radarr.MediaManagementConfigResource.model_fields.items()
    }
    unknown_current = set(current) - known
    if unknown_current:
        raise RuntimeError(
            f"Radarr returned media management settings this client does not know, refusing to overwrite them: {sorted(unknown_current)}"
        )
    unknown_user = set(user_settings) - known
    if unknown_user:
        raise RuntimeError(
            f"Unknown Radarr media management settings: {sorted(unknown_user)}"
        )
    merged = radarr.MediaManagementConfigResource.from_dict(
        {**current, **user_settings}
    )
    mm_api.update_media_management_config(
        id=str(current["id"]), media_management_config_resource=merged
    )


def main(config: SettingsSyncConfig, api_client: radarr.ApiClient) -> None:
    sync_download_clients(config.download_clients, api_client)
    sync_media_management(config.media_management, api_client)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Sync user-provided Nixarr settings to Radarr"
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
    with radarr_client() as client:
        main(config, client)

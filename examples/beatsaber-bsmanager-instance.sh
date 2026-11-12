#!/bin/bash
# Starts a Beat Saber version installed by BSManager (e.g. a modded 1.40.8) with the same command
# BSManager 1.6 uses on Linux, so it can be added to Steam as a non-Steam VR shortcut and started
# from Steam Link. Edit the three paths below.
#
# Steam: Add a Non-Steam Game > this script; Properties: compatibility OFF (this script runs Proton
# itself), "Include in VR Library" ON.
INSTANCE="$HOME/BSManager/BSManager/BSInstances/1.40.8"         # BSManager > version folder
PREFIX="$HOME/BSManager/BSManager/SharedContent/compatdata"     # BSManager's Proton prefix (player data)
PROTON="$HOME/.local/share/Steam/steamapps/common/Proton - Experimental/proton"   # BSManager's Proton

export WINEDLLOVERRIDES="winhttp=n,b"                 # loads BSIPA, i.e. the mods
export STEAM_COMPAT_DATA_PATH="$PREFIX"
export STEAM_COMPAT_INSTALL_PATH="$INSTANCE"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
export STEAM_COMPAT_APP_ID=620980 SteamAppId=620980 SteamOverlayGameId=620980 SteamGameId=620980
export SteamEnv=1 OXR_NO_TEXTURE_SOURCE_ALPHA=1

cd "$INSTANCE" || exit 1
exec "$PROTON" run "$INSTANCE/Beat Saber.exe" --no-yeet "$@"    # --no-yeet: BSManager passes it for non-Steam builds

#!/bin/sh
# M1 Pro MacBook Pro installer bootstrap. Run on the Mac: sh install.sh [server URL]
# Downloads the installer and its metadata from your own install server (see README.md).
if true; then
    set -e
    if [ ! -e /System ]; then
        echo "This installer must be run from macOS (or recoveryOS)."
        exit 1
    fi
    export LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
    if ! curl --no-progress-meter file:/// >/dev/null 2>&1; then
        echo "Your version of cURL is too old. Installing requires at least macOS 26.5."
        exit 1
    fi
    if [ "$#" -gt 0 ]; then
        SERVER=$1
        shift
    else
        SERVER=${NEO_SERVER:-http://127.0.0.1:8000}
    fi
    SERVER=${SERVER%/}
    case "$SERVER" in
        http://*|https://*) ;;
        *)
            echo "Usage: sh install.sh [http://host:port]"
            exit 1
            ;;
    esac
    case "$SERVER" in
        https://*)
            CURL_SAFE='--proto =https --proto-redir =https'
            ;;
        http://*)
            CURL_SAFE='--max-redirs 0'
            http_host=${SERVER#http://}
            http_host=${http_host%%/*}
            case "$http_host" in
                *:*)
                    http_port=${http_host##*:}
                    case "$http_port" in
                        ''|*[!0-9]*) ;;
                        *) http_host=${http_host%:*} ;;
                    esac
                    ;;
            esac
            case "$http_host" in
                127.0.0.1|localhost|'[::1]') ;;
                *)
                    if [ "${NEO_ALLOW_HTTP:-}" != 1 ]; then
                        echo 'Plain HTTP is only allowed for a server on this Mac (127.0.0.1). Use https://, or set NEO_ALLOW_HTTP=1 if you trust every device on this network.'
                        exit 1
                    fi
                    printf 'Warning: downloading the installer over plain HTTP from %s; anyone on this network could tamper with it.\n' "$SERVER"
                    ;;
            esac
            ;;
    esac
    export DISTRO="SteamOS for M1 Pro MacBook Pro (unofficial)"
    export VERSION_FLAG=$SERVER/installer/latest
    export INSTALLER_BASE=$SERVER/installer
    export INSTALLER_DATA=$SERVER/installer/installer_data.json
    export REPO_BASE=$SERVER
    echo
    echo "Bootstrapping installer:"
    if ! TMP=$(mktemp -d /tmp/neo-install.XXXXXX); then
        echo "Cannot create a private staging directory in /tmp."
        exit 1
    fi
    cd "$TMP"
    echo "  Checking version..."
    if ! PKG_VER="$(curl $CURL_SAFE --fail --no-progress-meter -L "$VERSION_FLAG")"; then
        echo "Cannot reach the install server at $SERVER (expected $VERSION_FLAG)."
        exit 1
    fi
    echo "  Version: $PKG_VER"
    PKG="installer-$PKG_VER.tar.gz"
    echo "  Downloading..."
    curl $CURL_SAFE --no-progress-meter -L -o "$PKG" "$INSTALLER_BASE/$PKG"
    curl $CURL_SAFE --no-progress-meter -L -O "$INSTALLER_DATA"
    echo "  Extracting..."
    tar xf "$PKG"
    echo "  Initializing..."
    echo
    if [ "$USER" != "root" ]; then
        echo "The installer needs to run as root."
        echo "Please enter your sudo password if prompted."
        exec caffeinate -dis sudo -E ./install.sh "$@"
    else
        exec caffeinate -dis ./install.sh "$@"
    fi
fi

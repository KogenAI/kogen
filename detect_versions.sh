#!/bin/bash
# Detect Elixir and Erlang versions from project files

detect_versions() {
    local project_root="$1"

    # No default versions - fail if not detected
    ELIXIR_VERSION=""
    OTP_VERSION=""

    # Try to detect from .tool-versions (most common)
    if [ -f "$project_root/.tool-versions" ]; then
        local elixir_line=$(grep "^elixir" "$project_root/.tool-versions" 2>/dev/null)
        local erlang_line=$(grep "^erlang" "$project_root/.tool-versions" 2>/dev/null)

        if [ -n "$elixir_line" ]; then
            local raw_elixir=$(echo "$elixir_line" | awk '{print $2}')
            # Strip OTP suffix if present (e.g., "1.18.2-otp-27" -> "1.18.2")
            ELIXIR_VERSION=$(echo "$raw_elixir" | sed 's/-otp-[0-9]*//')
        fi

        if [ -n "$erlang_line" ]; then
            OTP_VERSION=$(echo "$erlang_line" | awk '{print $2}')

            # Check if this version is available
            if ! check_otp_availability "$OTP_VERSION"; then
                return 1 # Exit with error
            fi
        fi

        # Fail if either version is missing
        if [ -z "$ELIXIR_VERSION" ] || [ -z "$OTP_VERSION" ]; then
            echo "❌ ERROR: Incomplete version specification in .tool-versions"
            echo "   Required: both 'elixir' and 'erlang' entries"
            return 1
        fi

        echo "✅ Detected versions from .tool-versions:"
        echo "   Elixir: $ELIXIR_VERSION"
        echo "   Erlang/OTP: $OTP_VERSION"
        return 0
    fi

    # Fail if no version files found
    echo "❌ ERROR: No version specification found"
    echo ""
    echo "💡 Create .tool-versions with version specifications:"
    echo ""
    echo "📝 Example .tool-versions:"
    echo "   elixir 1.18.4"
    echo "   erlang 27.3.4"
    echo ""
    return 1
}

# Function to get the OTP major version (needed for paths)
get_otp_major() {
    echo "$OTP_VERSION" | cut -d'.' -f1
}

# Function to check if OTP version is available by testing the download URL
check_otp_availability() {
    local requested_version="$1"

    # Determine architecture and Ubuntu version (same logic as elixir-lang.org/install.sh)
    local arch
    case "$(uname -m)" in
    x86_64) arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *)
        echo "❌ ERROR: Unsupported architecture: $(uname -m)"
        echo "   Supported: x86_64, aarch64, arm64"
        return 1
        ;;
    esac

    local lts="24.04" # Default Ubuntu LTS used by the installer
    local url="https://builds.hex.pm/builds/otp/${arch}/ubuntu-${lts}/OTP-${requested_version}.tar.gz"

    echo "🔍 Checking availability of OTP ${requested_version}..."

    # Test if the URL exists with a HEAD request
    if curl --output /dev/null --silent --head --fail "$url" 2>/dev/null; then
        echo "✅ OTP ${requested_version} is available"
        return 0
    else
        echo "❌ ERROR: Erlang/OTP version $requested_version is not available as precompiled build"
        echo ""
        echo "🔗 Checked URL: $url"
        echo ""
        echo "💡 Try checking available versions at:"
        echo "   https://builds.hex.pm/builds/otp/${arch}/ubuntu-${lts}/"
        echo ""
        echo "🔧 Common working versions to try:"
        echo "   • erlang 27.3.4"
        echo "   • erlang 26.2.5"
        echo "   • erlang 25.3.2"
        echo ""
        echo "💡 Please update your .tool-versions file with an available version."
        echo ""
        return 1
    fi
}

# Function to generate the Elixir install path
get_elixir_path() {
    # Check if ELIXIR_VERSION already contains OTP info
    if [[ "$ELIXIR_VERSION" == *"-otp-"* ]]; then
        # Version already has OTP suffix (e.g., "1.18.2-otp-27")
        echo "/home/ubuntu/.elixir-install/installs/elixir/${ELIXIR_VERSION}"
    else
        # Version needs OTP suffix added (e.g., "1.18.4" -> "1.18.4-otp-27")
        local otp_major=$(get_otp_major)
        echo "/home/ubuntu/.elixir-install/installs/elixir/${ELIXIR_VERSION}-otp-${otp_major}"
    fi
}

# Function to generate the OTP install path
get_otp_path() {
    echo "/home/ubuntu/.elixir-install/installs/otp/${OTP_VERSION}"
}

# Export versions for use in other scripts
export_versions() {
    export ELIXIR_VERSION
    export OTP_VERSION
    export OTP_MAJOR=$(get_otp_major)
    export ELIXIR_PATH=$(get_elixir_path)
    export OTP_PATH=$(get_otp_path)
    export MIX_PATH="${ELIXIR_PATH}/bin/mix"
    export ELIXIR_BIN_PATH="${ELIXIR_PATH}/bin"
    export OTP_BIN_PATH="${OTP_PATH}/bin"
}

# If called directly, detect and export
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    detect_versions "${1:-.}"
    export_versions

    echo ""
    echo "Exported environment variables:"
    echo "  ELIXIR_VERSION=$ELIXIR_VERSION"
    echo "  OTP_VERSION=$OTP_VERSION"
    echo "  OTP_MAJOR=$OTP_MAJOR"
    echo "  ELIXIR_PATH=$ELIXIR_PATH"
    echo "  MIX_PATH=$MIX_PATH"
fi

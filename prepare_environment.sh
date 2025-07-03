#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/utils.sh"

REPO_ROOT="$TARGET_REPO_PATH"

echo "🔧 Preparing development environment..."
echo "📁 Project: $REPO_ROOT"

# Check if .tool-versions exists
if [ ! -f "$REPO_ROOT/.tool-versions" ]; then
    echo "❌ No .tool-versions file found in project root"
    echo "   Create a .tool-versions file with your desired Elixir and Erlang versions"
    echo "   Example:"
    echo "   erlang 26.2.5"
    echo "   elixir 1.16.3-otp-26"
    exit 1
fi

echo "✅ Found .tool-versions file"

cd "$REPO_ROOT"

echo "📋 Reading .tool-versions file:"
cat .tool-versions | while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    echo "   $line"
done

# Parse versions from .tool-versions
ERLANG_VERSION=""
ELIXIR_VERSION=""

while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # Parse tool and version
    tool=$(echo "$line" | awk '{print $1}')
    version=$(echo "$line" | awk '{print $2}')

    if [ -z "$tool" ] || [ -z "$version" ]; then
        echo "⚠️  Skipping invalid line: $line"
        continue
    fi

    case "$tool" in
    erlang)
        ERLANG_VERSION="$version"
        ;;
    elixir)
        ELIXIR_VERSION="$version"
        ;;
    esac
done <.tool-versions

if [ -z "$ELIXIR_VERSION" ]; then
    echo "❌ Could not find elixir version in .tool-versions"
    echo "   Required format:"
    echo "   elixir 1.16.3-otp-26"
    exit 1
fi

# Extract OTP version from elixir version string
OTP_VERSION=""
ELIXIR_VERSION_ONLY=""
if [[ "$ELIXIR_VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-otp-([0-9]+)$ ]]; then
    ELIXIR_VERSION_ONLY="${BASH_REMATCH[1]}"
    OTP_VERSION="${BASH_REMATCH[2]}"
else
    echo "❌ Could not extract version from elixir version: $ELIXIR_VERSION"
    echo "   Expected format: elixir 1.16.3-otp-26"
    exit 1
fi

echo ""
echo "🔨 Installing Elixir $ELIXIR_VERSION (OTP $OTP_VERSION)..."

# Use official Elixir installer script
INSTALLS_DIR="$HOME/.elixir-install/installs"
mkdir -p "$INSTALLS_DIR"

# Download and run official installer
curl -fsSO https://elixir-lang.org/install.sh
chmod +x install.sh

# Install with specified versions
if [ -n "$ERLANG_VERSION" ]; then
    # Use specific erlang version from .tool-versions
    ./install.sh "elixir@${ELIXIR_VERSION_ONLY}" "otp@${ERLANG_VERSION}"
else
    # Fall back to just OTP major version
    ./install.sh "elixir@${ELIXIR_VERSION_ONLY}" "otp@${OTP_VERSION}"
fi

# Set up environment variables
ELIXIR_BIN_PATH="$INSTALLS_DIR/elixir/${ELIXIR_VERSION_ONLY}-otp-${OTP_VERSION}/bin"
if [ -n "$ERLANG_VERSION" ]; then
    OTP_BIN_PATH="$INSTALLS_DIR/otp/${ERLANG_VERSION}/bin"
else
    # Find the actual OTP directory that was installed
    OTP_BIN_PATH="$INSTALLS_DIR/otp/${OTP_VERSION}"*/bin
    OTP_BIN_PATH=$(echo $OTP_BIN_PATH | awk '{print $1}') # Get first match
fi

# Update PATH for current session
export PATH="$ELIXIR_BIN_PATH:$OTP_BIN_PATH:$PATH"

# Add to .bashrc
BASHRC="$HOME/.bashrc"

if [ -f "$BASHRC" ]; then
    # Create a clean version of bashrc without ANY OCG-related content
    # Use awk to remove multi-line blocks that contain OCG-related patterns
    awk '
    BEGIN { skip = 0; buffer = "" }
    {
        # Check if this line starts an OCG-related block
        if (/Elixir and Erlang \(Optimum Codegen\)|Auto-source \.env in OCG workspaces|elixir-install/) {
            skip = 1
        }
        
        # If we see the workspace check pattern, skip the entire if block
        if (/if \[\[ "\$PWD" =~ \/codegen\/workspaces\// ) {
            skip = 1
            depth = 1
        }
        
        # Track if/fi depth when skipping
        if (skip && depth > 0) {
            if (/^[[:space:]]*if[[:space:]]/) depth++
            if (/^[[:space:]]*fi[[:space:]]*$/) {
                depth--
                if (depth == 0) {
                    skip = 0
                    next
                }
            }
        }
        
        # Also skip standalone env sourcing lines
        if (/set -a.*source.*\.env.*set \+a/ || /source.*WORKSPACE_ROOT.*\.env/) {
            next
        }
        
        # If not skipping, add to buffer
        if (!skip) {
            if (buffer != "") buffer = buffer "\n"
            buffer = buffer $0
        }
    }
    END { 
        # Clean up multiple consecutive empty lines
        gsub(/\n\n\n+/, "\n\n", buffer)
        # Remove trailing newlines
        gsub(/\n+$/, "", buffer)
        print buffer
    }
    ' "$BASHRC" >"$BASHRC.tmp"

    mv "$BASHRC.tmp" "$BASHRC"

    # Add new entries
    echo "" >>"$BASHRC"
    echo "# Elixir and Erlang (Optimum Codegen)" >>"$BASHRC"
    echo "export PATH=\"$ELIXIR_BIN_PATH:$OTP_BIN_PATH:\$PATH\"" >>"$BASHRC"
    echo "" >>"$BASHRC"
    echo "# Auto-source .env in OCG workspaces" >>"$BASHRC"
    echo "if [[ \"\$PWD\" =~ /codegen/workspaces/ ]]; then" >>"$BASHRC"
    echo "    # Find the workspace root (the directory directly under workspaces/)" >>"$BASHRC"
    echo "    WORKSPACE_ROOT=\$(echo \"\$PWD\" | grep -o '.*/codegen/workspaces/[^/]*')" >>"$BASHRC"
    echo "    if [ -n \"\$WORKSPACE_ROOT\" ] && [ -f \"\$WORKSPACE_ROOT/.env\" ]; then" >>"$BASHRC"
    echo "        set -a" >>"$BASHRC"
    echo "        source \"\$WORKSPACE_ROOT/.env\"" >>"$BASHRC"
    echo "        set +a" >>"$BASHRC"
    echo "    fi" >>"$BASHRC"
    echo "fi" >>"$BASHRC"

    echo "✅ Updated PATH in $BASHRC"
else
    echo "⚠️  ~/.bashrc not found, PATH not updated"
fi

# Clean up installer script
rm -f install.sh

# Source .env file if it exists
if [ -f "$REPO_ROOT/.env" ]; then
    echo ""
    echo "📄 Sourcing .env file..."
    set -a
    source "$REPO_ROOT/.env"
    set +a
    echo "✅ Environment variables loaded from .env"
else
    echo "ℹ️  No .env file found in project root"
fi

# Verify installation
echo ""
echo "✅ Verifying installation..."

if command -v elixir >/dev/null 2>&1; then
    CURRENT_ELIXIR_VERSION=$(elixir --version | grep "Elixir" | awk '{print $2}')
    echo "   ✅ Elixir: $CURRENT_ELIXIR_VERSION"
else
    echo "   ❌ Elixir not found in PATH"
fi

if command -v erl >/dev/null 2>&1; then
    # Show the same version we installed
    if [ -n "$ERLANG_VERSION" ]; then
        echo "   ✅ Erlang/OTP: $ERLANG_VERSION"
    else
        # Fallback to major version
        CURRENT_ERLANG_VERSION=$(erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell | tr -d '"')
        echo "   ✅ Erlang/OTP: $CURRENT_ERLANG_VERSION"
    fi
else
    echo "   ❌ Erlang not found in PATH"
fi

if command -v mix >/dev/null 2>&1; then
    echo "   ✅ Mix available"
else
    echo "   ❌ Mix not found"
fi

echo ""
echo "🎉 Environment preparation complete!"
echo ""
echo "💡 Next step: Run $OCG_CMD new <feature-name> to create a workspace"

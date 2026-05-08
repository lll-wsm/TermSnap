#!/bin/bash

# TermSnap Build & Package Script
# This script automates the process of cleaning, building, and packaging the TermSnap app.

set -e

# --- Configuration ---
PROJECT_NAME="TermSnap"
SCHEME="TermSnap"
CONFIGURATION="Release" # Default to Release
BUILD_DIR="./build"
OUTPUT_DIR="${BUILD_DIR}/${CONFIGURATION}"

# --- Usage ---
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -c, --configuration [Debug|Release]  Set build configuration (default: Release)"
    echo "  -h, --help                          Show this help message"
    exit 1
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -c|--configuration) CONFIGURATION="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter: $1"; usage ;;
    esac
    shift
done

echo "🚀 Starting build for ${PROJECT_NAME} (${CONFIGURATION})..."

# 1. Clean build directory
echo "🧹 Cleaning..."
xcodebuild -project "${PROJECT_NAME}.xcodeproj" -scheme "${SCHEME}" -configuration "${CONFIGURATION}" clean

# 2. Build the project
echo "🏗️ Building..."
xcodebuild -project "${PROJECT_NAME}.xcodeproj" -scheme "${SCHEME}" -configuration "${CONFIGURATION}" build

# 3. Locate build artifact in DerivedData
echo "🔍 Locating build artifact..."
DERIVED_DATA_PATH=$(xcodebuild -project "${PROJECT_NAME}.xcodeproj" -scheme "${SCHEME}" -showBuildSettings | grep -m 1 "BUILD_DIR =" | awk '{print $3}')
# xcodebuild's BUILD_DIR setting points to the products dir inside DerivedData
# Typically: .../Build/Products
APP_PATH="${DERIVED_DATA_PATH}/${CONFIGURATION}/${PROJECT_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
    # Fallback search if the above fails
    echo "⚠️  Could not find app at ${APP_PATH}, searching DerivedData..."
    APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "${PROJECT_NAME}.app" -path "*/${CONFIGURATION}/*" -type d | head -n 1)
fi

if [ -z "$APP_PATH" ]; then
    echo "❌ Error: Could not find ${PROJECT_NAME}.app"
    exit 1
fi

echo "✅ Found app at: ${APP_PATH}"

# 4. Copy to local build directory
echo "📦 Packaging to ${OUTPUT_DIR}..."
mkdir -p "${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}/${PROJECT_NAME}.app" # Ensure a clean copy
cp -R "${APP_PATH}" "${OUTPUT_DIR}/"

# 5. Register with Launch Services (The "Xcode Magic")
echo "🧪 Registering with Launch Services..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "${OUTPUT_DIR}/${PROJECT_NAME}.app"

# 6. Optional: Restart Finder to force refresh
echo "🔄 Refreshing Finder..."
killall Finder || true

echo "✨ Success! The packaged app is available at:"
echo "👉 ${OUTPUT_DIR}/${PROJECT_NAME}.app"
echo "💡 Note: If the menu doesn't appear, try opening the App once."

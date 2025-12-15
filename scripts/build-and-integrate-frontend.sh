#!/bin/bash
# Build and integrate React frontend with Antora supplemental UI

set -e

# Get the directory where the script is located
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Wiping out old Antora site..."
cd "$PROJECT_ROOT"
rm -rf www

echo "Regenerating Antora documentation site..."
npx antora default-site.yml

# Note: chatbot.hbs partial already exists in content/supplemental-ui/partials/
# and is checked into git. No need to generate it.

echo ""
echo "Building React frontend directly into www/ai-assistant/..."
cd "$PROJECT_ROOT/frontend"
NEXT_BUILD_DIR=../www/ai-assistant npm run build

echo ""
echo "✓ Frontend integration complete!"
echo "✓ Antora site regenerated"

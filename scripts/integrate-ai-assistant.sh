#!/bin/bash

set -e

# Script to integrate the AI Assistant into a target showroom repository
# Usage: ./integrate-ai-assistant.sh --target /path/to/target/repo

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse arguments
TARGET_DIR=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --target)
      TARGET_DIR="$2"
      shift 2
      ;;
    *)
      echo -e "${RED}Error: Unknown option $1${NC}"
      echo "Usage: $0 --target <directory>"
      exit 1
      ;;
  esac
done

# Validate target directory
if [[ -z "$TARGET_DIR" ]]; then
  echo -e "${RED}Error: --target option is required${NC}"
  echo "Usage: $0 --target <directory>"
  exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
  echo -e "${RED}Error: Target directory does not exist: $TARGET_DIR${NC}"
  exit 1
fi

# Check for default-site.yml
TARGET_SITE_YML="$TARGET_DIR/default-site.yml"
if [[ ! -f "$TARGET_SITE_YML" ]]; then
  echo -e "${RED}Error: default-site.yml not found in target directory: $TARGET_DIR${NC}"
  exit 1
fi

# Check for yq
if ! command -v yq &> /dev/null; then
  echo -e "${RED}Error: yq is not installed. Please install it first.${NC}"
  echo "  brew install yq    # macOS"
  echo "  or visit: https://github.com/mikefarah/yq"
  exit 1
fi

# Get the source directory (where this script is located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${GREEN}AI Assistant Integration Script${NC}"
echo "Source: $SOURCE_DIR"
echo "Target: $TARGET_DIR"
echo ""

# Function to copy directory excluding build artifacts
copy_directory() {
  local src="$1"
  local dest="$2"
  local name="$3"

  echo -e "${YELLOW}Copying $name...${NC}"

  if [[ ! -d "$src" ]]; then
    echo -e "${RED}  Warning: Source directory not found: $src${NC}"
    return
  fi

  # Create parent directory if needed
  mkdir -p "$(dirname "$dest")"

  # Use rsync to copy, using .gitignore if available
  if [[ -f "$SOURCE_DIR/.gitignore" ]]; then
    rsync -av \
      --exclude-from="$SOURCE_DIR/.gitignore" \
      --exclude='.git' \
      "$src/" "$dest/"
  else
    # Fallback to hardcoded exclusions if no .gitignore
    rsync -av \
      --exclude='.next' \
      --exclude='out' \
      --exclude='node_modules' \
      --exclude='__pycache__' \
      --exclude='*.pyc' \
      --exclude='.DS_Store' \
      --exclude='package-lock.json' \
      --exclude='www' \
      --exclude='.git' \
      "$src/" "$dest/"
  fi

  echo -e "${GREEN}  ✓ Copied $name${NC}"
}

# Function to copy a single file
copy_file() {
  local src="$1"
  local dest="$2"
  local name="$3"

  echo -e "${YELLOW}Copying $name...${NC}"

  if [[ ! -f "$src" ]]; then
    echo -e "${RED}  Warning: Source file not found: $src${NC}"
    return
  fi

  # Create parent directory if needed
  mkdir -p "$(dirname "$dest")"

  cp "$src" "$dest"
  echo -e "${GREEN}  ✓ Copied $name${NC}"
}

# 1. Copy backend directory
copy_directory "$SOURCE_DIR/backend" "$TARGET_DIR/backend" "backend"

# 2. Copy config directory
copy_directory "$SOURCE_DIR/config" "$TARGET_DIR/config" "config"

# 3. Copy frontend directory (excluding build artifacts)
copy_directory "$SOURCE_DIR/frontend" "$TARGET_DIR/frontend" "frontend"

# 4. Copy k8s directory
copy_directory "$SOURCE_DIR/k8s" "$TARGET_DIR/k8s" "k8s"

# 5. Copy scripts directory
copy_directory "$SOURCE_DIR/scripts" "$TARGET_DIR/scripts" "scripts"

# 6. Copy .env.yaml.example
copy_file "$SOURCE_DIR/.env.yaml.example" "$TARGET_DIR/.env.yaml.example" ".env.yaml.example"

# 7. Copy Dockerfile.backend
copy_file "$SOURCE_DIR/Dockerfile.backend" "$TARGET_DIR/Dockerfile.backend" "Dockerfile.backend"

# 8. Copy Antora extensions
copy_file "$SOURCE_DIR/content/lib/ai-assistant-build.js" "$TARGET_DIR/content/lib/ai-assistant-build.js" "Antora extension: ai-assistant-build.js"
copy_file "$SOURCE_DIR/content/lib/rag-export.js" "$TARGET_DIR/content/lib/rag-export.js" "Antora extension: rag-export.js"

# 9. Copy supplemental-ui partials
echo -e "${YELLOW}Copying supplemental-ui partials...${NC}"
PARTIALS_DIR="$TARGET_DIR/content/supplemental-ui/partials"
mkdir -p "$PARTIALS_DIR"

SOURCE_PARTIALS="$SOURCE_DIR/content/supplemental-ui/partials"
if [[ -d "$SOURCE_PARTIALS" ]]; then
  for file in "$SOURCE_PARTIALS"/*; do
    if [[ -f "$file" ]]; then
      filename=$(basename "$file")
      copy_file "$file" "$PARTIALS_DIR/$filename" "partial: $filename"
    fi
  done
fi

echo -e "${GREEN}  ✓ Supplemental-ui partials copied${NC}"

# 10. Create techdocs directory and copy all SAMPLE files
echo -e "${YELLOW}Setting up techdocs...${NC}"
TECHDOCS_DIR="$TARGET_DIR/content/modules/ROOT/assets/techdocs"
mkdir -p "$TECHDOCS_DIR"

# Copy all SAMPLE* files from techdocs
SOURCE_TECHDOCS="$SOURCE_DIR/content/modules/ROOT/assets/techdocs"
if [[ -d "$SOURCE_TECHDOCS" ]]; then
  for file in "$SOURCE_TECHDOCS"/SAMPLE*; do
    if [[ -f "$file" ]]; then
      filename=$(basename "$file")
      copy_file "$file" "$TECHDOCS_DIR/$filename" "techdoc: $filename"
    fi
  done
fi

# Copy all SAMPLE* files from pages
PAGES_DIR="$TARGET_DIR/content/modules/ROOT/pages"
mkdir -p "$PAGES_DIR"

SOURCE_PAGES="$SOURCE_DIR/content/modules/ROOT/pages"
if [[ -d "$SOURCE_PAGES" ]]; then
  for file in "$SOURCE_PAGES"/SAMPLE*; do
    if [[ -f "$file" ]]; then
      filename=$(basename "$file")
      copy_file "$file" "$PAGES_DIR/$filename" "page: $filename"
    fi
  done
fi

echo -e "${GREEN}  ✓ Techdocs and sample pages setup complete${NC}"

# 11. Modify default-site.yml using yq
echo -e "${YELLOW}Modifying default-site.yml...${NC}"

# Force set supplemental_files
echo "  Setting ui.supplemental_files..."
yq eval -i '.ui.supplemental_files = "./content/supplemental-ui"' "$TARGET_SITE_YML"

# Add the ai-assistant-build extension if not already present
EXTENSION_EXISTS=$(yq eval '.antora.extensions[] | select(.require == "./content/lib/ai-assistant-build.js")' "$TARGET_SITE_YML")

if [[ -z "$EXTENSION_EXISTS" ]]; then
  echo "  Adding ai-assistant-build extension..."

  # Check if antora.extensions exists
  if yq eval '.antora.extensions' "$TARGET_SITE_YML" | grep -q "null"; then
    # Create the extensions array
    yq eval -i '.antora.extensions = []' "$TARGET_SITE_YML"
  fi

  # Add the extension
  yq eval -i '.antora.extensions += [{"require": "./content/lib/ai-assistant-build.js", "enabled": true}]' "$TARGET_SITE_YML"
else
  echo "  ai-assistant-build extension already exists, skipping..."
fi

# Add the rag-export extension if not already present
RAG_EXTENSION_EXISTS=$(yq eval '.antora.extensions[] | select(.require == "./content/lib/rag-export.js")' "$TARGET_SITE_YML")

if [[ -z "$RAG_EXTENSION_EXISTS" ]]; then
  echo "  Adding rag-export extension..."

  # Check if antora.extensions exists
  if yq eval '.antora.extensions' "$TARGET_SITE_YML" | grep -q "null"; then
    # Create the extensions array
    yq eval -i '.antora.extensions = []' "$TARGET_SITE_YML"
  fi

  # Add the extension with outputDir configuration
  yq eval -i '.antora.extensions += [{"require": "./content/lib/rag-export.js", "enabled": true, "outputDir": "./rag-content"}]' "$TARGET_SITE_YML"
else
  echo "  rag-export extension already exists, skipping..."
fi

echo -e "${GREEN}  ✓ default-site.yml updated${NC}"

echo ""
echo -e "${GREEN}✓ Integration complete!${NC}"
echo ""
echo -e "${GREEN}Summary of changes:${NC}"
echo "  • Added backend, config, frontend, k8s, scripts directories"
echo "  • Added .env.yaml.example and Dockerfile.backend"
echo "  • Added Antora extensions: ai-assistant-build.js, rag-export.js"
echo "  • Created techdocs directory with sample files"
echo "  • Updated default-site.yml with supplemental_files and extensions"
echo "  • Consult the README for next steps!"

#!/bin/bash
set -e

# Build MCP Router Core for macOS (Universal Binary)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/target/universal"

echo "Building MCP Router Core for macOS..."

cd "$PROJECT_DIR"

# Build for both architectures
echo "Building for x86_64..."
cargo build --release --target x86_64-apple-darwin

echo "Building for aarch64..."
cargo build --release --target aarch64-apple-darwin

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Create universal binary
echo "Creating universal binary..."
lipo -create \
    "target/x86_64-apple-darwin/release/libmcp_router_core.a" \
    "target/aarch64-apple-darwin/release/libmcp_router_core.a" \
    -output "$OUTPUT_DIR/libmcp_router_core.a"

# Also create dylib universal binary
lipo -create \
    "target/x86_64-apple-darwin/release/libmcp_router_core.dylib" \
    "target/aarch64-apple-darwin/release/libmcp_router_core.dylib" \
    -output "$OUTPUT_DIR/libmcp_router_core.dylib"

# Fix install_name for dylib (required for dlopen at runtime)
echo "Fixing dylib install_name..."
install_name_tool -id "@rpath/libmcp_router_core.dylib" "$OUTPUT_DIR/libmcp_router_core.dylib"

# Copy header
cp "$PROJECT_DIR/include/mcp_router_core.h" "$OUTPUT_DIR/"

# Copy Swift module
cp -r "$PROJECT_DIR/swift" "$OUTPUT_DIR/"

echo "Build complete!"
echo "Output directory: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"

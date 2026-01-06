#!/usr/bin/env bash
# ============================================================================
# mcp-router core 构建脚本
#
# 编译 Rust core 并部署到 Swift 项目目录
#
# 使用方式:
#   ./scripts/build-core.sh           # 构建并部署
#   ./scripts/build-core.sh release   # Release 模式构建
# ============================================================================
set -e

# 从脚本位置推断项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# 目录定义
CORE_DIR="$PROJECT_ROOT/core"
LIB_DIR="$PROJECT_ROOT/mcp-router/Lib"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[mcp-router]${NC} $*"; }
log_success() { echo -e "${GREEN}[mcp-router]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[mcp-router]${NC} $*"; }
log_error() { echo -e "${RED}[mcp-router]${NC} $*"; }

# ============================================================================
# 构建 Rust core
# ============================================================================
build_core() {
    local BUILD_MODE="${1:-release}"

    log_info "Building mcp-router-core ($BUILD_MODE)..."

    cd "$CORE_DIR"

    if [ "$BUILD_MODE" = "release" ]; then
        cargo build --release
        DYLIB="$CORE_DIR/target/release/libmcp_router_core.dylib"
    else
        cargo build
        DYLIB="$CORE_DIR/target/debug/libmcp_router_core.dylib"
    fi

    if [ ! -f "$DYLIB" ]; then
        log_error "dylib not found: $DYLIB"
        exit 1
    fi

    # 复制到 Lib 目录
    log_info "Copying to $LIB_DIR..."
    mkdir -p "$LIB_DIR"
    cp "$DYLIB" "$LIB_DIR/"

    # 复制头文件
    if [ -f "$CORE_DIR/include/mcp_router_core.h" ]; then
        cp "$CORE_DIR/include/mcp_router_core.h" "$LIB_DIR/"
    fi

    # 创建 module.modulemap
    cat > "$LIB_DIR/module.modulemap" << 'EOF'
module mcp_router_core {
    header "mcp_router_core.h"
    link "mcp_router_core"
    export *
}
EOF

    # 修改 dylib 的 install name
    log_info "Fixing install name..."
    install_name_tool -id "@rpath/libmcp_router_core.dylib" "$LIB_DIR/libmcp_router_core.dylib"

    # 重新签名 (使用开发者证书，与 app 保持一致)
    log_info "Re-signing..."
    # 尝试使用开发者证书，如果失败则使用 ad-hoc
    if codesign -f -s "Apple Development" "$LIB_DIR/libmcp_router_core.dylib" 2>/dev/null; then
        log_info "Signed with Apple Development certificate"
    else
        log_warn "Apple Development certificate not found, using ad-hoc signing"
        codesign -f -s - "$LIB_DIR/libmcp_router_core.dylib"
    fi

    log_success "Core built and deployed"
    log_info "dylib: $LIB_DIR/libmcp_router_core.dylib"

    # 显示 dylib 信息
    echo ""
    log_info "dylib info:"
    otool -L "$LIB_DIR/libmcp_router_core.dylib" | head -3
}

# ============================================================================
# 主逻辑
# ============================================================================
main() {
    local MODE="${1:-release}"

    log_info "mcp-router Core Build System"
    log_info "Root: $PROJECT_ROOT"
    echo ""

    build_core "$MODE"

    echo ""
    log_success "Build completed!"
}

main "$@"

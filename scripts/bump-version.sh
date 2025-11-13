#!/bin/bash

# 版本号自动更新脚本
# 自动更新 Xcode 项目版本号、创建 commit 和 git tag
#
# 注意：Build number (CURRENT_PROJECT_VERSION) 由 GitHub Actions 自动管理，无需手动更新
#
# 使用方法:
#   ./scripts/bump-version.sh 0.0.3           # 正式版
#   ./scripts/bump-version.sh 0.0.3-beta.1    # 预发布版

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 项目配置
PROJECT_FILE="mcp-router.xcodeproj/project.pbxproj"

# 检查参数
if [ -z "$1" ]; then
  echo -e "${RED}❌ 请提供版本号${NC}"
  echo "使用方法:"
  echo "  ./scripts/bump-version.sh 0.0.3           # 正式版"
  echo "  ./scripts/bump-version.sh 0.0.3-beta.1    # 预发布版"
  exit 1
fi

NEW_VERSION=$1

# 验证版本号格式（支持 semver 和 prerelease）
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
  echo -e "${RED}❌ 版本号格式不正确${NC}"
  echo "正确格式: X.Y.Z 或 X.Y.Z-prerelease"
  echo "示例: 1.0.0, 0.0.3-beta.1, 1.0.0-rc.2"
  exit 1
fi

# 检查 Git 工作区是否干净
if [ -n "$(git status --porcelain)" ]; then
  echo -e "${YELLOW}⚠️  Git 工作区有未提交的更改${NC}"
  echo "请先提交或暂存当前更改，然后再更新版本号"
  exit 1
fi

# 获取当前版本号
CURRENT_VERSION=$(grep -m 1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed 's/.*= "\(.*\)";/\1/')

echo -e "${BLUE}📊 版本信息${NC}"
echo "  当前版本: $CURRENT_VERSION"
echo "  新版本:   $NEW_VERSION"
echo ""
echo -e "${YELLOW}💡 Build number 将由 GitHub Actions 自动管理${NC}"
echo ""

# 询问确认
read -p "$(echo -e ${YELLOW}是否继续? [y/N]: ${NC})" -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${RED}❌ 已取消${NC}"
  exit 1
fi

# 更新版本号
echo -e "${GREEN}📝 更新 MARKETING_VERSION...${NC}"
sed -i '' "s/MARKETING_VERSION = \"$CURRENT_VERSION\"/MARKETING_VERSION = \"$NEW_VERSION\"/g" "$PROJECT_FILE"

# 验证更新
UPDATED_COUNT=$(grep -c "MARKETING_VERSION = \"$NEW_VERSION\"" "$PROJECT_FILE")

if [ "$UPDATED_COUNT" -ne 6 ]; then
  echo -e "${RED}❌ 版本号更新异常（预期 6 处，实际 $UPDATED_COUNT 处）${NC}"
  git checkout "$PROJECT_FILE"
  exit 1
fi

echo -e "${GREEN}✅ MARKETING_VERSION 已更新（6 处）${NC}"

# 创建 Git commit
echo -e "${GREEN}📦 创建 Git commit...${NC}"
git add "$PROJECT_FILE"
git commit -m "🔖 Bump version to $NEW_VERSION

- Update MARKETING_VERSION to $NEW_VERSION
- Build number will be auto-incremented by CI

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

COMMIT_HASH=$(git rev-parse --short HEAD)
echo -e "${GREEN}✅ Commit 已创建: $COMMIT_HASH${NC}"

# 创建 Git tag
echo -e "${GREEN}🏷️  创建 Git tag...${NC}"

# 判断是否为预发布版本
if [[ "$NEW_VERSION" =~ - ]]; then
  TAG_MESSAGE="Release v$NEW_VERSION (Pre-release)

This is a pre-release version for testing purposes.

Build number will be auto-incremented by GitHub Actions.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
else
  TAG_MESSAGE="Release v$NEW_VERSION

Build number will be auto-incremented by GitHub Actions.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
fi

git tag -a "v$NEW_VERSION" -m "$TAG_MESSAGE"
echo -e "${GREEN}✅ Tag 已创建: v$NEW_VERSION${NC}"

# 显示最近的 commits 和 tags
echo ""
echo -e "${BLUE}📋 最近的 commits:${NC}"
git log --oneline -3

echo ""
echo -e "${BLUE}🏷️  最近的 tags:${NC}"
git tag -l | tail -3

echo ""
echo -e "${GREEN}🎉 版本更新完成！${NC}"
echo ""
echo -e "${YELLOW}接下来的步骤:${NC}"
echo "  1. 推送 commit 和 tag 到远程:"
echo "     ${BLUE}git push origin main${NC}"
echo "     ${BLUE}git push origin v$NEW_VERSION${NC}"
echo ""
echo "  2. 或者一次性推送（包括 tags）:"
echo "     ${BLUE}git push origin main --tags${NC}"
echo ""

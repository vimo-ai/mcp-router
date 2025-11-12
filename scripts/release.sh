#!/bin/bash

# 本地发布脚本（备用方案）
# 使用方法: ./scripts/release.sh 1.0.0

set -e

if [ -z "$1" ]; then
  echo "❌ 请提供版本号"
  echo "使用方法: ./scripts/release.sh 1.0.0"
  exit 1
fi

VERSION=$1
ARCHIVE_PATH="build/mcp-router.xcarchive"
EXPORT_PATH="build"
APP_NAME="mcp-router"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"

echo "🚀 开始发布版本 ${VERSION}"

# 1. 清理旧的构建产物
echo "🧹 清理旧的构建产物..."
rm -rf build/
mkdir -p build

# 2. 构建 App
echo "🔨 构建 App..."
xcodebuild -project mcp-router.xcodeproj \
           -scheme mcp-router \
           -configuration Release \
           -archivePath "$ARCHIVE_PATH" \
           archive

# 3. 导出 App
echo "📦 导出 App..."
xcodebuild -exportArchive \
           -archivePath "$ARCHIVE_PATH" \
           -exportPath "$EXPORT_PATH" \
           -exportOptionsPlist ExportOptions.plist

# 4. 创建 ZIP
echo "🗜️  创建 ZIP..."
cd build
ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "$ZIP_NAME"
cd ..

# 5. 签名（使用 Keychain 中的私钥）
echo "✍️  签名更新包..."
if [ ! -f "Sparkle-2.6.4/bin/sign_update" ]; then
  echo "📥 下载 Sparkle 工具..."
  cd build
  curl -LO https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-2.6.4.tar.xz
  tar -xf Sparkle-2.6.4.tar.xz
  mv Sparkle-2.6.4 ../
  cd ..
fi

SIGNATURE=$(./Sparkle-2.6.4/bin/sign_update "build/$ZIP_NAME")
echo "📝 签名: $SIGNATURE"

# 6. 获取文件大小
SIZE=$(stat -f%z "build/$ZIP_NAME")
echo "📏 文件大小: $SIZE bytes"

# 7. 生成 appcast item
echo "📄 生成 appcast.xml 条目..."
cat > build/appcast-item.xml <<EOF
    <item>
        <title>Version ${VERSION}</title>
        <sparkle:version>${VERSION}</sparkle:version>
        <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
        <pubDate>$(date -R)</pubDate>
        <description><![CDATA[
            <h2>What's New</h2>
            <p>Check the <a href="https://github.com/vimo-ai/mcp-router/releases/tag/v${VERSION}">release notes</a> for details.</p>
        ]]></description>
        <enclosure
            url="https://github.com/vimo-ai/mcp-router/releases/download/v${VERSION}/${ZIP_NAME}"
            sparkle:edSignature="${SIGNATURE}"
            length="${SIZE}"
            type="application/octet-stream"
            sparkle:version="${VERSION}"
            sparkle:shortVersionString="${VERSION}" />
        <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    </item>
EOF

echo ""
echo "✅ 构建完成！"
echo ""
echo "📦 文件位置: build/${ZIP_NAME}"
echo "📝 appcast 条目: build/appcast-item.xml"
echo ""
echo "接下来的步骤:"
echo "1. 创建 Git tag:"
echo "   git tag v${VERSION}"
echo "   git push origin v${VERSION}"
echo ""
echo "2. 创建 GitHub Release 并上传 build/${ZIP_NAME}"
echo ""
echo "3. 更新 appcast.xml (将 build/appcast-item.xml 的内容添加到 appcast.xml 的 <channel> 中)"
echo "   git add appcast.xml"
echo "   git commit -m '🔄 Update appcast.xml for v${VERSION}'"
echo "   git push"

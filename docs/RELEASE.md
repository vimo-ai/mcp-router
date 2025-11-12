# 发布指南

本文档说明如何发布 mcp-router 的新版本。

## 📋 前置条件

- [x] Sparkle 已集成到 App
- [x] GitHub Secrets 已配置（`DEPLOY` 包含私钥）
- [x] 项目版本号已更新

---

## 🚀 方式 1：GitHub Actions 自动发布（推荐）

### 步骤

1. **更新版本号**

   在 Xcode 中修改：
   - Project Settings → General → Version: `0.0.2`
   - 或者修改 `project.pbxproj` 中的 `MARKETING_VERSION`

2. **提交代码**

   ```bash
   git add .
   git commit -m "✨ Prepare for v0.0.2 release"
   git push
   ```

3. **创建并推送 Tag**

   ```bash
   git tag v0.0.2
   git push origin v0.0.2
   ```

4. **等待自动构建**

   - GitHub Actions 会自动触发
   - 访问 https://github.com/vimo-ai/mcp-router/actions 查看进度
   - 大约 5-10 分钟完成

5. **验证发布**

   自动完成的事项：
   - ✅ 构建 App
   - ✅ 创建 ZIP
   - ✅ 签名
   - ✅ 创建 GitHub Release
   - ✅ 更新 `appcast.xml`

6. **编辑 Release Notes**（可选）

   访问 https://github.com/vimo-ai/mcp-router/releases
   - 编辑自动生成的 Release Notes
   - 添加功能说明、Bug 修复等

---

## 🛠️ 方式 2：本地脚本发布（备用）

如果 GitHub Actions 失败，可以使用本地脚本。

### 步骤

1. **运行发布脚本**

   ```bash
   ./scripts/release.sh 0.0.2
   ```

2. **脚本会自动完成**

   - ✅ 构建 App
   - ✅ 创建 ZIP
   - ✅ 签名（从 Keychain 读取私钥）
   - ✅ 生成 `appcast-item.xml`

3. **创建 Git Tag**

   ```bash
   git tag v0.0.2
   git push origin v0.0.2
   ```

4. **创建 GitHub Release**

   ```bash
   # 使用 GitHub CLI
   gh release create v0.0.2 \
      build/mcp-router-0.0.2.zip \
      --title "Version 0.0.2" \
      --notes "Release notes here"

   # 或者手动访问
   # https://github.com/vimo-ai/mcp-router/releases/new
   ```

5. **更新 appcast.xml**

   - 复制 `build/appcast-item.xml` 的内容
   - 粘贴到 `appcast.xml` 的 `<channel>` 标签内（在 `</channel>` 之前）
   - 提交并推送

   ```bash
   git add appcast.xml
   git commit -m "🔄 Update appcast.xml for v0.0.2"
   git push
   ```

---

## 🧪 测试更新

### 本地测试

1. **安装旧版本**
   - 构建并安装 v0.0.1 版本

2. **发布新版本**
   - 按照上述步骤发布 v0.0.2

3. **触发更新检查**
   - 打开 App → 设置 → 立即检查更新
   - 或者菜单栏 → Check for Updates

4. **验证更新流程**
   - ✅ 检测到新版本
   - ✅ 显示 Release Notes
   - ✅ 下载并安装
   - ✅ 重启后版本正确

---

## 📝 版本号规范

遵循 **语义化版本号** (Semantic Versioning)：

```
MAJOR.MINOR.PATCH

例如: 0.0.1 → 0.0.2 → 0.1.0 → 1.0.0
```

### 规则

- **MAJOR**: 重大更新，不兼容的 API 变更
- **MINOR**: 新功能，向后兼容
- **PATCH**: Bug 修复，向后兼容

### 示例

- `0.0.1` → `0.0.2`: 修复了几个 Bug
- `0.0.2` → `0.1.0`: 添加了新功能
- `0.1.0` → `1.0.0`: 正式版发布

---

## 🔍 故障排查

### 问题 1: GitHub Actions 失败

**症状**: Actions 运行失败

**解决方案**:
```bash
# 查看日志
# https://github.com/vimo-ai/mcp-router/actions

# 常见原因：
# 1. 私钥配置错误 → 检查 GitHub Secrets 中的 DEPLOY
# 2. 构建失败 → 检查 Xcode 项目配置
# 3. 权限问题 → 检查 GitHub Actions 权限设置
```

### 问题 2: 签名失败

**症状**: `sign_update` 命令报错

**解决方案**:
```bash
# 确认私钥在 Keychain 中
security find-generic-password -s "Sparkle ED25519" -w

# 如果找不到，重新生成密钥对
./Sparkle-2.6.4/bin/generate_keys
```

### 问题 3: 用户无法检测到更新

**症状**: App 检查更新时显示"已是最新版本"

**解决方案**:
```bash
# 1. 检查 appcast.xml 是否已更新
curl https://raw.githubusercontent.com/vimo-ai/mcp-router/main/appcast.xml

# 2. 检查版本号是否正确
# appcast.xml 中的版本号必须 > 用户当前版本

# 3. 清除 Sparkle 缓存
rm -rf ~/Library/Caches/com.higuaifan.mcp-router/
```

---

## 🎯 Checklist

发布前检查清单：

- [ ] 代码已测试，无明显 Bug
- [ ] 版本号已更新
- [ ] CHANGELOG 已更新（如有）
- [ ] 创建并推送 Git Tag
- [ ] GitHub Release 已创建
- [ ] appcast.xml 已更新
- [ ] 本地测试更新流程成功

---

## 📚 相关资源

- [Sparkle 官方文档](https://sparkle-project.org/documentation/)
- [语义化版本规范](https://semver.org/lang/zh-CN/)
- [GitHub Releases](https://github.com/vimo-ai/mcp-router/releases)
- [GitHub Actions](https://github.com/vimo-ai/mcp-router/actions)

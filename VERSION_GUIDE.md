# 版本号管理指南

本文档说明 MCP Router 的版本号管理规范，确保 Sparkle 自动更新功能正常工作。

## 版本号体系

MCP Router 使用**双版本号系统**：

### 1. CFBundleVersion（构建版本号）
- **格式**：纯数字递增（如 1, 2, 3, 4...）
- **用途**：Sparkle 用于版本比较
- **管理**：✨ **GitHub Actions 自动递增**，无需手动维护
- **规则**：每次发布自动 +1，永不回退

### 2. CFBundleShortVersionString（显示版本号）
- **位置**：`project.pbxproj` 中的 `MARKETING_VERSION`
- **格式**：语义化版本（如 0.0.2, 0.0.3-beta.1, 1.0.0）
- **用途**：用户可见的版本号
- **管理**：手动修改并提交
- **规则**：遵循语义化版本规范

## 重要原则

### ⚠️ Sparkle 版本比较机制

Sparkle 使用 `CFBundleVersion` 进行版本比较，而不是 `CFBundleShortVersionString`！

**错误示例**：
```
当前应用：
  CFBundleVersion = 1
  CFBundleShortVersionString = 0.0.2

Appcast 更新：
  sparkle:version = 0.0.3
  sparkle:shortVersionString = 0.0.3

结果：Sparkle 比较 "0.0.3" < "1"，认为没有更新 ❌
```

**正确示例**：
```
当前应用：
  CFBundleVersion = 2
  CFBundleShortVersionString = 0.0.2

Appcast 更新：
  sparkle:version = 3
  sparkle:shortVersionString = 0.0.3

结果：Sparkle 比较 "3" > "2"，提示更新 ✅
```

## 发布流程

### 发布新版本（稳定版或 Beta 版）

**现在只需 3 步！**

1. **更新语义化版本号**

在 Xcode 项目中修改 `MARKETING_VERSION`：
```bash
# 方法1：直接修改 project.pbxproj
MARKETING_VERSION = X.Y.Z[-beta.N]

# 方法2：使用 Xcode
# Target → General → Version: X.Y.Z[-beta.N]
```

⚠️ **注意**：不需要修改 `CURRENT_PROJECT_VERSION`（build number），它会自动递增！

2. **提交代码并打 Tag**
```bash
git add .
git commit -m "chore: bump version to X.Y.Z[-beta.N]"
git tag vX.Y.Z[-beta.N]
git push origin main
git push origin vX.Y.Z[-beta.N]
```

3. **GitHub Actions 自动完成剩余工作**
- ✅ 从 appcast.xml 读取最新 build number
- ✅ 自动递增 build number（+1）
- ✅ 构建应用时注入新的 build number
- ✅ 生成 appcast.xml，使用纯数字 build number
- ✅ 自动添加 beta channel 标签（如果版本号包含 beta/alpha/rc）
- ✅ 签名并发布

## 版本号映射表

| 发布时间 | CFBundleVersion（自动） | CFBundleShortVersionString（手动） | Channel（自动） | 说明 |
|---------|-------------------|------------------------------|---------------|------|
| 初始版本 | 1 | 0.0.1 | default | 首次发布 |
| Beta 版 | 2 | 0.0.2-beta.2 | beta | 第二个 beta |
| Beta 版 | 3 | 0.0.2-beta.3 | beta | 添加 beta channel 功能 |
| Beta 版 | 4 | 0.0.2-beta.4 | beta | UI 改进 |
| Beta 版 | 5（自动递增） | 0.0.2-beta.5 | beta（自动检测） | 下一个 beta |
| 稳定版 | 6（自动递增） | 0.0.3 | default（自动检测） | 正式版 |

## Beta Channel 系统

### 用户设置
- **关闭** "接收预发布版本"：只看到 `default` channel 的更新
- **开启** "接收预发布版本"：看到 `beta` + `default` channel 的更新（取最新）

### Appcast 配置示例

```xml
<!-- 稳定版 -->
<item>
    <title>Version 0.0.3</title>
    <sparkle:version>4</sparkle:version>  <!-- CFBundleVersion -->
    <sparkle:shortVersionString>0.0.3</sparkle:shortVersionString>
    <!-- 无 channel 标签 = default channel -->
    <enclosure url="..." sparkle:edSignature="..." />
</item>

<!-- Beta 版 -->
<item>
    <title>Version 0.0.4-beta.1</title>
    <sparkle:version>5</sparkle:version>  <!-- 必须 > 稳定版的 version -->
    <sparkle:shortVersionString>0.0.4-beta.1</sparkle:shortVersionString>
    <sparkle:channel>beta</sparkle:channel>
    <enclosure url="..." sparkle:edSignature="..." />
</item>
```

## 常见问题

### Q1: 为什么提示 "You're up to date" 但明明有新版本？

**原因**：`CFBundleVersion` 没有递增，或者 appcast 中的 `sparkle:version` 比当前的 `CFBundleVersion` 小。

**解决**：确保每次发布时 `CURRENT_PROJECT_VERSION` 递增。

### Q2: Beta 版本发布后，能回退到更早的稳定版吗？

**不能**。一旦发布了 build 5 的 beta 版，下一个稳定版的 build 必须 ≥ 6。

### Q3: 如何测试本地更新？

参考 `test-local-update.sh` 脚本：
1. 启动本地 HTTP 服务器
2. 修改 Info.plist 的 SUFeedURL 指向 localhost
3. 创建测试 appcast.xml
4. 测试完成后运行 `cleanup-test.sh` 恢复配置

## 检查清单

发布前确认：
- [ ] `CURRENT_PROJECT_VERSION` 已递增
- [ ] `MARKETING_VERSION` 符合语义化版本
- [ ] Git tag 与 `MARKETING_VERSION` 一致
- [ ] Beta 版本添加了 `-beta.N` 后缀
- [ ] 提交了代码并推送了 tag

## 参考资料

- [Sparkle 官方文档](https://sparkle-project.org/documentation/)
- [Publishing an Update](https://sparkle-project.org/documentation/publishing/)
- [Semantic Versioning](https://semver.org/)

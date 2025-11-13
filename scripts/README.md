# Scripts 使用说明

## bump-version.sh - 版本号自动更新脚本

自动化版本号更新、创建 commit 和 git tag 的完整流程。

### 功能

- ✅ 自动更新 Xcode 项目中的 `MARKETING_VERSION`
- ✅ 自动递增或指定 `CURRENT_PROJECT_VERSION` (Build 号)
- ✅ 验证版本号格式（支持 semver 和 prerelease）
- ✅ 检查 Git 工作区状态
- ✅ 自动创建符合项目规范的 commit（带 emoji）
- ✅ 自动创建 Git tag
- ✅ 显示更新后的状态

### 使用方法

#### 1. 正式版本（自动递增 Build 号）

```bash
./scripts/bump-version.sh 0.0.3
```

这会：
- 版本号更新为 `0.0.3`
- Build 号自动从当前值递增（例如 3 → 4）

#### 2. 预发布版本（beta/alpha/rc）

```bash
./scripts/bump-version.sh 0.0.3-beta.1
./scripts/bump-version.sh 1.0.0-rc.2
./scripts/bump-version.sh 2.0.0-alpha.1
```

#### 3. 指定 Build 号

```bash
./scripts/bump-version.sh 0.0.3 5
```

这会：
- 版本号更新为 `0.0.3`
- Build 号更新为 `5`

### 版本号格式

支持标准的语义化版本号（Semantic Versioning）：

- **正式版**: `X.Y.Z` (例如: `1.0.0`, `0.0.3`)
- **预发布版**: `X.Y.Z-prerelease` (例如: `0.0.3-beta.1`, `1.0.0-rc.2`)

### 脚本流程

1. **验证参数** - 检查版本号格式是否正确
2. **检查 Git 状态** - 确保工作区干净，避免混入其他更改
3. **显示当前和新版本** - 让你确认更改
4. **更新项目文件** - 修改 `project.pbxproj` 中的 6 处版本号配置
5. **验证更新** - 确保所有位置都已正确更新
6. **创建 Commit** - 使用项目规范的格式（🔖 emoji + 英文）
7. **创建 Tag** - 格式为 `vX.Y.Z`
8. **显示后续步骤** - 提示如何推送到远程

### 示例输出

```
📊 当前版本信息
  版本号: 0.0.2-beta.4
  Build:  3

🔢 自动递增 Build 号: 3 → 4

🎯 新版本信息
  版本号: 0.0.2-beta.4 → 0.0.3
  Build:  3 → 4

是否继续? [y/N]: y

📝 更新 project.pbxproj...
✅ 版本号已更新（6 处）
📦 创建 Git commit...
✅ Commit 已创建: a1b2c3d
🏷️  创建 Git tag...
✅ Tag 已创建: v0.0.3

🎉 版本更新完成！

接下来的步骤:
  1. 推送 commit 和 tag 到远程:
     git push origin main
     git push origin v0.0.3
```

### 注意事项

1. **工作区必须干净** - 运行前请先提交或暂存所有更改
2. **版本号不可重复** - 如果 tag 已存在会报错
3. **Build 号建议递增** - 除非有特殊原因，否则使用自动递增
4. **推送前检查** - 可以使用 `git log` 和 `git tag` 检查是否正确

### 常见问题

**Q: 如果更新失败怎么办？**

脚本会自动回滚更改。如果需要手动回滚：
```bash
git reset --hard HEAD~1  # 撤销 commit
git tag -d vX.Y.Z        # 删除 tag
```

**Q: 可以更新已发布的版本吗？**

不建议。如果必须修改已发布的版本，需要先删除远程 tag：
```bash
git push origin :refs/tags/vX.Y.Z  # 删除远程 tag
git tag -d vX.Y.Z                   # 删除本地 tag
```

**Q: Build 号有什么用？**

Build 号用于区分同一版本号的不同构建。在开发过程中，即使版本号相同，每次构建的 Build 号也应该递增。

---

## release.sh - 完整发布脚本

用于构建、签名和发布应用的完整流程。

详细说明请参考脚本内的注释。

### 使用方法

```bash
./scripts/release.sh 0.0.3
```

这个脚本会：
1. 构建应用
2. 创建签名的 ZIP 包
3. 生成 appcast.xml 条目
4. 提示后续的 GitHub Release 步骤

### 推荐工作流程

```bash
# 1. 更新版本号
./scripts/bump-version.sh 0.0.3

# 2. 推送到远程
git push origin main --tags

# 3. 构建和发布
./scripts/release.sh 0.0.3

# 4. 在 GitHub 上创建 Release 并上传构建产物
```

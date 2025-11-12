# MCP Router - Workspace 功能使用指南

## ✅ 已完成功能

### Phase 3: Workspace 核心架构 ✅
- ✅ Workspace 数据模型(token、projectPath、继承配置)
- ✅ Token 自动生成与唯一性校验
- ✅ HTTPServer 支持 `X-Workspace-Token` Header 路由
- ✅ Default Workspace 自动初始化

### Phase 4: 拖放文件夹功能 ✅
- ✅ 拖放区域 UI 与视觉反馈
- ✅ .mcp.json 文件自动处理(检测、解析、合并、写入)
- ✅ MCPConfigManager 工具类(配置管理)
- ✅ 自动 Token 生成与配置注入

### Phase 5: 管理界面 ✅
- ✅ Workspace 列表视图(卡片展示)
- ✅ Workspace 编辑界面(继承/自定义 Server 选择)
- ✅ Token 复制功能
- ✅ 配置预览

---

## 🚀 快速开始

### 1. 启动应用

编译并运行应用后:
- ✅ 菜单栏会出现闪电图标 ⚡️
- ✅ HTTP 服务自动运行在 `http://localhost:3000`
- ✅ 自动创建 Default Workspace

### 2. 查看 Workspaces

点击菜单栏图标 → "Open Settings" → 切换到 "Workspaces" Tab

你会看到:
- 📌 **Default Workspace** (星标)
  - Token: `default`
  - 包含所有已启用的 Servers(context7, janghood)

### 3. 创建新 Workspace - 方式 1: 拖放文件夹 (推荐)

1. 打开 Workspaces Tab
2. **拖入你的项目文件夹**到窗口
3. 应用会自动:
   - 生成唯一 Token(8位)
   - 检测 `.mcp.json` 文件
   - 合并配置(保留原有配置)
   - 创建 Workspace 记录

**示例**:
```
拖入: ~/Desktop/my-project
  ↓
自动生成 Token: a1b2c3d4
  ↓
写入 .mcp.json:
{
  "mcpServers": {
    "mcp-router": {
      "type": "http",
      "url": "http://localhost:3000",
      "headers": {
        "X-Workspace-Token": "a1b2c3d4"
      }
    }
  }
}
```

### 4. 创建新 Workspace - 方式 2: 手动创建

1. 点击 "Add Workspace" 按钮
2. 填写信息:
   - **名称**: 项目名称
   - **Token**: 自动生成(可手动修改)
   - **Server 配置**:
     - 继承默认: 使用 Default Workspace 的 Server 列表
     - 自定义选择: 勾选需要的 Servers
3. 点击"保存"

### 5. 在 Claude Code 中使用

在你的项目目录下打开 Claude Code,它会自动读取 `.mcp.json`:

```json
{
  "mcpServers": {
    "mcp-router": {
      "type": "http",
      "url": "http://localhost:3000",
      "headers": {
        "X-Workspace-Token": "a1b2c3d4"
      }
    }
  }
}
```

现在 Claude Code 调用工具时:
- ✅ 自动携带 `X-Workspace-Token: a1b2c3d4` Header
- ✅ MCP Router 根据 Token 路由到对应 Workspace
- ✅ 只返回该 Workspace 启用的 Servers 和工具

---

## 🔍 工作原理

### Token 映射流程

```
项目 A (.mcp.json)
  Token: a1b2c3d4
  ↓
Claude Code 发送请求
  Header: X-Workspace-Token: a1b2c3d4
  ↓
MCP Router 查找 Workspace
  找到: Workspace "my-project" (Token: a1b2c3d4)
  ↓
返回该 Workspace 启用的工具
  - context7 (AI 代码搜索)
  - janghood (工具集)
```

```
项目 B (无 .mcp.json 或 Token)
  ↓
Claude Code 发送请求
  Header: (无 X-Workspace-Token)
  ↓
MCP Router 使用 Default Workspace
  ↓
返回 Default Workspace 的工具
  - context7
  - janghood
```

### 配置继承

- **继承模式**: Workspace 自动使用 Default Workspace 的 Server 列表
  - 优点: 中心化管理,一次配置全局生效
  - 适用: 大部分项目使用相同的工具集

- **自定义模式**: Workspace 独立选择 Servers
  - 优点: 灵活配置,按项目需求定制
  - 适用: 特殊项目需要特定工具

---

## 📝 使用场景

### 场景 1: Web 前端项目

```
Workspace: "web-app"
Token: abc123ef
Servers:
  ✅ context7 (代码搜索)
  ✅ chrome-devtools (浏览器调试)
  ❌ janghood (不需要)
```

### 场景 2: iOS 项目

```
Workspace: "ios-app"
Token: def456gh
Servers:
  ✅ context7 (代码搜索)
  ✅ janghood (工具集)
  ❌ chrome-devtools (不需要)
```

### 场景 3: 快速原型项目(继承默认)

```
Workspace: "prototype"
Token: ghi789jk
继承: Default Workspace
Servers: (自动继承所有默认 Servers)
```

---

## 🎯 核心优势

### 1. 零配置门槛
- 拖入文件夹即可,无需手动编辑 JSON
- 自动生成 Token 和配置

### 2. 单端口多项目
- 所有项目使用 `localhost:3000`
- 通过 Token 自动路由

### 3. Token 优化
- 每个项目只看到自己需要的工具
- 避免一次性返回所有工具浪费 Token

### 4. 配置继承
- Default Workspace 集中管理
- 新项目默认继承,特殊需求可自定义

---

## 🔧 管理操作

### 编辑 Workspace

1. 点击 Workspace 卡片的"编辑"按钮
2. 修改名称或 Server 配置
3. 保存

### 复制 Token

点击 Workspace 卡片上的复制按钮 📋,Token 会复制到剪贴板

### 删除 Workspace

1. 点击"删除"按钮
2. 应用会自动移除 `.mcp.json` 中的 `mcp-router` 配置
3. (如果 .mcp.json 中没有其他 Server,会删除整个文件)

**注意**: 不能删除 Default Workspace

---

## 🐛 故障排查

### 问题 1: 拖入文件夹没反应

**原因**: 拖入的可能不是文件夹
**解决**: 确保拖入的是文件夹(目录),而非文件

### 问题 2: Token 冲突

**原因**: Token 已被其他 Workspace 使用
**解决**: 手动编辑 `.mcp.json`,修改 Token 为唯一值

### 问题 3: Claude Code 没有调用 mcp-router

**原因**: `.mcp.json` 格式错误或路径不对
**解决**:
1. 检查 `.mcp.json` 是否在项目根目录
2. 验证 JSON 格式是否正确
3. 重启 Claude Code

### 问题 4: 工具列表为空

**原因**: Workspace 没有启用任何 Server
**解决**:
1. 检查 Workspace 是否选择了"继承默认"
2. 或者手动选择需要的 Servers

---

## 📊 技术细节

### 数据模型

```swift
Workspace {
    id: UUID
    token: String (unique)        // "a1b2c3d4"
    name: String                   // "my-project"
    projectPath: String?           // "/path/to/project"
    isDefault: Bool                // false
    inheritFromDefault: Bool       // true
    servers: [ServerConfig]        // 多对多关系
}
```

### HTTP Header

```http
POST http://localhost:3000
Content-Type: application/json
X-Workspace-Token: a1b2c3d4

{
  "jsonrpc": "2.0",
  "method": "tools/list",
  "id": 1
}
```

### .mcp.json 格式

```json
{
  "mcpServers": {
    "mcp-router": {
      "type": "http",
      "url": "http://localhost:3000",
      "headers": {
        "X-Workspace-Token": "a1b2c3d4"
      }
    }
  }
}
```

---

## ✨ 下一步计划

### 已完成 ✅
- Phase 1: 基础架构 ✅
- Phase 2: 菜单栏应用 ✅
- Phase 3: Workspace 数据模型 ✅
- Phase 4: 拖放文件夹功能 ✅
- Phase 5: 管理界面 ✅

### 可选增强(Phase 7)
- [ ] 开机自启动(SMAppService)
- [ ] 文件监控(.mcp.json 变化自动同步)
- [ ] 请求日志查看
- [ ] Workspace 使用统计
- [ ] 配置导入/导出

---

**享受使用 MCP Router! 🎉**

# TODO — SSH Config 导入 & SSH 认证方式

状态：**实现中**，分支 `feature/ssh-config-import`。

---

## 1. 已确定的决策

1. **关闭 App Sandbox**（已修改 `macSCP.entitlements`）。
   理由：沙盒下无法可靠读取 `~/.ssh/config` 与其中引用的私钥；`Include` 指向 `~/.ssh` 之外时书签方案也覆盖不到。
   代价：不能上架 App Store（本项目本来也只走 Developer ID / DMG），且**旧版本通过沙盒容器保存的密码需要重新输入一次**（沙盒应用的钥匙串条目在容器内，关闭沙盒后读不到）。
2. **交互**：在 New Connection 按钮旁新增导入按钮 → 点击后直接解析 `~/.ssh/config`（不再弹文件选择框）→ 弹预览 sheet（默认全选）→ Import → 写入 SwiftData → 列表刷新并选中第一条。
3. **落点**：导入到根级（`folderId = nil`），与手工创建的主机一致，不建专用文件夹。
4. **不去重**：同一目标多别名、重复导入都会产生新条目，由用户在预览里自行取消勾选。
5. **认证方式**：密码、RSA、ed25519 三种都要可用。带口令的私钥本阶段只给明确错误提示，口令输入留 P1。
6. **PR**：提到 origin（`RUBisco0211/macSCP`）的 `main`，描述用中文。

## 2. 已完成

- [x] `SSHConfigParser`：`Host`/`HostName`/`User`/`Port`/`IdentityFile`/`Include`、`Key=Value`、引号与注释、`%h/%r/%p/%d/%u/%%`、first-obtained-value-wins、通配与 `!` 取反、Include 防环与深度上限、`Match` 块忽略。
- [x] `SSHConfigEntry` + 结构化告警（含按 alias 归类，供预览逐条显示）。
- [x] `SSHConfigImporter`：Entry → `Connection` 映射（根级、`ssh-config` 标签）。
- [x] `SSHConfigImportViewModel` + `SSHConfigImportSheet`：预览、逐条勾选、全选/反选、Import。
- [x] 连接列表工具栏新增导入按钮（New Connection 右侧）。
- [x] `SSHPrivateKeyLoader`：OpenSSH 头部解析判断 RSA/ed25519 与是否加密；两条会话链路共用。
- [x] `SFTPSession` / `TerminalSession` 改用共用加载器，ed25519 可用，密钥错误可诊断（不可读 / 格式不支持 / 需要口令 / 口令错误）。
- [x] `AppError.privateKeyError` 透传密钥错误文案。
- [x] 关闭沙盒，删除不再需要的授权/书签服务。
- [x] 构建兼容性修复：`swift-async-algorithms` 1.1.1 → 1.1.7（Xcode 27/Swift 6.2 下 1.1.1 触发 region-isolation 编译错误）；测试替身 `MockSFTPSession` 从 `actor` 改为 `@MainActor final class`（项目默认 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，跨模块符合被隐式隔离的协议）。

## 3. 待办

### P1

- [ ] 带口令私钥的输入 UI（加载器已预留 `passphrase` 参数）。
      注意：**Citadel 0.11.x 只接受 bcrypt KDF rounds < 18，而 OpenSSH 10 默认 24**，
      因此 macOS 27 上新生成的加密密钥无法解密。当前加载器会给出可操作错误
      （提示 `ssh-keygen -p -a 16 -f <key>`）。要真正支持，需要升级 Citadel
      或自行实现 bcrypt KDF 解密。
- [ ] `ConnectionEntity` 增加 `source` / `sourceAlias`，重复导入时更新而非新增（SwiftData 轻量迁移，需用旧库验证）。
- [ ] 导入后 banner 提示"已导入 N 条"。
- [ ] `Include` 跨目录失败时，提示用户可以手动把该目录加入导入范围（目前只告警跳过）。

### P2

- [ ] `ProxyJump` 跳板连接。
- [ ] 配置变更检测 / 重新导入预览差异。
- [ ] PEM 格式 RSA 密钥（`-----BEGIN RSA PRIVATE KEY-----`）转换或直接支持。
- [ ] 导入 S3 或其他来源。

## 4. 验收

- [x] 单测覆盖：解析语义、导入映射、预览选择、密钥类型识别、密钥错误分支、列表导入持久化。
- [x] 编译 + 全部单元测试通过（`xcodebuild test ... -only-testing:macSCPTests`，115 个用例）。
- [ ] 手测：真实 `~/.ssh/config` → 预览 5 条 → 全选导入 → 列表出现 5 条。
- [ ] 手测：RSA 主机连 SFTP/终端；ed25519 主机（OrbStack `orb`，需注意它依赖 `ProxyCommand`，仍不可连）连 SFTP/终端。
- [ ] 手测：密码主机导入后连接时弹密码框。
- [ ] 手测：带口令密钥连接时提示"需要口令"而不是笼统的认证失败。

## 5. 已知限制 / 坑

- `HostName` 值可能带尾部空格，解析器已 trim。
- `Include` 目标常在 `~/.ssh` 之外（OrbStack 在 `~/.orbstack/ssh/`），可读但属于另一来源；无法解析时告警跳过。
- `ProxyCommand none` 是"显式禁用"，不误报为不支持。
- 同一目标多别名（如 `lab-port-1185` 与 `lab-port-1185-codex`）只差端口转发，导入后是两个相同条目。
- 关闭沙盒后，旧版本的沙盒钥匙串条目不可见，已保存密码需重输一次。
- 应用不再有沙盒隔离，`~/.ssh` 内容对进程可见，需在 PR 中明确说明这是有意的权衡。

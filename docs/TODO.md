# TODO — SSH Config 导入 & SSH 认证方式

状态：**实现中**，分支 `feature/ssh-config-import`。

---

## 1. 已确定的决策

1. **关闭 App Sandbox**：沙盒下无法读取 `IdentityFile`，会导致导入的主机连不上。
   但导入仍然**由用户选择文件**：点击导入 → `NSOpenPanel` → 用户选中一个 `ssh_config` 文件。
   **只解析被选中的这个文件，不跟随 `Include`**。
   源码与 UI 中**不出现任何写死的配置路径**（不假定它叫什么、放在哪里），统一把这类文件称作 `ssh_config`。
2. **交互**：导入按钮 → 选择 `ssh_config` → 解析 → 与数据库去重 → 直接入库（**没有预览和勾选**）→ 列表刷新并选中第一条。
3. **落点**：根级（`folderId = nil`）。**不自动写 tag、不写 description、不建文件夹**，这些用户自有字段保持为空。
4. **去重**：以 `原始主机名|端口号|用户名`（小写归一）作为 key，与库中已有连接比对，重复的跳过；同一批内重复也只保留第一条。
5. **认证方式**：密码、RSA、ed25519 三种都要可用。`IdentityFile` 在导入时解析成**绝对路径**存库（相对路径按配置文件所在目录解析，`~` 展开为真实 home），连接时才读取密钥。带口令的私钥本阶段只给明确错误提示，口令输入留 P1。
6. **不支持的内容直接忽略**：`Include`、`ProxyJump`/`ProxyCommand`、端口转发、`Match`、通配 `Host` 等都不产生 UI 警告或 Notes；只在日志里记录。
7. **PR**：提到 origin（`RUBisco0211/macSCP`）的 `main`，描述用中文。
8. **数据位置**：回到 SwiftData 的默认存储（`ModelConfiguration` 不指定 URL），不引入自定义路径、迁移或 schema 探测。

## 2. 已完成

- [x] `SSHConfigParser`：`Host`/`HostName`/`User`/`Port`/`IdentityFile`、`Key=Value`、引号与注释、`%h/%r/%p/%d/%u/%%`、first-obtained-value-wins、通配与 `!` 取反、`Match` 块忽略；`Include` 与不支持项静默忽略；`IdentityFile` 解析为绝对路径。
- [x] `SSHConfigImporter`：Entry → `Connection` 映射；不写 tag/description/folder；提供 `host|port|username` 去重 key。
- [x] 导入执行：选择文件 → 解析 → 去重 → 写入 → 刷新并选中第一条（无预览 UI）。
- [x] 连接列表工具栏新增导入按钮（New Connection 右侧，纯图标）。
- [x] `SSHPrivateKeyLoader`：OpenSSH 头部解析判断 RSA/ed25519 与是否加密；两条会话链路共用。
- [x] `SFTPSession` / `TerminalSession` 改用共用加载器，ed25519 可用，密钥错误可诊断（不可读 / 格式不支持 / 需要口令 / 口令错误）。
- [x] `AppError.privateKeyError` 透传密钥错误文案。
- [x] 关闭 App Sandbox（便于读取密钥），导入通过 `SSHConfigFilePicker` 由用户选择 `ssh_config` 文件，解析器不读取 Include 目标。
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
- [ ] 如果以后需要跟随 `Include`：把被包含文件也纳入解析，并补上去重与去重 key 的说明。

- [x] **RSA 认证支持 rsa-sha2-256/512**：依赖自己 fork 的 Citadel（`RUBisco0211/Citadel` 分支 `rsa-sha2` @ `9f55d61`，按 revision 固定，内容即上游 PR #135），
      加载器改用 `SSHAuthenticationMethod.rsaSHA2`，依次提供 `rsa-sha2-512`、`rsa-sha2-256`，最后回退 `ssh-rsa`。
      已用真实服务器验证：同一把 RSA 密钥之前 `allAuthenticationOptionsFailed`，现在认证成功。
      **后续动作**：上游合并 #135 后切回官方包并删除 fork 分支；在此之前若需更新 fork，把 `rsa-sha2` rebase 到上游 `main`。

### P2

- [ ] `ProxyJump` 跳板连接。
- [ ] 配置变更检测 / 重新导入预览差异。
- [ ] PEM 格式 RSA 密钥（`-----BEGIN RSA PRIVATE KEY-----`）转换或直接支持。
- [ ] 导入 S3 或其他来源。

## 4. 验收

- [x] 单测覆盖：解析语义、导入映射、去重、密钥类型识别、密钥错误分支、列表导入持久化。
- [x] 编译 + 全部单元测试通过（`xcodebuild test ... -only-testing:macSCPTests`）。
- [ ] 手测：点导入 → 选择 `ssh_config` → 无预览 → 列表出现新增主机（4 条；`orb` 在 `Include` 里，按设计被跳过）。
- [ ] 手测：再次导入同一个文件 → 不新增重复连接。
- [ ] 手测：RSA 主机连 SFTP/终端；ed25519 主机（OrbStack `orb`，需注意它依赖 `ProxyCommand`，仍不可连）连 SFTP/终端。
- [ ] 手测：密码主机导入后连接时弹密码框。
- [ ] 手测：带口令密钥连接时提示"需要口令"而不是笼统的认证失败。

## 5. 已知限制 / 坑

- `HostName` 值可能带尾部空格，解析器已 trim。
- **`Include` 不跟随**：只读用户选中的文件，`Include` 里的主机不会导入，且不提示（按需求静默忽略）。
- 去重只比较 `host|port|username`：同机不同用户/端口会被视为不同主机；同一主机改了用户名后会重复导入。
- `ProxyCommand none` 是"显式禁用"，不误报为不支持。
- 同一目标多别名（如 `lab-host` 与 `lab-host-codex`）只差端口转发，导入后是两个相同条目。
- RSA 现在走 `rsa-sha2-512/256`，旧服务器仍可回退 `ssh-rsa`；连接失败提示会列出尝试过的算法。

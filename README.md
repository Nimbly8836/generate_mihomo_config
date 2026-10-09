# gen-mihomo-config

用一个 `values.yaml` 渲染 `config-template.yaml.erb`，生成最终的 Mihomo 配置。

## 用法

```bash
ruby generate_mihomo_config.rb --values config-values.yaml --output config.yaml
```

也可以从示例开始：

```bash
cp config-values.example.yaml config-values.yaml
ruby generate_mihomo_config.rb -v config-values.yaml
```

## 简单 Web 前端

项目提供一个本地 Ruby Web 前端，用于编辑 `values.yaml` 并生成、下载 `config.yaml`：

本地 Web 运行需要 Ruby 3.2+ 和 `sqlite3` gem（固定 2.8.1，SQLite 3.37+）；纯命令行生成器不需要 SQLite。

```bash
gem install --user-install sqlite3 --version 2.8.1 --no-document
ruby web_server.rb
# 浏览器打开 http://127.0.0.1:4567
```

若平台没有预编译 gem，需要 C/C++ 编译工具、make 和 pkg-config；可安装系统 SQLite 开发包后使用
`gem install --user-install sqlite3 --version 2.8.1 --platform ruby --no-document -- --enable-system-libraries`（Debian/Ubuntu：`build-essential pkg-config libsqlite3-dev`）。Docker 已安装绑定和运行库，CI 也安装同一版本。

生成过程使用临时目录，不会覆盖仓库中的 `config-values.yaml` 或其他配置文件。可通过环境变量修改监听地址和端口：

```bash
HOST=127.0.0.1 PORT=4567 ruby web_server.rb
```

前端文件位于 `web/index.html`，支持浏览器本地保存 YAML 编辑内容、生成配置和下载结果。
表单模式与 YAML 模式相互独立，不自动转换；表单字段（包括 WG 密钥）不保存到 localStorage。
默认只展开基础设置和节点订阅；IP4P 实验功能、WireGuard、自定义规则和外部规则集统一放在“高级配置”中，按需展开。折叠不会清空或停用已经填写的参数。
生成成功后会自动弹出只读配置预览，可复制内容或点击“下载配置”保存为 `config.yaml`；页面外不再提供重复的下载按钮。
若浏览器限制导致自动复制失败，会选中文本并提示手动复制。预览不会额外保存生成内容到浏览器；请妥善保管其中的订阅和密钥。

表单的“高级配置 → 实验功能”中提供 **启用 IP4P（实验功能）** 开关，默认不勾选。
勾选后生成 `experimental.dialer-ip4p-convert: true`，不自动开启 IPv6 或修改 WG 节点；
需要运行配置的 Mihomo 核心支持这个字段。开关只影响表单模式，YAML 模式仍以编辑内容为准。

### 把订阅中的节点加入分组

在“节点订阅”下展开 **把订阅节点加入分组**，点击 **添加分组**：

1. 选择 `my_proxy` 等已有目标组，或直接输入一个新组名。
2. 勾选要加入的订阅（支持全选）。同名来源只显示一个勾选项，选中即包含所有同名来源。
3. 生成并导入配置。多个订阅的节点会在目标组中一起显示，无需复制节点或手写 `use`。

可以添加多张分组卡片；同一目标组的选择会合并。移除卡片只取消该分组设置，不删除上方订阅；切换表单 / YAML 模式不会自动互相转换。新组也可作为下方自定义规则或外部规则集的目标。

### 发布订阅与身份恢复

生成成功后，填写配置名称，点击 **发布订阅** 才会把本次预览的完整 Mihomo YAML 和对应的 `values.yaml` 一起保存到服务器；不会重新渲染或更换其中的 Web 密钥。
返回的 `/s/<随机令牌>` 是完整配置订阅，**不是 `proxy-providers` 的节点列表**。把它导入支持完整配置订阅的客户端。
链接持有者可以读取其中的所有密码、订阅地址和 WG 私钥；链接不具备任何管理权限。不要公开分享。

- **我的配置订阅**：按名称和更新时间选择配置。浏览器持有随机身份（HttpOnly Cookie，无注册、密码或指纹），只能管理自己的订阅；公开只读链接不能获取源文件。
- **编辑源配置**：把上次发布的 `values.yaml` 加载到 YAML 编辑器；即使原先通过表单创建，也统一通过 YAML 编辑，不做表单反向转换。修改后重新生成并检查预览，再点击 **更新原订阅**，URL 保持不变；也可 **另存为新订阅**。
- 生成预览不会保存修改；发布绑定本次成功生成的源文件和成品，不读取生成后继续修改的表单/编辑器。每份订阅只保留最后一次发布内容，**没有自动保存、草稿箱或历史版本**。
- 旧订阅若未保存源文件，会提示手动补录 `values.yaml` 后重新生成并更新；不会从成品反推源文件。旧链接和原成品继续可用。
- **更多操作**：重命名、用最新生成配置更新选中订阅、重置链接或删除。重置/删除需确认，旧 URL 立即返回 404；已下载的配置无法远程撤回。
- 首次取得身份时显示恢复码，请在“我的配置订阅 → 身份与恢复码”中复制并离线保管。后端只存恢复码与会话凭据的 SHA-256 摘要，无法再次导出旧码。
- **导入恢复码** 可长期重复使用，同一身份可在多台设备同时登录，恢复不会换码或注销其他设备。当前浏览器已登录该身份时复用现有会话；否则创建独立设备会话。导入后页面显示的是你提交的原码，不是服务器重新导出的秘密。
- **重置恢复码** 是唯一使旧恢复码失效的操作；返回的新码仍长期有效，重置不会退出任何已登录设备。需要切换身份时先备份当前身份的恢复码。**恢复码泄露后应立即重置，但这不会撤销攻击者已建立的会话**；当前没有单设备/全部设备退出管理入口，疑似会话泄露需停止服务并由运营者处理数据及相关配置密钥。
- Cookie 和恢复码同时丢失，便无法再管理原订阅；服务没有管理员找回入口。Cookie/服务器会话从创建起最长保留一年（浏览器仍可能提前清除），到期可用恢复码重新登录；恢复码本身没有有效期。

源配置、配置快照、订阅令牌、恢复码不写入 localStorage；仅保留主题和输入模式偏好，也不再读取旧版的 YAML 本地缓存。恢复码只在当前页面内存中显示。刷新页面会丢失未发布的修改；旧版已留下的浏览器缓存可手动清理。
订阅永久保留到主动删除或存储丢失；身份不会自动清理，以免破坏恢复能力。

### YAML 编辑器与参考配置

“编辑配置文件”模式提供 YAML 语法高亮和行号，长行横向滚动，不与真实换行混淆。
`Tab` / `Shift+Tab` 调整两空格缩进，`Esc` 返回生成按钮。高亮是编辑辅助，配置仍需在生成时校验。
切换输入模式不会清空当前页面的编辑内容；生成和编辑都不会自动保存输入。需要保留时，请主动发布或更新配置订阅。

点击标题旁的 **参考配置**，可查看、复制仓库公开的 [`config-values.example.yaml`](config-values.example.yaml)。
示例包含基础设置、订阅、本地节点、IP4P/IPv6 覆盖、WG、自定义分组/规则、外部规则集、测速和 Fake-IP 设置；
WG 等可选示例在注释中，启用时应替换相应空块，而不是保留重复键。
它是填写参考，不是可直接联网的默认配置，请替换 URL、密码和密钥占位符。
打开或复制参考配置不会覆盖编辑区，也不会额外写入 localStorage。

编辑器使用本地打包的 CodeMirror 5.65.21（MIT，见 [来源和更新说明](web/vendor/codemirror/README.md)），无 CDN 请求或 Node 运行依赖。
服务只按固定白名单提供编辑器资源和 `/examples/values.yaml`；该路径对应公开示例，不读取私人 values。
不要将个人订阅或密钥写入这个公开示例文件。

### 在表单中添加 WG 节点

点击 **添加 WG 节点**，填写名称、服务器、端口、客户端隧道地址、客户端私钥、服务端公钥和 `allowed-ips` 网段。
支持添加/移除多个节点，以及预共享密钥、MTU、保活秒数、服务器 IPv4/IPv6 解析偏好。
客户端地址不带 CIDR 前缀，IPv4 / IPv6 至少填一个；网段和域名列表每行一项。

分流方式可以选择：

- 按 `allowed-ips` 自动生成网段规则；
- 只为指定的较窄网段生成规则；
- 仅分流域名（生成 `routes: []`，必须填写域名）。

名称为 `office` 时生成 `wg_office_node` 和 `wg_office`，默认只处理内网规则，失败不自动回落直连。`final` 会列出该组供手动选择，但不会默认选中，也不会自动加入 `proxy` / `all_nodes`。
不会自动建立隧道、配置内网 DNS 或启用 IPv6；高级参数仍可使用 YAML 模式。

### 手写规则和外部规则集

- **直接代理到 proxy / 直接连接到 DIRECT**：每行只写 `类型,匹配值`，如 `DOMAIN-SUFFIX,example.com`。不要写 URL、目标策略或 `no-resolve`；完整/逻辑规则请使用 YAML 的 `local_rules`。
- **插入其他内置组**：每行写 `组名: 类型,匹配值`。下方列出当前分组模式的全部内置组；切换 simple/detailed 后同步更新，也会提示本表单的 WG 组。
  simple 模式使用 `chat`、`ai` 等父组；`telegram`、`openai` 等详细组只能在 detailed 模式使用。填写不存在的组会报错，不会静默忽略。
- **外部规则集**：点击添加，填写唯一名称、规则文件直链、`behavior`、`format` 和目标组。要让整个外部列表走普通代理，将目标组填为 `proxy`；无需另外手写 `RULE-SET`。
  支持多个来源和可选 `no-resolve`；目标组输入框提供当前内置组、WG 组及 `DIRECT` / `REJECT` 建议。

外部规则源必须是 Clash/Mihomo 规则文件，不是订阅节点或 GitHub 网页地址。
`domain` 为域名列表，`ipcidr` 为网段列表，`classical` 为带规则类型但不带策略的列表；
`yaml` 文件需带 `payload`，`text` 为逐行文本，`mrs` 为二进制文件且不能配合 `classical`。
例如填写 `custom_media`、`https://example.com/media.mrs`、`domain`、`mrs`、`media`。
URL 只是占位示例，请替换为可信来源；Web 只生成配置，不下载或验证来源内容。
默认由 Mihomo 使用配置时通过 `DIRECT` 下载，每 24 小时更新。
手写规则和 WG 规则优先于外部规则集；不同来源冲突时先匹配排在前面的规则。

### Docker / Docker Compose

镜像只运行 Web 生成器及 REST API，不包含或运行 Mihomo，不建立 WG 隧道，也不需要特权模式、TUN 设备或宿主机网络。
镜像默认监听容器内 `0.0.0.0:4567`，以非 root 用户（UID/GID `10001`）运行。

仓库提供 [`compose.yaml`](compose.yaml)，默认镜像为：

```text
ghcr.io/nimbly8836/generate_mihomo_config:latest
```

**首次使用远程镜像前，需要先将 Docker/workflow 文件推送到 GitHub，并等待 Actions 成功发布。**
若 GHCR 包是私有的，需要先登录，或由维护者将该包的可见性设置为 Public。

```bash
# 在 compose.yaml 所在目录执行；需要 Docker Compose v2+
docker compose pull
docker compose up -d --wait

# 浏览器打开 http://127.0.0.1:4567
docker compose ps
docker compose logs -f web

# 更新镜像
docker compose pull
docker compose up -d --wait

# 停止
docker compose down
```

Compose 默认只发布到宿主机的 `127.0.0.1`，并使用只读根文件系统、64 MiB `/tmp` 临时内存目录、
禁用额外 Linux capabilities。订阅通过命名卷 `subscription-data` 持久化到 `/data`（UID/GID 10001，目录 0700、文件 0600）。无需挂载私人配置或源代码。
`docker compose down` 保留数据；**`down -v` 会删除订阅与管理身份**。绑定挂载时须事先设置对应权限。
可以通过环境变量（或 Compose 同目录的 `.env`）设置：

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `MIHOMO_WEB_IMAGE` | 上述 GHCR 镜像的 `latest` | 切换版本、本地镜像或 fork 的镜像地址 |
| `WEB_BIND_ADDRESS` | `127.0.0.1` | 宿主机绑定地址 |
| `WEB_PORT` | `4567` | 宿主机端口；容器内仍为 4567 |
| `PUBLIC_BASE_URL` | `http://127.0.0.1:${WEB_PORT:-4567}` | 网站唯一规范 origin；部署时明确设置为 `https://你的域名`，不含路径 |

原生 Ruby 运行还支持 `DATA_DIR`（默认仓库下已忽略的 `./data`）；镜像与 Compose 固定使用 `/data`。
原生 `PUBLIC_BASE_URL` 默认 `http://127.0.0.1:$PORT`。只能使用 HTTPS 或 loopback HTTP origin（127.0.0.1、localhost、[::1]）；浏览器访问地址必须与其一致。

例如 `WEB_PORT=8080 docker compose up -d --wait`，随后访问 `http://127.0.0.1:8080`。
**公网部署必须使用 HTTPS 反向代理，并明确设置 `PUBLIC_BASE_URL`。** HTTP 仅用于绑定 loopback 的本地开发，不要通过 `WEB_BIND_ADDRESS=0.0.0.0` 将 HTTP 服务公开。
代理须保留规范 `Host`；服务不信任 `X-Forwarded-*` 生成 URL、决定 Cookie 安全属性或识别客户端 IP。
HTTPS origin 会设置 `Secure; HttpOnly; SameSite=Strict` Cookie，本地 HTTP 不设置 Secure。
管理写请求要求相同 Origin、规范 Host、JSON 和 `X-Mihomo-Request: 1`；没有开放 CORS。
表单里的“Web 密钥”是生成的 Mihomo 配置密钥，不是这个生成器网站的登录密码。

旧 `/api/v1/configs` 创建结果仍只保存在内存中（最多最近 32 份），重启或淘汰后下载 URL 失效；新的 `/s/` 订阅在重启后保留。
源配置可能包含密码、订阅地址及 WG 私钥；只有所属身份可经管理 API 读取，磁盘上与成品一起受权限保护但不加密。不要在共享浏览器上保留管理身份，旧版遗留的本地输入缓存请自行清理。

#### 存储、安全与运行限制

持久化使用 `DATA_DIR/subscriptions.sqlite3`：身份、设备会话与订阅分别按行存储，会话摘要、会话到期时间、恢复摘要、只读令牌和所属身份均有索引；只查询/更新目标行，不再读取或重写整份 JSON。写操作使用 SQLite `BEGIN IMMEDIATE` 事务（含容量检查），读操作使用一致性事务；启用外键、`synchronous=FULL`、DELETE 回滚日志和 `secure_delete`。不保留历史内容，但文件系统快照、备份和异常中断留下的日志仍可能含秘密。
请使用支持 SQLite 文件锁、flock/原子 rename/fsync 的本地持久卷，单实例部署；不要跨不可靠的网络文件系统共享数据。
文件损坏、初始化后数据库丢失、被替换或不可写时请求失败，不会静默重建数据库或重新导入旧 JSON。修复权限或停止服务后恢复完整备份（含 `subscriptions.lock` 及可能存在的 SQLite 回滚日志）；不要手工删除锁文件或在线替换数据库。
备份前停止服务并复制整个数据目录，离线加密备份并限制访问；存储包含明文配置密码、WG 私钥及只读令牌，**不是加密保险箱**。不支持旧版服务与新版服务同时访问同一数据目录。

**旧 JSON 自动迁移**：升级前停止旧服务并备份完整数据目录。首次启动会在旧锁文件保护下完整校验 `subscriptions.json`，在临时 SQLite 数据库的单个事务中导入，再 fsync/原子安装；身份 ID、会话/恢复摘要、订阅 ID、令牌、名称、更新时间、成品与源文件原文均保留，旧链接无需更换。原 `session_hash` 迁入独立设备会话表，并从迁移时起获得完整一年的服务器有效期（浏览器 Cookie 自身到期日不延长）；原恢复码从此可重复使用，直到主动重置。旧条目缺少名称/源文件时使用默认名称/空源文件。无效结构、重复凭据/键、损坏 YAML 或超限数据会阻止启动，不会跳过坏记录或创建空身份库。导入提交前失败可修复旧文件后重试。
迁移完成后 `subscriptions.json` 原样保留为 0600 的**敏感、静态旧备份**，不再读取或更新，数据库始终优先；它可能包含已经撤销的会话摘要/恢复摘要、旧令牌和已删除的配置。验证现有 Cookie、恢复能力和订阅链接并另做 SQLite 备份后，可安全移走或删除旧 JSON；不要把它公开、提交到 Git，或当作最新备份恢复。恢复旧备份会回滚撤销状态，可能重新启用旧凭据/链接。
初始化标记先于数据库安装持久化，以防旧凭据意外复活；若恰在两者之间断电/失败，服务将拒绝启动，需离线恢复完整备份（或由运营者核验遗留 `.subscriptions-*.sqlite3` 后恢复为正式数据库），不会冒险自动重新迁移。迁移前失败遗留的临时文件也按敏感备份处理；确认无用后离线删除。

固定限制（见 `lib/subscription_store.rb` / `lib/web_security.rb`）：1000 个身份，每身份一个长期恢复码、多个独立设备会话；每身份 20 个订阅、全局 1000 个；单份成品与源文件各 512 KiB、名称 1–80 字符、逻辑数据 32 MiB（按每行 JSON 等价字节数记账，包含设备会话、名称/空源字段及少量分隔开销；SQLite 页、索引、回滚日志和旧 JSON 备份另占磁盘空间，不受此逻辑上限约束）；请求体 1 MiB、请求头 16 KiB，读/写连接各 5 秒。
超限拒绝且不改动原订阅/恢复码/设备会话；身份容量满后需运营者规划备份/迁移，不会自动删除旧用户。
设备数量没有任意的小额上限，也不驱逐旧设备；新增会话受同一 32 MiB 事务容量及请求限速约束。每次创建会话时按索引清除过期会话，未过期会话不被清理；当前身份的有效会话复用不占新增空间。大量未到期会话仍可能耗尽容量，运营者需监测并规划存储；恢复码从不过期。
内置固定分钟窗口限速：直接 TCP 对端 120 请求/分钟、全局 1200 请求/分钟；限速表最多 1024 项，每分钟清空。反向代理后所有用户共享代理 IP 配额，重启也会清空限速窗口。
这是小型串行 Ruby TCP 服务，**不是生产级 DDoS 防护**。匿名发布天然可能被滥用或占满容量。
反向代理还应设置连接数、请求/生成频率、请求体大小、读写与上游超时，并按真实客户端地址限流（仅在代理层信任自己的转发链）；不要将后端端口直接公开。
关闭或脱敏 `/s/*` 的访问日志，也不要记录 Cookie、恢复请求体或配置。服务自身不记录请求路径、令牌或生成器输出。
所有响应均使用 `Cache-Control: private, no-store`、`Referrer-Policy: no-referrer` 和 `nosniff`；代理也不得缓存订阅/管理响应。
旧生成 API 保持无 Cookie 的兼容调用方式；它们只生成/暂存结果，不能管理持久订阅，同样受请求大小、输出大小及速率限制。

#### 本地验证

```bash
gem install --user-install minitest --version '~> 5.25' --no-document
gem install --user-install sqlite3 --version 2.8.1 --no-document
ruby -Itest test/generate_mihomo_config_test.rb
ruby -Itest test/subscription_store_test.rb
ruby -Itest test/subscription_store_migration_test.rb
ruby -Itest test/web_subscriptions_test.rb
node --test test/web_form_test.cjs
```

#### 本地构建（无需等待 GHCR 发布）

```bash
docker build -t mihomo-config-web:local .
MIHOMO_WEB_IMAGE=mihomo-config-web:local docker compose up -d --wait
```

`.dockerignore` 使用白名单，Dockerfile 也只显式复制运行代码、本地编辑器资源和公开示例；
不会将私人 values、生成的配置、订阅凭据或 `.git` 打进镜像。运行环境无需 Node.js 或额外应用 gem。

#### GitHub Actions 构建与发布

[`.github/workflows/docker.yml`](.github/workflows/docker.yml) 自动执行：

- PR 到 `main`：运行生成器、表单、订阅持久化与 HTTP 生命周期/安全测试，构建原生镜像，并通过 Compose 测试页面、健康检查、IP4P、WG 生成和下载；不发布镜像。
- 推送 `main`：测试通过后发布 `latest` 和 `sha-<短提交号>`。
- 推送 `v*` 标签：发布同名镜像标签（如 `v1.0.0`）及提交号标签。
- 支持 Actions 页面手动运行；只有 `main` 分支运行会更新 `latest`。
- 发布 `linux/amd64` 和 `linux/arm64`，使用仓库自带的 `GITHUB_TOKEN` 登录 GHCR，无需 Docker Hub 凭据。

Actions 固定到具体提交 SHA；需允许仓库 Actions 运行及 workflow 的 `packages: write` 权限。
这套自动化不执行真实订阅下载或 WG 连通性验证，也不等于对 Web 服务做了完整的安全审计。

### REST API

Web 服务启动后还提供版本化 REST API：

```bash
# 健康检查
curl http://127.0.0.1:4567/api/v1/health

# 创建配置，values 可以是 JSON 对象或完整 YAML 字符串
curl -X POST http://127.0.0.1:4567/api/v1/configs \
  -H 'Content-Type: application/json' \
  -d '{"values":{"proxy_providers":[],"local_proxies":[],"local_rules":[]}}'
```

创建接口返回 `id` 和 `download_url`。随后可以查询生成结果，或直接下载：

```bash
curl http://127.0.0.1:4567/api/v1/configs/<id>
curl -OJ http://127.0.0.1:4567/api/v1/configs/<id>/download
```

`POST /api/generate` 为当前页面返回 `{config, source, message}`；`source` 是本次生成实际使用的输入（YAML 字符串原样保留，对象转成 YAML）。它不会持久保存输入。旧版 `/api/v1/configs` 的临时结果和下载不包含 `source`。

匿名订阅 API（管理凭据仅在 `mihomo_session` Cookie 中；所有非 GET 请求均为 JSON，要求上述 Origin/Host/自定义头）：

| 方法与路径 | 请求 / 返回 |
| --- | --- |
| `POST /api/identity` | `{}`；已有有效身份不轮换，无身份时创建；首次返回 `recovery_code` 并设置 Cookie |
| `GET /api/subscriptions` | 返回 `subscriptions: [{id, name, has_source, url, updated_at}]`，不创建身份、不返回源文件 |
| `GET /api/subscriptions/<id>/source` | 仅所属身份可读，返回 `{id, name, source}`；旧记录的 `source` 为 `null` |
| `POST /api/subscriptions` | `{name, source: "values YAML", config: "完整成品 YAML"}`；返回 `{id, name, has_source, url, updated_at}` |
| `PUT /api/subscriptions/<id>` | `{name, source, config}`；原子替换源文件与成品，URL 不变 |
| `PATCH /api/subscriptions/<id>` | `{name}`；只重命名，源文件、成品与 URL 不变 |
| `POST /api/subscriptions/<id>/reset` | `{}`；更换只读 URL，返回新元数据 |
| `DELETE /api/subscriptions/<id>` | `{}`；删除，返回 `{deleted: true}` |
| `POST /api/identity/recovery` | `{}`；显式重置旧恢复码，返回新的 `recovery_code`，所有已登录设备保持有效 |
| `POST /api/identity/recover` | `{recovery_code: "..."}`；可重复使用，新设备设置独立 Cookie，已有同身份有效 Cookie 则复用且不再设置 Cookie；始终返回 `recovery_code: null`，原恢复码保持有效 |
| `GET /s/<token>` | 无需 Cookie；只读原始完整 YAML 字节，失效令牌返回 404 |

身份 ID、管理会话、恢复码、订阅 ID 与只读令牌分别使用独立的 32 字节加密随机数。ID 不是凭据。
非所属订阅与不存在订阅统一返回 404；无效会话 401、来源校验失败 403、容量满 409、过大请求 413、无效配置 422、限速 429。
兼容旧客户端：创建/更新仍接受仅 `{config}`，未提供名称时创建为“未命名配置”、更新保留原名；未提供源文件的更新会清除旧源文件，避免与新成品错配。源文件必须是 YAML 根映射；失败更新不会替换原源文件或成品。
管理 API 接收已渲染快照，不重新调用生成器；校验 YAML 根映射含 `proxy-groups` / `rules` 数组，不保证任意手工上传配置的 Mihomo 运行有效性。正常锚点、别名值和合并可用；拒绝复杂/别名映射键、循环/前向别名、超过 64 层的语法树或展开后超过 100000 个节点的别名图，防止小文件消耗过量校验资源。

缺少 `port`、`web_port`、`tun_device`、`dns_split_cn_foreign`、`group_mode` 或 `web_secret` 时会自动补默认值。

## 主要配置

```yaml
# simple 或 detailed，默认 simple
group_mode: simple

# 默认使用 Yacd-meta；两项均可覆盖
external_ui: ./Yacd-meta-gh-pages/
external_ui_url: https://github.com/MetaCubeX/yacd/archive/gh-pages.zip

proxy_providers:
  - name: main
    # 节点名称会变为 Main | 原节点名；省略时使用 name
    prefix: Main
    url: https://example.com/subscription.yaml

local_proxies: []
local_proxy_groups: []
local_rules: []
```

`external_ui` 是 Mihomo 面板目录，`external_ui_url` 是 Mihomo 自动下载面板的压缩包地址。默认面板为 `Yacd-meta-gh-pages`，用户可以替换为其他兼容 Mihomo API 的面板。

订阅的 `prefix` 会转换为 Mihomo 的 `override.additional-prefix`。订阅下载默认使用 `DIRECT`；需要通过代理更新时，可以在对应 provider 中显式设置 `proxy`。

### 同名节点订阅合并

生成页面可以多次填写同一个订阅名，例如：

```text
main | https://example.com/one.yaml | Main
main | https://example.com/two.yaml | Main
```

两条链接的节点都会进入 `all_nodes` 和对应地区组，后面的来源不会覆盖前面的来源。YAML / API 的 `proxy_providers` 列表同样支持多个相同 `name`（按名称精确匹配，区分大小写）。

- 完整条目完全相同时去重；同一个 URL 的前缀、筛选、请求头等参数不同则分别保留，不丢弃设置。
- Mihomo 的一个 HTTP provider 只能使用一个 URL，所以内部生成 `main`、`main__2` 等独立 provider，并自动避开用户已经使用的名称。这是来源汇总，不是把 URL 填成数组，也不是由生成器下载节点。
- 各来源使用独立 HTTP 缓存；重复的显式 `path` 自动加后缀，避开其他已指定路径。前缀省略时仍使用原订阅名，不带内部编号。
- 自定义策略组中的 `use: [main]` 会展开为全部同名来源，`config_overrides.proxy-groups` 中的 `use` 也适用；需要选择单个来源时请为它填写不同的订阅名。
- **不按节点名称去重**，不合并“我的配置订阅”中发布的完整配置链接。已发布的旧配置须重新生成后主动更新，才会应用新行为。

### YAML / API 指定订阅节点的分组

```yaml
# main、backup 对应上面的 proxy_providers.name；不填写 URL 或节点前缀。
group_providers:
  my_proxy: [main]
  combined: [main, backup]
```

上述配置把 `main` 的所有节点加入 `my_proxy`，并建立 `combined` 组汇总两份订阅。底层使用 Mihomo 原生 `use`，仍由客户端下载和更新订阅，不需要服务器聚合。所选订阅仍保留在原有 `all_nodes` / 地区组中。

- 已有目标组保留手写节点、类型和其他选项；地区组原有筛选仍生效。如需展示全部节点，请选择 `my_proxy` 或新建无筛选的组。
- `my_proxy` 没有手写节点时优先使用所选订阅节点；没有加载到任何节点时仍按原有策略回退 `DIRECT`，并非节点连接失败就切换直连。
- 新组为 `select`，自动加入 `final`；没有加载到任何节点时使用 `REJECT`。此设置不会自行添加分流规则。
- 填写订阅原名会包含全部同名来源；未知订阅名、空列表、与节点同名或保留名称冲突的目标组会报错，不会静默忽略。
- `config_overrides` 仍最后应用；如果整体覆盖 `proxy-groups`，需要自行保留这些分组。

## 最终配置覆盖

在 values 中使用 `config_overrides`，可覆盖模板输出中的任意 Mihomo 字段，或增加核心支持的实验/插件配置：

```yaml
config_overrides:
  ipv6: true
  dns:
    ipv6: true
  experimental:
    dialer-ip4p-convert: true
```

只设置 `dns.ipv6` 不会丢失原来的 `nameserver`、`fake-ip-filter` 等其他 DNS 项。
此入口在模板渲染、`fake_ip_filter` 追加完成后执行，优先级最高；最后仅将策略组 `use` 中的同名订阅引用展开为实际 provider 列表。
生成文件把 `config_overrides` 中的配置块按你填写的顺序放在最前面，块内也优先显示你填写的字段，
其余默认字段随后保留。同一个配置键只输出一次；显示顺序本身不会改变 Mihomo 的匹配优先级。

- 配置块（mapping）递归合并；未提及的字段保留。
- 列表整体替换，不按名称合并或自动追加。例如覆盖 `rules`、`proxies`、`proxy-groups` 时需给出完整列表。
- 标量直接替换，`false`、`0`、空字符串等不会被当成未配置。
- `null` 写成 YAML 空值，不表示删除字段；`{}` 是空合并，不会清空已有配置块。
- 使用最终 Mihomo 字段名，例如 `mixed-port`、`external-controller`，不是生成器输入名 `port`、`web_port`。
- 未设置或写成 `{}` 时通常保持输出格式；设置 `group_providers`、非空覆盖或自定义策略组需要展开同名订阅引用时，会重新序列化 YAML，不保留模板注释和原有排版。
- 自定义字段仅透传，不安装插件、不保证当前核心识别；覆盖造成的无效策略引用等需自行校验。

节点级字段（例如 WireGuard 的 `ip-version`、密钥、`allowed-ips`）继续写在 `local_proxies` 节点内，原样传递。
只在 values 顶层填写 `ipv6`、`dns`、`experimental` 不会自动覆盖模板，必须放到 `config_overrides` 内。
Web 的“编辑配置文件”模式、REST API 的 `values` 对象或 YAML 字符串也支持这个入口；表单模式暂未单独提供编辑控件。

## 精简 Fake-IP 例外

`dns.fake-ip-filter` 是 DNS 兼容性例外：命中的域名返回真实 IP，而不是 Fake-IP。
它不是直连列表，最终走代理还是直连仍由 `rules` 决定。
在 `fake-ip` 模式下建议保留常用例外，但不需要把所有音乐、游戏、视频服务都放进默认列表。

```yaml
# 默认 basic：18 条常用内网/本机、校时、STUN 和网络检测例外。
# compat：恢复此前的 89 条完整历史兼容列表。
fake_ip_filter_mode: basic

# 按需追加，自动去除重复项；两种模式都支持。
fake_ip_filter:
  - music.163.com
  - +.my-device.test
```

这是默认 DNS 行为的调整，不只是折叠显示：精简后，未列出的服务会正常使用 Fake-IP。
若特定音乐/游戏/设备出现兼容问题，可追加其域名，或设置 `fake_ip_filter_mode: compat`。
精简列表不保证覆盖所有设备、校时服务或游戏的需求；切换前后应结合自己的应用验证。

如要完全自定义列表，仍可使用最高优先级的覆盖入口：

```yaml
config_overrides:
  dns:
    fake-ip-filter:
      - '*.lan'
      - '*.local'
      - +.my-device.test
```

该列表会替换所选模式的默认列表及 `fake_ip_filter` 追加项。
写成 `fake-ip-filter: []` 可清空生成配置中的此列表，但不推荐在未验证兼容性的情况下直接清空。

## WireGuard 内网快速配置

在 values 中添加 `wireguard` 列表，即可自动生成节点、独立分组和内网分流规则。
完整示例见 [`config-values-wireguard.example.yaml`](config-values-wireguard.example.yaml)。
每个条目对应单个 peer；多 peer 高级配置仍放在 `local_proxies` 中手动配置。

```yaml
wireguard:
  - name: office
    server: wg.example.com
    port: 51820
    ip: 10.7.0.2
    private-key: REPLACE_WITH_CLIENT_PRIVATE_KEY
    public-key: REPLACE_WITH_SERVER_PUBLIC_KEY
    allowed-ips:
      - 10.7.0.0/24
      - 192.168.50.0/24
```

先替换示例中的服务器、隧道地址和密钥；占位密钥会被校验拒绝，不能直接连接。
`ip` / `ipv6` 是客户端在隧道内的地址，不带 `/24` 等掩码。密钥必须为 Base64 编码的 32 字节值。
`name` 使用小写英文开头，可包含数字、下划线和连字符。

上例自动生成：

- 节点 `wg_office_node`（默认 `udp: true`）；
- 独立 `select` 组 `wg_office`，选项为 `wg_office_node` 和 `REJECT`；
- `IP-CIDR,10.7.0.0/24,wg_office,no-resolve`；
- `IP-CIDR,192.168.50.0/24,wg_office,no-resolve`。

**默认规则位置**为手写规则之后、默认 SSH/22 端口直连及私有域名/IP 直连之前，
因此访问上述内网（包括 SSH）不会先被默认 `DIRECT` 规则匹配。
`local_rules` / `proxy_rules` / `direct_rules` / `group_rules` 仍然优先，宽泛的手写规则可能覆盖 WG 自动规则。
WG 节点和分组不会自动加入 `my_proxy`、`proxy`、地区组或其他普通出口组；隧道失败不自动回落直连。
可在面板将 `wg_office` 切到 `REJECT` 来拒绝访问这些目标。

### 收窄网段、追加域名及多个隧道

```yaml
wireguard:
  - name: office
    # ...同上填写 server / port / ip / 密钥...
    allowed-ips: [10.7.0.0/24, 192.168.50.0/24]
    routes: [192.168.50.0/24]
    domains: [office.internal]
```

- 不写 `routes` 时，按 `allowed-ips` 自动生成 IP 规则；显式填写时，只为 `routes` 生成 IP 规则。
- `routes` 必须包含在 `allowed-ips` 中；支持 IPv4/IPv6 CIDR，IPv6 自动生成 `IP-CIDR6`。
- `domains` 为裸域名，自动生成 `DOMAIN-SUFFIX`，匹配自身及子域名；不接受 URL、通配符或完整规则文本。
- `routes: []` 配合非空 `domains` 可仅按域名分流。内网域名需要可用的 DNS；此功能不自动配置内网 DNS。
- 若 `allowed-ips` 包含 `0.0.0.0/0` 或 `::/0`，必须显式提供较窄的 `routes`，或用 `routes: []` 配合域名。
  内网快速模式拒绝生成 `/0` 分流，以免意外接管全局流量。
- 可以添加多个命名不同的条目，例如 `office`、`home`。规则按填写顺序生成，重叠网段/域名先匹配前面的条目，建议避免重叠。
- `pre-shared-key`、`mtu`、`persistent-keepalive`、`ip-version`、`remote-dns-resolve`、`dns` 等节点参数原样透传。
  IPv6 开关和 IP4P 等实验功能仍通过 `config_overrides` 配置，不自动启用；是否可用取决于核心及网络环境。
- `config_overrides` 仍具有最终优先级；整体替换 `proxies`、`proxy-groups` 或 `rules` 会替换自动生成的对应列表。

```bash
# 先复制示例并填写自己的配置，不要将真实密钥提交到仓库。
cp config-values-wireguard.example.yaml config-values-wg.yaml
ruby generate_mihomo_config.rb --values config-values-wg.yaml --output config-wg.yaml
```

CLI、Web 的 WG 表单 / 完整 YAML 编辑模式和 REST API 的 `values` 输入都使用此入口。
生成器只生成配置，不负责建立隧道、修改系统路由或验证服务端转发能力。
字段参考：[Mihomo WireGuard 文档](https://wiki.metacubex.one/config/proxies/wg/)。

## 代理组模式

### simple

使用简单分类组，并保留独立的 Apple 分组：

```text
proxy → region / all_nodes → node
ai → proxy
game → proxy
media → proxy
chat → proxy
dev → proxy
cloud → proxy
apple → cloud → proxy
download → proxy
adult → proxy
china → DIRECT
other → proxy
final → proxy（默认，可独立选择其他策略组）
```

### detailed

详细服务组默认引用对应的简单分类组：

```text
openai → ai → proxy → region → node
claude → ai → proxy → ...
steam → game → proxy → ...
netflix → media → proxy → ...
github → dev → proxy → ...
```

详细组只是增加控制粒度，不重复维护节点列表。用户可以在详细组中直接选择地区或 `DIRECT` 覆盖父级默认选择。

详细组包括：

- AI：`openai`、`claude`、`gemini`、`copilot`
- Game：`steam`、`epic`、`blizzard`、`ps`、`xbox`、`nintendo`
- Media：`youtube`、`netflix`、`disney`、`prime`、`hbo`、`twitch`、`spotify`
- Chat：`telegram`、`discord`、`whatsapp`、`x`
- Dev：`github`、`gitlab`、`docker`
- Cloud：`google`、`apple`、`microsoft`、`onedrive`（`apple` 在 simple 模式中也保留）

### final 独立兜底选择

未匹配规则的流量仍由 `MATCH,final` 处理。`final` 默认选择 `proxy`，但可以独立改选 `DIRECT`、地区组、`all_nodes`、`my_proxy`、`default`、简单分类组或 `apple`；detailed 模式还可选择 `openai`、`netflix` 等已生成的详细服务组，不再仅有 `proxy` / `DIRECT` 两个选项。

`final` 包含当前生成的所有其他分组，包括隐藏的 `*_auto`、`ad_block`、WG 组及新建的订阅分组。只排除 `final` 自身以及直接或间接引用它的自定义组，以免形成循环。选择 WG 组不会扩大其 `allowed-ips`，选择 `ad_block` 可能拒绝流量；这些选项不会默认启用。其他组原有的默认出口不变，`china` 仍优先直连且仅保留一个 `DIRECT`。

### Apple 独立分组

`apple` 在 simple / detailed 两种模式中均为可见的 `select` 组，Apple 和 Apple 中国区规则集（`apple_domain`、`apple_cn_domain`）均指向它。默认跟随 `cloud`，保持原有出口行为；也可单独选择 `DIRECT`、`proxy` 或地区组。例如选择 `hk` 后，默认由 `hk_auto` 自动选择香港节点。

## 地区组

所有地区组使用 `select`，默认选择对应的隐藏 `url-test` 自动组，也可手动选择匹配地区的订阅节点：

```text
hk
jp
tw
sg
us
kr
eu
others
```

地区组显示为 `jp`、`hk` 等名称，每组的首项和默认选择是 `jp_auto`、`hk_auto` 等自动组。自动组设置 `hidden: true`，不单独占用面板的组列表，但仍可在对应地区组中选中。选择具体节点后会固定使用该节点，要恢复自动切换请重新选中对应的 `*_auto`。

地区组和自动组均不包含 `my_proxy`、`DIRECT` 或手写节点；自动组只引用订阅节点，不引用地区父组或其他策略组，避免循环引用和绕到直连。手写节点仍通过独立的 `my_proxy` 使用。

自动组默认每 300 秒重新测速，`lazy: false` 保持持续健康检查；测速发现当前节点不可用时会选择其他可用节点，正常情况下新节点需快超过 `tolerance`（默认 50ms）才切换。切换依赖健康检查结果，不保证业务请求无缝恢复，也不会跨地区切换。`url_test` 可覆盖这些参数，其中 `url`、`interval`、`lazy` 同时用于订阅默认的 `health-check`；订阅自己显式配置的 `health-check` 仍优先。

无订阅时自动组只包含 `REJECT`；订阅中没有匹配节点时通过 `empty-fallback: REJECT` 拒绝连接，避免空组隐式直连。需要支持 `empty-fallback` 的 Mihomo 核心，建议升级到最新稳定版。

升级后请重新生成并重载配置。面板可能恢复之前缓存的选择，而不是采用新的默认项；如需自动切换，请确认地区组选择的是对应的 `*_auto`。

`eu` 覆盖英国、德国、法国、荷兰、意大利、西班牙、瑞典、瑞士、奥地利、波兰、俄罗斯等常见欧洲节点，并排除已单独处理的亚洲、美国和中国节点。

## 规则来源

默认提供 **51 个独立更新的规则提供者**，不是把少量手写域名当作全部覆盖。
服务规则主要来自 [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)，广告另保留旧版的
[217heidai/adblockfilters](https://github.com/217heidai/adblockfilters)。

| 类别 | 内置 provider | 说明 |
| --- | --- | --- |
| 基础域名 | `ads`、`private`、`cn`、`non_cn`、`tracker` | 保留原有入口 |
| AI | `openai_domain`、`claude_domain`、`gemini_domain`、`copilot_domain`、`ai_domain` | 专用集优先；综合集还覆盖 Cursor、Perplexity 等 |
| 游戏 | `steam_domain`、`epic_domain`、`blizzard_domain`、`ps_domain`、`xbox_domain`、`nintendo_domain`、`games_domain` | 平台集 + 游戏综合集 |
| 媒体 | `youtube_domain`、`netflix_domain`、`disney_domain`、`prime_domain`、`hbo_domain`、`twitch_domain`、`spotify_domain`、`bilibili_domain`、`biliintl_domain`、`bahamut_domain` | 保留国内/海外媒体的匹配覆盖 |
| 通信 | `telegram_domain`、`discord_domain`、`whatsapp_domain`、`twitter_domain`、`facebook_domain`、`instagram_domain`、`reddit_domain` | 按 simple/detailed 路由到父组或服务组 |
| 开发/云服务 | `github_domain`、`gitlab_domain`、`docker_domain`、`google_domain`、`google_cn_domain`、`apple_domain`、`apple_cn_domain`、`microsoft_domain`、`onedrive_domain` | OneDrive 先于 Microsoft；AI 先于 Google/GitHub |
| 成人内容 | `ehentai_domain` | 路由到 `adult` |
| IP | `private_ip`、`google_ip`、`netflix_ip`、`telegram_ip`、`twitter_ip`、`cn_ip` | `behavior: ipcidr`，恢复旧版服务 IP 覆盖 |
| 广告聚合 | `adblock_mihomo` | 217heidai 同系列 MRS 版，与 `ads` 一起进入 `ad_block` |

MetaCubeX 的域名集使用 `meta/geo/geosite/*.mrs`，IP 集使用 `meta/geo/geoip/*.mrs`，每 24 小时刷新；
`adblock_mihomo` 使用 `main/rules/adblockmihomo.mrs`，每 8 小时刷新。
目录及保留名称由生成器的同一份规则目录定义，避免与 `custom_rule_providers` 重名后静默覆盖。

从 GEOSITE 改为独立 MRS 的部分仍来自同一上游，不能只凭 provider 数量声称覆盖增加。
实际补充包括：恢复 217heidai 广告源、恢复 Google/Netflix/Twitter 的 IP 分流、补充私有 IP，
以及 Claude/Gemini/Copilot 的完整上游集合与 AI 综合集合。旧 OpenAI CDN/存储域名的显式补充也保留。
IP 规则使用 `no-resolve`，可匹配已有目标 IP，但不会为了匹配主动解析一个仅有域名的请求。

规则顺序为：

```text
local_rules → proxy_rules → direct_rules → group_rules
→ wireguard 自动内网规则
→ SSH / 端口规则
→ custom_rule_providers
→ private / private_ip
→ adblock_mihomo / ads / tracker
→ AI、Game、Media、Chat、Dev、Cloud 的域名规则
→ Google / Netflix / Telegram / Twitter 的 IP 规则
→ cn / cn_ip
→ non_cn
→ MATCH,final
```

所有内置 HTTP 规则集默认通过 `DIRECT` 下载，消除对尚未可用的代理组的依赖；这不保证网络或上游始终可达。
`proxy` / `all_nodes` 在没有订阅或手写节点时仍可通过 `my_proxy` 回退到 `DIRECT`；地区组不使用这条回退路径，空组拒绝连接。
更新失败时可使用已有的本地 `path` 缓存；首次启动无网络且无缓存时，不能保证远程规则可用。
广告误拦截时，可用优先级更高的自定义直连规则放行，或将 `ad_block` 切到 `DIRECT`。

### 如何验证规则源

```bash
# 离线结构回归；安装 mihomo 时也校验生成的 simple/detailed 配置
ruby -Itest test/generate_mihomo_config_test.rb

# 在线检查：需要 ax、mihomo；会下载所有内置源，不读取你的 values 或私人订阅
ruby script/check_rule_providers.rb
```

在线脚本逐一下载 MRS、调用 Mihomo 解码、检查非空内容及代表性域名/IP 样本，打印每个源的记录数与 SHA-256；
任何失败都会返回非零退出码。临时文件在检查后清理，不改用户配置或运行中的 Mihomo。
它证明的是“此时来源可用、内容可解析、样本包含”，不是全互联网覆盖率。
`mihomo -t` 仅用于配置校验，不能代替这些下载检查，也不能代替实际流量的命中日志验证。

旧配置中的 Emby 专用列表、个人源 IP 直连、UDP/443 拦截及个别站点偏好仍应通过下面的自定义入口配置，
不会自动复制成所有用户的默认规则。

用户自定义规则集同样支持 `url`、`path`、`format`、`behavior`、`interval`、`proxy` 和 `rule_options`：

```yaml
custom_rule_providers:
  - name: private_ai
    behavior: classical
    format: text
    url: https://example.com/private-ai.list
    policy: ai
    # 默认 DIRECT，也可以写 proxy: proxy
```

除了优化后的默认规则外，可以用简单列表把自定义规则直接插入指定策略组。列表项通常只写匹配器，生成器会自动追加策略：

```yaml
proxy_rules:
  - DOMAIN-SUFFIX,example-proxy.test

direct_rules:
  - DOMAIN-SUFFIX,example-direct.test

group_rules:
  chat:
    - DOMAIN-SUFFIX,example-telegram.test
  media:
    - DOMAIN-SUFFIX,example-media.test
```

`proxy_rules` 和 `direct_rules` 分别直接路由到 `proxy` 和 `DIRECT`；`group_rules` 的键可以使用任意已存在的内置组，例如 `ai`、`chat`、`media`、`dev`、`cloud`；详细模式下也可以使用 `telegram`、`openai` 等详细组。也支持写完整的 Mihomo 规则项，生成器会替换最后一个策略字段。

`local_rules` 会放在规则最前面，适合临时覆盖模板规则：

```yaml
local_rules:
  - DOMAIN-SUFFIX,example.com,ai
  - IP-CIDR,192.0.2.0/24,DIRECT,no-resolve
```

## 空订阅行为

- 只有远程订阅：地区组自动选择匹配地区的订阅节点；无匹配节点的地区组拒绝连接。
- 只有手写节点：手写节点进入 `my_proxy`，可通过 `proxy` / `all_nodes` 使用；地区组拒绝连接。
- 两者都有：地区组只使用订阅节点，手写节点仍通过独立的 `my_proxy` 入口使用。
- 两者都没有：`my_proxy`、`proxy` 和默认规则兜底仍可回退到 `DIRECT`，但显式选择地区组时拒绝连接。

## 兼容说明

`default`、`my_proxy`、`all_nodes`、`domestic`、`other` 仍保留作为兼容入口。新配置建议使用 `proxy`、`final`、`china` 等简单名称。

模板已移除 Mihomo 已废弃的顶层 `global-client-fingerprint`。协议相关的 `client-fingerprint` 应放在具体手写节点中，订阅节点则由订阅内容提供。

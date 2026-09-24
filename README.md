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

```bash
ruby web_server.rb
# 浏览器打开 http://127.0.0.1:4567
```

生成过程使用临时目录，不会覆盖仓库中的 `config-values.yaml` 或其他配置文件。可通过环境变量修改监听地址和端口：

```bash
HOST=127.0.0.1 PORT=4567 ruby web_server.rb
```

前端文件位于 `web/index.html`，支持浏览器本地保存 YAML 编辑内容、生成配置和下载结果。
表单模式与 YAML 模式相互独立，不自动转换；表单字段（包括 WG 密钥）不保存到 localStorage。
默认只展开基础设置和节点订阅；WireGuard、自定义规则和外部规则集统一放在“高级配置”中，按需展开。折叠不会清空或停用已经填写的参数。
生成成功后会自动弹出只读配置预览，可复制内容或点击“下载配置”保存为 `config.yaml`；页面外不再提供重复的下载按钮。
若浏览器限制导致自动复制失败，会选中文本并提示手动复制。预览不会额外保存生成内容到浏览器；请妥善保管其中的订阅和密钥。

表单的“基础设置”中提供 **启用 IP4P（实验功能）** 开关，默认不勾选。
勾选后生成 `experimental.dialer-ip4p-convert: true`，不自动开启 IPv6 或修改 WG 节点；
需要运行配置的 Mihomo 核心支持这个字段。开关只影响表单模式，YAML 模式仍以编辑内容为准。

### 在表单中添加 WG 节点

点击 **添加 WG 节点**，填写名称、服务器、端口、客户端隧道地址、客户端私钥、服务端公钥和 `allowed-ips` 网段。
支持添加/移除多个节点，以及预共享密钥、MTU、保活秒数、服务器 IPv4/IPv6 解析偏好。
客户端地址不带 CIDR 前缀，IPv4 / IPv6 至少填一个；网段和域名列表每行一项。

分流方式可以选择：

- 按 `allowed-ips` 自动生成网段规则；
- 只为指定的较窄网段生成规则；
- 仅分流域名（生成 `routes: []`，必须填写域名）。

名称为 `office` 时生成 `wg_office_node` 和 `wg_office`，不混入普通出口，失败不自动回落直连。
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
禁用额外 Linux capabilities。无需挂载私人配置或源代码。
可以通过环境变量（或 Compose 同目录的 `.env`）设置：

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `MIHOMO_WEB_IMAGE` | 上述 GHCR 镜像的 `latest` | 切换版本、本地镜像或 fork 的镜像地址 |
| `WEB_BIND_ADDRESS` | `127.0.0.1` | 宿主机绑定地址 |
| `WEB_PORT` | `4567` | 宿主机端口；容器内仍为 4567 |

例如 `WEB_PORT=8080 docker compose up -d --wait`，随后访问 `http://127.0.0.1:8080`。
**当前 Web/API 没有登录鉴权，不要直接暴露到公网。** 如需其他设备访问，应先部署有访问控制和 HTTPS 的反向代理。
表单里的“Web 密钥”是生成的 Mihomo 配置密钥，不是这个生成器网站的登录密码。

创建结果保存在服务进程内存中，重启后原有下载 URL 失效；请及时下载。
浏览器 YAML 编辑内容可能保存在该浏览器的 localStorage 中，其中可能包含密钥，不建议在共享浏览器上使用。

#### 本地构建（无需等待 GHCR 发布）

```bash
docker build -t mihomo-config-web:local .
MIHOMO_WEB_IMAGE=mihomo-config-web:local docker compose up -d --wait
```

`.dockerignore` 使用白名单，Dockerfile 也只显式复制运行需要的 5 个源文件；
不会将私人 values、生成的配置、订阅凭据或 `.git` 打进镜像。运行环境无需 Node.js 或额外应用 gem。

#### GitHub Actions 构建与发布

[`.github/workflows/docker.yml`](.github/workflows/docker.yml) 自动执行：

- PR 到 `main`：运行生成器和表单测试，构建原生镜像，并通过 Compose 测试页面、健康检查、IP4P、WG 生成和下载；不发布镜像。
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

旧的 `/api/generate` 接口仍然保留，用于兼容当前页面。

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
此入口在模板渲染、`fake_ip_filter` 追加完成后执行，优先级最高。
生成文件把 `config_overrides` 中的配置块按你填写的顺序放在最前面，块内也优先显示你填写的字段，
其余默认字段随后保留。同一个配置键只输出一次；显示顺序本身不会改变 Mihomo 的匹配优先级。

- 配置块（mapping）递归合并；未提及的字段保留。
- 列表整体替换，不按名称合并或自动追加。例如覆盖 `rules`、`proxies`、`proxy-groups` 时需给出完整列表。
- 标量直接替换，`false`、`0`、空字符串等不会被当成未配置。
- `null` 写成 YAML 空值，不表示删除字段；`{}` 是空合并，不会清空已有配置块。
- 使用最终 Mihomo 字段名，例如 `mixed-port`、`external-controller`，不是生成器输入名 `port`、`web_port`。
- 未设置或写成 `{}` 时，输出格式保持不变；非空覆盖会重新序列化 YAML，不保留模板注释和原有排版。
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

只使用简单分类组：

```text
proxy → region / all_nodes → node
ai → proxy
game → proxy
media → proxy
chat → proxy
dev → proxy
cloud → proxy
download → proxy
adult → proxy
china → DIRECT
other → final
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
- Cloud：`google`、`apple`、`microsoft`、`onedrive`

## 地区组

所有地区组都是可手动选择的 `select` 组，并以内置隐藏的 `url-test` 子组作为默认项：

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

地区组显示为 `jp`、`hk` 等名称；`jp_auto` 等自动测速子组默认隐藏，不影响手动选择地区组。手动选择地区组后可以在其中切换自动测速结果或 `my_proxy`。

默认每 300 秒重新测速；当新节点比当前节点快超过 `tolerance`（默认 50ms）时切换。`lazy: true` 表示只有该组真正被使用时才开始测速。

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
`proxy`、地区组和测速组在没有订阅或手写节点时通过 `my_proxy` 回退到 `DIRECT`。
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

- 只有远程订阅：provider 和地区组正常使用订阅节点。
- 只有手写节点：手写节点进入 `my_proxy`，其他组通过它使用节点。
- 两者都有：远程和手写节点都可用。
- 两者都没有：`my_proxy`、`proxy`、地区组、规则兜底均可回退到 `DIRECT`。

## 兼容说明

`default`、`my_proxy`、`all_nodes`、`domestic`、`other` 仍保留作为兼容入口。新配置建议使用 `proxy`、`final`、`china` 等简单名称。

模板已移除 Mihomo 已废弃的顶层 `global-client-fingerprint`。协议相关的 `client-fingerprint` 应放在具体手写节点中，订阅节点则由订阅内容提供。

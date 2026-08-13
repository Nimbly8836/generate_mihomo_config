# gen-mihomo-config

用一个 `values.yaml` 渲染 `config-template.yaml.erb`，生成最终的 Mihomo 配置。

## 用法

```bash
ruby generate_mihomo_config.rb --values config-values.yaml --output config.yaml
```

也可以直接参考仓库里的示例：

```bash
cp config-values.example.yaml config-values.yaml
ruby generate_mihomo_config.rb -v config-values.yaml
```

默认会生成 `config.yaml`。如果 `port`、`web_port`、`tun_device`、`dns_split_cn_foreign`、`web_secret` 没写，脚本会自动补默认值。

## values 结构

```yaml
proxy_providers: []

local_proxies: []
# 可选：将上面的 [] 替换为手写节点列表
# local_proxies:
#   - name: local_ss
#     type: ss
#     server: "127.0.0.1"
#     port: 8388
#     cipher: aes-128-gcm
#     password: "change-me"

local_proxy_groups: []
  # - name: custom_group
  #   type: select
  #   proxies:
  #     - DIRECT
  #     - hong_kong
  #     - japan

custom_rule_providers: []
  # - name: mx_emby
  #   behavior: classical
  #   format: text
  #   path: ./rules/mx_emby.list
  #   policy: mx_emby
  # - name: private_ai
  #   behavior: classical
  #   format: yaml
  #   url: "https://example.com/private-ai.yaml"
  #   path: ./rule_providers/private_ai.yaml
  #   interval: 86400
  #   policy: openai
  #   rule_options:
  #     - no-resolve

local_rules:
  - DOMAIN-SUFFIX,example.com,custom_group

# 是否按国内外分流 DNS
# false: 默认值，不区分国内外，不启用 fallback
# true: 启用 nameserver-policy + fallback + fallback-filter
dns_split_cn_foreign: false

# 额外追加到 dns.fake-ip-filter 的域名
fake_ip_filter:
  - "+.example.com"
  - "stun.example.net"
```

字段说明：

- `proxy_providers`: 可选的远程订阅列表；每个条目都需要 `name` 和 `url`
- `local_proxies`: 本地静态节点列表，可在没有远程订阅时独立使用
- `local_proxy_groups`: 额外自定义策略组，直接按 Mihomo `proxy-groups` 项的结构填写
- `custom_rule_providers`: 额外自定义规则集；支持本地 `path` 文件和远程 `url`，并自动生成对应的 `RULE-SET`
- `local_rules`: 额外自定义规则，按写入顺序插入到规则最前面
- `fake_ip_filter`: 额外追加到 `dns.fake-ip-filter` 的域名列表；不会覆盖模板内置默认项
- `dns_split_cn_foreign`: 是否按国内外分流 DNS；默认 `false`

### 节点来源模式

1. **仅远程订阅**：所有基于 provider 的策略组，包括地区组、`private_vps`、`all_nodes` 和 `auto_select`，继续使用订阅节点。
2. **仅手写节点**：手写节点只直接属于 `local_proxy`；其他节点策略组通过 `local_proxy` 使用这些节点。
3. **两者均为空**：不使用代理节点，代理出口回退到 `DIRECT`；现有的 `REJECT`/广告拦截规则仍然生效，生成的配置无需订阅或节点也可正常启动。

模板已移除顶层的 `global-client-fingerprint`。上面的 Shadowsocks（`type: ss`）示例不需要 `client-fingerprint`。仅当 Mihomo 文档明确所选协议支持该字段时才使用：手写本地节点应将其放在对应的 `local_proxies` 节点上；订阅节点则必须由订阅/provider 内容提供，因为生成器不会改写 provider 节点。

## 当前规则约定

- `local_proxy_groups` 会追加到 `proxy-groups:` 末尾，并自动成为 `default` 和所有业务策略组的可选项
- 自定义策略组不会注入地区/节点聚合组，也不会注入 `local_proxy`、`ad_block`、`auto_select`
- `custom_rule_providers` 会追加到 `rule-providers:`，并自动在 `rules:` 里生成 `RULE-SET,name,policy`
- `local_rules` 放在 `rules:` 最上面，优先级最高
- `fake_ip_filter` 会追加到 `dns.fake-ip-filter:` 末尾，并自动跳过与默认列表重复的项
- 中国大陆流量优先走 `domestic`
- `GEOSITE,geolocation-!cn` 默认走 `default`
- `GEOSITE,geolocation-!cn` 放在接近末尾的位置，只在前面的更具体规则都未命中时生效
- 最后一条仍然是 `MATCH,other`，作为最终兜底

## 直接增加一个分组和规则

```yaml
proxy_providers:
  - name: default_provider
    url: "https://example.com/subscription.yaml"

local_proxies: []

local_proxy_groups:
  - name: custom_group
    type: select
    proxies:
      - DIRECT
      - hong_kong
      - japan
      - singapore

local_rules:
  - DOMAIN-SUFFIX,example.com,custom_group

custom_rule_providers:
  - name: mx_emby
    behavior: classical
    format: text
    path: ./rules/mx_emby.list
    policy: custom_group

fake_ip_filter:
  - "+.example.com"
  - "stun.example.net"
```

说明：

- `local_proxy_groups` 里直接写完整策略组，不支持复用模板内部的 anchor，比如 `<<: *pr`
- 自定义策略组会自动进入全局和业务策略组，无需逐个修改模板；地区及节点聚合组保持不变
- `custom_rule_providers` 的 `policy` 写命中的策略组名；`url` 和 `path` 二选一即可，`url + path` 则表示远程规则和本地缓存路径同时指定
- `custom_rule_providers` 的规则文件内容不要再写第三列策略名；例如 `classical + text` 文件里应写 `DOMAIN-SUFFIX,example.com`
- `custom_rule_providers.rule_options` 会拼到 `RULE-SET` 末尾，适合 `no-resolve` 这类额外参数
- `local_rules` 的第三列写你上面定义的分组名即可，比如 `custom_group`
- `fake_ip_filter` 只做追加，不会删掉模板里的默认兼容域名

## 文件说明

- `generate_mihomo_config.rb`: 读取 values 并渲染 ERB 模板
- `config-template.yaml.erb`: Mihomo 配置模板
- `config-values.example.yaml`: 最小可用示例

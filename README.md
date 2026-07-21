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

local_rules:
  - DOMAIN-SUFFIX,example.com,default

# 是否按国内外分流 DNS
# false: 默认值，不区分国内外，不启用 fallback
# true: 启用 nameserver-policy + fallback + fallback-filter
dns_split_cn_foreign: false
```

字段说明：

- `proxy_providers`: 可选的远程订阅列表；每个条目都需要 `name` 和 `url`
- `local_proxies`: 本地静态节点列表，可在没有远程订阅时独立使用
- `local_rules`: 额外自定义规则，按写入顺序插入到规则最前面
- `dns_split_cn_foreign`: 是否按国内外分流 DNS；默认 `false`

### 节点来源模式

1. **仅远程订阅**：现有的地区、全部节点和自动测速策略组继续使用订阅节点。
2. **仅手写节点**：手写节点只直接属于 `local_proxy`；其他节点策略组通过 `local_proxy` 使用这些节点。
3. **两者均为空**：各节点策略组通过 `local_proxy` 解析到 `DIRECT`，生成的配置仍可正常启动。

模板已移除顶层的 `global-client-fingerprint`。`client-fingerprint` 是否适用取决于节点协议；需要时应配置在 `local_proxies` 中对应的本地节点上。

## 当前规则约定

- `local_rules` 放在 `rules:` 最上面，优先级最高
- 中国大陆流量优先走 `domestic`
- `GEOSITE,geolocation-!cn` 默认走 `default`
- `GEOSITE,geolocation-!cn` 放在接近末尾的位置，只在前面的更具体规则都未命中时生效
- 最后一条仍然是 `MATCH,other`，作为最终兜底

## 文件说明

- `generate_mihomo_config.rb`: 读取 values 并渲染 ERB 模板
- `config-template.yaml.erb`: Mihomo 配置模板
- `config-values.example.yaml`: 最小可用示例

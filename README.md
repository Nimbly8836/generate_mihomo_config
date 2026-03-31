# gen-mihomo-config

用一个 `values.yaml` 渲染 `config-template.yaml`，生成最终的 Mihomo 配置。

## 用法

```bash
ruby generate_mihomo_config.rb --values config-values.yaml --output config.yaml
```

也可以直接参考仓库里的示例：

```bash
cp config-values.example.yaml config-values.yaml
ruby generate_mihomo_config.rb -v config-values.yaml
```

默认会生成 `config.yaml`。如果 `port`、`web_port`、`tun_device`、`web_secret` 没写，脚本会自动补默认值。

## values 结构

```yaml
proxy_providers:
  - name: provider_name
    url: "https://example.com/subscription.yaml"

local_proxies: []

local_rules:
  - DOMAIN-SUFFIX,example.com,default
```

字段说明：

- `proxy_providers`: 远程订阅列表，至少需要 `name` 和 `url`
- `local_proxies`: 本地静态节点列表
- `local_rules`: 额外自定义规则，按写入顺序插入到规则最前面

## 当前规则约定

- `local_rules` 放在 `rules:` 最上面，优先级最高
- 中国大陆流量优先走 `domestic`
- `GEOSITE,geolocation-!cn` 默认走 `default`
- `GEOSITE,geolocation-!cn` 放在接近末尾的位置，只在前面的更具体规则都未命中时生效
- 最后一条仍然是 `MATCH,other`，作为最终兜底

## 文件说明

- `generate_mihomo_config.rb`: 读取 values 并渲染 ERB 模板
- `config-template.yaml`: Mihomo 配置模板
- `config-values.example.yaml`: 最小可用示例

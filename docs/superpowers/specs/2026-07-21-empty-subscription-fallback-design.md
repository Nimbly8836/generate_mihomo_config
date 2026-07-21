# Empty-Subscription and DIRECT Fallback Design

## 中文审查摘要

本设计让生成器在没有远程订阅时仍能产出可由 Mihomo 启动的配置：订阅型策略组改为引用 `local_proxy`；如果也没有手写节点，`local_proxy` 使用 `DIRECT`，形成纯直连配置。同时删除 Mihomo 已移除的顶层 `global-client-fingerprint` 配置，但不擅自为具体节点补充协议相关的 `client-fingerprint`。

影响范围限定在 ERB 模板、回归测试和示例说明，不改变 values 文件结构，也不改变存在远程订阅时的策略组行为。主要风险是 Mihomo 对策略组嵌套引用的校验，以及测试环境可能没有安装 Mihomo；因此测试同时包含不依赖外部二进制的结构断言，以及检测到 Mihomo 时执行的集成校验。

待确认的关键决定已经收敛为：手写节点只直接进入 `local_proxy`；无订阅时其他订阅型策略组通过 `local_proxy` 间接使用它们；无任何节点时允许纯 `DIRECT` 启动。

## Problem Statement

The generator accepts remote providers through `proxy_providers` and handwritten static nodes through `local_proxies`. The template currently renders an empty `use` list into provider-backed proxy groups when `proxy_providers` is empty. Mihomo treats an empty `use` list as missing and rejects the generated configuration with an error such as:

```text
proxy group[0]: private_vps: `use` or `proxies` missing
```

Although handwritten nodes are rendered under the top-level `proxies` key and collected by the `local_proxy` group, they do not provide a fallback for `private_vps`, the regional groups, `all_nodes`, or `auto_select`.

The template also emits the removed top-level field:

```yaml
global-client-fingerprint: random
```

Current Mihomo versions report that `client-fingerprint` must instead be configured on an individual proxy where the relevant protocol supports it.

## Goals

1. Generate a valid Mihomo configuration when remote subscriptions are absent.
2. Keep handwritten nodes directly owned only by the `local_proxy` group.
3. Let provider-backed groups remain usable without subscriptions by referencing `local_proxy`.
4. Generate a valid DIRECT-only configuration when both remote subscriptions and handwritten nodes are absent.
5. Remove the obsolete global client-fingerprint setting.
6. Preserve existing behavior when one or more remote providers are configured.

## Non-Goals

- Automatically classifying handwritten nodes into regional groups.
- Combining handwritten nodes directly with remote-provider nodes.
- Adding `client-fingerprint` to every handwritten proxy.
- Redesigning the existing proxy-group hierarchy or routing rules.
- Addressing unrelated Mihomo warnings or changing the values schema.

## Proposed Design

### Provider-backed group fallback

The shared `provider_use_defaults` anchor remains the single source of provider membership for `private_vps`, regional groups, and `all_nodes`.

When `provider_names` is non-empty, the anchor preserves its current output:

```yaml
type: select
use:
  - provider_name
```

When `provider_names` is empty, the anchor instead emits:

```yaml
type: select
proxies:
  - local_proxy
```

Each inheriting group therefore has a non-empty `proxies` collection. Existing `filter` and `exclude-filter` fields remain in the generated configuration; they are relevant when providers are present and do not alter the explicit `local_proxy` fallback.

**中文提示：** 这里不把每个手写节点复制到所有地区组，而只引用统一入口 `local_proxy`，避免节点归属重复和行为扩散。

### Automatic selection fallback

When providers are present, `auto_select` retains its current provider-based `use` list and `DIRECT` candidate.

When providers are absent, `auto_select` emits exactly the following membership, with no `use` key and no separate `DIRECT` candidate:

```yaml
proxies:
  - local_proxy
```

This keeps all handwritten nodes directly confined to `local_proxy` and prevents `auto_select` from preferring a separately listed `DIRECT` candidate over the local group. If `local_proxy` itself contains only `DIRECT`, the nested fallback remains a valid direct route.

### DIRECT-only mode

The existing `local_proxy` behavior is retained:

- With handwritten nodes, its `proxies` list contains those node names.
- Without handwritten nodes, its `proxies` list contains `DIRECT`.

Combining this behavior with the provider-backed fallback ensures that every referenced strategy group remains resolvable even when both input lists are empty. The output is not stripped down to a minimal file; it preserves the normal routing and group structure while all proxy-capable paths ultimately resolve to `DIRECT`.

### Client fingerprint migration

The top-level `global-client-fingerprint: random` field is removed from the template.

No replacement is generated automatically. A per-proxy `client-fingerprint` is protocol-specific and should remain an optional field supplied in the corresponding `local_proxies` entry or remote-provider content. The generator already preserves additional proxy fields, so no values-schema change is necessary.

**中文提示：** “删除全局字段”不等于“关闭所有指纹能力”；需要指纹的节点仍可自行设置节点级 `client-fingerprint`。

## Data Flow

1. The generator loads and normalizes `proxy_providers` and `local_proxies`.
2. `TemplateContext#provider_names` and `TemplateContext#local_proxy_names` expose the normalized names to ERB.
3. The template renders `local_proxy` from `local_proxy_names`, falling back to `DIRECT` when empty.
4. The template renders provider-backed groups from `provider_names`:
   - provider names present → `use` remote providers;
   - provider names absent → `proxies: [local_proxy]`.
5. The generator writes the rendered YAML without adding runtime Mihomo validation; parsing and Mihomo validation are verification responsibilities described below.

No new runtime state, configuration key, or helper API is introduced.

## Error Handling and Compatibility

Existing validation for malformed providers, malformed local proxies, and missing required fields remains unchanged. This design handles valid empty arrays as a supported operating mode rather than treating them as an input error. The current generator does not validate duplicate names or collisions with built-in proxy-group names; collision-free names remain an input assumption, and adding collision validation is outside this change.

Backward compatibility is maintained for configurations with providers because their rendered `use` lists do not change. Handwritten node definitions also remain unchanged. The only unconditional output difference is removal of the obsolete `global-client-fingerprint` field.

## Testing Strategy

Regression tests will invoke the generator through its command-line interface using temporary values and output files. Tests will assert parsed YAML behavior rather than depending only on textual formatting.

Required cases:

1. **No providers, one handwritten node**
   - `local_proxy` contains the handwritten node.
   - Provider-backed groups contain exactly `proxies: [local_proxy]` for membership and omit `use`.
   - `auto_select` contains exactly `proxies: [local_proxy]` for membership and omits `use`.
   - Across every proxy group, the handwritten node name appears directly only in `local_proxy`.

2. **No providers, no handwritten nodes**
   - `local_proxy` contains `DIRECT`.
   - Provider-backed groups and `auto_select` remain resolvable through `local_proxy`.
   - The configuration supports DIRECT-only startup.

3. **Provider present, with and without a handwritten node**
   - A normalized structural comparison verifies that every affected group preserves its current type, provider `use` list, filters, exclusions, `auto_select` tolerance, and existing `DIRECT` candidate.
   - Neither `local_proxy` nor a handwritten node is added directly to provider-backed groups.
   - Across every proxy group, a handwritten node name appears directly only in `local_proxy`.

4. **Removed global fingerprint**
   - The generated top-level mapping does not contain `global-client-fingerprint`.
   - Extra node-level fields such as `client-fingerprint` continue to pass through unchanged.

5. **Mihomo integration validation**
   - When the `mihomo` executable is available, run `mihomo -t -f <generated-config>` for the local-node and DIRECT-only cases.
   - If Mihomo is unavailable in a developer environment, skip only the binary integration assertion; structural regression tests remain mandatory.
   - Completion cannot be claimed until both empty-provider cases have passed validation with a supported Mihomo version, either locally or in CI.

The implementation will follow test-driven development. The empty-provider and obsolete-field regression tests must first fail for the expected reasons. Provider-present preservation and node-field passthrough are characterization tests and may pass before the production change; they must remain green throughout implementation.

## Alternatives Considered

### Duplicate conditional logic in every proxy group

Each provider-backed group could independently choose between `use` and `proxies`. This is explicit but duplicates ERB logic and makes future groups easy to implement inconsistently.

### Remove provider-backed groups when providers are absent

The template could omit regional and provider-derived groups entirely. However, many business groups and routing rules reference them, requiring broad conditional rewriting. This increases risk and produces structurally different configurations for little practical benefit.

### Insert handwritten nodes directly into every group

This would make each group independently selectable or testable, but it violates the requirement that handwritten nodes directly belong only to `local_proxy`, duplicates membership, and silently changes semantics when providers coexist with local nodes.

## Technical Vocabulary / 技术词汇

- **fallback** — 兜底方案
- **provider-backed group** — 由订阅提供者支撑的策略组
- **handwritten static node** — 手写静态节点
- **nested reference** — 嵌套引用
- **resolvable** — 可解析并最终指向有效目标的
- **backward compatibility** — 向后兼容性
- **obsolete field** — 已废弃字段
- **protocol-specific** — 协议相关的
- **structural assertion** — 结构性断言
- **integration validation** — 集成校验

## 审查清单

- [ ] 确认无订阅时，地区组、`private_vps`、`all_nodes` 通过 `local_proxy` 间接使用手写节点。
- [ ] 确认有订阅时保持现有 `use` 行为，不自动混入手写节点。
- [ ] 确认订阅和手写节点都为空时允许纯 `DIRECT` 启动。
- [ ] 确认删除顶层 `global-client-fingerprint`，但允许节点级 `client-fingerprint` 原样透传。
- [ ] 确认不在本次修改中重构策略组层级或处理其他无关警告。
- [ ] 确认 Mihomo 不可用时仅跳过集成校验，结构测试仍必须执行。

# Empty-Subscription Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate Mihomo configurations that validate with handwritten-only or DIRECT-only inputs, while removing the obsolete global fingerprint field and preserving provider-present behavior.

**Architecture:** Keep normalization and validation in `TemplateContext` unchanged. Express the new behavior only at the two shared ERB membership points: the `provider_use_defaults` anchor and `auto_select`. Add CLI-level Minitest coverage that parses generated YAML, characterizes provider-present output, enforces local-node ownership, and optionally invokes Mihomo for integration validation.

**Tech Stack:** Ruby, ERB, Psych/YAML, Minitest from the Ruby standard library, Open3, Mihomo CLI, GitNexus CLI.

---

## 中文实施摘要

本计划先建立“有订阅时行为不变”的特征测试，再写两个会失败的空订阅回归测试，随后只修改模板的公共策略组入口。第二个 TDD 循环删除 `global-client-fingerprint` 并验证节点级 `client-fingerprint` 继续透传。最后更新示例和 README，并用 Mihomo 1.19.27 或兼容版本实际校验“手写节点模式”和“纯 DIRECT 模式”。

实施不会修改 `generate_mihomo_config.rb` 的 values 结构或校验逻辑，也不会触碰仓库中现有的未跟踪私有配置文件。模板修改前必须执行 GitNexus 影响分析；每次提交前必须执行 `gitnexus detect-changes`。

## File Responsibility Map

- Create `test/generate_mihomo_config_test.rb`: CLI-level structural and Mihomo integration tests.
- Create `test/fixtures/provider-present-groups.yaml`: normalized golden snapshot for affected provider-present groups, captured before production changes.
- Modify `config-template.yaml.erb`: no-provider group fallback and obsolete fingerprint removal.
- Modify `config-values.example.yaml`: document optional providers and handwritten-only/DIRECT-only input.
- Modify `README.md`: explain supported source combinations and node-level fingerprints.
- Do not modify `generate_mihomo_config.rb`: existing normalization and pass-through behavior are sufficient.
- Do not modify or stage `config-values.yaml`, `config-lw.yaml`, `lw-vps.yaml`, `config.yaml`, or other user-specific untracked/ignored files.

## Task 0: Prepare an isolated, fresh analysis baseline

**Files:**
- Verify only; do not modify project files.

- [ ] **Step 1: Work in an isolated Git worktree**

Use the `superpowers:using-git-worktrees` workflow before implementation. Confirm the worktree starts from the approved spec and plan commits. Never copy user-specific untracked configuration files into the worktree.

- [ ] **Step 2: Refresh GitNexus without rewriting project context files**

Run:

```bash
npx gitnexus status
npx gitnexus analyze --index-only
npx gitnexus status
```

Expected: the final status reports the implementation worktree's current commit as indexed. Always use `--index-only` in this repository because `.claude/`, `AGENTS.md`, and `CLAUDE.md` may be untracked in the original workspace.

- [ ] **Step 3: Record user-file integrity when any private files are present**

Run:

```bash
baseline=/tmp/gen-mihomo-config-user-files.sha256
: > "$baseline"
for file in config-values.yaml config-lw.yaml lw-vps.yaml config.yaml; do
  [ ! -e "$file" ] || shasum -a 256 "$file" >> "$baseline"
done
git status --short --untracked-files=all
printf 'Recorded %s protected file hashes\n' "$(wc -l < "$baseline" | tr -d ' ')"
```

Expected in a clean worktree: zero protected files. If executing in the original workspace, retain the baseline for Task 5 and use only path-specific `git add`; never use `git add .` or `git add -A`.

## Task 1: Establish provider-present characterization coverage

**Files:**
- Create: `test/generate_mihomo_config_test.rb`
- Create: `test/fixtures/provider-present-groups.yaml`

- [ ] **Step 1: Create the test directories and test harness**

Run:

```bash
mkdir -p test/fixtures
```

Then create `test/generate_mihomo_config_test.rb` with:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

class GenerateMihomoConfigTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  GENERATOR = File.join(ROOT, "generate_mihomo_config.rb")
  TEMPLATE = File.join(ROOT, "config-template.yaml.erb")
  PROVIDER_GROUP_NAMES = %w[
    private_vps
    hong_kong
    taiwan
    japan
    united_states
    singapore
    other_regions
    all_nodes
  ].freeze
  SNAPSHOT_GROUP_NAMES = (PROVIDER_GROUP_NAMES + %w[auto_select]).freeze

  def with_generated_config(values)
    Dir.mktmpdir("mihomo-generator-test") do |directory|
      values_path = File.join(directory, "values.yaml")
      output_path = File.join(directory, "config.yaml")
      File.write(values_path, YAML.dump(values))

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        GENERATOR,
        "--values", values_path,
        "--template", TEMPLATE,
        "--output", output_path
      )

      assert status.success?, "generator failed:\n#{stdout}\n#{stderr}"
      config = YAML.safe_load_file(output_path, permitted_classes: [], aliases: true)
      yield config, output_path
    end
  end

  def proxy_group(config, name)
    config.fetch("proxy-groups").find { |group| group.fetch("name") == name } ||
      flunk("missing proxy group #{name}")
  end

  def normalized_affected_groups(config)
    SNAPSHOT_GROUP_NAMES.to_h do |name|
      [name, proxy_group(config, name).reject { |key, _| key == "name" }]
    end
  end

  def handwritten_proxy(name: "handwritten", extra: {})
    {
      "name" => name,
      "type" => "ss",
      "server" => "127.0.0.1",
      "port" => 8388,
      "cipher" => "aes-128-gcm",
      "password" => "test-password"
    }.merge(extra)
  end

  def provider_present_values
    {
      "proxy_providers" => [
        {
          "name" => "remote_provider",
          "url" => "https://example.com/subscription.yaml"
        }
      ],
      "local_proxies" => [handwritten_proxy],
      "local_rules" => []
    }
  end

  def directly_referencing_groups(config, proxy_name)
    config.fetch("proxy-groups").filter_map do |group|
      group.fetch("name") if Array(group["proxies"]).include?(proxy_name)
    end
  end

  def mihomo_available?
    system("command -v mihomo >/dev/null 2>&1")
  end

  def assert_mihomo_valid(output_path)
    Dir.mktmpdir("mihomo-test-home") do |home|
      stdout, stderr, status = Open3.capture3(
        "mihomo", "-d", home, "-t", "-f", output_path
      )
      assert status.success?, "mihomo validation failed:\n#{stdout}\n#{stderr}"
    end
  end

  def test_provider_present_groups_match_characterized_structure
    expected = YAML.safe_load_file(
      File.join(__dir__, "fixtures", "provider-present-groups.yaml"),
      permitted_classes: [],
      aliases: true
    )

    [
      [[handwritten_proxy], ["handwritten"], ["local_proxy"]],
      [[], ["DIRECT"], []]
    ].each do |local_proxies, expected_local_members, handwritten_references|
      values = provider_present_values.merge("local_proxies" => local_proxies)

      with_generated_config(values) do |config, _output_path|
        assert_equal expected, normalized_affected_groups(config)
        assert_equal expected_local_members, proxy_group(config, "local_proxy").fetch("proxies")
        assert_equal handwritten_references,
                     directly_referencing_groups(config, "handwritten")
      end
    end
  end
end
```

- [ ] **Step 2: Capture the pre-change normalized provider-present snapshot**

Run this before any production template edit:

```bash
ruby -Itest -r./test/generate_mihomo_config_test -e '
  test = GenerateMihomoConfigTest.new("snapshot")
  test.with_generated_config(test.provider_present_values) do |config, _|
    snapshot = test.normalized_affected_groups(config)
    File.write("test/fixtures/provider-present-groups.yaml", YAML.dump(snapshot))
  end
'
```

Expected: `test/fixtures/provider-present-groups.yaml` contains all eight provider-backed groups and `auto_select` (nine groups total), including current types, filters, exclusions, provider `use`, `DIRECT`, and tolerance values. `local_proxy` is asserted separately for both local-node variants.

- [ ] **Step 3: Inspect the snapshot for accidental dynamic or secret data**

Run:

```bash
ruby -ryaml -e '
  data = YAML.safe_load_file("test/fixtures/provider-present-groups.yaml", aliases: true)
  abort "wrong groups" unless data.keys.sort == %w[all_nodes auto_select hong_kong japan other_regions private_vps singapore taiwan united_states].sort
  abort "secret leaked" if File.read(ARGV[0]).match?(/test-password|web_secret/)
  puts "snapshot groups=#{data.keys.length}; no secret data"
' test/fixtures/provider-present-groups.yaml
```

Expected: `snapshot groups=9; no secret data`.

- [ ] **Step 4: Run the characterization test**

Run:

```bash
ruby -Itest test/generate_mihomo_config_test.rb --name test_provider_present_groups_match_characterized_structure
```

Expected: PASS before any template behavior changes.

- [ ] **Step 5: Stage exact paths and check affected scope before committing**

Run:

```bash
git add test/generate_mihomo_config_test.rb test/fixtures/provider-present-groups.yaml
npx gitnexus detect-changes --scope staged --repo generate_mihomo_config
```

Expected: the staged diff contains only the new test and fixture. GitNexus may report no mapped symbols for new files; staged path inspection remains authoritative.

- [ ] **Step 6: Commit the characterization coverage and refresh the index**

```bash
git commit -m "test: characterize provider-backed groups"
npx gitnexus analyze --index-only
```

Expected: the graph index is fresh for the new commit before subsequent impact analysis.

## Task 2: Implement handwritten-only and DIRECT-only fallbacks

**Files:**
- Modify: `test/generate_mihomo_config_test.rb`
- Modify: `config-template.yaml.erb:324-337`
- Modify: `config-template.yaml.erb:520-534`

- [ ] **Step 1: Add the failing empty-provider regression tests**

Insert these methods before the final `end` in `test/generate_mihomo_config_test.rb`:

```ruby
  def test_handwritten_only_structure_routes_provider_groups_through_local_proxy
    values = {
      "proxy_providers" => [],
      "local_proxies" => [handwritten_proxy],
      "local_rules" => []
    }

    with_generated_config(values) do |config, _output_path|
      assert_equal ["handwritten"], proxy_group(config, "local_proxy").fetch("proxies")

      PROVIDER_GROUP_NAMES.each do |name|
        group = proxy_group(config, name)
        assert_equal ["local_proxy"], group.fetch("proxies"), name
        refute group.key?("use"), name
      end

      auto_select = proxy_group(config, "auto_select")
      assert_equal ["local_proxy"], auto_select.fetch("proxies")
      refute auto_select.key?("use")
      assert_equal ["local_proxy"], directly_referencing_groups(config, "handwritten")
    end
  end

  def test_direct_only_structure_uses_local_proxy_fallback
    values = {
      "proxy_providers" => [],
      "local_proxies" => [],
      "local_rules" => []
    }

    with_generated_config(values) do |config, _output_path|
      assert_equal ["DIRECT"], proxy_group(config, "local_proxy").fetch("proxies")

      PROVIDER_GROUP_NAMES.each do |name|
        group = proxy_group(config, name)
        assert_equal ["local_proxy"], group.fetch("proxies"), name
        refute group.key?("use"), name
      end

      auto_select = proxy_group(config, "auto_select")
      assert_equal ["local_proxy"], auto_select.fetch("proxies")
      refute auto_select.key?("use")
    end
  end

  def test_handwritten_only_config_validates_with_mihomo
    skip "mihomo executable is unavailable" unless mihomo_available?

    values = {
      "proxy_providers" => [],
      "local_proxies" => [handwritten_proxy],
      "local_rules" => []
    }

    with_generated_config(values) do |_config, output_path|
      assert_mihomo_valid(output_path)
    end
  end

  def test_direct_only_config_validates_with_mihomo
    skip "mihomo executable is unavailable" unless mihomo_available?

    values = {
      "proxy_providers" => [],
      "local_proxies" => [],
      "local_rules" => []
    }

    with_generated_config(values) do |_config, output_path|
      assert_mihomo_valid(output_path)
    end
  end
```

- [ ] **Step 2: Run both structural tests and verify RED**

Run:

```bash
ruby -Itest test/generate_mihomo_config_test.rb --name '/structure/'
```

Expected: both structural tests FAIL because provider-backed groups expose an empty `use` instead of `proxies: [local_proxy]`. Structural assertions never skip, regardless of Mihomo availability.

- [ ] **Step 3: Run GitNexus impact analysis before editing template-dependent symbols**

Run:

```bash
npx gitnexus impact --repo generate_mihomo_config --direction upstream config-template.yaml.erb
npx gitnexus context --repo generate_mihomo_config config-template.yaml.erb
npx gitnexus impact --repo generate_mihomo_config --direction upstream provider_names
npx gitnexus impact --repo generate_mihomo_config --direction upstream local_proxy_names
npx gitnexus context --repo generate_mihomo_config provider_names
npx gitnexus context --repo generate_mihomo_config local_proxy_names
```

Expected: GitNexus may report zero graph dependants because ERB references are not represented as call edges. Record that limitation and compensate with the CLI-level golden, structural, and Mihomo tests. If any result is HIGH or CRITICAL, stop and warn the user before editing.

- [ ] **Step 4: Change the shared provider membership anchor**

Replace the `provider_use_defaults` membership branch in `config-template.yaml.erb` with:

```erb
# 使用订阅节点的策略组默认参数
provider_use_defaults: &provider_use_defaults
  # 手动选择节点组
  type: select
<% if provider_names.empty? -%>
  # 没有远程订阅时统一使用本地静态节点组；该组自身会以 DIRECT 兜底
  proxies:
    - local_proxy
<% else -%>
  # 使用 values 文件中定义的所有远程订阅
  use:
<% provider_names.each do |name| -%>
    - <%= name %>
<% end -%>
<% end -%>
```

- [ ] **Step 5: Change `auto_select` to use the same no-provider fallback**

Replace the complete `auto_select` group with:

```erb
  # 自动测速选择节点
  - name: auto_select
    type: url-test
    tolerance: 2
<% if provider_names.empty? -%>
    proxies:
      - local_proxy
<% else -%>
    proxies:
      - DIRECT
    use:
<% provider_names.each do |name| -%>
      - <%= name %>
<% end -%>
<% end -%>
```

- [ ] **Step 6: Run the empty-provider tests and verify GREEN**

Run:

```bash
ruby -Itest test/generate_mihomo_config_test.rb --name '/handwritten_only|direct_only/'
```

Expected: 4 tests PASS. Structural tests never skip; the two separate integration tests skip only if Mihomo is unavailable. On the current machine Mihomo is installed, so all four must pass with zero skips.

- [ ] **Step 7: Run the provider characterization test**

Run:

```bash
ruby -Itest test/generate_mihomo_config_test.rb --name test_provider_present_groups_match_characterized_structure
```

Expected: PASS, proving provider-present structure and handwritten-node ownership are unchanged.

- [ ] **Step 8: Stage exact paths, run GitNexus change detection, commit, and refresh**

```bash
git add config-template.yaml.erb test/generate_mihomo_config_test.rb
npx gitnexus detect-changes --scope staged --repo generate_mihomo_config
git commit -m "fix: support configs without subscriptions"
npx gitnexus analyze --index-only
```

Expected: the staged diff contains only the template and regression tests. GitNexus may not map ERB dependencies; test evidence is the primary safety net.

## Task 3: Remove the obsolete global fingerprint safely

**Files:**
- Modify: `test/generate_mihomo_config_test.rb`
- Modify: `config-template.yaml.erb:23-24`

- [ ] **Step 1: Add fingerprint regression and characterization tests**

Insert these methods before the final `end` in `test/generate_mihomo_config_test.rb`:

```ruby
  def test_generated_config_omits_global_client_fingerprint
    values = {
      "proxy_providers" => [],
      "local_proxies" => [],
      "local_rules" => []
    }

    with_generated_config(values) do |config, _output_path|
      refute config.key?("global-client-fingerprint")
    end
  end

  def test_node_level_client_fingerprint_passes_through
    values = {
      "proxy_providers" => [],
      "local_proxies" => [
        handwritten_proxy(extra: { "client-fingerprint" => "chrome" })
      ],
      "local_rules" => []
    }

    with_generated_config(values) do |config, _output_path|
      proxy = config.fetch("proxies").find { |item| item.fetch("name") == "handwritten" }
      assert_equal "chrome", proxy.fetch("client-fingerprint")
    end
  end
```

- [ ] **Step 2: Verify the regression test is RED and the pass-through characterization is GREEN**

Run:

```bash
ruby -Itest test/generate_mihomo_config_test.rb --name test_generated_config_omits_global_client_fingerprint
ruby -Itest test/generate_mihomo_config_test.rb --name test_node_level_client_fingerprint_passes_through
```

Expected: the first test FAILS because the top-level field exists; the second test PASSES because arbitrary node-level fields already pass through.

- [ ] **Step 3: Remove the obsolete template field and its comment**

Delete both of these lines from `config-template.yaml.erb`:

```yaml
# TLS 指纹策略，random 可降低特征固定带来的风险
global-client-fingerprint: random
```

Do not leave the fingerprint comment attached to `keep-alive-interval`, and do not add any automatic per-proxy replacement.

- [ ] **Step 4: Run all tests and verify GREEN**

Run:

```bash
ruby -Itest test/generate_mihomo_config_test.rb
```

Expected: 7 tests PASS, zero failures; only the two dedicated integration tests may skip if `mihomo` is unavailable.

- [ ] **Step 5: Confirm the removed warning with an actual generated DIRECT-only config**

Run:

```bash
tmpdir=$(mktemp -d)
printf '%s\n' 'proxy_providers: []' 'local_proxies: []' 'local_rules: []' > "$tmpdir/values.yaml"
ruby generate_mihomo_config.rb --values "$tmpdir/values.yaml" --output "$tmpdir/config.yaml"
mihomo -v
output=$(mihomo -d "$tmpdir" -t -f "$tmpdir/config.yaml" 2>&1)
mihomo_status=$?
printf '%s\n' "$output"
test "$mihomo_status" -eq 0 || { rm -rf "$tmpdir"; exit "$mihomo_status"; }
case "$output" in
  *global-client-fingerprint*) rm -rf "$tmpdir"; exit 1 ;;
esac
rm -rf "$tmpdir"
```

Expected: the recorded Mihomo version is supported, configuration validation exits 0, and output contains no `global-client-fingerprint` message.

- [ ] **Step 6: Stage exact paths, run GitNexus change detection, commit, and refresh**

```bash
git add config-template.yaml.erb test/generate_mihomo_config_test.rb
npx gitnexus detect-changes --scope staged --repo generate_mihomo_config
git commit -m "fix: remove obsolete global fingerprint"
npx gitnexus analyze --index-only
```

## Task 4: Document optional subscriptions and local-only usage

**Files:**
- Modify: `config-values.example.yaml:12-20`
- Modify: `README.md:17-39`

- [ ] **Step 1: Update the example values file**

Replace the provider and local proxy example section with:

```yaml
# 远程订阅列表；可留空，name 不能重复
proxy_providers: []
# proxy_providers:
#   - name: default_provider
#     url: "https://example.com/subscription.yaml"

# 本地静态代理节点；可与订阅独立使用
local_proxies: []
# local_proxies:
#   - name: my_proxy
#     type: ss
#     server: 127.0.0.1
#     port: 8388
#     cipher: aes-128-gcm
#     password: "change-me"

# proxy_providers 和 local_proxies 都为空时，生成纯 DIRECT 配置
# client-fingerprint 是否适用取决于代理协议；需要时在对应节点中设置
```

Keep the existing `local_rules` example immediately after this section.

- [ ] **Step 2: Update the README values example and field descriptions**

Change the README example to show `proxy_providers: []` and a commented handwritten node, then state explicitly:

```markdown
`proxy_providers` 和 `local_proxies` 可以独立使用：

- 只有远程订阅：订阅节点继续进入现有地区组和自动选择组。
- 只有手写节点：节点只直接进入 `local_proxy`，其他节点策略组通过 `local_proxy` 使用它们。
- 两者都为空：所有节点策略最终通过 `local_proxy` 使用 `DIRECT`，配置仍可启动。

Mihomo 已移除顶层 `global-client-fingerprint`。如果某个代理协议需要指纹，请在对应的 `local_proxies` 节点中设置 `client-fingerprint`。
```

Also change the field description from “远程订阅列表，至少需要” to “可选的远程订阅列表；每项至少需要”. Correct the file description from `config-template.yaml` to `config-template.yaml.erb` while editing the same section.

- [ ] **Step 3: Run the complete automated test suite**

Run:

```bash
ruby -Itest test/generate_mihomo_config_test.rb
```

Expected: 7 tests PASS, no failures.

- [ ] **Step 4: Stage exact paths, run GitNexus change detection, and commit documentation**

```bash
git add README.md config-values.example.yaml
npx gitnexus detect-changes --scope staged --repo generate_mihomo_config
git commit -m "docs: explain local-only Mihomo configs"
npx gitnexus analyze --index-only
```

## Task 5: Final verification and scope audit

**Files:**
- Verify only; no expected production edits.

- [ ] **Step 1: Run all Ruby tests with deterministic seed output**

Run:

```bash
ruby -Itest test/generate_mihomo_config_test.rb --seed 1
```

Expected: 7 tests, zero failures and zero errors. On the current machine Mihomo is installed, so there must be zero skips.

- [ ] **Step 2: Verify handwritten-only output with Mihomo**

Run:

```bash
tmpdir=$(mktemp -d)
cat > "$tmpdir/values.yaml" <<'YAML'
proxy_providers: []
local_proxies:
  - name: handwritten
    type: ss
    server: 127.0.0.1
    port: 8388
    cipher: aes-128-gcm
    password: test-password
local_rules: []
YAML
ruby generate_mihomo_config.rb --values "$tmpdir/values.yaml" --output "$tmpdir/config.yaml"
mihomo -v
mihomo -d "$tmpdir" -t -f "$tmpdir/config.yaml"
status=$?
rm -rf "$tmpdir"
exit $status
```

Expected: exit status 0 and successful Mihomo configuration validation.

- [ ] **Step 3: Verify DIRECT-only output with Mihomo**

Run:

```bash
tmpdir=$(mktemp -d)
printf '%s\n' 'proxy_providers: []' 'local_proxies: []' 'local_rules: []' > "$tmpdir/values.yaml"
ruby generate_mihomo_config.rb --values "$tmpdir/values.yaml" --output "$tmpdir/config.yaml"
mihomo -v
mihomo -d "$tmpdir" -t -f "$tmpdir/config.yaml"
status=$?
rm -rf "$tmpdir"
exit $status
```

Expected: exit status 0 and successful Mihomo configuration validation.

- [ ] **Step 4: Audit graph impact and working tree scope**

Run:

```bash
npx gitnexus detect-changes --scope compare --base-ref HEAD~4 --repo generate_mihomo_config
git status --short --untracked-files=all
git diff --name-only HEAD~4..HEAD
git diff --stat HEAD~4..HEAD
baseline=/tmp/gen-mihomo-config-user-files.sha256
[ ! -s "$baseline" ] || shasum -a 256 -c "$baseline"
```

Expected:

- The comparison spans all four implementation commits, including the characterization fixture.
- GitNexus may not map the ERB dependency, but it must not report unexpected mapped symbols or flows.
- The four commits touch only `test/generate_mihomo_config_test.rb`, `test/fixtures/provider-present-groups.yaml`, `config-template.yaml.erb`, `README.md`, and `config-values.example.yaml`.
- Exact baseline hashes still match for every protected user-specific file; none is staged or committed.

- [ ] **Step 5: Request final code review**

Use the `superpowers:requesting-code-review` workflow. The reviewer must compare the implementation against `docs/superpowers/specs/2026-07-21-empty-subscription-fallback-design.md`, inspect the tests, and confirm both Mihomo validation modes from fresh command output.

## Technical Vocabulary / 技术词汇

- **characterization test** — 记录并保护现有行为的特征测试
- **golden snapshot** — 作为预期基准的固定快照
- **regression test** — 防止缺陷再次出现的回归测试
- **blast radius** — 修改影响范围
- **provider membership** — 订阅提供者成员关系
- **DIRECT-only mode** — 仅直连模式
- **pass-through behavior** — 原样透传行为
- **integration assertion** — 集成层断言
- **deterministic seed** — 确定性随机种子
- **scope audit** — 变更范围审计

## 中文审查清单

- [ ] 确认测试先固定“有订阅时不变”，再处理空订阅失败。
- [ ] 确认空订阅时只有 `local_proxy` 直接持有手写节点名。
- [ ] 确认空输入通过 `local_proxy → DIRECT`，而不是删除现有策略组。
- [ ] 确认 `auto_select` 无订阅时只有 `local_proxy`，不额外保留 `DIRECT`。
- [ ] 确认删除全局指纹但保留节点级字段透传。
- [ ] 确认实际运行两次 `mihomo -t`，不能只依赖 YAML 结构测试。
- [ ] 确认不修改用户私有 values/config 文件。
- [ ] 确认每次提交前执行 GitNexus 变更检测。

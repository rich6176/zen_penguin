# Zen Penguin

Zen Penguin renders configuration files for a GitHub Actions job. [`zen_penguin.json`](zen_penguin.json) lists every map file. Each entry has a namespace, and every file is loaded into one map. The template reads that map and names the file it writes.

The action is a Docker container. GitHub does not run Elixir directly. Jobs need a Linux runner. It is not published to GitHub Marketplace.

## The map

A namespace is the path of that file in the map, split on `.`. The file body is the keys at that path. A namespace can appear once. A second entry with the same namespace fails the step, because those keys would land on the same node. The same key under two namespaces stays. Paths stay inside the action.

```json
{
  "defaults_files": [
    { "namespace": "zp.defaults", "file": "maps/defaults.json" }
  ],
  "env_files": [
    { "namespace": "zp.dev", "file": "maps/envs/dev.json" },
    { "namespace": "zp.prod", "file": "maps/envs/prod.json" }
  ],
  "junkyard_files": [
    { "namespace": "zp.dev.san-antonio", "file": "maps/junkyards/dev/san-antonio.json" },
    { "namespace": "zp.dev.chicago", "file": "maps/junkyards/dev/chicago.json" },
    { "namespace": "zp.prod.chicago", "file": "maps/junkyards/prod/chicago.json" }
  ]
}
```

The sample index also lists local and test, and both junkyards for every env. `zp.dev` holds `log_level`. `zp.dev.san-antonio` and `zp.prod.chicago` hold `junkyard_code` and `service_url`. `zp.defaults` holds `items`, `service.region`, and `aws_secret`. Those entries load as:

```json
{
  "zp": {
    "defaults": {
      "items": [{"code": "p1"}, {"code": "p2"}],
      "service": {"region": "south"},
      "aws_secret": {"$secret": "AWS_SECRET"}
    },
    "dev": {
      "log_level": "debug",
      "san-antonio": {
        "junkyard_code": "san-antonio",
        "service_url": "https://san-antonio-dev.example.internal"
      },
      "chicago": {
        "junkyard_code": "chicago",
        "service_url": "https://chicago-dev.example.internal"
      }
    },
    "prod": {
      "log_level": "error",
      "chicago": {
        "junkyard_code": "chicago",
        "service_url": "https://chicago-prod.example.internal"
      }
    }
  }
}
```

`log_level` on `zp.dev` and `zp.prod` both stay. `service_url` on `zp.dev.chicago` and `zp.prod.chicago` both stay. The namespace is what keeps them apart.

`env` and `junkyard` are not filters. The workflow still has to pass both, and the template sees them as `@env` and `@junkyard`. Loading does not drop the other namespaces.

Object keys stay strings. A value can be a string, number, boolean, `null`, array, or object. `false`, `0`, `[]`, and `{}` are present values. `null` and `""` are missing values.

## Templates

Templates live in [`templates/`](templates/). Every `*.eex` file is rendered with the same map. The template receives one binding, `assigns`. `@env` reads `assigns.values.env`, the selected name. `fetch` walks `assigns.map`. The template does not pass `assigns` itself.

`fetch("zp.dev.san-antonio.service_url")` always reads the dev san-antonio node. The sample builds the path from the selected names:

```elixir
service_url: <%= fetch("zp." <> @env <> "." <> @junkyard <> ".service_url") %>
log_level: <%= fetch("zp." <> @env <> ".log_level") %>
junkyard: <%= fetch("zp." <> @env <> "." <> @junkyard <> ".junkyard_code") %>
region: <%= fetch("zp.defaults.service.region") %>
<%= for item <- fetch("zp.defaults.items") do %>item: <%= item["code"] %>
<% end %>
aws_secret: <%= fetch("zp.defaults.aws_secret") %>
```

For `env=dev` and `junkyard=san-antonio` the service path is `zp.dev.san-antonio.service_url`. The same template writes the chicago URL when the workflow selects chicago, and the prod URL when it selects prod. `zp.defaults` does not change with the selection. A condition is Elixir `if`, and a loop is Elixir `for`.

`<% output "junkyard.yaml" %>` sets the filename under the workflow `output` directory and prints nothing. Each template calls `output` once. A missing call, a second call, or two templates naming the same file fails the step and writes nothing.

The sample [`templates/service.yaml.eex`](templates/service.yaml.eex) writes `junkyard.yaml`. [`templates/items.txt.eex`](templates/items.txt.eex) writes `items.txt` from the same `items` array. Adding a template adds another file. The action writes the EEx bytes and does not reformat or validate them. The caller checks the file with the parser and version they run.

## Missing keys and values

[`config.exs`](config.exs) sets the policy. Callers do not pass it.

```elixir
%{
  missing_key: :fail,
  missing_value: :null
}
```

Each setting is `:fail` or `:null`. `:fail` stops the step and names the path. `:null` prints the characters `null`. `fetch` follows this. A missing `zp.dev` key is not taken from `zp.prod`. A condition that does not match prints nothing.

`<%= @name %>` follows the policy when that assign is the whole expression. Inside a larger expression, `@name` is the raw value, so `||` is ordinary Elixir and does not apply the policy.

## Secrets

A value stores the secret key and never the secret value:

```json
{"aws_secret": {"$secret": "AWS_SECRET"}}
```

The marker counts only when `$secret` is the sole key of that object. The template prints the resolved value:

```elixir
aws_secret: <%= fetch("zp.defaults.aws_secret") %>
```

The workflow injects the key before the action starts. [`render.yml`](.github/workflows/render.yml) selects the GitHub environment `${{ inputs.junkyard }}-${{ inputs.env }}` and maps each key the value file uses:

```yaml
env:
  AWS_SECRET: ${{ secrets.AWS_SECRET }}
```

A missing or empty variable for that key is a missing value. The action does not log the value. Do not print a rendered file that contains it, and do not upload it as an artifact.

A template can also call `System.get_env/1`, or choose a key with `if`, because a template is Elixir. That needs no renderer change. The workflow still has to inject whatever key the template or the value file names. A new secret key is added to the value map and to the `env` block in `render.yml`. The sample stores that key on `zp.defaults`.

## Calling it

Tag this repository `v1`. In the action repository settings, allow Actions access from other repositories in the organization.

```yaml
jobs:
  configure:
    uses: <owner>/zen_penguin/.github/workflows/render.yml@v1
    with:
      env: dev
      junkyard: san-antonio
      output: config
    secrets: inherit
```

`env` and `junkyard` are required. Each must be one path segment (`[A-Za-z0-9._-]`). `output` is the directory under the workspace. The action input `variables` accepts those two as `KEY=VALUE` lines, with blank lines and `#` comments ignored, or as a JSON object. `config-paths` lists the written paths, one per line.

Moving the `v1` tag updates every caller that pins `@v1`. A caller that pins a commit SHA stays on that revision.

## Trust

Templates and [`config.exs`](config.exs) are Elixir. They run with the job's privileges, including any secret the workflow injected. Keep them in this repository. The container finds them by walking up from the compiled application until it sees `zen_penguin.json`.

`ZEN_PENGUIN_ROOT` overrides that directory. It is not an action input. Do not point it at the caller workspace. A directory supplied that way is compiled and executed the same way as the bundled templates.

The sample template prints `aws_secret` when the value file asks for it. A missing variable prints `null`. When the workflow injects `AWS_SECRET`, the rendered file contains the secret. Do not log that file or upload it as an artifact.

## Checks

On a machine with Elixir 1.18 or newer:

```bash
mix deps.get
mix format --check-formatted
mix credo --strict
mix deps.audit
mix test --cover
```

`mix test --cover` requires 100% line coverage. [`.github/workflows/test.yml`](.github/workflows/test.yml) runs those checks, a secret scan, and a local render on every push and pull request.

The tests set a fake `AWS_SECRET` themselves. To render once the way the container does:

```bash
docker build -t zen-penguin .
mkdir -p /tmp/zen-workspace
docker run --rm \
  -e INPUT_VARIABLES=$'env=dev\njunkyard=san-antonio' \
  -e INPUT_OUTPUT=config \
  -e GITHUB_WORKSPACE=/github/workspace \
  -e GITHUB_OUTPUT=/github/output \
  -v /tmp/zen-workspace:/github/workspace \
  zen-penguin
```

The rendered files are under `/tmp/zen-workspace/config`. For `env=dev` and `junkyard=san-antonio`, `junkyard.yaml` contains `log_level: debug` and the san-antonio dev URL. Do not commit the output.

## License

[Apache License 2.0](LICENSE). Anyone can use, change, and ship the action. Copies keep this license, the copyright notice, and any notices in [NOTICE](NOTICE). Changed files say that they were changed.

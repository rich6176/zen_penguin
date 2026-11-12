defmodule ZenPenguin.RenderTest do
  use ExUnit.Case, async: false

  @dev_junkyard """

  service_url: https://san-antonio-dev.example.internal
  log_level: debug
  junkyard: san-antonio
  region: south
  item: p1
  item: p2

  aws_secret: null
  """

  @dev_items """

  p1
  p2

  """

  setup do
    previous = System.get_env("AWS_SECRET")

    on_exit(fn ->
      restore_env("AWS_SECRET", previous)
    end)

    System.delete_env("AWS_SECRET")
    :ok
  end

  test "dev writes the selected log level and leaves the other namespaces loaded" do
    {workspace, paths} = render("env=dev\njunkyard=san-antonio")

    assert paths == ["config/items.txt", "config/junkyard.yaml"]
    assert File.read!(Path.join(workspace, "config/junkyard.yaml")) == @dev_junkyard
    assert File.read!(Path.join(workspace, "config/items.txt")) == @dev_items

    root =
      fixture_root(%{
        "zen_penguin.json" =>
          listed([
            {"zp.local", "maps/local.json"},
            {"zp.dev", "maps/dev.json"},
            {"zp.prod", "maps/prod.json"}
          ]),
        "maps/local.json" => "{\"log_level\": \"info\"}\n",
        "maps/dev.json" => "{\"log_level\": \"debug\"}\n",
        "maps/prod.json" => "{\"log_level\": \"error\"}\n",
        "templates/out.txt.eex" => """
        <% output "out.txt" %>
        selected=<%= fetch("zp." <> @env <> ".log_level") %>
        local=<%= fetch("zp.local.log_level") %>
        prod=<%= fetch("zp.prod.log_level") %>
        env=<%= @env %>
        """
      })

    body = rendered("env=dev\njunkyard=san-antonio", "out.txt", root: root)
    assert body =~ "selected=debug"
    assert body =~ "local=info"
    assert body =~ "prod=error"
    assert body =~ "env=dev"
  end

  test "each selected env and junkyard reads its own values" do
    local = rendered("env=local\njunkyard=san-antonio", "junkyard.yaml")
    assert local =~ "log_level: info\n"
    assert local =~ "service_url: https://san-antonio-local.example.internal\n"

    chicago = rendered("env=dev\njunkyard=chicago", "junkyard.yaml")
    assert chicago =~ "log_level: debug\n"
    assert chicago =~ "junkyard: chicago\n"
    assert chicago =~ "service_url: https://chicago-dev.example.internal\n"

    test_env = rendered("env=test\njunkyard=chicago", "junkyard.yaml")
    assert test_env =~ "log_level: warn\n"
    assert test_env =~ "service_url: https://chicago-test.example.internal\n"

    prod = rendered("env=prod\njunkyard=san-antonio", "junkyard.yaml")
    assert prod =~ "log_level: error\n"
    assert prod =~ "service_url: https://san-antonio-prod.example.internal\n"
  end

  test "present false, zero, empty list, and empty object are values" do
    root =
      fixture_root(%{
        "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
        "maps/dev.json" => "{\"flag\": false, \"count\": 0, \"items\": [], \"meta\": {}}\n",
        "templates/out.txt.eex" => """
        <% output "out.txt" %>
        [<%= fetch("zp." <> @env <> ".flag") %>][<%= fetch("zp.dev.count") %>][<%= fetch("zp.dev.items") %>]
        """
      })

    assert rendered("env=dev\njunkyard=san-antonio", "out.txt", root: root) =~ "[false][0][]"
  end

  test "fetch follows the missing key and missing value policy" do
    null_root =
      fixture_root(%{
        "config.exs" => "%{missing_key: :null, missing_value: :null}\n",
        "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
        "maps/dev.json" => "{\"blank\": \"\"}\n",
        "templates/out.txt.eex" => """
        <% output "out.txt" %>
        <%= fetch("zp." <> @env <> ".blank") %>
        <%= fetch("zp." <> @env <> ".log_level") %>
        """
      })

    body = rendered("env=dev\njunkyard=san-antonio", "out.txt", root: null_root)
    assert body =~ "null"
    assert length(String.split(body, "null")) == 3

    fail_value =
      fixture_root(%{
        "config.exs" => "%{missing_key: :null, missing_value: :fail}\n",
        "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
        "maps/dev.json" => "{\"blank\": \"\"}\n",
        "templates/out.txt.eex" => "<% output \"out.txt\" %><%= fetch(\"zp.dev.blank\") %>\n"
      })

    assert_raise ZenPenguin.Error, "missing value zp.dev.blank", fn ->
      render("env=dev\njunkyard=san-antonio", root: fail_value)
    end
  end

  test "a bare missing key or value follows the policy, and || supplies the fallback" do
    root =
      fixture_root(%{
        "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
        "maps/dev.json" => "{\"blank\": \"\", \"nothing\": null}\n",
        "templates/out.txt.eex" => """
        <% output "out.txt" %>
        <%= fetch("zp.dev.blank") || "fallback" %>
        <%= fetch("zp.dev.nothing") || "fallback" %>
        <%= @missing || "fallback" %>
        <%= fetch("zp.dev.blank") %>
        """
      })

    body = rendered("env=dev\njunkyard=san-antonio", "out.txt", root: root)
    assert body =~ "fallback"

    fail_key =
      fixture_root(%{
        "config.exs" => "%{missing_key: :fail, missing_value: :null}\n",
        "zen_penguin.json" => "{\"env_files\": []}\n",
        "templates/out.txt.eex" => "<% output \"out.txt\" %><%= @missing %>\n"
      })

    assert_raise ZenPenguin.Error, "missing key missing", fn ->
      render("env=dev\njunkyard=san-antonio", root: fail_key)
    end

    null_key =
      fixture_root(%{
        "config.exs" => "%{missing_key: :null, missing_value: :null}\n",
        "zen_penguin.json" => "{\"env_files\": []}\n",
        "templates/out.txt.eex" => "<% output \"out.txt\" %><%= @missing %>\n"
      })

    assert rendered("env=dev\njunkyard=san-antonio", "out.txt", root: null_key) == "null\n"
  end

  test "a secret key is read from the environment" do
    System.put_env("AWS_SECRET", "example-token")

    root =
      fixture_root(%{
        "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
        "maps/dev.json" => "{\"aws_secret\": {\"$secret\": \"AWS_SECRET\"}}\n",
        "templates/out.txt.eex" => """
        <% output "out.txt" %>
        <%= fetch("zp." <> @env <> ".aws_secret") %>
        """
      })

    assert rendered("env=dev\njunkyard=san-antonio", "out.txt", root: root) =~ "example-token"

    System.delete_env("AWS_SECRET")

    fail_root =
      fixture_root(%{
        "config.exs" => "%{missing_key: :fail, missing_value: :fail}\n",
        "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
        "maps/dev.json" => "{\"aws_secret\": {\"$secret\": \"AWS_SECRET\"}}\n",
        "templates/out.txt.eex" => "<% output \"out.txt\" %><%= fetch(\"zp.dev.aws_secret\") %>\n"
      })

    assert_raise ZenPenguin.Error, "missing value zp.dev.aws_secret", fn ->
      render("env=dev\njunkyard=san-antonio", root: fail_root)
    end
  end

  test "a missing or repeated output call fails before writing" do
    missing =
      fixture_root(%{
        "zen_penguin.json" => "{\"env_files\": []}\n",
        "templates/out.txt.eex" => "hello\n"
      })

    assert_raise ZenPenguin.Error, "template did not call output/1", fn ->
      render("env=dev\njunkyard=san-antonio", root: missing)
    end

    repeated =
      fixture_root(%{
        "zen_penguin.json" => "{\"env_files\": []}\n",
        "templates/out.txt.eex" => """
        <% output "one.txt" %>
        <% output "two.txt" %>
        """
      })

    assert_raise ZenPenguin.Error, "output/1 called more than once", fn ->
      render("env=dev\njunkyard=san-antonio", root: repeated)
    end
  end

  test "two templates cannot write the same file" do
    root =
      fixture_root(%{
        "zen_penguin.json" => "{\"env_files\": []}\n",
        "templates/a.eex" => "<% output \"same.txt\" %>a\n",
        "templates/b.eex" => "<% output \"same.txt\" %>b\n"
      })

    assert_raise ZenPenguin.Error, ~r/same\.txt/, fn ->
      render("env=dev\njunkyard=san-antonio", root: root)
    end
  end

  test "a failed template writes nothing" do
    root =
      fixture_root(%{
        "zen_penguin.json" => "{\"env_files\": []}\n",
        "templates/a.eex" => "<% output \"a.txt\" %>ok\n",
        "templates/b.eex" => "<% output \"b.txt\" %><%= @missing %>\n"
      })

    workspace = empty_workspace()

    assert_raise ZenPenguin.Error, "missing key missing", fn ->
      ZenPenguin.Render.run(
        root: root,
        workspace: workspace,
        output: "config",
        variables: "env=dev\njunkyard=san-antonio"
      )
    end

    assert File.ls!(workspace) == []
  end

  test "output paths and caller variables stay inside their directories" do
    assert_raise ZenPenguin.Error, ~r/output filename/, fn ->
      root =
        fixture_root(%{
          "zen_penguin.json" => "{\"env_files\": []}\n",
          "templates/out.txt.eex" => "<% output \"../nope.txt\" %>x\n"
        })

      render("env=dev\njunkyard=san-antonio", root: root)
    end

    assert_raise ZenPenguin.Error, ~r/path escapes/, fn ->
      render("env=dev\njunkyard=san-antonio", output: "../outside")
    end

    assert_raise ZenPenguin.Error, ~r/one path segment/, fn ->
      render("env=dev/evil\njunkyard=san-antonio")
    end

    assert_raise ZenPenguin.Error, ~r/unknown variable/, fn ->
      render("env=dev\njunkyard=san-antonio\nregion=south")
    end
  end

  test "variables accept comments, blank lines, and a JSON object" do
    lines = """
    # select the env
    env=dev

    junkyard=chicago
    """

    assert rendered(lines, "junkyard.yaml") =~ "log_level: debug\n"

    json = ~s({"env":"test","junkyard":"san-antonio"})
    assert rendered(json, "junkyard.yaml") =~ "log_level: warn\n"
  end

  test "a condition that does not match prints nothing" do
    root =
      fixture_root(%{
        "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
        "maps/dev.json" => "{\"log_level\": \"debug\"}\n",
        "templates/out.txt.eex" => """
        <% output "out.txt" %>
        <%= if @env == "prod" do %>log_level: <%= fetch("zp." <> @env <> ".log_level") %>
        <% end %>
        """
      })

    body = rendered("env=dev\njunkyard=chicago", "out.txt", root: root)
    refute body =~ "log_level:"
  end

  defp listed(entries) do
    body =
      Enum.map_join(entries, ",\n", fn {namespace, file} ->
        ~s|    { "namespace": "#{namespace}", "file": "#{file}" }|
      end)

    "{\n  \"env_files\": [\n#{body}\n  ]\n}\n"
  end

  defp rendered(variables, filename, opts \\ []) do
    {workspace, _paths} = render(variables, opts)
    File.read!(Path.join([workspace, opts[:output] || "config", filename]))
  end

  defp render(variables, opts \\ []) do
    workspace = empty_workspace()

    paths =
      ZenPenguin.Render.run(
        root: opts[:root] || File.cwd!(),
        workspace: workspace,
        output: opts[:output] || "config",
        variables: variables
      )

    {workspace, paths}
  end

  defp empty_workspace do
    workspace = Path.join(System.tmp_dir!(), "zen-penguin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    workspace
  end

  defp fixture_root(files) do
    root = Path.join(System.tmp_dir!(), "zen-penguin-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    files =
      Map.put_new(files, "config.exs", "%{missing_key: :fail, missing_value: :null}\n")

    Enum.each(files, fn {relative, body} ->
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end)

    root
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end

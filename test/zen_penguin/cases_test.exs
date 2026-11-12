defmodule ZenPenguin.CasesTest do
  use ExUnit.Case, async: false

  setup do
    previous = System.get_env("AWS_SECRET")
    on_exit(fn -> restore_env("AWS_SECRET", previous) end)
    System.delete_env("AWS_SECRET")
    :ok
  end

  describe "namespaces" do
    test "the same key stays under each namespace" do
      root =
        root(%{
          "zen_penguin.json" =>
            listed([
              {"zp.dev", "maps/dev.json"},
              {"zp.prod", "maps/prod.json"}
            ]),
          "maps/dev.json" => "{\"log_level\": \"debug\"}\n",
          "maps/prod.json" => "{\"log_level\": \"error\"}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %>
          dev=<%= fetch("zp.dev.log_level") %>
          prod=<%= fetch("zp.prod.log_level") %>
          """
        })

      body = rendered("env=dev\njunkyard=san-antonio", root: root)
      assert body =~ "dev=debug"
      assert body =~ "prod=error"
    end

    test "a repeated namespace fails before either file is merged" do
      root =
        root(%{
          "zen_penguin.json" =>
            listed([
              {"zp.dev", "maps/a.json"},
              {"zp.dev", "maps/b.json"}
            ]),
          "maps/a.json" => "{\"log_level\": \"debug\"}\n",
          "maps/b.json" => "{\"trace\": true}\n",
          "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
        })

      assert_raise ZenPenguin.Error, "duplicate namespace zp.dev", fn ->
        render("env=dev\njunkyard=san-antonio", root: root)
      end
    end

    test "a parent namespace keeps its own keys beside a child namespace" do
      root =
        root(%{
          "zen_penguin.json" =>
            listed([
              {"zp", "maps/shared.json"},
              {"zp.dev", "maps/dev.json"}
            ]),
          "maps/shared.json" => "{\"region\": \"south\"}\n",
          "maps/dev.json" => "{\"log_level\": \"debug\"}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %>
          <%= fetch("zp.region") %>
          <%= fetch("zp.dev.log_level") %>
          """
        })

      body = rendered("env=dev\njunkyard=san-antonio", root: root)
      assert body =~ "south"
      assert body =~ "debug"
    end

    test "a parent file cannot replace a child namespace with a key" do
      root =
        root(%{
          "zen_penguin.json" =>
            listed([
              {"zp.dev", "maps/dev.json"},
              {"zp", "maps/shared.json"}
            ]),
          "maps/dev.json" => "{\"log_level\": \"debug\"}\n",
          "maps/shared.json" => "{\"dev\": \"nope\"}\n",
          "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
        })

      assert_raise ZenPenguin.Error, ~r/duplicate key dev/, fn ->
        render("env=dev\njunkyard=san-antonio", root: root)
      end
    end
  end

  describe "fetch" do
    test "false, zero, empty list, and empty object are present" do
      root =
        root(%{
          "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
          "maps/dev.json" => "{\"flag\": false, \"count\": 0, \"items\": [], \"meta\": {}}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %>
          [<%= fetch("zp.dev.flag") %>]
          [<%= fetch("zp.dev.count") %>]
          <%= for item <- fetch("zp.dev.items") do %><%= item %><% end %>
          """
        })

      assert rendered("env=dev\njunkyard=san-antonio", root: root) =~ "[false]\n[0]\n"
    end

    test "a float is printed" do
      root =
        root(%{
          "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
          "maps/dev.json" => "{\"ratio\": 1.5}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %><%= fetch("zp.dev.ratio") %>
          """
        })

      assert rendered("env=dev\njunkyard=san-antonio", root: root) =~ "1.5"
    end

    test "null and an empty string are missing values" do
      root =
        root(%{
          "config.exs" => "%{missing_key: :null, missing_value: :null}\n",
          "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
          "maps/dev.json" => "{\"blank\": \"\", \"nothing\": null, \"kept\": \"yes\"}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %>
          <%= fetch("zp.dev.blank") %>
          <%= fetch("zp.dev.nothing") %>
          <%= fetch("zp.dev.kept") %>
          """
        })

      body = rendered("env=dev\njunkyard=san-antonio", root: root)
      assert body =~ "null"
      assert body =~ "yes"
    end

    test "a missing namespace prints null when the policy says null" do
      root =
        root(%{
          "config.exs" => "%{missing_key: :null, missing_value: :fail}\n",
          "zen_penguin.json" => "{\"env_files\": []}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %>
          <%= fetch("zp." <> @env <> ".log_level") %>
          <%= fetch("zp.prod.log_level") %>
          """
        })

      body = rendered("env=dev\njunkyard=san-antonio", root: root)
      assert length(String.split(body, "null")) == 3
    end

    test "fetch rejects a path that is not a dotted string" do
      root =
        root(%{
          "zen_penguin.json" => "{\"env_files\": []}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %><%= fetch(1) %>
          """
        })

      assert_raise ZenPenguin.Error, ~r/fetch\/1 expects a dotted path/, fn ->
        render("env=dev\njunkyard=san-antonio", root: root)
      end
    end

    test "fetch rejects an empty path segment" do
      root =
        root(%{
          "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
          "maps/dev.json" => "{\"log_level\": \"debug\"}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %><%= fetch("zp..log_level") %>
          """
        })

      assert_raise ZenPenguin.Error, ~r/dotted path/, fn ->
        render("env=dev\njunkyard=san-antonio", root: root)
      end
    end

    test "a path through a string fails" do
      root =
        root(%{
          "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
          "maps/dev.json" => "{\"log_level\": \"debug\"}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %><%= fetch("zp.dev.log_level.extra") %>
          """
        })

      assert_raise ZenPenguin.Error, ~r/not an object/, fn ->
        render("env=dev\njunkyard=san-antonio", root: root)
      end
    end

    test "printing a map or a data list fails" do
      root =
        root(%{
          "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
          "maps/dev.json" => "{\"meta\": {\"a\": 1}, \"nums\": [1, 2]}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %><%= fetch("zp.dev.meta") %>
          """
        })

      assert_raise ZenPenguin.Error, ~r/cannot print/, fn ->
        render("env=dev\njunkyard=san-antonio", root: root)
      end

      list_root =
        root(%{
          "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
          "maps/dev.json" => "{\"nums\": [1, 2]}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %><%= fetch("zp.dev.nums") %>
          """
        })

      assert_raise ZenPenguin.Error, ~r/cannot print/, fn ->
        render("env=dev\njunkyard=san-antonio", root: list_root)
      end
    end

    test "fetch of a namespace map can read one key" do
      root =
        root(%{
          "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
          "maps/dev.json" => "{\"log_level\": \"debug\"}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %><%= fetch(fetch("zp." <> @env), "log_level") %>
          """
        })

      assert rendered("env=dev\njunkyard=san-antonio", root: root) =~ "debug"
    end
  end

  describe "secrets" do
    test "an empty secret is a missing value" do
      System.put_env("AWS_SECRET", "")

      root =
        root(%{
          "config.exs" => "%{missing_key: :fail, missing_value: :fail}\n",
          "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
          "maps/dev.json" => "{\"token\": {\"$secret\": \"AWS_SECRET\"}}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %><%= fetch("zp." <> @env <> ".token") %>
          """
        })

      assert_raise ZenPenguin.Error, "missing value zp.dev.token", fn ->
        render("env=dev\njunkyard=san-antonio", root: root)
      end
    end

    test "a map with more than the secret marker stays a map" do
      System.put_env("AWS_SECRET", "example-token")

      root =
        root(%{
          "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
          "maps/dev.json" => "{\"token\": {\"$secret\": \"AWS_SECRET\", \"note\": \"keep\"}}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %><%= fetch("zp.dev.token") %>
          """
        })

      assert_raise ZenPenguin.Error, ~r/cannot print/, fn ->
        render("env=dev\njunkyard=san-antonio", root: root)
      end
    end
  end

  describe "map files" do
    test "rejected index files" do
      assert_raise ZenPenguin.Error, ~r/must be an object/, fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "zen_penguin.json" => "[\"maps/dev.json\"]\n",
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end

      assert_raise ZenPenguin.Error, ~r/env_files must list files/, fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "zen_penguin.json" => "{\"env_files\": {}}\n",
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end

      assert_raise ZenPenguin.Error, ~r/entries must be objects/, fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "zen_penguin.json" => "{\"env_files\": [\"maps/dev.json\"]}\n",
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end

      assert_raise ZenPenguin.Error, ~r/missing namespace/, fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "zen_penguin.json" => "{\"env_files\": [{\"file\": \"maps/dev.json\"}]}\n",
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end

      assert_raise ZenPenguin.Error, ~r/namespace must be a string/, fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "zen_penguin.json" =>
                "{\"env_files\": [{\"namespace\": 1, \"file\": \"maps/dev.json\"}]}\n",
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end

      assert_raise ZenPenguin.Error, ~r/is not a namespace/, fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "zen_penguin.json" =>
                "{\"env_files\": [{\"namespace\": \"zp.\", \"file\": \"maps/dev.json\"}]}\n",
              "maps/dev.json" => "{}\n",
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end

      assert_raise ZenPenguin.Error, ~r/could not read/, fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "zen_penguin.json" => listed([{"zp.dev", "maps/missing.json"}]),
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end

      assert_raise ZenPenguin.Error, ~r/invalid JSON/, fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "zen_penguin.json" => listed([{"zp.dev", "maps/bad.json"}]),
              "maps/bad.json" => "{",
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end

      assert_raise ZenPenguin.Error, ~r/must be an object/, fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "zen_penguin.json" => listed([{"zp.dev", "maps/bad.json"}]),
              "maps/bad.json" => "[]\n",
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end

      assert_raise ZenPenguin.Error, ~r/stay inside the action/, fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "zen_penguin.json" => listed([{"zp.dev", "/etc/passwd"}]),
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end

      assert_raise ZenPenguin.Error, ~r/stay inside the action/, fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "zen_penguin.json" => listed([{"zp.dev", "../outside.json"}]),
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end

      assert_raise ZenPenguin.Error, ~r/zen_penguin.json is missing/, fn ->
        render("env=dev\njunkyard=san-antonio", root: root(%{}))
      end
    end
  end

  describe "variables and output" do
    test "missing, duplicate, and malformed variables fail" do
      assert_raise ZenPenguin.Error, "missing variable env", fn ->
        render("junkyard=san-antonio")
      end

      assert_raise ZenPenguin.Error, "missing variable junkyard", fn ->
        render("env=dev")
      end

      assert_raise ZenPenguin.Error, "duplicate variable env", fn ->
        render("env=dev\nenv=test\njunkyard=san-antonio")
      end

      assert_raise ZenPenguin.Error, ~r/invalid variable line/, fn ->
        render("env")
      end

      assert_raise ZenPenguin.Error, ~r/one path segment/, fn ->
        render("env=\njunkyard=san-antonio")
      end

      assert_raise ZenPenguin.Error, ~r/one path segment/, fn ->
        render("env=dev\njunkyard=san antonio")
      end

      assert_raise ZenPenguin.Error, ~r/must be a string/, fn ->
        render(~s({"env": 1, "junkyard": "san-antonio"}))
      end

      assert_raise ZenPenguin.Error, ~r/object of strings/, fn ->
        render("{")
      end
    end

    test "a dotted junkyard name is one segment" do
      root =
        root(%{
          "zen_penguin.json" => "{\"env_files\": []}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %><%= @junkyard %>
          """
        })

      assert rendered("env=dev\njunkyard=san.antonio_1", root: root) =~ "san.antonio_1"
    end

    test "output rejects an absolute directory and a non-string filename" do
      assert_raise ZenPenguin.Error, ~r/stay inside the workspace/, fn ->
        render("env=dev\njunkyard=san-antonio", output: "/tmp/out")
      end

      root =
        root(%{
          "zen_penguin.json" => "{\"env_files\": []}\n",
          "templates/out.txt.eex" => "<% output 1 %>x\n"
        })

      assert_raise ZenPenguin.Error, ~r/filename string/, fn ->
        render("env=dev\njunkyard=san-antonio", root: root)
      end
    end

    test "two templates write two files" do
      root =
        root(%{
          "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
          "maps/dev.json" => "{\"name\": \"penguin\"}\n",
          "templates/a.eex" => "<% output \"a.txt\" %><%= fetch(\"zp.dev.name\") %>\n",
          "templates/b.eex" => "<% output \"b.txt\" %>ok\n"
        })

      {workspace, paths} = render("env=dev\njunkyard=san-antonio", root: root)
      assert paths == ["config/a.txt", "config/b.txt"]
      assert File.read!(Path.join(workspace, "config/a.txt")) =~ "penguin"
      assert File.read!(Path.join(workspace, "config/b.txt")) =~ "ok"
    end
  end

  describe "config.exs" do
    test "a bad policy and a missing policy fail" do
      assert_raise ZenPenguin.Error, ~r/missing_key must be :fail or :null/, fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "config.exs" => "%{missing_key: :nope, missing_value: :null}\n",
              "zen_penguin.json" => "{\"env_files\": []}\n",
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end

      assert_raise ZenPenguin.Error, "config.exs is missing missing_key", fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "config.exs" => "%{missing_value: :null}\n",
              "zen_penguin.json" => "{\"env_files\": []}\n",
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end

      assert_raise ZenPenguin.Error, "config.exs must return a map", fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "config.exs" => ":ok\n",
              "zen_penguin.json" => "{\"env_files\": []}\n",
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end
    end
  end

  describe "renderer edges" do
    test "fetch/2 applies the missing key and missing value policy" do
      missing_key =
        root(%{
          "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
          "maps/dev.json" => "{\"log_level\": \"debug\"}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %><%= fetch(fetch("zp.dev"), "missing") %>
          """
        })

      assert_raise ZenPenguin.Error, "missing key missing", fn ->
        render("env=dev\njunkyard=san-antonio", root: missing_key)
      end

      missing_value =
        root(%{
          "config.exs" => "%{missing_key: :fail, missing_value: :fail}\n",
          "zen_penguin.json" => listed([{"zp.dev", "maps/dev.json"}]),
          "maps/dev.json" => "{\"blank\": \"\"}\n",
          "templates/out.txt.eex" => """
          <% output "out.txt" %><%= fetch(fetch("zp.dev"), "blank") %>
          """
        })

      assert_raise ZenPenguin.Error, "missing value blank", fn ->
        render("env=dev\njunkyard=san-antonio", root: missing_value)
      end
    end

    test "fetch/2 rejects a key that is not a string and a namespace that is not a map" do
      bad_key =
        root(%{
          "zen_penguin.json" => "{\"env_files\": []}\n",
          "templates/out.txt.eex" => "<% output \"out.txt\" %><%= fetch(%{}, 1) %>\n"
        })

      assert_raise ZenPenguin.Error, ~r/fetch\/2 expects a key string/, fn ->
        render("env=dev\njunkyard=san-antonio", root: bad_key)
      end

      bad_namespace =
        root(%{
          "zen_penguin.json" => "{\"env_files\": []}\n",
          "templates/out.txt.eex" => "<% output \"out.txt\" %><%= fetch(1, \"key\") %>\n"
        })

      assert_raise ZenPenguin.Error, "missing key key", fn ->
        render("env=dev\njunkyard=san-antonio", root: bad_namespace)
      end
    end

    test "a bare assign can follow the missing value policy" do
      assigns = %{
        values: %{},
        missing_values: MapSet.new([:token]),
        missing_key: :fail,
        missing_value: :null
      }

      assert ZenPenguin.Render.bare_assign(assigns, :token) == "null"

      assert_raise ZenPenguin.Error, ~r/invalid missing_key policy/, fn ->
        ZenPenguin.Render.bare_assign(
          %{assigns | missing_values: MapSet.new(), missing_key: :nope},
          :gone
        )
      end
    end

    test "nested rendered chunks print" do
      root =
        root(%{
          "zen_penguin.json" => "{\"env_files\": []}\n",
          "templates/out.txt.eex" => "<% output \"out.txt\" %><%= [\"a\", [\"b\"]] %>\n"
        })

      assert rendered("env=dev\njunkyard=san-antonio", root: root) =~ "ab"
    end

    test "the index file itself must be readable JSON" do
      assert_raise ZenPenguin.Error, ~r/invalid JSON/, fn ->
        render("env=dev\njunkyard=san-antonio",
          root:
            root(%{
              "zen_penguin.json" => "{",
              "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
            })
        )
      end

      directory =
        root(%{
          "zen_penguin.json" => "{\"env_files\": []}\n",
          "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
        })

      index = Path.join(directory, "zen_penguin.json")
      File.chmod!(index, 0o000)

      on_exit(fn -> File.chmod(index, 0o644) end)

      assert_raise ZenPenguin.Error, ~r/could not read/, fn ->
        render("env=dev\njunkyard=san-antonio", root: directory)
      end
    end

    test "a namespace cannot pass through a value that is not an object" do
      leaf =
        root(%{
          "zen_penguin.json" =>
            listed([
              {"zp", "maps/parent.json"},
              {"zp.dev", "maps/dev.json"}
            ]),
          "maps/parent.json" => "{\"dev\": \"nope\"}\n",
          "maps/dev.json" => "{\"log_level\": \"debug\"}\n",
          "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
        })

      assert_raise ZenPenguin.Error, "dev must be an object", fn ->
        render("env=dev\njunkyard=san-antonio", root: leaf)
      end

      nested =
        root(%{
          "zen_penguin.json" =>
            listed([
              {"zp", "maps/parent.json"},
              {"zp.dev.extra", "maps/extra.json"}
            ]),
          "maps/parent.json" => "{\"dev\": \"nope\"}\n",
          "maps/extra.json" => "{\"log_level\": \"debug\"}\n",
          "templates/out.txt.eex" => "<% output \"out.txt\" %>x\n"
        })

      assert_raise ZenPenguin.Error, "dev must be an object", fn ->
        render("env=dev\njunkyard=san-antonio", root: nested)
      end
    end

    test "an empty, absolute, or NUL output filename is rejected" do
      for filename <- ["", "/tmp/out.txt", <<0>>] do
        directory =
          root(%{
            "zen_penguin.json" => "{\"env_files\": []}\n",
            "templates/out.txt.eex" => "<% output #{inspect(filename)} %>x\n"
          })

        assert_raise ZenPenguin.Error, ~r/output filename/, fn ->
          render("env=dev\njunkyard=san-antonio", root: directory)
        end
      end
    end
  end

  describe "sample project" do
    test "each sample env and junkyard is readable from the same map" do
      local = rendered("env=local\njunkyard=chicago", "junkyard.yaml")
      assert local =~ "log_level: info\n"
      assert local =~ "junkyard: chicago\n"
      assert local =~ "service_url: https://chicago-local.example.internal\n"

      assert rendered("env=dev\njunkyard=san-antonio", "junkyard.yaml") =~ "log_level: debug\n"

      assert rendered("env=test\njunkyard=san-antonio", "junkyard.yaml") =~
               "service_url: https://san-antonio-test.example.internal\n"

      assert rendered("env=prod\njunkyard=chicago", "junkyard.yaml") =~
               "service_url: https://chicago-prod.example.internal\n"

      assert rendered("env=dev\njunkyard=san-antonio", "items.txt") =~ "p1\n"
      assert rendered("env=dev\njunkyard=san-antonio", "items.txt") =~ "p2\n"
    end
  end

  defp listed(entries) do
    body =
      Enum.map_join(entries, ",\n", fn {namespace, file} ->
        ~s|    { "namespace": "#{namespace}", "file": "#{file}" }|
      end)

    "{\n  \"env_files\": [\n#{body}\n  ]\n}\n"
  end

  defp rendered(variables, opts)

  defp rendered(variables, filename) when is_binary(filename) do
    rendered(variables, filename: filename)
  end

  defp rendered(variables, opts) when is_list(opts) do
    filename = opts[:filename] || if(opts[:root], do: "out.txt", else: "junkyard.yaml")
    {workspace, _paths} = render(variables, opts)
    File.read!(Path.join([workspace, opts[:output] || "config", filename]))
  end

  defp render(variables, opts \\ []) do
    workspace = Path.join(System.tmp_dir!(), "zen-penguin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    paths =
      ZenPenguin.Render.run(
        root: opts[:root] || File.cwd!(),
        workspace: workspace,
        output: opts[:output] || "config",
        variables: variables
      )

    {workspace, paths}
  end

  defp root(files) do
    directory =
      Path.join(System.tmp_dir!(), "zen-penguin-root-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    files = Map.put_new(files, "config.exs", "%{missing_key: :fail, missing_value: :null}\n")

    Enum.each(files, fn {relative, body} ->
      path = Path.join(directory, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end)

    directory
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end

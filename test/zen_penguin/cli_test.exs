defmodule ZenPenguin.CLITest do
  use ExUnit.Case, async: false

  @env_keys ~w(GITHUB_WORKSPACE INPUT_OUTPUT INPUT_VARIABLES GITHUB_OUTPUT ZEN_PENGUIN_ROOT)

  setup do
    previous = Map.new(@env_keys, fn key -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Enum.each(@env_keys, &System.delete_env/1)
    :ok
  end

  test "execute writes config-paths and finds the action root" do
    root = fixture_root()
    workspace = empty_dir("workspace")
    output = Path.join(empty_dir("output"), "github-output")

    System.put_env("ZEN_PENGUIN_ROOT", root)
    System.put_env("GITHUB_WORKSPACE", workspace)
    System.put_env("INPUT_OUTPUT", "config")
    System.put_env("INPUT_VARIABLES", "env=dev\njunkyard=san-antonio")
    System.put_env("GITHUB_OUTPUT", output)

    assert ZenPenguin.CLI.execute() == :ok
    assert File.read!(Path.join(workspace, "config/out.txt")) == "ok\n"

    assert File.read!(output) ==
             "config-paths<<ZENPENGUIN_CONFIG_PATHS\nconfig/out.txt\nZENPENGUIN_CONFIG_PATHS\n"

    assert ZenPenguin.CLI.main() == :ok

    System.delete_env("GITHUB_OUTPUT")
    assert ZenPenguin.CLI.execute() == :ok

    System.delete_env("ZEN_PENGUIN_ROOT")
    assert ZenPenguin.CLI.execute() == :ok
    assert File.read!(Path.join(workspace, "config/junkyard.yaml")) =~ "log_level: debug\n"
  end

  test "main reports a missing index and asks the runtime to halt" do
    root = empty_dir("missing-root")
    File.write!(Path.join(root, "config.exs"), "%{missing_key: :fail, missing_value: :null}\n")
    System.put_env("ZEN_PENGUIN_ROOT", root)
    System.put_env("GITHUB_WORKSPACE", empty_dir("workspace"))
    System.put_env("INPUT_OUTPUT", "config")
    System.put_env("INPUT_VARIABLES", "env=dev\njunkyard=san-antonio")

    parent = self()

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        ZenPenguin.CLI.main([], fn code -> send(parent, {:halt, code}) end)
      end)

    assert stderr =~ "zen_penguin.json is missing"
    assert_received {:halt, 1}
  end

  test "find_root walks up to the index and fails at the filesystem root" do
    parent = empty_dir("action")
    File.write!(Path.join(parent, "zen_penguin.json"), "{\"env_files\": []}\n")
    nested = Path.join(parent, "lib/app")
    File.mkdir_p!(nested)

    assert ZenPenguin.CLI.find_root(nested) == parent

    assert_raise ZenPenguin.Error, "zen_penguin.json not found", fn ->
      ZenPenguin.CLI.find_root("/")
    end
  end

  defp fixture_root do
    root = empty_dir("root")

    File.write!(Path.join(root, "config.exs"), "%{missing_key: :fail, missing_value: :null}\n")
    File.write!(Path.join(root, "zen_penguin.json"), "{\"env_files\": []}\n")
    File.mkdir_p!(Path.join(root, "templates"))
    File.write!(Path.join(root, "templates/out.txt.eex"), "<% output \"out.txt\" %>ok\n")
    root
  end

  defp empty_dir(name) do
    path =
      Path.join(System.tmp_dir!(), "zen-penguin-#{name}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end

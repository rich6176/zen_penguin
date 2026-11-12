defmodule ZenPenguin.CLI do
  @moduledoc false

  def main(args \\ []) do
    main(args, &System.halt/1)
  end

  def main(_args, halt) when is_function(halt, 1) do
    case execute() do
      :ok ->
        :ok

      {:error, message} ->
        IO.puts(:stderr, message)
        halt.(1)
    end
  end

  def execute do
    paths =
      ZenPenguin.Render.run(
        root: root(),
        workspace: System.fetch_env!("GITHUB_WORKSPACE"),
        output: System.fetch_env!("INPUT_OUTPUT"),
        variables: System.fetch_env!("INPUT_VARIABLES")
      )

    write_output(paths)
    :ok
  rescue
    error in ZenPenguin.Error ->
      {:error, error.message}
  end

  defp write_output(paths) do
    case System.get_env("GITHUB_OUTPUT") do
      nil ->
        :ok

      file ->
        File.mkdir_p!(Path.dirname(file))

        body = [
          "config-paths<<ZENPENGUIN_CONFIG_PATHS\n",
          Enum.join(paths, "\n"),
          "\nZENPENGUIN_CONFIG_PATHS\n"
        ]

        File.write!(file, body, [:append])
    end
  end

  defp root do
    case System.get_env("ZEN_PENGUIN_ROOT") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        :zen_penguin
        |> :code.lib_dir()
        |> to_string()
        |> find_root()
    end
  end

  def find_root(path) do
    if File.regular?(Path.join(path, "zen_penguin.json")) do
      path
    else
      parent = Path.dirname(path)

      if parent == path do
        raise ZenPenguin.Error, "zen_penguin.json not found"
      else
        find_root(parent)
      end
    end
  end
end

defmodule ZenPenguin.Render do
  @moduledoc false

  @path_segment ~r/\A[A-Za-z0-9._-]+\z/
  @output_key :zen_penguin_output

  def run(opts) do
    root = Keyword.fetch!(opts, :root)
    workspace = Path.expand(Keyword.fetch!(opts, :workspace))
    output = Keyword.fetch!(opts, :output)
    variables = parse_variables(Keyword.fetch!(opts, :variables))
    config = load_config(Path.join(root, "config.exs"), root)
    values = load_values(root)
    assigns = build_assigns(values, variables, config)
    output_dir = output_directory(workspace, output)

    templates = templates(root)

    rendered =
      Enum.map(templates, fn template ->
        source = File.read!(template)
        {filename, body} = eval_template(source, assigns, template)
        path = output_file(output_dir, filename)
        {path, body}
      end)

    assert_unique_paths!(rendered)
    File.mkdir_p!(output_dir)

    Enum.each(rendered, fn {path, body} ->
      File.write!(path, body)
    end)

    Enum.map(rendered, fn {path, _body} ->
      Path.relative_to(path, workspace)
    end)
  end

  def parse_variables(text) when is_binary(text) do
    map =
      case String.trim(text) do
        "{" <> _ = json -> decode_variables(json)
        other -> decode_lines(other)
      end

    env = fetch_variable!(map, "env")
    junkyard = fetch_variable!(map, "junkyard")

    extra = Map.keys(map) -- ["env", "junkyard"]

    unless extra == [] do
      raise ZenPenguin.Error, "unknown variable #{Enum.join(extra, ", ")}"
    end

    %{env: env, junkyard: junkyard}
  end

  def bare_assign(assigns, key) do
    case Map.fetch(assigns.values, key) do
      {:ok, value} ->
        stringify(value)

      :error ->
        if MapSet.member?(assigns.missing_values, key) do
          apply_policy(assigns.missing_value, key, "value")
        else
          apply_policy(assigns.missing_key, key, "key")
        end
    end
  end

  def raw_assign(assigns, key) do
    Map.get(assigns.values, key)
  end

  def fetch(assigns, path) when is_binary(path) do
    case path_segments(path) do
      :error ->
        raise ZenPenguin.Error, "fetch/1 expects a dotted path, got #{inspect(path)}"

      segments ->
        walk(assigns, assigns.map, segments, path)
    end
  end

  def fetch(_assigns, other) do
    raise ZenPenguin.Error, "fetch/1 expects a dotted path, got #{inspect(other)}"
  end

  def fetch(assigns, namespace, key) when is_binary(key) do
    case lookup(namespace, key) do
      :missing_key -> apply_policy(assigns.missing_key, key, "key")
      :missing_value -> apply_policy(assigns.missing_value, key, "value")
      {:value, value} -> value
    end
  end

  def fetch(_assigns, _namespace, key) do
    raise ZenPenguin.Error, "fetch/2 expects a key string, got #{inspect(key)}"
  end

  defp lookup(namespace, key) when is_map(namespace) do
    case Map.fetch(namespace, key) do
      :error -> :missing_key
      {:ok, nil} -> :missing_value
      {:ok, ""} -> :missing_value
      {:ok, value} -> {:value, value}
    end
  end

  defp lookup(_namespace, _key), do: :missing_key

  defp path_segments(path) do
    segments = String.split(path, ".")

    if segments == [] or Enum.any?(segments, &(&1 == "")) do
      :error
    else
      segments
    end
  end

  defp walk(assigns, node, [key], path) do
    case lookup(node, key) do
      :missing_key -> apply_policy(assigns.missing_key, path, "key")
      :missing_value -> apply_policy(assigns.missing_value, path, "value")
      {:value, value} -> value
    end
  end

  defp walk(assigns, node, [key | rest], path) do
    case lookup(node, key) do
      {:value, child} when is_map(child) ->
        walk(assigns, child, rest, path)

      {:value, other} ->
        raise ZenPenguin.Error, "#{path} passes through #{inspect(other)}, which is not an object"

      _ ->
        apply_policy(assigns.missing_key, path, "key")
    end
  end

  def record_output(filename) when is_binary(filename) do
    case Process.get(@output_key) do
      nil ->
        Process.put(@output_key, filename)
        nil

      _existing ->
        raise ZenPenguin.Error, "output/1 called more than once"
    end
  end

  def record_output(other) do
    raise ZenPenguin.Error, "output/1 expects a filename string, got #{inspect(other)}"
  end

  def stringify(value) when is_binary(value), do: value
  def stringify(value) when is_atom(value), do: Atom.to_string(value)
  def stringify(value) when is_integer(value), do: Integer.to_string(value)
  def stringify(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])

  def stringify(value) when is_list(value) do
    if rendered_chunks?(value) do
      IO.iodata_to_binary(value)
    else
      raise ZenPenguin.Error,
            "cannot print #{inspect(value)}; walk arrays and maps in the template"
    end
  end

  def stringify(value) do
    raise ZenPenguin.Error,
          "cannot print #{inspect(value)}; walk arrays and maps in the template"
  end

  defp rendered_chunks?(list) when is_list(list) do
    Enum.all?(list, fn
      chunk when is_binary(chunk) -> true
      chunk when is_list(chunk) -> rendered_chunks?(chunk)
      _ -> false
    end)
  end

  defp eval_template(source, assigns, file) do
    Process.delete(@output_key)

    try do
      quoted = EEx.compile_string(source, engine: ZenPenguin.Engine, file: file)
      {body, _binding} = Code.eval_quoted(quoted, [assigns: assigns], file: file)

      case Process.get(@output_key) do
        nil ->
          raise ZenPenguin.Error, "template did not call output/1"

        filename when is_binary(filename) ->
          {filename, body}
      end
    after
      Process.delete(@output_key)
    end
  end

  defp build_assigns(map, variables, config) do
    %{
      values: %{env: variables.env, junkyard: variables.junkyard},
      map: resolve(map),
      missing_values: MapSet.new(),
      missing_key: config.missing_key,
      missing_value: config.missing_value
    }
  end

  defp resolve(map) when is_map(map) do
    if secret_object?(map) do
      resolve_secret(map)
    else
      Map.new(map, fn {key, value} -> {key, resolve(value)} end)
    end
  end

  defp resolve(list) when is_list(list) do
    Enum.map(list, &resolve/1)
  end

  defp resolve(other), do: other

  defp secret_object?(map) do
    map_size(map) == 1 and Map.has_key?(map, "$secret") and is_binary(map["$secret"])
  end

  defp resolve_secret(map) do
    case System.get_env(map["$secret"]) do
      nil -> nil
      "" -> nil
      secret -> secret
    end
  end

  defp apply_policy(:null, _key, _kind), do: "null"

  defp apply_policy(:fail, key, kind) do
    raise ZenPenguin.Error, "missing #{kind} #{key}"
  end

  defp apply_policy(other, _key, kind) do
    raise ZenPenguin.Error, "invalid missing_#{kind} policy #{inspect(other)}"
  end

  defp load_config(path, root) do
    path = inside!(path, root)

    case Code.eval_file(path) do
      {config, _binding} when is_map(config) ->
        missing_key = policy!(config, :missing_key)
        missing_value = policy!(config, :missing_value)
        %{missing_key: missing_key, missing_value: missing_value}

      _ ->
        raise ZenPenguin.Error, "config.exs must return a map"
    end
  end

  defp policy!(config, key) do
    case Map.fetch(config, key) do
      {:ok, value} when value in [:fail, :null] ->
        value

      {:ok, other} ->
        raise ZenPenguin.Error, "#{key} must be :fail or :null, got #{inspect(other)}"

      :error ->
        raise ZenPenguin.Error, "config.exs is missing #{key}"
    end
  end

  defp load_values(root) do
    json_path = Path.join(root, "zen_penguin.json")

    unless File.regular?(json_path) do
      raise ZenPenguin.Error, "zen_penguin.json is missing"
    end

    source = inside!(json_path, root)

    case read_json(source) do
      document when is_map(document) ->
        {map, _seen} =
          Enum.reduce(document, {%{}, MapSet.new()}, fn {group, entries}, acc ->
            load_group(root, group, entries, acc)
          end)

        map

      other ->
        raise ZenPenguin.Error, "zen_penguin.json must be an object, got #{inspect(other)}"
    end
  end

  defp load_group(root, group, entries, acc) when is_list(entries) do
    Enum.reduce(entries, acc, fn entry, {map, seen} ->
      namespace = entry_field(entry, "namespace", group)
      file = entry_field(entry, "file", group)

      if MapSet.member?(seen, namespace) do
        raise ZenPenguin.Error, "duplicate namespace #{namespace}"
      end

      path = value_file(root, file, "zen_penguin.json")
      object = read_object(path)
      map = put_namespace(map, namespace_segments(namespace), object, path)
      {map, MapSet.put(seen, namespace)}
    end)
  end

  defp load_group(_root, group, other, _acc) do
    raise ZenPenguin.Error, "#{group} must list files, got #{inspect(other)}"
  end

  defp entry_field(entry, field, group) when is_map(entry) do
    case Map.fetch(entry, field) do
      {:ok, value} when is_binary(value) and value != "" ->
        value

      {:ok, other} ->
        raise ZenPenguin.Error, "#{group} #{field} must be a string, got #{inspect(other)}"

      :error ->
        raise ZenPenguin.Error, "#{group} entry is missing #{field}"
    end
  end

  defp entry_field(other, _field, group) do
    raise ZenPenguin.Error, "#{group} entries must be objects, got #{inspect(other)}"
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, value} ->
            value

          {:error, reason} ->
            raise ZenPenguin.Error, "#{path} is invalid JSON: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise ZenPenguin.Error, "could not read #{path}: #{inspect(reason)}"
    end
  end

  defp namespace_segments(namespace) do
    segments = String.split(namespace, ".")

    if segments == [] or Enum.any?(segments, &(not Regex.match?(@path_segment, &1))) do
      raise ZenPenguin.Error, "#{namespace} is not a namespace"
    end

    segments
  end

  defp put_namespace(map, [segment], object, source) do
    current = Map.get(map, segment, %{})

    unless is_map(current) do
      raise ZenPenguin.Error, "#{segment} must be an object"
    end

    Map.put(map, segment, merge_keys(current, object, source))
  end

  defp put_namespace(map, [segment | rest], object, source) do
    child = Map.get(map, segment, %{})

    unless is_map(child) do
      raise ZenPenguin.Error, "#{segment} must be an object"
    end

    Map.put(map, segment, put_namespace(child, rest, object, source))
  end

  defp value_file(root, relative, source) do
    if relative == "" or String.contains?(relative, "\0") or Path.type(relative) == :absolute or
         Enum.any?(Path.split(relative), &(&1 == "..")) do
      raise ZenPenguin.Error, "#{source} path must stay inside the action"
    end

    inside!(Path.expand(relative, root), root)
  end

  defp merge_keys(into, extra, source) do
    Enum.reduce(extra, into, fn {key, value}, acc ->
      if Map.has_key?(acc, key) do
        raise ZenPenguin.Error, "duplicate key #{key} in #{source}"
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp read_object(path) do
    case File.read(path) do
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, map} when is_map(map) ->
            map

          {:ok, _} ->
            raise ZenPenguin.Error, "#{path} must be an object"

          {:error, reason} ->
            raise ZenPenguin.Error, "#{path} is invalid JSON: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise ZenPenguin.Error, "could not read #{path}: #{inspect(reason)}"
    end
  end

  defp templates(root) do
    dir = inside!(Path.join(root, "templates"), root)

    dir
    |> Path.join("*.eex")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp decode_variables(json) do
    case JSON.decode(json) do
      {:ok, map} when is_map(map) ->
        Map.new(map, fn
          {key, value} when is_binary(key) and is_binary(value) ->
            {key, value}

          {key, value} ->
            raise ZenPenguin.Error, "variable #{key} must be a string, got #{inspect(value)}"
        end)

      _ ->
        raise ZenPenguin.Error, "variables JSON must be an object of strings"
    end
  end

  defp decode_lines(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      line = String.trim(line)

      if line == "" or String.starts_with?(line, "#") do
        acc
      else
        put_variable_line(acc, line)
      end
    end)
  end

  defp put_variable_line(acc, line) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        put_variable(acc, String.trim(key), String.trim(value))

      _ ->
        raise ZenPenguin.Error, "invalid variable line #{inspect(line)}"
    end
  end

  defp put_variable(acc, key, value) do
    if Map.has_key?(acc, key) do
      raise ZenPenguin.Error, "duplicate variable #{key}"
    else
      Map.put(acc, key, value)
    end
  end

  defp fetch_variable!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> segment!(key, value)
      :error -> raise ZenPenguin.Error, "missing variable #{key}"
    end
  end

  defp segment!(key, value) do
    if Regex.match?(@path_segment, value) do
      value
    else
      raise ZenPenguin.Error, "#{key} must be one path segment"
    end
  end

  defp output_directory(workspace, output) do
    if Path.type(output) == :absolute or String.contains?(output, "\0") do
      raise ZenPenguin.Error, "output must stay inside the workspace"
    end

    path = Path.expand(output, workspace)
    inside!(path, workspace)
  end

  defp output_file(directory, filename) do
    if not is_binary(filename) or filename == "" or String.contains?(filename, "\0") or
         Path.type(filename) == :absolute do
      raise ZenPenguin.Error, "output filename must stay inside the output directory"
    end

    if Enum.any?(Path.split(filename), &(&1 == "..")) do
      raise ZenPenguin.Error, "output filename must stay inside the output directory"
    end

    inside!(Path.expand(filename, directory), directory)
  end

  defp inside!(path, parent) do
    path = Path.expand(path)
    parent = Path.expand(parent)

    if path == parent or String.starts_with?(path, parent <> "/") do
      path
    else
      raise ZenPenguin.Error, "path escapes #{parent}"
    end
  end

  defp assert_unique_paths!(rendered) do
    rendered
    |> Enum.map(fn {path, _} -> path end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_path, count} -> count > 1 end)
    |> case do
      [] ->
        :ok

      duplicates ->
        names = Enum.map_join(duplicates, ", ", fn {path, _} -> Path.basename(path) end)
        raise ZenPenguin.Error, "templates write the same file #{names}"
    end
  end
end

defmodule ZenPenguin.Engine do
  @moduledoc false

  @behaviour EEx.Engine

  @impl true
  defdelegate init(opts), to: EEx.Engine

  @impl true
  defdelegate handle_body(state), to: EEx.Engine

  @impl true
  defdelegate handle_begin(state), to: EEx.Engine

  @impl true
  defdelegate handle_end(state), to: EEx.Engine

  @impl true
  defdelegate handle_text(state, meta, text), to: EEx.Engine

  @impl true
  def handle_expr(state, "=", {:@, meta, [{name, _, atom}]})
      when is_atom(name) and is_atom(atom) do
    line = meta[:line] || 0

    expr =
      quote line: line do
        ZenPenguin.Render.bare_assign(var!(assigns), unquote(name))
      end

    EEx.Engine.handle_expr(state, "=", expr)
  end

  def handle_expr(state, marker, expr) do
    expr = Macro.prewalk(expr, &expand/1)

    expr =
      if marker == "=" do
        quote do
          case unquote(expr) do
            nil -> ""
            other -> ZenPenguin.Render.stringify(other)
          end
        end
      else
        expr
      end

    EEx.Engine.handle_expr(state, marker, expr)
  end

  defp expand({:fetch, meta, [path]}) do
    line = meta[:line] || 0

    quote line: line do
      ZenPenguin.Render.fetch(var!(assigns), unquote(path))
    end
  end

  defp expand({:fetch, meta, [namespace, key]}) do
    line = meta[:line] || 0

    quote line: line do
      ZenPenguin.Render.fetch(var!(assigns), unquote(namespace), unquote(key))
    end
  end

  defp expand({:output, meta, [filename]}) do
    filename = Macro.prewalk(filename, &expand/1)
    line = meta[:line] || 0

    quote line: line do
      ZenPenguin.Render.record_output(unquote(filename))
    end
  end

  defp expand({:@, meta, [{name, _, atom}]}) when is_atom(name) and is_atom(atom) do
    line = meta[:line] || 0

    quote line: line do
      ZenPenguin.Render.raw_assign(var!(assigns), unquote(name))
    end
  end

  defp expand(other), do: other
end

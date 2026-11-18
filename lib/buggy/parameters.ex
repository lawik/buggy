defmodule Buggy.Parameters do
  @moduledoc """
  Robot parameters by their dotted names, with values as text: for consoles
  such as the BLE one (see `Buggy.BLE.Console`).

      Buggy.Parameters.get(Buggy.Robot, "limits.max_throttle")
      #=> {:ok, [:limits, :max_throttle], %{value: 0.3, type: :float, ...}}

      Buggy.Parameters.set(Buggy.Robot, "limits.max_throttle", "0.4")
      Buggy.Parameters.unset(Buggy.Robot, "limits.max_throttle")

  Unsetting puts a parameter back to the value it starts with, the robot's
  `params` from `config :buggy, Buggy.Robot` or else the DSL default, and
  deletes its saved value (see `Buggy.ParameterStore`), so a later change to
  the default applies again.

  Names are matched against the robot's parameters, so no atoms are made
  from what a client sends.
  """

  alias BB.Parameter

  @type path :: [atom()]

  @doc "Every parameter under `prefix` (dotted, `\"\"` for all), sorted by name."
  @spec list(module(), String.t()) :: [{String.t(), path(), map()}]
  def list(robot, prefix \\ "") do
    entries =
      for {path, meta} <- Parameter.list(robot),
          name = name(path),
          prefix == "" or name == prefix or String.starts_with?(name, prefix <> "."),
          do: {name, path, meta}

    Enum.sort_by(entries, &elem(&1, 0))
  end

  @doc "Look up a parameter by name."
  @spec get(module(), String.t()) :: {:ok, path(), map()} | {:error, String.t()}
  def get(robot, name) do
    case Enum.find(Parameter.list(robot), fn {path, _meta} -> name(path) == name end) do
      {path, meta} -> {:ok, path, meta}
      nil -> {:error, "no parameter #{name}"}
    end
  end

  @doc "Set a parameter from text, parsed according to its type."
  @spec set(module(), String.t(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def set(robot, name, text) do
    with {:ok, path, meta} <- get(robot, name),
         {:ok, value} <- parse(meta[:type], String.trim(text)),
         :ok <- write(robot, path, value) do
      {:ok, current(robot, path, value)}
    end
  end

  @doc """
  Put a parameter back to its starting value and forget its saved value.
  """
  @spec unset(module(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def unset(robot, name) do
    with {:ok, path, meta} <- get(robot, name),
         {:ok, value} <- starting_value(robot, path, meta),
         :ok <- write(robot, path, value),
         :ok <- forget(robot, path) do
      {:ok, current(robot, path, value)}
    end
  end

  defp forget(robot, path) do
    case Buggy.ParameterStore.forget(robot, path) do
      :ok -> :ok
      {:error, reason} -> {:error, "back to its default, but still saved: #{inspect(reason)}"}
    end
  end

  @doc "A parameter's dotted name."
  @spec name(path()) :: String.t()
  def name(path), do: Enum.map_join(path, ".", &Atom.to_string/1)

  @doc "A value as text."
  @spec format(term()) :: String.t()
  def format(nil), do: "(none)"
  def format(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  def format(value) when is_binary(value), do: value
  def format(%Localize.Unit{name: unit, value: value}), do: "#{format(value)} #{unit}"
  def format(value) when is_atom(value) or is_integer(value), do: to_string(value)
  def format(value), do: inspect(value)

  @doc "A type as text, with its bounds."
  @spec describe_type(map()) :: String.t()
  def describe_type(meta) do
    type =
      case meta[:type] do
        {:unit, unit} -> "#{unit}"
        {:in, values} -> Enum.map_join(values, "|", &format/1)
        nil -> "any"
        type when is_atom(type) -> Atom.to_string(type)
        type -> inspect(type)
      end

    case {meta[:min], meta[:max]} do
      {nil, nil} -> type
      {min, nil} -> "#{type} >= #{format(min)}"
      {nil, max} -> "#{type} <= #{format(max)}"
      {min, max} -> "#{type} #{format(min)}..#{format(max)}"
    end
  end

  @doc "Parse text as a value of a parameter type."
  @spec parse(term(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def parse(:float, text) do
    case Float.parse(text) do
      {float, ""} -> {:ok, float}
      _ -> {:error, "not a number: #{text}"}
    end
  end

  def parse(:integer, "0x" <> hex) do
    case Integer.parse(hex, 16) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "not an integer: 0x#{hex}"}
    end
  end

  def parse(:integer, text) do
    case Integer.parse(text) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "not an integer: #{text}"}
    end
  end

  def parse(:boolean, text) do
    case String.downcase(text) do
      t when t in ["true", "on", "yes", "1"] -> {:ok, true}
      f when f in ["false", "off", "no", "0"] -> {:ok, false}
      _ -> {:error, "not true or false: #{text}"}
    end
  end

  def parse(:string, text), do: {:ok, unquote_text(text)}

  def parse({:in, values}, text) do
    case Enum.find(values, &(format(&1) == text)) do
      nil -> {:error, "not one of #{Enum.map_join(values, ", ", &format/1)}"}
      value -> {:ok, value}
    end
  end

  def parse(:atom, text) do
    {:ok, String.to_existing_atom(text)}
  rescue
    ArgumentError -> {:error, "unknown value: #{text}"}
  end

  # "12.5" in the declared unit, or "12.5 radian" in any compatible one.
  def parse({:unit, unit}, text) do
    {magnitude, unit_name} =
      case String.split(text, " ", parts: 2, trim: true) do
        [magnitude, name] -> {magnitude, name}
        [magnitude] -> {magnitude, BB.Unit.unit_name(unit)}
        [] -> {"", nil}
      end

    with {:ok, number} <- parse(:float, magnitude) do
      case Localize.Unit.new(number, unit_name) do
        {:ok, value} -> {:ok, value}
        {:error, exception} -> {:error, Exception.message(exception)}
      end
    end
  end

  def parse(type, _text), do: {:error, "can't set a #{inspect(type)} from text"}

  defp unquote_text(<<q, rest::binary>> = text) when q in [?", ?'] do
    if String.ends_with?(rest, <<q>>) and rest != "",
      do: binary_part(rest, 0, byte_size(rest) - 1),
      else: text
  end

  defp unquote_text(text), do: text

  defp write(robot, path, value) do
    case Parameter.set(robot, path, value) do
      :ok -> :ok
      {:error, reason} -> {:error, describe_error(reason)}
    end
  end

  defp current(robot, path, fallback) do
    case Parameter.get(robot, path) do
      {:ok, value} -> value
      _ -> fallback
    end
  end

  # What the robot starts with: its start-up `params` win over the default.
  defp starting_value(robot, path, meta) do
    configured =
      :buggy
      |> Application.get_env(robot, [])
      |> Keyword.get(:params, [])
      |> lookup(path)

    case configured || Map.fetch(meta, :default) do
      {:ok, nil} -> {:error, "#{name(path)} has no default to go back to"}
      {:ok, value} -> {:ok, value}
      :error -> {:error, "#{name(path)} has no default to go back to"}
    end
  end

  defp lookup(params, [key]) when is_list(params) do
    if Keyword.keyword?(params) and Keyword.has_key?(params, key),
      do: {:ok, Keyword.fetch!(params, key)}
  end

  defp lookup(params, [key | rest]) when is_list(params) do
    if Keyword.keyword?(params), do: lookup(Keyword.get(params, key), rest)
  end

  defp lookup(_params, _path), do: nil

  defp describe_error(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe_error(reason) when is_binary(reason), do: reason
  defp describe_error(reason), do: inspect(reason)
end

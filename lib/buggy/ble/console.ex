defmodule Buggy.BLE.Console do
  @moduledoc """
  A line-based text console over the Nordic UART Service, for Bluefruit
  Connect's UART screen, nRF Toolbox or any serial-over-BLE terminal.

      help                 this list
      state                the robot's state
      commands             the robot's commands and their arguments
      <command> [args]     run a robot command, e.g. `arm`, `steer -0.5`,
                           `throttle 0.3 2000` (arguments in order, or
                           `name=value`)
      params [prefix]      list parameters, e.g. `params calibration`
      get <name>           one parameter, with its type, default and doc
      set <name> <value>   set a parameter, e.g. `set limits.max_throttle 0.4`
      unset <name>         put a parameter back to its default
      wifi                 the Wi-Fi network and address
      wifi <ssid> [psk]    join a network; quote names with spaces

  `run/3` turns a line into actions for `Buggy.BLE`: text to send back, a
  command still running to report on when it finishes, or a Wi-Fi join
  (which `Buggy.BLE` runs, one at a time, shared with Improv).
  """

  alias BB.Robot.Runtime
  alias Buggy.Parameters

  @type action ::
          {:reply, String.t()}
          | {:await, pid(), String.t()}
          | {:wifi_join, String.t(), String.t()}

  # How long a robot command gets to finish before the reply says it's
  # running, and its result follows when it's done.
  @yield_ms 500

  @help """
  state              robot state
  commands           robot commands
  <command> [args]   e.g. arm, steer -0.5,
                     throttle 0.3 2000
  params [prefix]    list parameters
  get <name>         one parameter
  set <name> <value> set a parameter
  unset <name>       back to its default
  wifi               Wi-Fi status
  wifi <ssid> [psk]  join a network
  Control Pad: arrows drive, 1 arms,
  2 disarms.
  """

  @doc "Run one line. `opts` go to `Buggy.WiFi.status/1`."
  @spec run(String.t(), module(), keyword()) :: [action()]
  def run(line, robot, opts \\ []) do
    case OptionParser.split(String.trim(line)) do
      [] -> []
      [word | args] -> run(String.downcase(word), args, robot, opts)
    end
  end

  defp run("help", _args, _robot, _opts), do: reply(@help)
  defp run("?", _args, _robot, _opts), do: reply(@help)

  defp run("state", _args, robot, _opts), do: reply("state: #{robot_state(robot)}")

  defp run("commands", _args, robot, _opts) do
    robot
    |> commands()
    |> Enum.map(fn command ->
      args = Enum.map_join(command.arguments, "", &" #{&1.name}=#{Parameters.format(&1.default)}")
      "#{command.name}#{args}\n"
    end)
    |> Enum.join()
    |> reply()
  end

  defp run("params", args, robot, _opts) do
    case Parameters.list(robot, Enum.join(args, "")) do
      [] ->
        reply("no parameters #{Enum.join(args, "")}")

      params ->
        reply(Enum.map_join(params, "", fn {name, _, meta} -> "#{line(name, meta)}\n" end))
    end
  end

  defp run("get", [name], robot, _opts) do
    case Parameters.get(robot, name) do
      {:ok, _path, meta} ->
        doc = if meta[:doc], do: "\n  #{meta[:doc]}", else: ""

        reply(
          "#{line(name, meta)}\n  #{Parameters.describe_type(meta)}, " <>
            "default #{Parameters.format(meta[:default])}#{doc}"
        )

      {:error, message} ->
        reply("error: #{message}")
    end
  end

  defp run("set", [name | value], robot, _opts) when value != [] do
    case Parameters.set(robot, name, Enum.join(value, " ")) do
      {:ok, new} -> reply("#{name} = #{Parameters.format(new)}")
      {:error, message} -> reply("error: #{message}")
    end
  end

  defp run("unset", [name], robot, _opts) do
    case Parameters.unset(robot, name) do
      {:ok, value} -> reply("#{name} = #{Parameters.format(value)} (default)")
      {:error, message} -> reply("error: #{message}")
    end
  end

  defp run("wifi", [], _robot, opts) do
    case Buggy.WiFi.status(opts) do
      %{connection: connection} when connection not in [:lan, :internet] ->
        reply("wifi: not connected (#{connection})")

      %{ssid: ssid, connection: connection, address: address} ->
        reply("wifi: #{ssid || "connected"}, #{connection}, #{address || "no address"}")
    end
  end

  defp run("wifi", [ssid | psk], _robot, _opts) when length(psk) <= 1 do
    [{:reply, "wifi: joining #{ssid}...\n"}, {:wifi_join, ssid, Enum.join(psk)}]
  end

  defp run(word, _args, _robot, _opts) when word in ["get", "set", "unset", "wifi"],
    do: reply("usage: " <> usage(word))

  defp run(word, args, robot, _opts) do
    case Enum.find(commands(robot), &(Atom.to_string(&1.name) == word)) do
      nil -> reply("unknown command #{word}, try help")
      command -> run_command(robot, command, args)
    end
  end

  defp usage("get"), do: "get <name>"
  defp usage("set"), do: "set <name> <value>"
  defp usage("unset"), do: "unset <name>"
  defp usage("wifi"), do: "wifi [<ssid> [psk]]"

  defp run_command(robot, command, args) do
    name = Atom.to_string(command.name)

    with {:ok, goal} <- goal(command, args),
         {:ok, pid} <- Runtime.execute(robot, command.name, goal) do
      case BB.Command.yield(pid, @yield_ms) do
        nil -> [{:reply, "#{name}: running\n"}, {:await, pid, name}]
        result -> reply("#{name}: #{format_result(result)}")
      end
    else
      {:error, reason} -> reply("#{name}: error #{describe(reason)}")
    end
  catch
    :exit, reason -> reply("#{Atom.to_string(command.name)}: error #{describe(reason)}")
  end

  @doc "Wait for a command that was still running, and describe how it ended."
  @spec await(pid(), String.t()) :: String.t()
  def await(pid, name), do: "#{name}: #{format_result(BB.Command.await(pid, :infinity))}\n"

  @doc "A command's result as text."
  @spec format_result(term()) :: String.t()
  def format_result({:ok, value}), do: "ok" <> format_value(value)
  def format_result({:ok, value, _next}), do: "ok" <> format_value(value)
  def format_result({:error, reason}), do: "error #{describe(reason)}"
  def format_result(other), do: inspect(other, limit: 10)

  defp format_value(nil), do: ""
  defp format_value(:ok), do: ""

  defp format_value(%{} = map) when not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join("", fn {key, value} -> " #{key}=#{Parameters.format(value)}" end)
  end

  defp format_value(value), do: " " <> Parameters.format(value)

  # Positional arguments in declaration order, or name=value.
  defp goal(command, args) do
    {named, positional} = Enum.split_with(args, &String.contains?(&1, "="))

    if length(positional) > length(command.arguments) do
      {:error, "too many arguments, try commands"}
    else
      named =
        Map.new(named, fn pair ->
          [key, value] = String.split(pair, "=", parts: 2)
          {key, value}
        end)

      positional =
        command.arguments |> Enum.zip(positional) |> Map.new(fn {a, v} -> {a.name, v} end)

      build_goal(command.arguments, named, positional)
    end
  end

  defp build_goal(arguments, named, positional) do
    known = MapSet.new(arguments, &Atom.to_string(&1.name))

    case Enum.find(Map.keys(named), &(not MapSet.member?(known, &1))) do
      nil ->
        Enum.reduce_while(arguments, {:ok, %{}}, fn argument, {:ok, goal} ->
          case Map.get(named, Atom.to_string(argument.name)) || Map.get(positional, argument.name) do
            nil ->
              {:cont, {:ok, goal}}

            text ->
              case Parameters.parse(argument.type, text) do
                {:ok, value} -> {:cont, {:ok, Map.put(goal, argument.name, value)}}
                {:error, message} -> {:halt, {:error, "#{argument.name}: #{message}"}}
              end
          end
        end)

      unknown ->
        {:error, "no argument #{unknown}"}
    end
  end

  defp commands(robot) do
    robot
    |> BB.Dsl.Info.commands()
    |> Enum.filter(&is_struct(&1, BB.Dsl.Command))
  end

  defp line(name, meta), do: "#{name} = #{Parameters.format(meta[:value])}"

  @doc "The robot's state, or `:unavailable` while it isn't running."
  @spec robot_state(module()) :: atom()
  def robot_state(robot) do
    Runtime.state(robot)
  rescue
    ArgumentError -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason, limit: 10)

  defp reply(text), do: [{:reply, String.trim_trailing(text) <> "\n"}]
end

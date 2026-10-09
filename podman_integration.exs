Mix.install([
  {:jason, "~> 1.4"}
])

defmodule WorkflowOrchestrator.Podman do
  @moduledoc """
  Podman integration for workflow orchestration in Elixir.

  Provides container execution capabilities for workflow tasks,
  including image management, resource limits, and lifecycle handling.
  """

  @type container_config :: %{
    image:        String.t(),
    command:      String.t()   | [String.t()],
    args:         [String.t()] | nil,
    env:          map()        | nil,
    volumes:      [String.t()] | nil,
    memory_limit: String.t()   | nil,
    cpu_limit:    String.t()   | nil,
    timeout:      non_neg_integer(),
    remove_after: boolean(),
    network:      String.t()   | nil,
    user:         String.t()   | nil,
    working_dir:  String.t()   | nil,
    pull_policy:  :always      | :missing | :never
  }

  @type container_result :: %{
    status:       :success     | :failure | :timeout,
    exit_code:    integer()    | nil,
    stdout:       String.t(),
    stderr:       String.t(),
    container_id: String.t()   | nil,
    duration_ms:  non_neg_integer()
  }

  @default_timeout 300_000  # 5 minutes
  @default_pull_policy :missing

  @doc """
  Run a container with the given configuration.

  Returns a result map with status, exit code, and output.
  """
  @spec run(container_config()) :: {:ok, container_result()} | {:error, term()}
  def run(config) when is_map(config) do
    start_time = System.monotonic_time(:millisecond)

    config = Map.merge(default_config(), config)

    with :ok <- pull_image_impl(config),
         {:ok, container_id, stdout, stderr, exit_code} <-
           execute_container(config),
         duration <- System.monotonic_time(:millisecond) - start_time do

      result = %{
        status: exit_status(exit_code),
        exit_code: exit_code,
        stdout: stdout,
        stderr: stderr,
        container_id: container_id,
        duration_ms: duration
      }

      cleanup_container(container_id, config)
      {:ok, result}
    else
      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        {:error, %{reason: reason, duration_ms: duration}}
    end
  end

  @doc """
  Check if a container image exists locally.
  """
  @spec image_exists?(String.t()) :: boolean()
  def image_exists?(image) do
    case run_podman(["image", "inspect", image]) do
      {:ok, _output} -> true
      {:error, _} -> false
    end
  end

  defp pull_image_impl(%{image: image, pull_policy: policy}) do
    case policy do
      :always  -> pull_image(image)
      :missing -> image_exists?(image) && :ok || pull_image(image)
      :never   -> :ok
      invalid  -> {:error, {:invalid_pull_policy, invalid}}
    end
  end

  @doc """
  Pull a container image from registry.
  """
  @spec pull_image(String.t()) :: :ok | {:error, term()}
  def pull_image(image) when is_binary(image) do
    case run_podman(["pull", image]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:image_pull_failed, reason}}
    end
  end

  @doc """
  Get container logs.
  """
  @spec get_logs(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_logs(container_id) do
    run_podman(["logs", container_id])
  end

  @doc """
  Remove a container.
  """
  @spec remove_container(String.t()) :: :ok | {:error, term()}
  def remove_container(container_id) do
    case run_podman(["rm", "-f", container_id]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List running containers.
  """
  @spec list_containers() :: {:ok, [map()]} | {:error, term()}
  def list_containers() do
    case run_podman(["ps", "--format", "json"]) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, containers} -> {:ok, containers}
          {:error, _} -> {:error, :json_decode_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get container stats.
  """
  @spec get_stats(String.t()) :: {:ok, map()} | {:error, term()}
  def get_stats(container_id) do
    case run_podman(["stats", "--no-stream", "--format", "json", container_id]) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, [stats | _]} -> {:ok, stats}
          {:ok, []} -> {:error, :container_not_running}
          {:error, _} -> {:error, :json_decode_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp default_config do
    %{
      timeout:      @default_timeout,
      remove_after: true,
      pull_policy:  @default_pull_policy,
      env:          %{},
      volumes:      [],
      args:         nil,
      memory_limit: nil,
      cpu_limit:    nil,
      network:      "default",
      user:         nil,
      working_dir:  nil
    }
  end

  defp execute_container(config) do
    with {:ok, container_id} <- create_container(config),
         :ok                 <- start_container(container_id),
         {:ok, exit_code}    <- wait_container(container_id, config.timeout),
         {:ok, stdout}       <- get_container_output(container_id, "stdout"),
         {:ok, stderr}       <- get_container_output(container_id, "stderr") do

      {:ok, container_id, stdout, stderr, exit_code}
    end
  end

  defp create_container(%{image: image, command: cmd, args: args} = config) do
    podman_args = [
      "create",
      "--name",
      generate_container_name(),
      "--rm=false"  # We handle cleanup
    ]

    podman_args = add_resource_limits(podman_args, config)
    podman_args = add_env_vars(podman_args, config)
    podman_args = add_volumes(podman_args, config)
    podman_args = add_network(podman_args, config)
    podman_args = add_user(podman_args, config)
    podman_args = add_working_dir(podman_args, config)

    podman_args = podman_args ++ [image]

    # Add command
    podman_args =
      case cmd do
        binary when is_binary(binary) -> podman_args ++ ["/bin/sh", "-c", binary]
        list when is_list(list) -> podman_args ++ list
      end

    # Add arguments
    podman_args =
      if args && is_list(args) do
        podman_args ++ args
      else
        podman_args
      end

    case run_podman(podman_args) do
      {:ok, output} ->
        container_id = String.trim(output)
        {:ok, container_id}

      {:error, reason} ->
        {:error, {:create_failed, reason}}
    end
  end

  defp start_container(container_id) do
    case run_podman(["start", container_id]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  defp wait_container(container_id, timeout) do
    task = Task.async(fn ->
      case run_podman(["wait", container_id]) do
        {:ok, output} ->
          case Integer.parse(String.trim(output)) do
            {exit_code, _} -> exit_code
            :error         -> 1
          end
        {:error, _} -> 1
      end
    end)

    case Task.await(task, timeout) do
      exit_code when is_integer(exit_code) -> {:ok, exit_code}
      _ -> {:error, :timeout}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp get_container_output(container_id, stream) do
    case run_podman(["logs", "--#{stream}", container_id]) do
      {:ok,    output} -> {:ok, output}
      {:error, reason} -> {:error, {:logs_failed, reason}}
    end
  end

  defp add_resource_limits(args, %{memory_limit: memory, cpu_limit: cpu}) do
    args = memory && (args ++ ["--memory", memory]) || args
    cpu && (args ++ ["--cpus", cpu]) || args
  end

  defp add_env_vars(args, %{env: env}) when is_map(env) do
    Enum.reduce(env, args, fn {key, value}, acc -> acc ++ ["-e", "#{key}=#{value}"] end)
  end

  defp add_env_vars(args, _), do: args

  defp add_volumes(args, %{volumes: volumes}) when is_list(volumes) do
    Enum.reduce(volumes, args, fn volume, acc -> acc ++ ["-v", volume] end)
  end

  defp add_volumes(args, _), do: args

  defp add_network(args, %{network: network}) when is_binary(network) do
    args ++ ["--network", network]
  end

  defp add_network(args, _), do: args

  defp add_user(args, %{user: user}) when is_binary(user) do
    args ++ ["-u", user]
  end

  defp add_user(args, _), do: args

  defp add_working_dir(args, %{working_dir: dir}) when is_binary(dir) do
    args ++ ["-w", dir]
  end

  defp add_working_dir(args, _), do: args

  defp cleanup_container(container_id, %{remove_after: true}) do
    Task.start(fn ->
      :timer.sleep(100)  # Brief delay to ensure logs are written
      remove_container(container_id)
    end)

    :ok
  end

  defp cleanup_container(_, _), do: :ok

  defp exit_status(0), do: :success
  defp exit_status(_), do: :failure

  defp generate_container_name do
    "task-#{:erlang.unique_integer([:positive])}"
  end

  defp run_podman(args) do
    cmd = "podman"
    opts = []

    case System.cmd(cmd, args, opts) do
      {output, 0} ->
        {:ok, output}

      {error, exit_code} ->
        {:error, %{exit_code: exit_code, error: error}}
    end
  rescue
    e ->
      {:error, %{exception: inspect(e)}}
  end
end

# Integration with Workflow Executor

defmodule WorkflowOrchestrator.TaskExecutor do
  @moduledoc """
  Task executor that supports both native and container tasks.
  """

  def run_task(%{type: :container} = task) do
    config = build_podman_config(task)

    case WorkflowOrchestrator.Podman.run(config) do
      {:ok, result} ->
        if result.exit_code == 0 do
          {:ok, result}
        else
          {:error, {:task_failed, result.exit_code, result.stderr}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_task(%{type: :native}) do
    # Native task execution (via erlexec or similar)
    :not_implemented
  end

  defp build_podman_config(task) do
    %{
      image:        Map.fetch!(task, :image),
      command:      Map.get(task, :command, ""),
      args:         Map.get(task, :args),
      env:          Map.get(task, :env, %{}),
      volumes:      Map.get(task, :volumes, []),
      memory_limit: Map.get(task, :memory_limit),
      cpu_limit:    Map.get(task, :cpu_limit),
      timeout:      Map.get(task, :timeout, 300_000),
      network:      Map.get(task, :network, "default"),
      working_dir:  Map.get(task, :working_dir),
      pull_policy:  Map.get(task, :pull_policy, :missing)
    }
  end
end

# Example usage

defmodule WorkflowOrchestrator.Example do
  @doc """
  Execute a python script

  - `**--rm**`: Automatically removes the container after it exits to keep your
    system clean.
  - `**-v ".:/app:Z"**`: Maps your current directory (.) to the `/app` directory
    inside the container. **Crucial Podman Tip:** __The :Z flag is required on
    SELinux systems (like Fedora, RHEL, or CentOS) to grant the container
    permission to access the host directory.__
  - `**-w /app**`: Sets the working directory inside the container to `/app` so
    `uv` can find your files immediately.
  - `**ghcr.io/astral-sh/uv:latest**`: The official Astral image containing the uv
    toolchain.
  - `**uv run script.py*``: Instructs uv to look for a pyproject.toml or
    script dependencies, set up a transient virtual environment, and execute your script.

  ## Handling Requirements (`requirements.txt` or `pyproject.toml`)

  If your script depends on external packages, uv will automatically read them if
  they are in your mounted directory:
  - **Using a script header (PEP 723)**: If your `script.py` has inline dependencies
    declared at the top, `uv run script.py` will install them on the fly.
  - **Using a requirements file**: You can force uv to install dependencies from
    your mapped volume before running.

  ## Caching Downloaded Packages

  - **Persistent Cache Volume**: `-v uv-cache:/root/.cache/uv:Z` creates a named
    Podman volume called `uv-cache` that maps directly to `uv`'s internal caching
    directory. This ensures subsequent container runs do not re-download packages.
  - The Copy Link Mode: `-e UV_LINK_MODE=copy` is essential. By default, `uv` attempts
    to hardlink or clone files from its cache to your project's environment. Because
    your project (/app) and the cache (/root/.cache/uv) live on completely separate
    volume filesystems, hardlinking will fail. Setting this variable instructs `uv`
    to cleanly copy packages instead.

  ## Execution Command & Working Directory

  - **Working Directory**: -w /app forces the container to start inside your
    mounted project folder.
  - **The Execution Command**: uv run `script.py` (or `uv run main.py`). The `uv`
    run tool is intelligent:
  - If a `pyproject.toml` or `requirements.txt` exists in your folder, it will
    instantly look for or create a transient virtual environment, install the
    prerequisites out of the persistent cache, and execute your script.
  - If you just want to execute a single file with specific dependencies without
    a project structure, you can pass them inline: `uv run --with` requests
    `script.py`.

  ## Passing Input (Interactive Data)

  - **Interactive Terminal**: The flags `-it` (`--interactive` and `--tty`) connect
    your host terminal's standard input (`stdin`) and standard output (`stdout`) to
    the container. This allows commands like `input()` inside your Python scripts
    to correctly read keyboard input in real-time.
  - **Piping Data (Alternative)**: If you want to pipe standard input into your
    container non-interactively (e.g., from a file), drop the -t flag but keep `-i`:
    ```bash
    cat data.txt | podman run --rm -i -v "$(pwd)":/app:Z ... uv run script.py
    ```

  """
  def example_container_task do
    %{
      id:      :process_data,
      type:    :container,
      image:   "ghcr.io/astral-sh/uv:debian-slim",
      command: "uv run python process.py",
      args: [
        "--rm",
        "-v", "/tmp:/app:Z",
        "-e", "UV_LINK_MODE=copy",
        "--input", "/data/input.csv"],
      env: %{
        "API_KEY" => "secret123",
        "LOG_LEVEL" => "DEBUG"
      },
      volumes: [
        "/tmp:/data",
        "/tmp:/app:ro"
      ],
      memory_limit: "512MB",
      cpu_limit:    "1.0",
      timeout:      300_000,
      working_dir:  "/app",
      pull_policy:  :missing
    }
  end

  def example_workflow do
    [
      %{
        id:      :extract,
        type:    :native,
        command: "curl https://api.example.com/data > /data/raw.json"
      },
      %{
        id:           :transform,
        type:         :container,
        image:        "python:3.11",
        command:      "python transform.py",
        env:          %{"INPUT" => "/data/raw.json", "OUTPUT" => "/data/processed.json"},
        volumes:      ["/data:/data"],
        memory_limit: "1GB",
        timeout:      600_000
      },
      %{
        id:           :validate,
        type:         :container,
        image:        "python:3.11",
        command:      "python validate.py /data/processed.json",
        volumes:      ["/data:/data"],
        memory_limit: "512MB"
      }
    ]
  end

  def run_example do
    task = example_container_task()

    case WorkflowOrchestrator.TaskExecutor.run_task(task) do
      {:ok, result} ->
        IO.inspect(result, label: "Container execution succeeded")
        IO.puts("STDOUT: #{result.stdout}")
        IO.puts("STDERR: #{result.stderr}")

      {:error, reason} ->
        IO.inspect(reason, label: "Container execution failed")
    end
  end
end

WorkflowOrchestrator.Example.run_example()

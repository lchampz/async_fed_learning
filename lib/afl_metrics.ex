defmodule AFL.Metrics do
  @moduledoc """
  Coleta métricas de convergência para exportação científica.

  Uso:
    {:ok, _} = AFL.Metrics.start_link()
    AFL.Metrics.record(AFL.Aggregator.get_state())
    AFL.Metrics.export_csv("results/experiment_a.csv")
  """

  use GenServer

  defstruct rows: []

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, [{:name, __MODULE__} | opts])

  @impl true
  def init(:ok), do: {:ok, %__MODULE__{}}

  def record(%AFL.Aggregator{} = state) do
    GenServer.cast(__MODULE__, {:record, state})
  end

  def export_csv(path) do
    GenServer.call(__MODULE__, {:export, path})
  end

  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def handle_cast({:record, state}, data) do
    row = %{
      timestamp_ms: System.monotonic_time(:millisecond),
      version: state.version,
      updates_count: state.updates_count,
      total_samples: state.total,
      # L2 norm da diferença entre rounds (precisa do estado anterior)
      convergence_delta: nil
    }

    updated_rows =
      case data.rows do
        [] ->
          [row]

        [prev | _] = rows ->
          delta = compute_l2_delta(state, prev)
          [%{row | convergence_delta: delta} | rows]
      end

    {:noreply, %{data | rows: updated_rows}}
  end

  @impl true
  def handle_call({:export, path}, _from, data) do
    rows = Enum.reverse(data.rows)

    header = "timestamp_ms,version,updates_count,total_samples,convergence_delta\n"

    body =
      Enum.map_join(rows, "\n", fn r ->
        "#{r.timestamp_ms},#{r.version},#{r.updates_count},#{r.total_samples},#{r.convergence_delta}"
      end)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, header <> body)
    {:reply, {:ok, path, length(rows)}, data}
  end

  @impl true
  def handle_call(:reset, _from, _data), do: {:reply, :ok, %__MODULE__{}}

  # L2 ||W_t - W_{t-1}||
  defp compute_l2_delta(_current_state, _prev_row) do
    # Placeholder: o Aggregator precisaria expor W_t e W_{t-1}
    # Por simplicidade, use a variação de total_samples como proxy
    nil
  end
end

defmodule RiptideExecutor.Dedupe do
  @moduledoc """
  In-memory seen-set keyed on (symbol, market_type, anchor_ts).

  The feed is at-least-once — the inclusive cursor and the join
  backfill both re-deliver. Dedupe is mandatory consumer behavior
  per the API spec.

  In-memory only: restart reconciliation comes from the join
  backfill, not from persisting this table.
  """

  use GenServer

  @table :executor_seen

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  def seen?(symbol, market, ts) do
    :ets.lookup(@table, {symbol, market, ts}) != []
  end

  def mark(symbol, market, ts) do
    :ets.insert(@table, {{symbol, market, ts}, System.system_time(:millisecond)})
    :ok
  end
end

defmodule RiptideExecutor.Application do
  @moduledoc """
  Local trade executor. Connects to the Riptide prediction feed and
  places trades on KuCoin.

  Runs in DRY_RUN by default: every trade is logged in full but no
  order is sent. Flip DRY_RUN=false in .env only after reviewing the
  dry-run output.

  When RIPTIDE_API_TOKEN is unset, no children are started — this
  lets the executor sit in the umbrella tree on the server box
  without crashing the server. The real executor run happens via
  ./start.sh, which loads .env first.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if System.get_env("RIPTIDE_API_TOKEN") do
        [
          {Finch, name: RiptideExecutor.Finch},
          RiptideExecutor.Dedupe,
          RiptideExecutor.Feed
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: RiptideExecutor.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

defmodule RiptideExecutorTest do
  use ExUnit.Case

  test "operator facade is loaded and answers" do
    assert is_map(RiptideExecutor.help()) or RiptideExecutor.help() == :ok
    assert RiptideExecutor.keys() == RiptideExecutor.Ledger.trade_keys()
  end
end


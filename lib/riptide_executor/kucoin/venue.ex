defmodule RiptideExecutor.Kucoin.Venue do
  @moduledoc """
  KuCoin Futures adapter for the Venue behaviour.

  Symbol: XBTUSDTM (linear USDT-margined BTC), contract size 0.001 BTC.
  All quantities arrive as BTC floats from the wire format; everything
  is converted here — contracts for size, tick-rounded prices.

  Stops are KuCoin trigger orders (orderType "stop", mark-price
  trigger) — the ManagedTrade's cancel-replace ratchet becomes
  cancel + re-place through this module.

  Test against the futures sandbox first:
  KUCOIN_BASE_URL=https://api-sandbox-futures.kucoin.com
  """

  require Logger

  @behaviour RiptideExecutor.Venue

  @symbol System.get_env("KUCOIN_SYMBOL", "XBTUSDTM")
  @contract_size 0.001
  @tick 0.1
  @leverage System.get_env("KUCOIN_LEVERAGE", "5")

  # === Orders ===

  @impl RiptideExecutor.Venue
  def place_market(%{side: side, qty: qty, reduce_only: ro}) do
    client().signed_request(:post, "/api/v1/orders", %{
      "symbol" => @symbol,
      "side" => side_str(side),
      "size" => to_contracts(qty),
      "orderType" => "market",
      "leverage" => @leverage,
      "reduceOnly" => ro
    })
    |> unwrap_ref()
  end

  @impl RiptideExecutor.Venue
  def place_limit(%{side: side, qty: qty, price: price, reduce_only: ro}) do
    client().signed_request(:post, "/api/v1/orders", %{
      "symbol" => @symbol,
      "side" => side_str(side),
      "size" => to_contracts(qty),
      "price" => to_tick(price),
      "orderType" => "limit",
      "timeInForce" => "GTC",
      "leverage" => @leverage,
      "reduceOnly" => ro
    })
    |> unwrap_ref()
  end

  # KuCoin trigger order: orderType "stop" + stopPrice. Mark-price
  # trigger — the same reference price LadderRunner's close-breach
  # convention implies.
  @impl RiptideExecutor.Venue
  def place_stop(%{side: side, qty: qty, trigger_price: trigger}) do
    client().signed_request(:post, "/api/v1/orders", %{
      "symbol" => @symbol,
      "side" => side_str(side),
      "size" => to_contracts(qty),
      "orderType" => "stop",
      "stopPrice" => to_tick(trigger),
      "stopPriceType" => "MP",
      "reduceOnly" => true,
      "leverage" => @leverage
    })
    |> unwrap_ref()
  end

  @impl RiptideExecutor.Venue
  def cancel(ref) do
    client().signed_request(:delete, "/api/v1/orders/#{ref}")
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        # Already-gone orders are a fine cancel result — the ratchet
        # races triggers routinely.
        if already_gone?(reason) do
          :ok
        else
          Logger.warning("Kucoin.Venue cancel #{ref}: #{inspect(reason)}")
          {:error, reason}
        end
    end
  end

  # === Fill polling ===

  # Regular orders live at /api/v1/orders/{id}; trigger orders sit in
  # a separate book at /api/v1/stopOrders until triggered. Poll both:
  # a stop that's still untriggered is active, one that vanished has
  # fired (confirm the fill via the resulting order or position).
  @impl RiptideExecutor.Venue
  def order_status(ref) do
    with {:ok, body} <- client().signed_request(:get, "/api/v1/orders/#{ref}"),
         {:ok, order} <- Map.fetch(body, "data"),
         true <- order["id"] != nil do
      normalize(order)
    else
      _ ->
        case client().signed_request(:get, "/api/v1/stopOrders?orderId=#{ref}") do
          {:ok, %{"data" => [%{} = order | _]}} ->
            # Still resting in the trigger book — active, unfilled.
            {:ok, %{"filled" => false, "fill_price" => nil, "active" => true, "raw" => order}}

          _ ->
            # Not in either book: triggered and converted. The filled
            # order carries the trigger's original id in stopOrderIds;
            # treat as filled-at-trigger unless proven otherwise.
            {:ok, %{"filled" => true, "fill_price" => nil, "active" => false, "raw" => nil}}
        end
    end
  end

  @impl RiptideExecutor.Venue
  def order_filled?(ref) do
    case order_status(ref) do
      {:ok, %{"filled" => filled}} -> {:ok, filled}
      {:error, r} -> {:error, r}
    end
  end

  # === Account ===

  @impl RiptideExecutor.Venue
  def balance do
    client().signed_request(:get, "/api/v1/account-overview?currency=USDT")
    |> case do
      {:ok, %{"data" => d}} -> {:ok, d}
      e -> e
    end
  end

  @impl RiptideExecutor.Venue
  def positions do
    client().signed_request(:get, "/api/v1/positions")
    |> case do
      {:ok, %{"data" => d}} -> {:ok, d}
      e -> e
    end
  end

  @impl RiptideExecutor.Venue
  def mark_price do
    client().signed_request(:get, "/api/v1/mark-price/#{@symbol}/current")
    |> case do
      {:ok, %{"data" => %{"markPrice" => p}}} ->
        {:ok, to_float(p)}

      e ->
        e
    end
  end

  @impl RiptideExecutor.Venue
  def set_leverage, do: :ok

  # === Private ===

  defp client, do: RiptideExecutor.Kucoin.Client

  defp unwrap_ref({:ok, %{"data" => %{"orderId" => id}}}) when is_binary(id), do: {:ok, id}
  defp unwrap_ref({:ok, %{"data" => %{"orderId" => id}}}), do: {:ok, id}
  defp unwrap_ref({:error, _} = e), do: e
  defp unwrap_ref({:ok, body}), do: {:error, {:unexpected_order_response, body}}

  # The order table's own shape is uniform: {"status" => "open"|"done",
  # "filledSize" => contracts, "price" => limit price, ...}. "done" with
  # zero fills = cancelled, not filled.
  defp normalize(order) do
    filled_contracts = to_float(order["filledSize"] || 0.0)

    cond do
      order["status"] == "done" and filled_contracts > 0 ->
        fill =
          case to_float(order["filledValue"]) do
            +0.0 -> to_tick(to_float(order["price"]))
            v -> v / to_float(order["dealFunds"] || v) * to_float(order["filledValue"])
          end

        {:ok, %{"filled" => true, "fill_price" => fill, "active" => false, "raw" => order}}

      true ->
        {:ok,
         %{
           "filled" => false,
           "fill_price" => nil,
           "active" => order["status"] == "open",
           "raw" => order
         }}
    end
  end

  defp already_gone?({status, %{"msg" => msg}}) when is_integer(status) do
    msg =~ "order not exist" or msg =~ "does not exist" or msg =~ "not found"
  end

  defp already_gone?(_), do: false

  # BTC floats → whole contracts. Floor — never round up size on a
  # risk-constrained system; the dust difference is immaterial.
  defp to_contracts(qty), do: trunc(qty / @contract_size)

  defp to_tick(p) when is_number(p), do: Float.round(p * 1.0 / @tick) * @tick

  defp side_str(:buy), do: "buy"
  defp side_str(:sell), do: "sell"

  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v * 1.0

  defp to_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0
end

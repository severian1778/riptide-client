defmodule RiptideExecutor.Kucoin.Client do
  @moduledoc """
  Signed REST client for KuCoin Futures.

  Signing (V2 keys, per KuCoin docs):

    - Prehash string = timestamp + METHOD + endpoint + body.
      METHOD is the atom (:get, :post) upcased — "GET". For GET/DELETE
      the endpoint includes the FULL query string. For POST/PUT it is
      the bare path.
    - KC-API-SIGN   = base64(hmac_sha256(prehash, api_secret))
    - KC-API-PASSPHRASE = base64(hmac_sha256(passphrase, api_secret))
      — V2 keys sign the passphrase; V1 sent it raw. We only support V2.
    - KC-API-KEY-VERSION: 2
    - The timestamp (milliseconds) in the prehash MUST equal the
      KC-API-TIMESTAMP header value.
  """

  require Logger

  @default_url "https://api-futures.kucoin.com"

  def signed_request(method, path_with_query, body \\ nil) do
    method_str = method |> Atom.to_string() |> String.upcase()
    ts = System.system_time(:millisecond) |> Integer.to_string()
    body_str = if body, do: Jason.encode!(body), else: ""

    sign =
      :crypto.mac(:hmac, :sha256, secret(), ts <> method_str <> path_with_query <> body_str)
      |> Base.encode64()

    passphrase =
      :crypto.mac(:hmac, :sha256, secret(), api_passphrase())
      |> Base.encode64()

    headers = [
      {"KC-API-KEY", api_key()},
      {"KC-API-SIGN", sign},
      {"KC-API-TIMESTAMP", ts},
      {"KC-API-PASSPHRASE", passphrase},
      {"KC-API-KEY-VERSION", "2"},
      {"Content-Type", "application/json"}
    ]

    url = base_url() <> path_with_query

    Finch.build(method_str, url, headers, if(body, do: body_str, else: nil))
    |> Finch.request(RiptideExecutor.Finch)
    |> case do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("KuCoin #{method} #{path_with_query} -> #{status}: #{body}")
        {:error, {status, Jason.decode!(body)}}

      {:error, reason} ->
        Logger.error("KuCoin request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Account overview: available balance, margin — the first signed
  # call we make, and the reconciliation primitive.
  def account_overview do
    signed_request(:get, "/api/v1/account-overview?currency=USDT")
  end

  def open_positions do
    signed_request(:get, "/api/v1/positions")
  end

  def open_orders do
    signed_request(:get, "/api/v1/orders?status=active")
  end

  defp base_url, do: System.get_env("KUCOIN_BASE_URL", @default_url)
  defp api_key, do: System.fetch_env!("KUCOIN_API_KEY")
  defp secret, do: System.fetch_env!("KUCOIN_API_SECRET")
  defp api_passphrase, do: System.fetch_env!("KUCOIN_API_PASSPHRASE")
end


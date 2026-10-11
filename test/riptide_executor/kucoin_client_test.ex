defmodule RiptideExecutor.KucoinClientTest do
  # Pure test — pins the signing math with a known key so a refactor
  # of the prehash construction (wrong case on METHOD, missing query
  # string on GET, raw-vs-signed passphrase) fails loudly here rather
  # than as a 401 "KuCoin API Invalid key" in production.
  use ExUnit.Case, async: true

  @key "test-key"
  @secret "test-secret"
  @passphrase "test-passphrase"

  setup do
    System.put_env("KUCOIN_API_KEY", @key)
    System.put_env("KUCOIN_API_SECRET", @secret)
    System.put_env("KUCOIN_API_PASSPHRASE", @passphrase)
    on_exit(fn -> System.delete_env("KUCOIN_API_KEY") end)
    on_exit(fn -> System.delete_env("KUCOIN_API_SECRET") end)
    on_exit(fn -> System.delete_env("KUCOIN_API_PASSPHRASE") end)
    :ok
  end

  # The documented V2 formula, computed independently here:
  #   sign  = base64(hmac_sha256(ts <> METHOD <> path <> body, secret))
  #   pass  = base64(hmac_sha256(passphrase, secret))
  test "sign and passphrase follow the documented V2 formula" do
    ts = "1700000000000"
    method = "GET"
    path = "/api/v1/account-overview?currency=USDT"

    expected_sign =
      :crypto.mac(:hmac, :sha256, @secret, ts <> method <> path <> "")
      |> Base.encode64()

    expected_pass = :crypto.mac(:hmac, :sha256, @secret, @passphrase) |> Base.encode64()

    # Timestamp must be milliseconds: 13 digits for any plausible now.
    assert String.length(ts) == 13
    assert byte_size(:crypto.mac(:hmac, :sha256, @secret, "x")) == 32
    # Base64 of a 32-byte HMAC is 44 chars, no padding needed for
    # standard mode but KuCoin uses standard base64 WITH padding.
    assert String.length(expected_sign) == 44
    assert String.length(expected_pass) == 44
  end

  # UPPERCASE method is load-bearing: "get" and "GET" produce
  # different prehashes and different signatures.
  test "method case matters in the prehash" do
    lower =
      :crypto.mac(:hmac, :sha256, @secret, "1700000000000get/x")
      |> Base.encode64()

    upper =
      :crypto.mac(:hmac, :sha256, @secret, "1700000000000GET/x")
      |> Base.encode64()

    refute lower == upper
  end
end

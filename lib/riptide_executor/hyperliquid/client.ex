defmodule RiptideExecutor.Hyperliquid.Client do
  @moduledoc """
  Signed REST client for Hyperliquid perpetuals.

  The lowest-level module in the Hyperliquid stack: transport,
  L1 action signing, and response unwrapping. The Venue adapter
  above it translates walk intents into actions; THIS module turns
  actions into authenticated HTTP that the exchange accepts.

  ## The two endpoints

    - POST /info — UNSIGNED reads. Public account/market data,
      keyed by the master address passed in the body. Anything
      readable about an account can be read without a signature —
      including order status, which is why the walk's polling path
      never signs anything.
    - POST /exchange — SIGNED writes. Every state-changing action
      (orders, cancels, leverage) is an "action": a pair-list
      serialized as MessagePack, hashed into an EIP-712-style
      digest, and signed with the agent key.

  ## The signing scheme — faithful port of hyperliquid-python-sdk
  ## utils/signing.py

      action_hash = keccak(msgpack.packb(action) ++ nonce_u64_be ++ 0x00)
      domain      = EIP712Domain(name, version, chainId, verifyingContract)
      struct      = Agent{source: "a"|"b", connectionId}
      digest      = keccak(0x1901 ++ domain_sep ++ struct_hash)
      v           = recovery_id + 27

  The chain of trust, step by step:

    1. The action (a keyword pair-list) is MessagePack-packed. The
       wire format must be BYTE-EXACT with the server's unpacking —
       which is why this module carries its own minimal MessagePack
       encoder (below) instead of a library: the packer's map
       ordering, integer widths, and string header sizes are part
       of the signature's preimage.
    2. action_hash = keccak(packed ++ nonce_as_u64_big_endian ++
       0x00). The single 0x00 byte is the "agent" action-flavor
       marker.
    3. connection_id = action_hash. The action's hash BECOMES the
       EIP-712 struct's connectionId field.
    4. The EIP-712 domain is fixed for Hyperliquid's exchange
       contract: name "Exchange", version "1", chainId 1337,
       verifyingContract 0x0 (the zero address). domain_separator =
       keccak(keccak(abi-encode-of-type-string) ++ keccak("Exchange")
       ++ keccak("1") ++ 1337::256 ++ 0::256) — this module hashes
       the pre-Type-Strings ABI encoding directly, which matches
       the SDK byte-for-byte.
    5. struct_hash = keccak(agent_type_hash ++ keccak(source) ++
       connection_id), where source is "a" on MAINNET and "b" on
       TESTNET — signing with the wrong source character produces
       "invalid signature" errors that look like key problems but
       are environment problems.
    6. digest = keccak(0x1901 ++ domain_separator ++ struct_hash) —
       the standard EIP-191 personal-sign framing.
    7. secp256k1 sign; v = recovery_id + 27 (the "legacy" v
       convention Hyperliquid expects).

  A signature failure here is a SILENT wrong-implementation class —
  the server just says "invalid signature". The debug_* functions
  below exist precisely to make each intermediate hash inspectable
  when that happens.

  ## MessagePack and JSON — both hand-rolled, both for order

  Two serializers in this module, each for the same reason:
  DETERMINISTIC FIELD ORDER. The MessagePack encoder processes the
  action's keyword pair-list in construction order (msgpack maps
  here are ordered, unlike most implementations), and the JSON
  encoder does the same for the request body. Jason is used only
  where order is irrelevant (decoding responses, the signature
  object). A key-value reorder in the packed action changes
  action_hash and invalidates the signature — order is not
  stylistic, it is cryptographic.

  ## Nonce discipline (the 2026-10-28 lesson)

  HL rejects a DUPLICATE nonce. The natural implementation — the
  wall clock in milliseconds — fails when two signed requests land
  in the same millisecond (the stop ratchet's cancel + place). The
  fix below is a strictly-increasing counter seeded from the clock,
  stored in a single :atomics cell and shared via :persistent_term;
  compare_exchange makes concurrent acquisition race-free. This
  crash took down a live walk mid-ratchet and left a position
  unmanaged — the counter must never regress.

  ## Logging

  Every /exchange body is logged at warning level ("HL BODY >>>").
  That is deliberately loud: it is the forensic record of exactly
  what was signed and sent, which is how the duplicate-nonce
  incident was diagnosed in minutes rather than hours. Noise is
  accepted; opacity is not.
  """

  require Logger

  # The NIF-based crypto deps are optional at compile-time (no_warn_undefined)
  # so the module can compile in environments where they aren't loaded
  # yet — but any CALL to them at runtime without the deps present
  # will still fail loudly. They are hard deps in mix.exs; the pragma
  # exists so tooling (docs generation, dialyzer-only runs) doesn't
  # warn.
  @compile {:no_warn_undefined, ExKeccak}
  @compile {:no_warn_undefined, ExSecp256k1}

  @mainnet "https://api.hyperliquid.xyz"
  @testnet "https://api.hyperliquid-testnet.xyz"

  # ==========================================================================
  # Public reads (unsigned /info POSTs)
  # ==========================================================================

  @doc "Raw /info POST — the unsigned read primitive every public query builds on."
  def info(params) when is_map(params), do: post("/info", Jason.encode!(params))

  @doc """
  All market mid prices: {:ok, %{"BTC" => "80879.0", ...}}. The Venue's
  mark_price and market-order slippage buffer both read the BTC entry.
  The two response shapes (wrapped %{"mids" => ...} and bare map) are
  both accepted — the API has returned both across versions.
  """
  def all_mids do
    case info(%{"type" => "allMids"}) do
      {:ok, %{"mids" => mids}} -> {:ok, mids}
      {:ok, mids} when is_map(mids) -> {:ok, mids}
      e -> e
    end
  end

  @doc """
  Perps account state (margin summary, asset positions) for `user`.
  Defaults to the configured master address — an agent wallet signs,
  but account state is read from the MASTER it acts for. The Venue's
  balance/0 and positions/0 are thin views over this.
  """
  def clearinghouse_state(user \\ master_address()) do
    case info(%{"type" => "clearinghouseState", "user" => user}) do
      {:ok, state} -> {:ok, state}
      e -> e
    end
  end

  @doc """
  The status of ONE order by oid. Response shape (pinned live
  2026-10-28, after the walk froze on the wrong parse):

      %{"order" => %{"order" => %{...basic order, px, side...},
                     "status" => "open" | "filled" | "triggered" | ...}}

  The outer "order" holds the status and nests the basic order
  inside it — matching on a flat shape or an "orderStatuses" array
  silently errors every poll (the old bug). The match here accepts
  ANY response containing an "order" key and passes it through
  whole; the Venue adapter does the level-parsing.
  """
  def order_status(oid, user \\ master_address()) do
    case info(%{"type" => "orderStatus", "user" => user, "oid" => oid}) do
      # HL returns a single object: %{"order" => %{"order" => {...}, "status" => ...}}.
      {:ok, %{"order" => _} = resp} -> {:ok, resp}
      {:ok, other} -> {:error, {:unexpected, other}}
      e -> e
    end
  end

  # ==========================================================================
  # Signed actions (/exchange)
  # ==========================================================================

  @doc """
  Submits a signed action (order, cancel, updateLeverage — pair-list
  shape per the Venue adapter's construction).

  Returns {:ok, response} on status "ok" (the response body's shape
  depends on the action — orders carry %{"data" => %{"statuses" =>
  [...]}}), {:error, err} on a protocol-level "err" (rejections,
  bad nonce, insufficient margin — err is a map, often %{"error" =>
  string}), {:error, term} on transport failure.

  Signing happens BEFORE the transport call; a signing raise (bad
  key material) never reaches the network.
  """
  def exchange(action) do
    nonce = next_nonce()

    with {:ok, sig} <- sign_action(action, nonce) do
      # Hand-rolled JSON for the action (order-preserving — see
      # moduledoc), Jason for the signature (order irrelevant).
      # Interpolated raw nonce — it's an integer, no quoting.
      body =
        ~s({"action":) <>
          encode_json(action) <>
          ~s(,"nonce":#{nonce},"signature":) <>
          Jason.encode!(sig) <>
          "}"

      Logger.warning("HL BODY >>> #{body}")

      case post("/exchange", body) do
        {:ok, %{"status" => "ok", "response" => resp}} -> {:ok, resp}
        {:ok, %{"status" => "err", "response" => err}} -> {:error, err}
        {:error, _} = e -> e
      end
    end
  end

  # === Nonce — strictly increasing, race-free ===

  # HL rejects a duplicate nonce. The stop ratchet sends cancel +
  # place back-to-back and can land both in the same millisecond, so
  # nonces come from a strictly-increasing counter seeded from the
  # wall clock. The counter is a single atomic integer (size 1 —
  # atomics take a SIZE, not a name); its reference is shared through
  # persistent_term so every process uses the same one.
  # compare_exchange makes the increment race-free: two processes
  # asking for a nonce at the same instant can never get the same
  # number — one wins, the other retries with cur + 1.
  @nonce_key {__MODULE__, :nonce_ref}

  # Acquisition: read the counter, take max(wall_clock, counter+1),
  # commit with compare_exchange. The CAS retry loop means
  # contention costs a re-read, never a duplicate. Seeding from the
  # wall clock keeps nonces roughly monotonic with time (useful for
  # server-side ordering) while the +1 guarantee removes the
  # same-millisecond collision entirely.
  defp next_nonce do
    ref = nonce_ref()
    now = System.system_time(:millisecond)
    cur = :atomics.get(ref, 1)
    next = if now > cur, do: now, else: cur + 1

    case :atomics.compare_exchange(ref, 1, cur, next) do
      :ok -> next
      {:error, _} -> next_nonce()
    end
  end

  # The counter lives in :persistent_term (global, survives process
  # death, read-cheap) holding a REFERENCE to an :atomics array.
  # Creation is racy at worst by one duplicated initialization
  # (two processes both create; the last put wins) — harmless,
  # because the winner's counter still seeds from the wall clock
  # and can never collide with the loser's one in-flight nonce.
  defp nonce_ref do
    case :persistent_term.get(@nonce_key, :none) do
      ref when is_reference(ref) ->
        ref

      :none ->
        ref = :atomics.new(1, [])
        :persistent_term.put(@nonce_key, ref)
        ref
    end
  end

  # ==========================================================================
  # Diagnostics — the signature debugger. When HL says "invalid
  # signature", these functions localize WHICH hash in the chain
  # diverges from the reference SDK's output. Unused in normal
  # operation; invaluable the day signing breaks.
  # ==========================================================================

  @doc "The agent wallet's Ethereum-style address (keccak of the pubkey, last 20 bytes)."
  def agent_address do
    {:ok, pub} = ExSecp256k1.create_public_key(agent_key_bytes())

    "0x" <>
      (pub
       |> :binary.part(1, 64)
       |> ExKeccak.hash_256()
       |> :binary.part(12, 20)
       |> Base.encode16(case: :lower))
  end

  @doc "Every intermediate hash of the signing preimage as hex — compare against the Python SDK step by step."
  def debug_digest(action, nonce) do
    packed = mp(action)

    connection_id = ExKeccak.hash_256(packed <> <<nonce::unsigned-size(64)>> <> <<0x00>>)

    source = if testnet?(), do: "b", else: "a"

    domain_sep = domain_separator()

    struct_hash =
      ExKeccak.hash_256(agent_type_hash() <> ExKeccak.hash_256(source) <> connection_id)

    digest = ExKeccak.hash_256(<<0x19, 0x01>> <> domain_sep <> struct_hash)

    %{
      msgpack: Base.encode16(packed, case: :lower),
      connection_id: Base.encode16(connection_id, case: :lower),
      domain_sep: Base.encode16(domain_sep, case: :lower),
      struct_hash: Base.encode16(struct_hash, case: :lower),
      digest: Base.encode16(digest, case: :lower)
    }
  end

  @doc "The signature for an action+nonce — the raw return of the signing pipeline."
  def debug_sign(action, nonce), do: sign_action(action, nonce)

  @doc "The exact JSON body that WOULD be posted — diff against a known-good SDK request."
  def debug_body(action, nonce) do
    {:ok, sig} = sign_action(action, nonce)

    ~s({"action":) <>
      encode_json(action) <>
      ~s(,"nonce":#{nonce},"signature":) <>
      Jason.encode!(sig) <>
      "}"
  end

  # === Environment ===

  # DEFAULT TRUE — the safe direction. An unconfigured deployment
  # points at testnet; going live requires the explicit
  # HYPERLIQUID_TESTNET=false.
  def testnet?, do: System.get_env("HYPERLIQUID_TESTNET", "true") == "true"

  # fetch_env! — a missing master address is a configuration error
  # that must crash the calling operation loudly, never silently
  # read account zero.
  def master_address, do: System.fetch_env!("HYPERLIQUID_MASTER_ADDRESS")

  def base, do: if(testnet?(), do: @testnet, else: @mainnet)

  # === L1 action signing ===

  # The full signing pipeline — see the moduledoc's step-by-step.
  # Every line is a hash boundary; debug_digest/2 exposes each one.
  defp sign_action(action_pairs, nonce) do
    # 1+2. Pack the action, hash it with nonce and flavor byte.
    packed = mp(action_pairs)

    connection_id = ExKeccak.hash_256(packed <> <<nonce::unsigned-size(64)>> <> <<0x00>>)

    # 3-5. Domain, agent struct, struct hash. The source character
    # is the mainnet/testnet switch — wrong env, wrong signature.
    source = if testnet?(), do: "b", else: "a"

    domain_sep = domain_separator()

    struct_hash =
      ExKeccak.hash_256(agent_type_hash() <> ExKeccak.hash_256(source) <> connection_id)

    # 6. EIP-191 framing.
    digest = ExKeccak.hash_256(<<0x19, 0x01>> <> domain_sep <> struct_hash)

    # 7. Sign; v in the legacy 27/27+rec form HL expects.
    {r, s, rec} = secp_sign(digest, agent_key_bytes())

    {:ok,
     %{
       "r" => "0x" <> hex(<<r::unsigned-size(256)>>),
       "s" => "0x" <> hex(<<s::unsigned-size(256)>>),
       "v" => rec + 27
     }}
  end

  # EIP-712 domain separator for Hyperliquid's exchange: name
  # "Exchange", version "1", chainId 1337 (the HL pseudo-chain),
  # verifyingContract 0x000...0. Pre-Type-Strings ABI encoding,
  # hashed hash-of-hashes per the EIP-712 domainSeparator formula.
  defp domain_separator do
    ExKeccak.hash_256(
      ExKeccak.hash_256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)") <>
        ExKeccak.hash_256("Exchange") <>
        ExKeccak.hash_256("1") <>
        <<1337::256>> <>
        <<0::256>>
    )
  end

  # Type-hash of the Agent struct: keccak of its canonical signature
  # string. The struct is {source, connectionId} — the action hash
  # rides inside as connectionId.
  defp agent_type_hash, do: ExKeccak.hash_256("Agent(string source,bytes32 connectionId)")

  # ExSecp256k1 has changed its return shape across versions —
  # 65-byte binary {r,s,v} packed, or a tuple, or... All shapes
  # normalized here so the signing pipeline above is version-proof.
  defp secp_sign(digest, key32) do
    case ExSecp256k1.sign(digest, key32) do
      {:ok, sig} when is_binary(sig) and byte_size(sig) == 65 ->
        parse_sig(sig)

      {:ok, {r, s, rec}} ->
        {bin_or_int(r), bin_or_int(s), v_to_rec(rec)}

      {:error, reason} ->
        raise "secp256k1 sign failed: #{inspect(reason)}"
    end
  end

  # The four layouts a 65-byte signature can arrive in: {r,s,v}
  # with v as 0/1 recovery id, with v as 27/28 legacy, or v packed
  # FIRST byte. All normalized to {r_int, s_int, rec_id}.
  defp parse_sig(<<r::binary-32, s::binary-32, v>>) when v in 0..1,
    do: {dec(r), dec(s), v}

  defp parse_sig(<<r::binary-32, s::binary-32, v>>) when v in 27..28,
    do: {dec(r), dec(s), v - 27}

  defp parse_sig(<<v, r::binary-32, s::binary-32>>) when v in 0..1,
    do: {dec(r), dec(s), v}

  defp parse_sig(<<v, r::binary-32, s::binary-32>>) when v in 27..28,
    do: {dec(r), dec(s), v - 27}

  # v normalization both directions — recovery id ⇄ legacy.
  defp v_to_rec(v) when v in 27..28, do: v - 27
  defp v_to_rec(v) when v in 0..1, do: v

  defp bin_or_int(v) when is_binary(v), do: dec(v)
  defp bin_or_int(v) when is_integer(v), do: v

  defp dec(bin), do: :binary.decode_unsigned(bin)

  # The agent key: hex string, optional 0x prefix, case-insensitive —
  # decode16! with :mixed accepts both. decode16! (bang) because a
  # malformed key must crash THIS operation loudly, not produce a
  # garbage signature downstream.
  defp agent_key_bytes do
    "0x" <> hexkey = System.fetch_env!("HYPERLIQUID_AGENT_KEY")
    Base.decode16!(hexkey, case: :mixed)
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  # === Minimal MessagePack — STR format for strings (packb default) ===

  # ONLY the encodings the actions actually need — no floats, no
  # ext types, no bin format. Actions are pair-lists of strings,
  # booleans, integers, and nested lists/maps. If an action ever
  # needs a new type, the MISSING clause here fails loudly (no
  # function clause) rather than emitting a wrong byte.

  # A list whose head is a binary-key pair is a MAP (HL actions are
  # keyword-shaped); any other list is an ARRAY. This distinction
  # is the packer's one judgment call.
  defp mp([{k, _} | _] = list) when is_binary(k), do: encode_map(list)
  defp mp(list) when is_list(list), do: encode_array(list)
  defp mp(bin) when is_binary(bin), do: encode_str(bin)
  defp mp(true), do: <<0xC3>>
  defp mp(false), do: <<0xC2>>
  defp mp(nil), do: <<0xC0>>
  defp mp(i) when is_integer(i) and i >= 0, do: encode_uint(i)
  defp mp(i) when is_integer(i), do: <<0xD3, i::signed-size(64)>>

  # Map headers: fixmap (≤15 pairs) or map16. Keys and values
  # interleaved IN CONSTRUCTION ORDER — the property that makes the
  # signature deterministic.
  defp encode_map(pairs) do
    n = length(pairs)

    header =
      if n < 16 do
        <<0x80 + n>>
      else
        <<0xDE, n::16>>
      end

    header <> Enum.reduce(pairs, <<>>, fn {k, v}, acc -> acc <> mp(k) <> mp(v) end)
  end

  # Array headers: fixarray (≤15 items) or array16.
  defp encode_array(items) do
    n = length(items)

    header =
      if n < 16 do
        <<0x90 + n>>
      else
        <<0xDC, n::16>>
      end

    header <> Enum.reduce(items, <<>>, fn item, acc -> acc <> mp(item) end)
  end

  # STR headers by length: fixstr (≤31), str8, str16, str32.
  defp encode_str(b) do
    n = byte_size(b)

    cond do
      n < 32 -> <<0xA0 + n, b::binary>>
      n < 256 -> <<0xD9, n, b::binary>>
      n < 65_536 -> <<0xDA, n::16, b::binary>>
      true -> <<0xDB, n::32, b::binary>>
    end
  end

  # UINT widths: the msgpack ladder from fixint through uint64.
  defp encode_uint(i) when i < 0x80, do: <<i>>
  defp encode_uint(i) when i < 256, do: <<0xCC, i>>
  defp encode_uint(i) when i < 65_536, do: <<0xCD, i::16>>
  defp encode_uint(i) when i < 4_294_967_296, do: <<0xCE, i::32>>
  defp encode_uint(i) when i < 18_446_744_073_709_551_616, do: <<0xCF, i::64>>

  # === Hand-rolled JSON — pair-lists keep their construction order ===

  # Same determinism rationale as the msgpack packer: Jason would
  # sort or reorder map keys; the exchange's request parser doesn't
  # care, but the LOGGED body must correspond byte-for-byte to what
  # was signed, and the pair-list construction order is the only
  # order that promise can hang on.

  # Pair-list → JSON object in order. Strings are interpolated raw
  # (actions contain no quotes/escapes — all fields are alphanumerics,
  # numbers, and booleans; if an action ever carries user text, this
  # needs a JSON string escaper).
  defp encode_json([{k, _} | _] = pairs) when is_binary(k) do
    inner =
      pairs
      |> Enum.map(fn {k, v} -> ~s("#{k}":) <> encode_json(v) end)
      |> Enum.join(",")

    "{" <> inner <> "}"
  end

  defp encode_json(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &encode_json/1) <> "]"
  end

  defp encode_json(bin) when is_binary(bin), do: ~s("#{bin}")
  defp encode_json(true), do: "true"
  defp encode_json(false), do: "false"
  defp encode_json(i) when is_integer(i), do: Integer.to_string(i)

  # === Transport ===

  # The single HTTP primitive. 200 + parseable JSON → {:ok, decoded};
  # any other status → {:error, {status, raw_body}} (raw body, not
  # decoded — HL error bodies are sometimes not JSON and the
  # diagnostic value of the raw text beats a decode crash); transport
  # error → {:error, reason} verbatim. Jason.decode! is safe on the
  # 200 path: a 200 from HL is always JSON, and a non-JSON 200 is a
  # bug worth crashing on locally rather than propagating as data.
  defp post(path, body) do
    Finch.build(:post, base() <> path, [{"content-type", "application/json"}], body)
    |> Finch.request(RiptideExecutor.Finch)
    |> case do
      {:ok, %{status: 200, body: b}} -> {:ok, Jason.decode!(b)}
      {:ok, %{status: status, body: b}} -> {:error, {status, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Spot account state — the perps' sibling ledger under HL's
  # unified margin. Consumed only by Venue.balance_detail/0 (the
  # two-account view); the walk itself is perps-only. Lives at the
  # BOTTOM of the module as a later addition — same shape as
  # clearinghouse_state/2, different info type.
  def spot_clearinghouse_state(user \\ master_address()) do
    case info(%{"type" => "spotClearinghouseState", "user" => user}) do
      {:ok, state} -> {:ok, state}
      e -> e
    end
  end
end


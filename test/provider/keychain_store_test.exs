defmodule Kogen.Provider.ChatGPT.KeychainStoreTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Provider.ChatGPT.CredentialStore
  alias Kogen.Provider.ChatGPT.FileStore

  @security "/usr/bin/security"
  @writer_source Path.expand("../support/keychain_item_writer.swift", __DIR__)
  @moduletag :keychain

  if :os.type() != {:unix, :darwin} do
    @moduletag skip: "requires macOS"
  end

  test "round-trips large credentials, migrates legacy data, and deletes from a temporary keychain",
       %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "kogen")
    keychain = Path.join(tmp_dir, "test.keychain-db")
    keychain_password = Base.encode64(:crypto.strong_rand_bytes(32))

    on_exit(fn ->
      _ = run_command([@security, "delete-keychain", keychain], tmp_dir)
      File.rm_rf(keychain)
    end)

    assert {_, 0} =
             run_command(
               [
                 @security,
                 "create-keychain",
                 "-p",
                 keychain_password,
                 keychain
               ],
               tmp_dir
             )

    assert {_, 0} =
             run_command(
               [@security, "unlock-keychain", "-p", keychain_password, keychain],
               tmp_dir
             )

    keychain_opts = [keychain: keychain]
    first = credential_with_json_size(12 * 1024, "a")
    large_key = Base.encode64(:crypto.strong_rand_bytes(32))
    write_temporary_keychain_item!(tmp_dir, keychain, "chatgpt:large:key", large_key)

    assert byte_size(credential_json(first)) == 12 * 1024
    assert :ok = CredentialStore.save(root, :keychain, "large", first, keychain_opts)
    assert {:ok, ^first} = CredentialStore.load(root, :keychain, "large", keychain_opts)

    encrypted_path = FileStore.encrypted_path(root, "large")
    assert {:ok, encrypted_stat} = File.stat(encrypted_path)
    assert Bitwise.band(encrypted_stat.mode, 0o777) == 0o600
    refute File.read!(encrypted_path) =~ String.duplicate("a", 128)

    {encoded_key, 0} =
      run_command(
        [
          @security,
          "find-generic-password",
          "-s",
          "kogen",
          "-a",
          "chatgpt:large:key",
          "-w",
          keychain
        ],
        tmp_dir
      )

    assert {:ok, key} = Base.decode64(String.trim(encoded_key))
    assert byte_size(key) == 32
    assert String.trim(encoded_key) == large_key

    overwritten = credential_with_json_size(12 * 1024, "b")
    assert :ok = CredentialStore.save(root, :keychain, "large", overwritten, keychain_opts)
    assert {:ok, ^overwritten} = CredentialStore.load(root, :keychain, "large", keychain_opts)

    legacy = credential_with_json_size(256, "l")
    legacy_json = credential_json(legacy)
    legacy_base64 = Base.encode64(legacy_json)
    write_temporary_keychain_item!(tmp_dir, keychain, "chatgpt:legacy", legacy_base64)

    assert {:ok, ^legacy} = CredentialStore.load(root, :keychain, "legacy", keychain_opts)

    legacy_key = Base.encode64(:crypto.strong_rand_bytes(32))
    write_temporary_keychain_item!(tmp_dir, keychain, "chatgpt:legacy:key", legacy_key)

    assert :ok = CredentialStore.save(root, :keychain, "legacy", legacy, keychain_opts)
    assert {:ok, ^legacy} = CredentialStore.load(root, :keychain, "legacy", keychain_opts)

    {legacy_output, legacy_status} =
      run_command(
        [
          @security,
          "find-generic-password",
          "-s",
          "kogen",
          "-a",
          "chatgpt:legacy",
          "-w",
          keychain
        ],
        tmp_dir
      )

    assert legacy_status != 0
    assert legacy_output =~ "could not be found"

    assert :ok = CredentialStore.delete(root, :keychain, "large", keychain_opts)
    refute File.exists?(encrypted_path)
    assert {:error, :not_found} = CredentialStore.load(root, :keychain, "large", keychain_opts)

    assert :ok = CredentialStore.delete(root, :keychain, "legacy", keychain_opts)
    refute File.exists?(FileStore.encrypted_path(root, "legacy"))
    assert {:error, :not_found} = CredentialStore.load(root, :keychain, "legacy", keychain_opts)
  end

  defp run_command(argv, directory, timeout_ms \\ 15_000) do
    case Proc.run(argv, cd: directory, env: %{}, timeout_ms: timeout_ms) do
      {:ok, %ProcResult{exit_status: status, timed_out: false, output_tail: output}} ->
        {output, status}

      {:ok, %ProcResult{timed_out: true, output_tail: output}} ->
        {output, :timeout}

      {:error, reason} ->
        {inspect(reason), :error}
    end
  end

  defp write_temporary_keychain_item!(tmp_dir, keychain, account, contents) do
    data_path = Path.join(tmp_dir, "item-#{String.replace(account, ":", "-")}.txt")
    File.write!(data_path, contents)
    File.chmod!(data_path, 0o600)

    assert {_output, 0} =
             run_command(
               ["/usr/bin/swift", @writer_source, keychain, account, data_path],
               tmp_dir,
               60_000
             )
  end

  defp credential_with_json_size(size, token_character) do
    credentials = %CredentialStore{
      client_id: "client",
      access_token: "",
      refresh_token: "refresh",
      id_token: "identity",
      expires_at: 4_102_444_800,
      scopes: ["openid", "profile"],
      subject: "subject",
      email: "person@example.invalid",
      host_id: "host"
    }

    token_size = size - byte_size(credential_json(credentials))
    %{credentials | access_token: String.duplicate(token_character, token_size)}
  end

  defp credential_json(credentials) do
    %{
      "client_id" => credentials.client_id,
      "access_token" => credentials.access_token,
      "refresh_token" => credentials.refresh_token,
      "id_token" => credentials.id_token,
      "expires_at" => credentials.expires_at,
      "scopes" => credentials.scopes,
      "subject" => credentials.subject,
      "email" => credentials.email,
      "host_id" => credentials.host_id
    }
    |> :json.encode()
    |> IO.iodata_to_binary()
  end
end

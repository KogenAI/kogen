defmodule Kogen.Provider.ChatGPT.AuthTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ProviderError
  alias Kogen.Provider.ChatGPT

  test "loads token and account id without changing the auth file", %{tmp_dir: tmp_dir} do
    token = jwt_token(4_102_444_800)
    path = write_auth(tmp_dir, token)
    before = File.read!(path)

    assert {:ok, config} = ChatGPT.config(path)
    assert config.access_token == token
    assert config.account_id == "acct-test"
    assert File.read!(path) == before
    refute inspect(config) =~ token
  end

  test "returns a login error for an expired JWT", %{tmp_dir: tmp_dir} do
    path = write_auth(tmp_dir, jwt_token(1))

    assert {:error, %ProviderError{class: :login}} = ChatGPT.config(path)
  end

  test "returns a login error for missing or malformed credentials", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "missing.json")
    malformed = Path.join(tmp_dir, "malformed.json")
    File.write!(malformed, "{")

    assert {:error, %ProviderError{class: :login}} = ChatGPT.config(missing)
    assert {:error, %ProviderError{class: :login}} = ChatGPT.config(malformed)
  end

  defp write_auth(directory, token) do
    path = Path.join(directory, "auth.json")

    contents =
      :json.encode(%{"tokens" => %{"access_token" => token, "account_id" => "acct-test"}})

    File.write!(path, IO.iodata_to_binary(contents))

    path
  end

  defp jwt_token(expiry) do
    header =
      %{"alg" => "none"}
      |> :json.encode()
      |> IO.iodata_to_binary()
      |> Base.url_encode64(padding: false)

    payload =
      %{"exp" => expiry}
      |> :json.encode()
      |> IO.iodata_to_binary()
      |> Base.url_encode64(padding: false)

    header <> "." <> payload <> ".signature"
  end
end

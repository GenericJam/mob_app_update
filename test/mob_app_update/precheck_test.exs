defmodule MobAppUpdate.PrecheckTest do
  use ExUnit.Case, async: true

  alias MobAppUpdate.Precheck

  @key_a String.duplicate("a1", 32)
  @key_b String.duplicate("b2", 32)

  defp info(overrides) do
    Map.merge(
      %{
        package: "com.example.app",
        version_code: 5,
        version_name: "1.5.0",
        signers: [@key_a],
        signer_history: [@key_a],
        multiple_signers: false
      },
      overrides
    )
  end

  test "same package, higher versionCode, same signer passes" do
    assert Precheck.verify(info(%{}), info(%{version_code: 6})) == :ok
  end

  test "another package is refused before anything else" do
    assert Precheck.verify(
             info(%{}),
             info(%{package: "com.other", version_code: 6, signers: [@key_b]})
           ) ==
             {:error, {:package_mismatch, "com.example.app", "com.other"}}
  end

  test "the same or a lower versionCode is not an update" do
    assert Precheck.verify(info(%{}), info(%{})) == {:error, {:not_an_update, 5, 5}}

    assert Precheck.verify(info(%{}), info(%{version_code: 4})) ==
             {:error, {:not_an_update, 5, 4}}
  end

  test "another signing key is refused" do
    assert Precheck.verify(
             info(%{}),
             info(%{version_code: 6, signers: [@key_b], signer_history: [@key_b]})
           ) ==
             {:error, {:signature_mismatch, [@key_a], [@key_b]}}
  end

  test "a rotated key whose lineage proves the installed signer passes" do
    rotated = info(%{version_code: 6, signers: [@key_b], signer_history: [@key_a, @key_b]})
    assert Precheck.verify(info(%{}), rotated) == :ok
  end

  test "an APK without readable signers is refused" do
    assert Precheck.verify(info(%{}), info(%{version_code: 6, signers: [], signer_history: []})) ==
             {:error, {:signature_mismatch, [@key_a], []}}
  end

  test "multiple signers must match as a set" do
    installed = info(%{signers: [@key_a, @key_b], signer_history: [], multiple_signers: true})

    assert Precheck.verify(installed, %{installed | version_code: 6, signers: [@key_b, @key_a]}) ==
             :ok

    assert Precheck.verify(installed, %{installed | version_code: 6, signers: [@key_a]}) ==
             {:error, {:signature_mismatch, [@key_a, @key_b], [@key_a]}}
  end
end

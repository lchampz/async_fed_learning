defmodule AFL.SmokeTest do
  use ExUnit.Case

  test "MockML generates tensors of the expected shape" do
    w = MockML.train()
    assert Nx.shape(w) == {MockML.model_size()}
  end
end

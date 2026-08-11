defmodule MockML do
  @model_size 10

  def model_size, do: @model_size

  def initial_weights, do: Nx.broadcast(0.0, {@model_size})

  # Simulates local gradient update: small random perturbation around zero,
  # producing weights that converge toward a non-trivial value when averaged.
  def train do
    # Use Erlang's PRNG to avoid the PRNG-key API surface of Nx.Random
    values = Enum.map(1..@model_size, fn _ -> :rand.normal() end)
    Nx.tensor(values, type: :f32)
  end
end

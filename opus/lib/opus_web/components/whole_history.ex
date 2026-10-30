defmodule OpusWeb.WholeHistory do
  @moduledoc """
  A strategy run over its whole test history, shown on its page and in the
  builder: "Against just holding" (`Opus.Trading.Strategies.report/4`) and
  "Is it fragile?" (`Opus.Trading.Strategies.fragility/6`).

  `panel/1` draws both. The functions keep the fragility pickers' state on
  the socket (`init/1`, `assign_axes/2`, `pick_axes/2`, `chosen_axes/1`);
  the LiveView starts the `:report` and `:fragility` asyncs and routes the
  `"fragility_axes"` and `"check_fragility"` events here.
  """
  use Phoenix.Component

  import OpusWeb.Copy
  import OpusWeb.ResultCharts

  alias Opus.Auro.Client
  alias Opus.Trading.Fragility

  @doc "Nothing run yet: the report loading, no settings picked."
  def init(socket),
    do: assign(socket, report: :loading, axes: [], fx: nil, fy: nil, fragility: :idle)

  @doc """
  The settings the fragility check can vary for `definition`. The first two
  are picked until a choice is made; a choice that still exists is kept.
  """
  def assign_axes(socket, definition) do
    axes = Fragility.axes(definition)
    ids = Enum.map(axes, & &1.id)
    {x, y} = Fragility.default_pair(axes)

    assign(socket,
      axes: axes,
      fx: if(socket.assigns.fx in ids, do: socket.assigns.fx, else: x && x.id),
      fy: if(socket.assigns.fy in ids, do: socket.assigns.fy, else: y && y.id)
    )
  end

  @doc "The pickers changed (`\"fragility_axes\"`): the old grid no longer applies."
  def pick_axes(socket, params) do
    y = if params["y"] in [nil, ""], do: nil, else: params["y"]
    assign(socket, fx: params["x"], fy: y, fragility: :idle)
  end

  @doc "The chosen settings as axes, `{x, y}` (y nil for a single row)."
  def chosen_axes(%{axes: axes, fx: fx, fy: fy}) do
    x = Enum.find(axes, &(&1.id == fx))
    y = if fy != fx, do: Enum.find(axes, &(&1.id == fy))
    {x, y}
  end

  @doc """
  An async's result on the socket (`handle_async/3` for `:report` and
  `:fragility`), with a failure in words.
  """
  def put_result(socket, :report, {:ok, {:ok, report}}), do: assign(socket, report: {:ok, report})

  def put_result(socket, :report, {:ok, {:error, reason}}),
    do: assign(socket, report: {:error, Client.describe_error(reason)})

  def put_result(socket, :report, {:exit, _reason}),
    do: assign(socket, report: {:error, "The history didn't finish loading."})

  def put_result(socket, :fragility, {:ok, {:ok, grid}}),
    do: assign(socket, fragility: {:ok, grid})

  def put_result(socket, :fragility, {:ok, {:error, reason}}),
    do: assign(socket, fragility: {:error, Client.describe_error(reason)})

  def put_result(socket, :fragility, {:exit, _reason}),
    do: assign(socket, fragility: {:error, "The check didn't finish."})

  attr :report, :any, required: true, doc: ":loading | {:ok, report | nil} | {:error, words}"
  attr :fragility, :any, required: true, doc: ":idle | :running | {:ok, grid} | {:error, words}"
  attr :axes, :list, required: true
  attr :fx, :string, default: nil
  attr :fy, :string, default: nil
  attr :instrument, :string, required: true
  attr :granularity, :string, required: true

  def panel(assigns) do
    assigns = assign(assigns, cells: cells(assigns))

    ~H"""
    <div class="grid gap-4 xl:grid-cols-2">
      <div class="flex min-w-0 flex-col gap-2 rounded-field bg-base-100 px-4 py-3">
        <span class="text-[14px] font-semibold">
          <.t {copy("Against just holding %{instrument}", instrument: @instrument)} />
        </span>
        <%= case @report do %>
          <% :loading -> %>
            <p class="m-0 text-[13px] text-muted">Running it over the whole history…</p>
          <% {:error, reason} -> %>
            <p class="m-0 text-[13px] text-muted">{reason}</p>
          <% {:ok, nil} -> %>
            <p class="m-0 text-[13px] text-muted">
              No history from before the holdout to run it on.
            </p>
          <% {:ok, report} -> %>
            <.vs_holding report={report} instrument={@instrument} />
        <% end %>
      </div>

      <div class="flex min-w-0 flex-col gap-3 rounded-field bg-base-100 px-4 py-3">
        <span class="text-[14px] font-semibold">
          <.t {copy("Is it fragile?")} />
        </span>
        <p class="m-0 text-[13px] text-muted">
          Re-runs it at settings near its own. A sturdy strategy keeps passing nearby;
          a lucky one only passes at its exact numbers.
        </p>
        <%= if @axes == [] do %>
          <p class="m-0 text-[13px] text-muted">Its blocks have no number settings to vary.</p>
        <% else %>
          <form id="fragility-axes" phx-change="fragility_axes" class="flex flex-wrap gap-2">
            <label class="flex min-w-0 flex-col gap-1 text-[12px] text-muted">
              Across
              <select name="x" class="select select-sm">
                <option :for={a <- @axes} value={a.id} selected={a.id == @fx}>{a.label}</option>
              </select>
            </label>
            <label class="flex min-w-0 flex-col gap-1 text-[12px] text-muted">
              Down
              <select name="y" class="select select-sm">
                <option value="" selected={is_nil(@fy)}>nothing (one row)</option>
                <option :for={a <- @axes} :if={a.id != @fx} value={a.id} selected={a.id == @fy}>
                  {a.label}
                </option>
              </select>
            </label>
          </form>
          <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
            <button
              type="button"
              phx-click="check_fragility"
              disabled={@fragility == :running}
              class="min-h-9 rounded-field border border-base-300 px-3 text-[13px] font-medium hover:border-primary disabled:opacity-50"
            >
              <%= if @fragility == :running do %>
                Checking {@cells} nearby settings…
              <% else %>
                Check {@cells} nearby settings
              <% end %>
            </button>
            <span :if={@granularity in ~w(M1 M5 M15)} class="text-[12px] text-muted">
              Intraday history is long: this takes about a minute.
            </span>
          </div>
          <%= case @fragility do %>
            <% {:ok, grid} -> %>
              <.fragility_grid
                grid={grid}
                x_label={Enum.find(@axes, &(&1.id == @fx)).label}
                y_label={(a = Enum.find(@axes, &(&1.id == @fy && @fy != @fx))) && a.label}
              />
            <% {:error, reason} -> %>
              <p class="m-0 text-[13px] text-muted">{reason}</p>
            <% _ -> %>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp cells(%{axes: []}), do: 0

  defp cells(assigns) do
    {x, y} = chosen_axes(assigns)
    length(Fragility.values(x)) * if(y, do: length(Fragility.values(y)), else: 1)
  end
end

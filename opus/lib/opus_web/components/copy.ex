defmodule OpusWeb.Copy do
  @moduledoc """
  One label, two voices. The serious wording and its r/wallstreetbets twin
  are both rendered; the stylesheet shows whichever the chosen theme asks
  for (`wsb:` variant on `[data-theme=wsb]`), so the toggle flips the copy
  instantly with no round trip and no server-side theme state.
  """
  use Phoenix.Component

  attr :s, :string, required: true, doc: "the serious wording"
  attr :wsb, :string, required: true, doc: "the WallStreetBets wording"

  def t(assigns) do
    ~H"""
    <span class="wsb:hidden">{@s}</span><span class="hidden wsb:inline">{@wsb}</span>
    """
  end
end

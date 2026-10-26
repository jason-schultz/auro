defmodule OpusWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use OpusWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout: a one-line header with the Auro wordmark, the
  page links and the theme toggle, then a single centred column.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="sticky top-0 z-10 border-b border-base-300 bg-base-100/95 backdrop-blur">
      <%!-- Safari on macOS 26 draws its bookmarks bar over the top ~40px of the
           page, so the bar's own content starts below that strip; the hit areas
           are tall enough that a link stays clickable even half-covered. --%>
      <div class="mx-auto flex w-full max-w-7xl items-center justify-between gap-6 px-4 pt-[max(2.5rem,env(safe-area-inset-top))] pb-3 sm:px-6">
        <a href={~p"/"} class="py-2 text-base font-semibold tracking-tight">Auro</a>
        <nav class="flex min-w-0 items-center gap-5 overflow-x-auto whitespace-nowrap text-sm">
          <a href={~p"/"} class="py-2 text-muted hover:text-base-content"><.t
            s="Dashboard"
            wsb="War room"
          /></a>
          <a href={~p"/strategies"} class="py-2 text-muted hover:text-base-content"><.t
            s="Strategies"
            wsb="Plays"
          /></a>
          <a href={~p"/journal"} class="py-2 text-muted hover:text-base-content"><.t
            s="Journal"
            wsb="Loss porn"
          /></a>
          <a href={~p"/accounts"} class="py-2 text-muted hover:text-base-content"><.t
            s="Accounts"
            wsb="The bag"
          /></a>
          <a href={~p"/options"} class="py-2 text-muted hover:text-base-content"><.t
            s="Options"
            wsb="Casino"
          /></a>
          <a href={~p"/instruments"} class="py-2 text-muted hover:text-base-content"><.t
            s="Instruments"
            wsb="Tickers"
          /></a>
          <a href={~p"/research"} class="py-2 text-muted hover:text-base-content"><.t
            s="Research"
            wsb="DD"
          /></a>
          <.theme_toggle />
        </nav>
      </div>
    </header>

    <main class="mx-auto w-full max-w-7xl px-4 py-8 sm:px-6">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/4 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/4 [[data-theme=dark]_&]:left-2/4 [[data-theme=wsb]_&]:left-3/4 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/4"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/4"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/4"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/4"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="wsb"
        aria-label="Use the WallStreetBets theme"
      >
        <.icon name="hero-rocket-launch-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end

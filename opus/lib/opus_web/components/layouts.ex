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
  page links, then a single centred column.

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
        <div class="flex items-center gap-6">
          <.link navigate={~p"/"} class="py-2 text-base font-semibold tracking-tight">Auro</.link>
          <.header_clock />
        </div>
        <nav class="flex min-w-0 items-center gap-5 overflow-x-auto whitespace-nowrap text-sm">
          <.link navigate={~p"/"} class="py-2 text-muted hover:text-base-content"><.t {copy("Dashboard")} /></.link>
          <.link navigate={~p"/strategies"} class="py-2 text-muted hover:text-base-content"><.t {copy("Strategies")} /></.link>
          <.link navigate={~p"/together"} class="py-2 text-muted hover:text-base-content"><.t {copy("Together")} /></.link>
          <.link navigate={~p"/safety"} class="py-2 text-muted hover:text-base-content"><.t {copy("Safety")} /></.link>
          <.link navigate={~p"/journal"} class="py-2 text-muted hover:text-base-content"><.t {copy("Journal")} /></.link>
          <.link navigate={~p"/accounts"} class="py-2 text-muted hover:text-base-content"><.t {copy("Accounts")} /></.link>
          <.link navigate={~p"/options"} class="py-2 text-muted hover:text-base-content"><.t {copy("Options")} /></.link>
          <.link navigate={~p"/instruments"} class="py-2 text-muted hover:text-base-content"><.t {copy("Instruments")} /></.link>
          <.link navigate={~p"/research"} class="py-2 text-muted hover:text-base-content"><.t {copy("Research")} /></.link>
          <.link navigate={~p"/settings"} class="py-2 text-muted hover:text-base-content"><.t {copy("Settings")} /></.link>
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
  The time where the viewer is (`Opus.Clock.display_zone/0`) and in New
  York, the market's: "Edmonton 14:05 · New York 16:05". The server renders
  it; the `.Clock` hook moves it on at each minute in the browser.
  """
  def header_clock(assigns) do
    now = DateTime.utc_now()

    assigns =
      assign(assigns,
        places:
          for zone <- Enum.uniq([Opus.Clock.display_zone(), Opus.Clock.market_zone()]) do
            %{zone: zone, city: OpusWeb.Format.city(zone), time: OpusWeb.Format.clock(now, zone)}
          end
      )

    ~H"""
    <span
      id="header-clock"
      phx-hook=".Clock"
      phx-update="ignore"
      class="hidden whitespace-nowrap text-[13px] tabular-nums text-muted md:inline"
    >
      <span :for={{place, i} <- Enum.with_index(@places)}>
        <span :if={i > 0} aria-hidden="true">·</span>
        {place.city} <time data-zone={place.zone}>{place.time}</time>
      </span>
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Clock">
      export default {
        mounted() { this.tick() },
        destroyed() { clearTimeout(this.timer) },
        tick() {
          const now = new Date()
          for (const el of this.el.querySelectorAll("[data-zone]")) {
            el.textContent = now.toLocaleTimeString("en-GB", {
              timeZone: el.dataset.zone, hour: "2-digit", minute: "2-digit", hourCycle: "h23"
            })
          }
          this.timer = setTimeout(() => this.tick(), 60000 - (now.getTime() % 60000))
        }
      }
    </script>
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
end

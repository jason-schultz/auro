defmodule OpusWeb.Copy do
  @moduledoc """
  One label, two voices. The serious wording and its r/wallstreetbets twin
  are both rendered; the stylesheet shows whichever the chosen theme asks
  for (`wsb:` variant on `[data-theme=wsb]`), so the toggle flips the copy
  instantly with no round trip and no server-side theme state.

  The words live in Gettext, keyed by the serious English: the serious
  wording in the `default` domain, its twin in the `wsb` domain
  (`priv/gettext/<locale>/LC_MESSAGES/wsb.po`). A missing twin falls back
  to the serious wording (`OpusWeb.Gettext`).

      <.t {copy("What happens next")} />
      <.t {copy("Test results on %{instrument}", instrument: @s.instrument)} />

  Components that take a label take the pair (`label={copy("Trades")}`)
  and render it with `<.t {@label} />`.
  """
  use Phoenix.Component

  @type voices :: %{s: String.t(), wsb: String.t()}

  @doc """
  Both voices of `msgid`, which must be a literal string so
  `mix gettext.extract` finds it. `bindings` fill its `%{name}` slots.
  """
  defmacro copy(msgid, bindings \\ Macro.escape(%{})) when is_binary(msgid) do
    quote do
      require Gettext.Macros

      %{
        s:
          Gettext.Macros.gettext_with_backend(OpusWeb.Gettext, unquote(msgid), unquote(bindings)),
        wsb:
          Gettext.Macros.dgettext_with_backend(
            OpusWeb.Gettext,
            "wsb",
            unquote(msgid),
            unquote(bindings)
          )
      }
    end
  end

  @doc """
  `copy/2` for wording that reads the same seriously in two places but has
  a different WSB twin in each: `context` tells them apart (Gettext's
  `msgctxt`).

      pcopy("buyer", "If the stock stays above %{strike}", strike: "$500")
  """
  defmacro pcopy(context, msgid, bindings \\ Macro.escape(%{}))
           when is_binary(context) and is_binary(msgid) do
    quote do
      require Gettext.Macros

      %{
        s:
          Gettext.Macros.pgettext_with_backend(
            OpusWeb.Gettext,
            unquote(context),
            unquote(msgid),
            unquote(bindings)
          ),
        wsb:
          Gettext.Macros.dpgettext_with_backend(
            OpusWeb.Gettext,
            "wsb",
            unquote(context),
            unquote(msgid),
            unquote(bindings)
          )
      }
    end
  end

  @doc """
  Both voices of a counted label: `msgid` for one, `msgid_plural` for
  more, each language choosing its own forms. `%{count}` is `n`.

      copy_n("%{count} thing needs you", "%{count} things need you", length(urgent))
  """
  defmacro copy_n(msgid, msgid_plural, n, bindings \\ Macro.escape(%{}))
           when is_binary(msgid) and is_binary(msgid_plural) do
    quote do
      require Gettext.Macros

      %{
        s:
          Gettext.Macros.ngettext_with_backend(
            OpusWeb.Gettext,
            unquote(msgid),
            unquote(msgid_plural),
            unquote(n),
            unquote(bindings)
          ),
        wsb:
          Gettext.Macros.dngettext_with_backend(
            OpusWeb.Gettext,
            "wsb",
            unquote(msgid),
            unquote(msgid_plural),
            unquote(n),
            unquote(bindings)
          )
      }
    end
  end

  attr :s, :string, required: true, doc: "the serious wording"
  attr :wsb, :string, required: true, doc: "the WallStreetBets wording"

  def t(assigns) do
    ~H"""
    <span class="wsb:hidden">{@s}</span><span class="hidden wsb:inline">{@wsb}</span>
    """
  end
end

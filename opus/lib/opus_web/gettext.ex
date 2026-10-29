defmodule OpusWeb.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API.

  By using [Gettext](https://hexdocs.pm/gettext), your module compiles translations
  that you can use in your application. To use this Gettext backend module,
  call `use Gettext` and pass it as an option:

      use Gettext, backend: OpusWeb.Gettext

      # Simple translation
      gettext("Here is the string to translate")

      # Plural translation
      ngettext("Here is the string to translate",
               "Here are the strings to translate",
               3)

      # Domain-based translation
      dgettext("errors", "Here is the error message to translate")

  See the [Gettext Docs](https://hexdocs.pm/gettext) for detailed usage.
  """
  use Gettext.Backend, otp_app: :opus

  # A label with no WallStreetBets wording in this language shows its
  # serious wording in this language, not the English msgid.
  @impl Gettext.Backend
  def handle_missing_translation(_locale, "wsb", msgctxt, msgid, bindings),
    do: {:default, Gettext.dpgettext(__MODULE__, "default", msgctxt, msgid, bindings)}

  def handle_missing_translation(locale, domain, msgctxt, msgid, bindings),
    do: super(locale, domain, msgctxt, msgid, bindings)

  @impl Gettext.Backend
  def handle_missing_plural_translation(_locale, "wsb", msgctxt, msgid, plural, n, bindings),
    do: {:default, Gettext.dpngettext(__MODULE__, "default", msgctxt, msgid, plural, n, bindings)}

  def handle_missing_plural_translation(locale, domain, msgctxt, msgid, plural, n, bindings),
    do: super(locale, domain, msgctxt, msgid, plural, n, bindings)
end

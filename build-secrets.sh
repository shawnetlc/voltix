#!/usr/bin/env bash
# build-secrets.sh - the build-time values every non-Windows build embeds.
#
# Bash counterpart to build-secrets.ps1. Sourced by build-all-apple.sh,
# build-ios.sh, build-android.sh and build-tizen.sh so there is ONE place per
# platform family to rotate them.
#
# Keep the values here in step with build-secrets.ps1. They are duplicated
# rather than shared because PowerShell and bash cannot read one another's
# syntax, and a generated file would be one more thing to forget to regenerate.
#
# An environment variable of the same name overrides the baked-in value, which
# is how CI supplies its own without editing this file.

# ── Azure Blob SAS ──────────────────────────────────────────────────────────
#
# A SAS is scoped to a single container, so there are two:
#   AZURE_BLOB_SAS_TOKEN           -> voltix-taste-profiles
#   AZURE_BLOB_SETTINGS_SAS_TOKEN  -> voltix-user-settings
#                                     (also holds watch history, under a path
#                                      prefix rather than its own container)
#
# Both expire 2027-06-01. When they lapse the app does not error: it reports
# itself unconfigured and falls back to the /api/voltix/azure-sync proxy, so
# everything keeps working and nobody notices. Diarise the date.
#
# Never put an account key here. Nothing in the app signs with one, and it
# would grant whoever unpacked the build full read/write/delete over every
# user's profile, settings and watch history.
: "${AZURE_BLOB_SAS_TOKEN:=sp=racw&st=2026-09-05T23:29:08Z&se=2027-06-01T07:44:08Z&spr=https&sv=2026-02-06&sr=c&sig=NWIl1HJ3UgLprg%2FYNCfyXUtbQNbHpeUzgRXpqyQ9utc%3D}"
: "${AZURE_BLOB_SETTINGS_SAS_TOKEN:=sp=racwd&st=2026-09-06T00:12:40Z&se=2027-06-01T08:27:40Z&spr=https&sv=2026-02-06&sr=c&sig=ZyhRWCNCM9WjR65nu9QBNgXYD9IkXyzrQJuAMm2Z86o%3D}"

# ── Grok / xAI ──────────────────────────────────────────────────────────────
#
# GrokTasteAiService resolves these as: runtime override, then compile-time
# define, then the user's own key from Settings, then the process environment.
# A baked-in key therefore outranks whatever a user has entered.
#
# Empty is a working state: the AI features fall back to the built-in offline
# synthesis engine.
: "${GROK_API_KEY:=xai-AYt8URqAiDKxJZoWlkSbVuGYfMJZra3QJtif4DT1OyCF8mp4qlYG9OzXwSRiFMGfShU4HugB4a5OZopQ}"
: "${GROK_MODEL:=grok-4.20-0309-non-reasoning}"
# Optional. Defaults to https://api.x.ai/v1/chat/completions when unset.
: "${GROK_ENDPOINT:=}"

# Emits the values as --dart-define arguments, one per line so callers can read
# them into an array safely. Values contain '&' and '=', so callers must quote:
#
#   mapfile -t SECRET_DEFINES < <(build_secret_dart_defines)
#   flutter build ipa "${SECRET_DEFINES[@]}"
#
build_secret_dart_defines() {
  [ -n "${AZURE_BLOB_SAS_TOKEN}" ] && \
    printf -- '--dart-define=AZURE_BLOB_SAS_TOKEN=%s\n' "${AZURE_BLOB_SAS_TOKEN}"
  [ -n "${AZURE_BLOB_SETTINGS_SAS_TOKEN}" ] && \
    printf -- '--dart-define=AZURE_BLOB_SETTINGS_SAS_TOKEN=%s\n' "${AZURE_BLOB_SETTINGS_SAS_TOKEN}"
  [ -n "${GROK_API_KEY}" ] && \
    printf -- '--dart-define=GROK_API_KEY=%s\n' "${GROK_API_KEY}"
  [ -n "${GROK_MODEL}" ] && \
    printf -- '--dart-define=GROK_MODEL=%s\n' "${GROK_MODEL}"
  [ -n "${GROK_ENDPOINT}" ] && \
    printf -- '--dart-define=GROK_ENDPOINT=%s\n' "${GROK_ENDPOINT}"
  return 0
}

write_secret_status() {
  if [ -n "${AZURE_BLOB_SAS_TOKEN}" ]; then
    echo "Azure SAS (taste profiles): supplied"
  else
    echo "Azure SAS (taste profiles): not set - using the sync proxy"
  fi
  if [ -n "${AZURE_BLOB_SETTINGS_SAS_TOKEN}" ]; then
    echo "Azure SAS (user settings):  supplied"
  else
    echo "Azure SAS (user settings):  not set - using the sync proxy"
  fi
  if [ -n "${GROK_API_KEY}" ]; then
    echo "Grok:                       supplied (${GROK_MODEL:-default model})"
  else
    echo "Grok:                       not set - offline synthesis only"
  fi
}

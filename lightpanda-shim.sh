#!/usr/bin/env bash
# Shim zwischen agent-browser und Lightpanda (im Image installiert).
#
# WARUM: agent-browser 0.27.0 startet Lightpanda mit
#     lightpanda serve --port <p> --timeout <ms>
# Aktuelle Lightpanda-Builds (>= 1.1.0 nightly) kennen kein "--timeout" mehr und
# brechen ab mit:
#     $level=fatal $msg="unknown argument" mode=serve arg=--timeout
# -> der CDP-Port wird nie bereit, agent-browser meldet
#    "Lightpanda exited before CDP became ready".
# Nächstliegendes Äquivalent ist "--http-timeout" (Millisekunden, Default 15000):
# es begrenzt die Übertragungsdauer der Requests, also praktisch dasselbe Ziel.
#
# Dieser Wrapper übersetzt --timeout → --http-timeout und reicht alles andere
# unverändert weiter. Echtes Binary: /opt/lightpanda/lightpanda.
declare -a out=()
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)
      shift
      if [ $# -gt 0 ]; then
        out+=(--http-timeout "$1")
        shift
      fi
      ;;
    --timeout=*)
      out+=("--http-timeout=${1#--timeout=}")
      shift
      ;;
    *)
      out+=("$1")
      shift
      ;;
  esac
done
exec /opt/lightpanda/lightpanda "${out[@]}"
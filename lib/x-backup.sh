# shellcheck shell=bash
# lib/x-backup.sh — `deploys backup` and `deploys restore`: the settings files of the config folder in one file, and back.
#
#   deploys backup [--out <file>]                 one JSON file with the settings (to the terminal without --out)
#   deploys restore <file> [--yes]                what would change; with --yes, write it (the old files are kept first)
#
# Only these files go in (BACKUP_FILES): window, rules, budget, prices, ignored, groups, guard, providers, clean, nightly,
# prepare, autofix-limits, slo, checklists and sessions (.json). Never the journal, caches, keys (they live in the keychain
# or the environment), auto-deploy allowances (they end on purpose) or anything about this machine (schedules). A file that
# is not valid JSON, or in which a secret-looking text is found, is left out and named. `restore` reads only those names,
# refuses any other, shows new/changed/same per file, and without --yes writes nothing. With --yes (and not in observer
# mode) the files it replaces are copied to restore-backup-<time>/ in the config folder first. It never starts a deploy.
# Sourced by deploys; uses CONFIG_DIR, atomic_write, af_mask, require_write and die.
# x-command: backup | all settings files (window, rules, budget, groups …) in one file, without keys or journal | deploys backup [--out <file>]
# x-command: restore | read such a file back: shows what would change, writes only with --yes (old files kept) | deploys restore <file> [--yes]

BACKUP_FILES="window rules budget prices ignored groups guard providers clean nightly prepare autofix-limits slo checklists sessions"

x_backup_main() {
  local out="" name f files="{}" skipped="[]" text m bundle
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) [ -n "${2:-}" ] || die "--out takes a file name"; out="$2"; shift ;;
      *) die "Unknown option $1. Usage: deploys backup [--out <file>]" ;;
    esac
    shift
  done
  for name in $BACKUP_FILES; do
    f="$CONFIG_DIR/$name.json"; [ -f "$f" ] || continue
    if ! jq -e . "$f" >/dev/null 2>&1; then skipped="$(jq -c --arg n "$name.json" --arg r "not valid JSON" '. + [{file:$n, reason:$r}]' <<<"$skipped")"; continue; fi
    text="$(jq -c . "$f")"; m="$(printf '%s\n' "$text" | af_mask)" || m=""
    if [ "$m" != "$text" ]; then skipped="$(jq -c --arg n "$name.json" --arg r "looks like it holds a secret" '. + [{file:$n, reason:$r}]' <<<"$skipped")"; continue; fi
    files="$(jq -c --arg n "$name.json" --argjson v "$text" '. + {($n): $v}' <<<"$files")"
  done
  bundle="$(jq -n --argjson files "$files" --argjson skipped "$skipped" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg v "$(cat "$SELF_DIR/VERSION" 2>/dev/null)" \
    '{deployCenterBackup: 1, createdAt: $at, version: $v, files: $files, skipped: $skipped}')"
  if [ -n "$out" ]; then
    printf '%s\n' "$bundle" | atomic_write "$out" || die "Could not write $out"
    chmod 600 "$out" 2>/dev/null || true
    echo "Wrote $out: $(jq '.files | length' <<<"$bundle") settings files$(jq -r 'if (.skipped | length) > 0 then ", left out: " + ([.skipped[] | "\(.file) (\(.reason))"] | join(", ")) else "" end' <<<"$bundle")."
  else
    printf '%s\n' "$bundle"
  fi
}

x_restore_main() {
  local file="" yes=0 name key cur new status stamp dir n=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes) yes=1 ;;
      -*) die "Unknown option $1. Usage: deploys restore <file> [--yes]" ;;
      *) [ -z "$file" ] || die "Usage: deploys restore <file> [--yes]"; file="$1" ;;
    esac
    shift
  done
  [ -n "$file" ] || die "Usage: deploys restore <file> [--yes]"
  [ -f "$file" ] || die "No such file: $file"
  [ "$(wc -c < "$file")" -le 5000000 ] || die "$file is too big for a settings backup"
  jq -e '.deployCenterBackup == 1 and (.files | type == "object")' "$file" >/dev/null 2>&1 || die "$file is not a deploys backup (deploys backup --out file)"
  for key in $(jq -r '.files | keys[]' "$file"); do
    case "$key" in *.json) ;; *) die "The backup names $key: not a settings file; nothing was changed" ;; esac
    case " $BACKUP_FILES " in *" ${key%.json} "*) ;; *) die "The backup names $key: not a settings file deploys backs up; nothing was changed" ;; esac
  done
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"; dir="$CONFIG_DIR/restore-backup-$stamp"
  [ "$yes" = 0 ] || require_write "restore"
  for key in $(jq -r '.files | keys[]' "$file"); do
    name="$CONFIG_DIR/$key"; new="$(jq -c --arg k "$key" '.files[$k]' "$file")"
    if [ ! -f "$name" ]; then status=new
    else cur="$(jq -c . "$name" 2>/dev/null)"; if [ "$cur" = "$new" ]; then status=same; else status=changed; fi; fi
    printf '  %-8s %s\n' "$status" "$key"
    [ "$status" != same ] || continue
    n=$((n + 1))
    [ "$yes" = 1 ] || continue
    if [ -f "$name" ]; then mkdir -p "$dir" && cp -p "$name" "$dir/$key" || die "Could not keep the old $key; nothing more was changed"; fi
    jq . <<<"$new" | atomic_write "$name" || die "Could not write $name"
  done
  if [ "$yes" = 1 ]; then echo "Restored $n files.$( [ ! -d "$dir" ] || echo " The old ones are in $dir.")"
  else echo "$n files would change. Nothing was written: add --yes to restore."; fi
}

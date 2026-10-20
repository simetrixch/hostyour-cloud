# =============================================================================
# require-forgejo-destinations.sh — the guard every launcher that hands a config to deploy-branch puts
# on the Forgejo destinations in it. SOURCED, NEVER RUN: each launcher reads it with `.` and calls
# require_forgejo_destinations once it has read its config into the shell.
#
#   require_forgejo_destinations   0 when FORGEJO_PLATFORM_REPOSITORY, FORGEJO_DEPLOY_REPOSITORY,
#                                  FORGEJO_ORGANISATIONS and FORGEJO_HOST are stated and the owner of each repository is
#                                  one of the organisations; 1 otherwise, with REFUSAL set to the end of
#                                  the sentence, which the launcher begins with its config's name
#
# WHY THE OWNERS ARE ASKED HERE. The program rows check each answer alone, and no step of a program
# reads two answers, so a set of organisations that leaves a repository's owner out passes every row.
# The producer of the Argo CD machine user refuses it too, but only on the machine, and
# deploy-branch persists it before that. What is asked here is the spelling of the config, so a
# shape the programs refuse (a missing slash, a space) is left to them.
#
# Forgejo names organisations without regard to case, so the owners are compared that way.
# =============================================================================

require_forgejo_destinations() {
  REFUSAL=''
  local name owner organisations
  for name in FORGEJO_PLATFORM_REPOSITORY FORGEJO_DEPLOY_REPOSITORY FORGEJO_ORGANISATIONS FORGEJO_HOST; do
    [ -n "${!name:-}" ] || { REFUSAL="states no $name, and nothing here may choose one"; return 1; }
  done
  organisations=",$(printf '%s' "$FORGEJO_ORGANISATIONS" | tr '[:upper:]' '[:lower:]'),"
  for name in FORGEJO_PLATFORM_REPOSITORY FORGEJO_DEPLOY_REPOSITORY; do
    owner="${!name%%/*}"
    case "$organisations" in
      *",$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]'),"*) ;;
      *) REFUSAL="states FORGEJO_ORGANISATIONS without $owner, the owner of $name: the organisations must include the owner of both repositories"; return 1 ;;
    esac
  done
}

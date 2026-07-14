# Pure package-list filtering. Ignores blank lines and '#' comments in the
# wanted list so the curated files can be annotated.

_clean_list() { grep -vE '^\s*(#|$)' "$1" | sort -u; }

available_pkgs() { # repo_list wanted_list
    comm -12 <(sort -u "$1") <(_clean_list "$2")
}

missing_pkgs() {   # repo_list wanted_list
    comm -13 <(sort -u "$1") <(_clean_list "$2")
}

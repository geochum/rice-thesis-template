#!/usr/bin/env bash
# Usage: ./build.sh [--verbose] [path/to/file.tex]
# PDF goes to .build/. Optional: LATEXMK_BIN=/path/to/latexmk
# Quiet by default. Pass --verbose (-v) to stream latexmk output.

set -euo pipefail

build_self_name() {
    basename "${BASH_SOURCE[0]}"
}

build_usage() {
    echo "Usage: ./$(build_self_name) [--verbose] [path/to/file.tex]"
}

build_path_sep() {
    case "$(uname -s 2>/dev/null || echo unknown)" in
        MINGW*|MSYS*|CYGWIN*|Windows_NT) printf ';' ;;
        *) printf ':' ;;
    esac
}

build_abspath() {
    local path="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$path"
    elif [ -d "$path" ]; then
        (cd "$path" && pwd)
    else
        echo "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
    fi
}

# Windows TeX (MiKTeX) needs drive-letter paths in TEXINPUTS/BIBINPUTS.
build_engine_path() {
    local path="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$path"
    else
        printf '%s\n' "$path"
    fi
}

# Directory that contains this script. Shared TeX inputs live here.
build_script_dir() {
    local source="${BASH_SOURCE[0]}"
    cd "$(dirname "$(build_abspath "$source")")" && pwd
}

build_rc_file() {
    local root="$1"
    if [ -f "$root/.latexmkrc" ]; then
        printf '%s\n' "$root/.latexmkrc"
    elif [ -f "$root/latexmkrc" ]; then
        printf '%s\n' "$root/latexmkrc"
    fi
}

build_prepend_search_path() {
    local var="$1"
    local root="$2"
    local sep
    sep="$(build_path_sep)"
    local current="${!var:-}"
    if [ -z "$current" ]; then
        export "$var=${root}${sep}"
    else
        export "$var=${root}${sep}${current}"
    fi
}

build_discover_tex_path() {
    local extra=()
    [ -d /Library/TeX/texbin ] && extra+=("/Library/TeX/texbin")

    local d
    for d in /usr/local/texlive/*/bin/*; do
        [ -d "$d" ] && extra+=("$d")
    done

    local miktex=""
    if [ -n "${LOCALAPPDATA:-}" ]; then
        miktex="${LOCALAPPDATA}/Programs/MiKTeX/miktex/bin/x64"
    fi
    if [ -z "$miktex" ] || [ ! -d "$miktex" ]; then
        miktex="${HOME}/AppData/Local/Programs/MiKTeX/miktex/bin/x64"
    fi
    [ -d "$miktex" ] && extra+=("$miktex")

    local p
    for p in "${extra[@]}"; do
        PATH="${p}:$PATH"
    done
    export PATH
}

build_resolve_latexmk() {
    if [ -n "${LATEXMK_BIN:-}" ]; then
        if [ -x "$LATEXMK_BIN" ] || command -v "$LATEXMK_BIN" >/dev/null 2>&1; then
            printf '%s\n' "$LATEXMK_BIN"
            return 0
        fi
        echo "Error: LATEXMK_BIN is set but not executable: $LATEXMK_BIN" >&2
        return 1
    fi
    if command -v latexmk >/dev/null 2>&1; then
        command -v latexmk
        return 0
    fi
    build_discover_tex_path
    if command -v latexmk >/dev/null 2>&1; then
        command -v latexmk
        return 0
    fi
    echo "Error: latexmk is not installed or not on PATH" >&2
    echo "  MacTeX: /Library/TeX/texbin   TeX Live: /usr/local/texlive/*/bin/*" >&2
    echo "  Windows: install MiKTeX or TeX Live and reopen the terminal" >&2
    return 1
}

build_count_pattern() {
    local pattern="$1"
    local file="$2"
    local count=0
    if [ -f "$file" ]; then
        count="$(grep -E -c "$pattern" "$file" 2>/dev/null || true)"
        if ! [[ "$count" =~ ^[0-9]+$ ]]; then
            count=0
        fi
    fi
    echo "$count"
}

build_pdf_size() {
    local pdf="$1"
    local size_bytes
    size_bytes="$(stat -f%z "$pdf" 2>/dev/null || stat -c%s "$pdf" 2>/dev/null || true)"
    if [ -z "$size_bytes" ]; then
        return 0
    fi
    if [ "$size_bytes" -lt 1024 ]; then
        echo "$size_bytes"
    elif [ "$size_bytes" -lt 1048576 ]; then
        echo "$((size_bytes / 1024))K"
    else
        if command -v bc >/dev/null 2>&1; then
            local size_mb
            size_mb="$(echo "scale=1; $size_bytes / 1048576" | bc)"
            echo "$(echo "$size_mb" | sed 's/\.0$//')M"
        else
            local size_mb
            size_mb="$(awk "BEGIN {printf \"%.1f\", $size_bytes / 1048576}")"
            echo "$(echo "$size_mb" | sed 's/\.0$//')M"
        fi
    fi
}

build_page_count() {
    local pdf="$1"
    local n=""
    if command -v pdfinfo >/dev/null 2>&1; then
        n="$(pdfinfo "$pdf" 2>/dev/null | awk '/^Pages:/{print $2}' || true)"
    elif command -v pdftk >/dev/null 2>&1; then
        n="$(pdftk "$pdf" dump_data 2>/dev/null | awk '/NumberOfPages/{print $2}' || true)"
    fi
    printf '%s\n' "$n"
}

build_tex_files() {
    local files=()
    local line
    while IFS= read -r line; do
        files+=("${line#./}")
    done < <(find . -maxdepth 1 -type f -name '*.tex' ! -name '.*' | sort)
    if [ ${#files[@]} -eq 0 ]; then
        return 1
    fi
    printf '%s\n' "${files[@]}"
}

build_choose_tex() {
    local files=()
    local line
    while IFS= read -r line; do
        files+=("$line")
    done < <(build_tex_files) || true

    if [ ${#files[@]} -eq 0 ]; then
        echo "No .tex files in this directory. $(build_usage)" >&2
        return 1
    fi
    if [ ${#files[@]} -eq 1 ]; then
        printf '%s\n' "${files[0]}"
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "Several .tex files in this directory. Pass one:" >&2
        local name
        for name in "${files[@]}"; do
            printf '  %s\n' "$name" >&2
        done
        return 1
    fi

    echo "" >&2
    echo -e "\033[1;36m  Select a .tex file\033[0m" >&2
    echo "" >&2
    local i
    for i in "${!files[@]}"; do
        echo -e "  \033[2m[$((i + 1))]\033[0m \033[36m${files[i]}\033[0m" >&2
    done
    echo "" >&2
    local selection
    read -r -p "  Select (1-${#files[@]}) or Enter to cancel: " selection
    if [ -z "$selection" ] || [ "$selection" = "q" ] || [ "$selection" = "Q" ]; then
        echo "Build cancelled." >&2
        return 2
    fi
    if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
        echo "Invalid selection. Build cancelled." >&2
        return 1
    fi
    local selected_index=$((selection - 1))
    if [ "$selected_index" -ge 0 ] && [ "$selected_index" -lt ${#files[@]} ]; then
        printf '%s\n' "${files[$selected_index]}"
        return 0
    fi
    echo "Invalid selection. Build cancelled." >&2
    return 1
}

build_warn_error_counts() {
    local log_path="$1"
    local error_count warning_count count
    error_count="$(build_count_pattern "^!" "$log_path")"
    warning_count=0
    count="$(build_count_pattern "^LaTeX Warning:" "$log_path")"
    warning_count=$((warning_count + ${count:-0}))
    count="$(build_count_pattern "^Package .* Warning:" "$log_path")"
    warning_count=$((warning_count + ${count:-0}))
    count="$(build_count_pattern "^Overfull" "$log_path")"
    warning_count=$((warning_count + ${count:-0}))
    count="$(build_count_pattern "^Underfull" "$log_path")"
    warning_count=$((warning_count + ${count:-0}))
    count="$(build_count_pattern "^Font shape" "$log_path")"
    warning_count=$((warning_count + ${count:-0}))
    count="$(build_count_pattern "^Missing character" "$log_path")"
    warning_count=$((warning_count + ${count:-0}))
    echo "$error_count $warning_count"
}

build_report_success() {
    local original_dir="$1"
    local pdf_path="$2"
    local log_path="$3"
    local base_name="$4"
    local elapsed="$5"

    local pdf_size page_count
    pdf_size="$(build_pdf_size "$pdf_path")"
    page_count="$(build_page_count "$pdf_path")"

    echo ""
    echo -e "\033[1;32m✓ Success\033[0m"

    local summary="$base_name.pdf"
    [ -n "$page_count" ] && summary="$summary · ${page_count} page(s)"
    [ -n "$pdf_size" ] && summary="$summary · $pdf_size"
    [ "$elapsed" -gt 0 ] && summary="$summary · ${elapsed}s"
    echo -e "  \033[2m$summary\033[0m"
    echo ""

    local display_path
    if [[ "$pdf_path" == "$original_dir"* ]]; then
        display_path="${pdf_path#$original_dir/}"
    else
        display_path="$base_name.pdf (in .build/)"
    fi
    echo -e "  \033[1mOutput:\033[0m"
    echo -e "    \033[2mFile:\033[0m   $display_path"
    [ -n "$page_count" ] && printf "    \033[2m%-6s\033[0m %s\n" "Pages:" "$page_count"
    [ -n "$pdf_size" ] && printf "    \033[2m%-6s\033[0m %s\n" "Size:" "$pdf_size"
    [ "$elapsed" -gt 0 ] && printf "    \033[2m%-6s\033[0m %s\n" "Time:" "${elapsed}s"

    if [ -f "$log_path" ]; then
        local counts error_count warning_count
        counts="$(build_warn_error_counts "$log_path")"
        error_count="${counts%% *}"
        warning_count="${counts##* }"
        if [ "$error_count" -gt 0 ] || [ "$warning_count" -gt 0 ]; then
            echo ""
            echo -e "  \033[1;33m⚠ Issues:\033[0m"
            [ "$error_count" -gt 0 ] && echo -e "    \033[31mErrors:\033[0m   $error_count"
            [ "$warning_count" -gt 0 ] && echo -e "    \033[33mWarnings:\033[0m $warning_count"
            echo -e "    \033[2mLog:\033[0m     $log_path"
        fi
    fi
}

build_print_log_excerpt() {
    local log_path="$1"
    local max_lines="${2:-8}"
    if [ ! -f "$log_path" ]; then
        return 1
    fi
    local start=""
    start="$(grep -n -E '^!' "$log_path" 2>/dev/null | head -n 1 | cut -d: -f1)" || true
    if [ -z "$start" ]; then
        return 1
    fi
    echo -e "  \033[1mLog excerpt:\033[0m"
    awk -v start="$start" -v max="$max_lines" '
        NR < start { next }
        printed > 2 && ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*\*+/ || $0 ~ /^\[/) { exit }
        { print "    " $0; printed++; if (printed >= max) exit }
    ' "$log_path"
}

build_report_failure() {
    local log_path="$1"
    local capture_path="${2:-}"
    echo ""
    echo -e "\033[1;31m✗ Compilation Failed\033[0m"
    echo ""
    if [ -f "$log_path" ]; then
        local counts error_count warning_count
        counts="$(build_warn_error_counts "$log_path")"
        error_count="${counts%% *}"
        warning_count="${counts##* }"
        echo -e "  \033[1mIssues Found:\033[0m"
        [ "$error_count" -gt 0 ] && echo -e "    \033[31mErrors:\033[0m   $error_count"
        [ "$warning_count" -gt 0 ] && echo -e "    \033[33mWarnings:\033[0m $warning_count"
        echo -e "    \033[2mLog:\033[0m      $log_path"
        echo ""
        local excerpt_status=0
        build_print_log_excerpt "$log_path" || excerpt_status=$?
        if [ "$excerpt_status" -ne 0 ] || { [ -n "$capture_path" ] && [ -f "$capture_path" ] && grep -Fq "pdflatex not found" "$capture_path"; }; then
            if [ -n "$capture_path" ] && [ -f "$capture_path" ]; then
                echo -e "  \033[1mlatexmk output:\033[0m"
                head -n 40 "$capture_path" | sed 's/^/    /'
            fi
        fi
    else
        echo -e "  \033[2mLog file not found: $log_path\033[0m"
        if [ -n "$capture_path" ] && [ -f "$capture_path" ]; then
            echo ""
            echo -e "  \033[1mlatexmk output:\033[0m"
            head -n 40 "$capture_path" | sed 's/^/    /'
        fi
    fi
    echo ""
    echo -e "  \033[2mRe-run with --verbose to stream latexmk.\033[0m"
    echo ""
}

build_main() {
    local tex_file="${1:-}"
    local verbose="${2:-0}"

    local script_dir
    script_dir="$(build_script_dir)"

    if [ -z "$tex_file" ]; then
        local pick_status=0
        tex_file="$(build_choose_tex)" || pick_status=$?
        if [ "$pick_status" -eq 2 ]; then
            return 0
        fi
        if [ "$pick_status" -ne 0 ]; then
            return 1
        fi
    fi

    if [ -z "$tex_file" ] || [ ! -f "$tex_file" ]; then
        echo -e "\033[31mError: No .tex file found. $(build_usage)\033[0m"
        return 1
    fi
    if [[ "$tex_file" != *.tex ]]; then
        echo -e "\033[31mError: File must have .tex extension: $tex_file\033[0m"
        return 1
    fi

    local latexmk_bin
    latexmk_bin="$(build_resolve_latexmk)" || return 1
    if ! command -v pdflatex >/dev/null 2>&1 && ! command -v pdflatex.exe >/dev/null 2>&1; then
        echo "Error: pdflatex not found" >&2
        return 1
    fi

    local original_dir
    original_dir="$(pwd)"
    local tex_file_abs tex_dir base_name build_dir tex_file_name
    tex_file_abs="$(build_abspath "$tex_file")"
    tex_dir="$(dirname "$tex_file_abs")"
    base_name="$(basename "$tex_file_abs" .tex)"
    build_dir="$tex_dir/.build"
    tex_file_name="$(basename "$tex_file_abs")"
    mkdir -p "$build_dir"

    # Always search the source directory (needed for .bib with -output-directory).
    local tex_dir_engine
    tex_dir_engine="$(build_engine_path "$tex_dir")"
    build_prepend_search_path TEXINPUTS "$tex_dir_engine"
    build_prepend_search_path BIBINPUTS "$tex_dir_engine"
    build_prepend_search_path BSTINPUTS "$tex_dir_engine"

    local root_engine
    root_engine="$(build_engine_path "$script_dir")"
    build_prepend_search_path TEXINPUTS "$root_engine"
    build_prepend_search_path BIBINPUTS "$root_engine"
    build_prepend_search_path BSTINPUTS "$root_engine"

    local latexmk_args=(
        -pdf
        -interaction=nonstopmode
        -synctex=1
        -silent
        -output-directory="$(build_engine_path "$build_dir")"
    )
    local rc_file=""
    rc_file="$(build_rc_file "$script_dir")"
    if [ -n "$rc_file" ]; then
        latexmk_args+=(-r "$rc_file")
    fi

    cd "$tex_dir" || return 1

    echo ""
    echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\033[1;36m  Compiling: \033[0m\033[36m$tex_file_name\033[0m"
    echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    if [ "$verbose" -eq 1 ]; then
        echo -e "  \033[2m[latexmk]\033[0m $latexmk_bin"
    fi

    local start_time end_time elapsed compile_status
    local capture_path=""
    capture_path="$(mktemp -t latexmk.XXXXXX 2>/dev/null || mktemp)"
    start_time="$(date +%s)"
    set +e
    if [ "$verbose" -eq 1 ]; then
        "$latexmk_bin" "${latexmk_args[@]}" "$tex_file_name"
        compile_status=$?
    else
        "$latexmk_bin" "${latexmk_args[@]}" "$tex_file_name" >"$capture_path" 2>&1
        compile_status=$?
    fi
    set -e
    end_time="$(date +%s)"
    elapsed=$((end_time - start_time))

    local pdf_path="$build_dir/$base_name.pdf"
    local log_path="$build_dir/$base_name.log"

    if [ -f "$pdf_path" ] && [ "$compile_status" -eq 0 ]; then
        build_report_success "$original_dir" "$pdf_path" "$log_path" "$base_name" "$elapsed"
        cd "$original_dir" || return 1
        return 0
    fi

    # latexmk can leave a partial PDF; still treat nonzero as failure.
    if [ -f "$pdf_path" ] && [ "$compile_status" -ne 0 ]; then
        build_report_failure "$log_path" "$capture_path"
        cd "$original_dir" || return 1
        return 1
    fi

    build_report_failure "$log_path" "$capture_path"
    cd "$original_dir" || return 1
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    verbose=0
    tex_file=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -v|--verbose)
                verbose=1
                ;;
            -h|--help)
                build_usage
                exit 0
                ;;
            --)
                shift
                if [ $# -gt 0 ]; then
                    tex_file="$1"
                fi
                break
                ;;
            -*)
                echo "Error: Unknown option: $1" >&2
                build_usage >&2
                exit 1
                ;;
            *)
                tex_file="$1"
                ;;
        esac
        shift
    done
    build_main "$tex_file" "$verbose"
fi

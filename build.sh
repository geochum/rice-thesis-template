#!/bin/bash
# Build script for Rice University Thesis (Bash version)
# Compiles LaTeX to a build directory (PDF and auxiliary files stay in .build/)
# Usage: ./build.sh [path/to/file.tex]
#        If no argument provided, checks for .tex files in the current directory

TEX_FILE="$1"

# Get the .tex file path from first argument or find one in current directory
if [ -z "$TEX_FILE" ]; then
    # Find all .tex files in current directory (portable: no mapfile)
    tex_files=()
    while IFS= read -r line; do
        tex_files+=("$line")
    done < <(find . -maxdepth 1 -name "*.tex" -type f | sort)
    
    if [ ${#tex_files[@]} -eq 0 ]; then
        TEX_FILE=""
    elif [ ${#tex_files[@]} -eq 1 ]; then
        # Only one file, use it (remove ./ prefix)
        TEX_FILE="${tex_files[0]#./}"
    else
        # Multiple files found - prompt user to choose (style matches compilation output)
        echo ""
        echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        echo -e "\033[1;36m  Select .tex file to build\033[0m"
        echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
        echo ""
        for i in "${!tex_files[@]}"; do
            echo -e "  \033[2m[$((i+1))]\033[0m \033[36m${tex_files[i]#./}\033[0m"
        done
        echo ""
        read -p "  Select (1-${#tex_files[@]}) or Enter to cancel: " selection
        
        if [ -z "$selection" ] || [ "$selection" = "q" ] || [ "$selection" = "Q" ]; then
            echo -e "\033[90mBuild cancelled.\033[0m"
            exit 0
        fi
        
        selected_index=$((selection - 1))
        if [ "$selected_index" -ge 0 ] 2>/dev/null && [ "$selected_index" -lt ${#tex_files[@]} ]; then
            TEX_FILE="${tex_files[$selected_index]#./}"
            echo -e "\033[32mSelected: $TEX_FILE\033[0m"
        else
            echo -e "\033[31mInvalid selection. Build cancelled.\033[0m"
            exit 1
        fi
    fi
fi

if [ -z "$TEX_FILE" ] || [ ! -f "$TEX_FILE" ]; then
    echo -e "\033[31mError: No .tex file found. Usage: ./build.sh [filename.tex]\033[0m"
    exit 1
fi

# Save the original directory to return to it later
ORIGINAL_DIR=$(pwd)

# Get absolute path and extract directory and basename
if command -v realpath >/dev/null 2>&1; then
    TEX_FILE_ABS=$(realpath "$TEX_FILE")
else
    # Fallback for systems without realpath (like older macOS)
    if [ -d "$TEX_FILE" ]; then
        TEX_FILE_ABS=$(cd "$TEX_FILE" && pwd)
    else
        TEX_FILE_ABS=$(cd "$(dirname "$TEX_FILE")" && pwd)/$(basename "$TEX_FILE")
    fi
fi
TEX_DIR=$(dirname "$TEX_FILE_ABS")
BASE_NAME=$(basename "$TEX_FILE_ABS" .tex)
BUILD_DIR="$TEX_DIR/.build"

# Create build directory and subdirs for \include{}/\subfile{} paths (LaTeX won't create parent dirs)
mkdir -p "$BUILD_DIR"
if [ -f "$TEX_FILE_ABS" ]; then
  grep -oE '\\(include|subfile)\{[^}]+\}' "$TEX_FILE_ABS" 2>/dev/null | \
  sed -E 's/.*\{([^}]+)\}/\1/' | \
  while read -r path; do
    dir=$(dirname "$path")
    if [ -n "$dir" ] && [ "$dir" != "." ]; then
      mkdir -p "$BUILD_DIR/$dir"
    fi
  done
fi

# Find project root (directory containing main.tex)
PROJECT_ROOT="$ORIGINAL_DIR"
while [ -n "$PROJECT_ROOT" ] && [ ! -f "$PROJECT_ROOT/main.tex" ]; do
    PARENT=$(dirname "$PROJECT_ROOT")
    # Stop if we've reached the root directory (dirname of / is still /)
    if [ "$PARENT" = "$PROJECT_ROOT" ]; then
        PROJECT_ROOT=""
        break
    fi
    PROJECT_ROOT="$PARENT"
done

# Change to the directory containing the .tex file for compilation
cd "$TEX_DIR" || exit 1

# Compile to build directory
TEX_FILE_NAME=$(basename "$TEX_FILE_ABS")
echo ""
echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[1;36m  Compiling: \033[0m\033[36m$TEX_FILE_NAME\033[0m"
echo -e "\033[1;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

# Set TEXINPUTS to include project root so subfiles can find included files
if [ -n "$PROJECT_ROOT" ]; then
    export TEXINPUTS="$PROJECT_ROOT:$TEXINPUTS"
    export BIBINPUTS="$PROJECT_ROOT:$BIBINPUTS"
fi

# Start timing
START_TIME=$(date +%s)

# Helper function to safely count pattern matches
count_pattern() {
    local pattern="$1"
    local file="$2"
    local count=0
    if [ -f "$file" ]; then
        # Use grep with wc -l to always get a number, even if 0 matches
        # xargs trims whitespace, ensuring we get a clean number
        count=$(grep -E "$pattern" "$file" 2>/dev/null | wc -l | xargs)
        # Ensure count is a valid number, default to 0 if not
        if ! [[ "$count" =~ ^[0-9]+$ ]]; then
            count=0
        fi
    fi
    echo "$count"
}

# First pass: pdflatex
echo -e "  \033[2m[1/3]\033[0m Running pdflatex..."
pdflatex -output-directory="$BUILD_DIR" -interaction=nonstopmode -synctex=1 "$TEX_FILE_NAME" >/dev/null 2>&1

# Check if bibliography needs to be compiled (for main.tex or files using natbib)
if [ "$TEX_FILE_NAME" = "main.tex" ] || [ "$BASE_NAME" = "main" ]; then
    echo -e "  \033[2m[   ]\033[0m Running bibtex..."
    bibtex -output-directory="$BUILD_DIR" "$BASE_NAME" >/dev/null 2>&1
fi

# Second pass: pdflatex (to incorporate bibliography)
echo -e "  \033[2m[2/3]\033[0m Running pdflatex..."
pdflatex -output-directory="$BUILD_DIR" -interaction=nonstopmode -synctex=1 "$TEX_FILE_NAME" >/dev/null 2>&1

# Third pass: pdflatex (to resolve all references)
echo -e "  \033[2m[3/3]\033[0m Running pdflatex..."
pdflatex -output-directory="$BUILD_DIR" -interaction=nonstopmode -synctex=1 "$TEX_FILE_NAME" >/dev/null 2>&1

# Check if PDF was created
PDF_PATH="$BUILD_DIR/$BASE_NAME.pdf"
LOG_PATH="$BUILD_DIR/$BASE_NAME.log"

if [ -f "$PDF_PATH" ]; then
    # Calculate compilation time (integer seconds)
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    
    # Get PDF size (format to match du -h output: "200K" or "1.2M")
    SIZE_BYTES=$(stat -f%z "$PDF_PATH" 2>/dev/null || stat -c%s "$PDF_PATH" 2>/dev/null)
    if [ -z "$SIZE_BYTES" ]; then
        PDF_SIZE=""
    elif [ "$SIZE_BYTES" -lt 1024 ]; then
        PDF_SIZE="${SIZE_BYTES}"
    elif [ "$SIZE_BYTES" -lt 1048576 ]; then
        PDF_SIZE="$((SIZE_BYTES / 1024))K"
    else
        # Calculate MB with one decimal place, using awk if bc is not available
        if command -v bc >/dev/null 2>&1; then
            SIZE_MB=$(echo "scale=1; $SIZE_BYTES / 1048576" | bc)
            PDF_SIZE=$(echo "$SIZE_MB" | sed 's/\.0$//')M
        else
            # Fallback using awk for floating point division
            SIZE_MB=$(awk "BEGIN {printf \"%.1f\", $SIZE_BYTES / 1048576}")
            PDF_SIZE=$(echo "$SIZE_MB" | sed 's/\.0$//')M
        fi
    fi
    
    # Try to get page count (multiple methods for compatibility)
    PAGE_COUNT=""
    if command -v pdfinfo >/dev/null 2>&1; then
        PAGE_COUNT=$(pdfinfo "$PDF_PATH" 2>/dev/null | grep "^Pages:" | awk '{print $2}')
    elif command -v pdftk >/dev/null 2>&1; then
        PAGE_COUNT=$(pdftk "$PDF_PATH" dump_data 2>/dev/null | grep "NumberOfPages" | awk '{print $2}')
    fi
    
    # Parse log file for errors and warnings
    if [ -f "$LOG_PATH" ]; then
        ERROR_COUNT=$(count_pattern "^!" "$LOG_PATH")
        # Count all types of warnings: LaTeX warnings, package warnings, overfull/underfull boxes, font issues, missing characters
        WARNING_COUNT=0
        count=$(count_pattern "^LaTeX Warning:" "$LOG_PATH"); WARNING_COUNT=$((WARNING_COUNT + ${count:-0}))
        count=$(count_pattern "^Package .* Warning:" "$LOG_PATH"); WARNING_COUNT=$((WARNING_COUNT + ${count:-0}))
        count=$(count_pattern "^Overfull" "$LOG_PATH"); WARNING_COUNT=$((WARNING_COUNT + ${count:-0}))
        count=$(count_pattern "^Underfull" "$LOG_PATH"); WARNING_COUNT=$((WARNING_COUNT + ${count:-0}))
        count=$(count_pattern "^Font shape" "$LOG_PATH"); WARNING_COUNT=$((WARNING_COUNT + ${count:-0}))
        count=$(count_pattern "^Missing character" "$LOG_PATH"); WARNING_COUNT=$((WARNING_COUNT + ${count:-0}))
        
        echo ""
        echo -e "\033[1;32m✓ Success\033[0m"
        
        # One-line summary: filename · pages · size · time
        SUMMARY="$BASE_NAME.pdf"
        [ -n "$PAGE_COUNT" ] && SUMMARY="$SUMMARY · ${PAGE_COUNT} page(s)"
        [ -n "$PDF_SIZE" ]  && SUMMARY="$SUMMARY · $PDF_SIZE"
        [ "$ELAPSED" -gt 0 ] && SUMMARY="$SUMMARY · ${ELAPSED}s"
        echo -e "  \033[2m$SUMMARY\033[0m"
        echo ""
        
        # Short path for display: relative to ORIGINAL_DIR if under it, else basename
        if [[ "$PDF_PATH" == "$ORIGINAL_DIR"* ]]; then
            DISPLAY_PATH="${PDF_PATH#$ORIGINAL_DIR/}"
        else
            DISPLAY_PATH="$BASE_NAME.pdf (in .build/)"
        fi
        echo -e "  \033[1mOutput:\033[0m"
        echo -e "    \033[2mFile:\033[0m   $DISPLAY_PATH"
        [ -n "$PAGE_COUNT" ] && printf "    \033[2m%-6s\033[0m %s\n" "Pages:" "$PAGE_COUNT"
        [ -n "$PDF_SIZE" ]  && printf "    \033[2m%-6s\033[0m %s\n" "Size:"  "$PDF_SIZE"
        [ "$ELAPSED" -gt 0 ] && printf "    \033[2m%-6s\033[0m %s\n" "Time:"  "${ELAPSED}s"
        
        # Show warnings/errors if present
        if [ "$ERROR_COUNT" -gt 0 ] || [ "$WARNING_COUNT" -gt 0 ]; then
            echo ""
            echo -e "  \033[1;33m⚠ Issues:\033[0m"
            [ "$ERROR_COUNT" -gt 0 ]   && echo -e "    \033[31mErrors:\033[0m   $ERROR_COUNT"
            [ "$WARNING_COUNT" -gt 0 ]  && echo -e "    \033[33mWarnings:\033[0m $WARNING_COUNT"
            echo -e "    \033[2mLog:\033[0m     $LOG_PATH"
        fi
    else
        echo ""
        echo -e "\033[1;32m✓ Success\033[0m"
        SUMMARY="$BASE_NAME.pdf"
        [ -n "$PDF_SIZE" ] && SUMMARY="$SUMMARY · $PDF_SIZE"
        echo -e "  \033[2m$SUMMARY\033[0m"
        echo ""
        if [[ "$PDF_PATH" == "$ORIGINAL_DIR"* ]]; then
            DISPLAY_PATH="${PDF_PATH#$ORIGINAL_DIR/}"
        else
            DISPLAY_PATH="$BASE_NAME.pdf (in .build/)"
        fi
        echo -e "  \033[1mOutput:\033[0m"
        echo -e "    \033[2mFile:\033[0m   $DISPLAY_PATH"
        [ -n "$PDF_SIZE" ] && printf "    \033[2m%-6s\033[0m %s\n" "Size:" "$PDF_SIZE"
    fi
else
    echo ""
    echo -e "\033[1;31m✗ Compilation Failed\033[0m"
    echo ""
    if [ -f "$LOG_PATH" ]; then
        ERROR_COUNT=$(count_pattern "^!" "$LOG_PATH")
        # Count all types of warnings: LaTeX warnings, package warnings, overfull/underfull boxes, font issues, missing characters
        WARNING_COUNT=0
        count=$(count_pattern "^LaTeX Warning:" "$LOG_PATH"); WARNING_COUNT=$((WARNING_COUNT + ${count:-0}))
        count=$(count_pattern "^Package .* Warning:" "$LOG_PATH"); WARNING_COUNT=$((WARNING_COUNT + ${count:-0}))
        count=$(count_pattern "^Overfull" "$LOG_PATH"); WARNING_COUNT=$((WARNING_COUNT + ${count:-0}))
        count=$(count_pattern "^Underfull" "$LOG_PATH"); WARNING_COUNT=$((WARNING_COUNT + ${count:-0}))
        count=$(count_pattern "^Font shape" "$LOG_PATH"); WARNING_COUNT=$((WARNING_COUNT + ${count:-0}))
        count=$(count_pattern "^Missing character" "$LOG_PATH"); WARNING_COUNT=$((WARNING_COUNT + ${count:-0}))
        
        echo -e "  \033[1mIssues Found:\033[0m"
        if [ "$ERROR_COUNT" -gt 0 ]; then
            echo -e "    \033[31mErrors:\033[0m   $ERROR_COUNT"
        fi
        if [ "$WARNING_COUNT" -gt 0 ]; then
            echo -e "    \033[33mWarnings:\033[0m $WARNING_COUNT"
        fi
        echo -e "    \033[2mLog:\033[0m      $LOG_PATH"
    else
        echo -e "  \033[2mLog file not found: $LOG_PATH\033[0m"
    fi
    echo ""
    cd "$ORIGINAL_DIR" || exit 1
    exit 1
fi

# Return to the original directory
cd "$ORIGINAL_DIR" || exit 1

#!/usr/bin/env bash
set -euo pipefail

# --- Constants ---
DRY_RUN="false"
SOURCE_DIR=""
TARGET_DIR=""
ARTIFACT_GLOB="**/*"

# --- Error handling ---
handle_error() {
    local line_no=$1
    local command=$2
    echo "ERROR: Command '$command' failed at line $line_no" >&2
    exit 1
}
trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

# --- Dry-run wrapper ---
run() {
    if [[ $DRY_RUN == "true" ]]; then
        echo "[DRY-RUN] $*"
        return 0
    fi
    "$@"
}

# --- Usage ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Sign Windows artifacts (.exe, .msi, .msix) with SSL.com eSigner CodeSignTool.
Non-Windows files are copied through unchanged.

Options:
  --source-dir DIR       Directory containing unsigned artifacts (required)
  --target-dir DIR       Output directory for signed artifacts (required)
  --artifact-glob GLOB   Glob pattern for files to consider for signing (default: **/*).
                         Controls signing scope only; the full tree is always copied.
  --dry-run              Print commands without executing
  --help                 Show this help message

Environment variables (required when not dry-run):
  ES_USERNAME       SSL.com account username
  ES_PASSWORD       SSL.com account password
  CREDENTIAL_ID     eSigner credential ID
  ES_TOTP_SECRET    TOTP secret for automated OTP

Environment variables (optional):
  ESIGNER_PROGRAM_NAME   Passed to CodeSignTool as -program_name for MSI (UAC display name)
  CODESIGNTOOL           Path to CodeSignTool (CodeSignTool.bat on Windows, CodeSignTool.sh on Linux/macOS)

Examples:
  entrypoint.sh --source-dir unsigned-artifacts --target-dir signed-output
  entrypoint.sh --source-dir unsigned-artifacts --target-dir signed-output --artifact-glob '*.exe'
  entrypoint.sh --source-dir unsigned-artifacts --target-dir signed-output --dry-run
EOF
}

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
    --source-dir)
        SOURCE_DIR="$2"
        shift 2
        ;;
    --target-dir)
        TARGET_DIR="$2"
        shift 2
        ;;
    --artifact-glob)
        ARTIFACT_GLOB="$2"
        shift 2
        ;;
    --dry-run)
        DRY_RUN="true"
        shift
        ;;
    --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
done

# --- Validation ---
if [[ -z $SOURCE_DIR ]]; then
    echo "ERROR: --source-dir is required" >&2
    exit 1
fi
if [[ -z $TARGET_DIR ]]; then
    echo "ERROR: --target-dir is required" >&2
    exit 1
fi
if [[ ! -d $SOURCE_DIR ]]; then
    echo "ERROR: Source directory does not exist: $SOURCE_DIR" >&2
    exit 1
fi

if [[ $DRY_RUN != "true" ]]; then
    for var in ES_USERNAME ES_PASSWORD CREDENTIAL_ID ES_TOTP_SECRET; do
        if [[ -z ${!var-} ]]; then
            echo "ERROR: $var environment variable is required (or use --dry-run)" >&2
            exit 1
        fi
    done
fi

resolve_codesigntool() {
    if [[ -n ${CODESIGNTOOL-} ]]; then
        echo "$CODESIGNTOOL"
        return
    fi
    if command -v CodeSignTool.bat >/dev/null 2>&1; then
        command -v CodeSignTool.bat
        return
    fi
    if command -v CodeSignTool.sh >/dev/null 2>&1; then
        command -v CodeSignTool.sh
        return
    fi
    echo "ERROR: CodeSignTool not found. Set CODESIGNTOOL or install CodeSignTool.bat / CodeSignTool.sh on PATH." >&2
    exit 1
}

# --- Glob matching (same semantics as sign-mac-artifacts) ---
matches_glob() {
    local file="$1"
    local pattern="$2"

    if [[ $pattern == "**/*" ]]; then
        return 0
    fi

    local filename
    filename=$(basename "$file")

    # shellcheck disable=SC2254
    case "$filename" in
    $pattern) return 0 ;;
    esac

    # shellcheck disable=SC2254
    case "$file" in
    $pattern) return 0 ;;
    esac

    return 1
}

lower_ext() {
    local f="$1"
    local ext="${f##*.}"
    if [[ $ext == "$f" ]]; then
        echo ""
        return
    fi
    echo "$ext" | tr '[:upper:]' '[:lower:]'
}

sign_one_file() {
    local file="$1"
    local ext
    ext=$(lower_ext "$file")

    local cst
    if [[ $DRY_RUN == "true" ]]; then
        cst="${CODESIGNTOOL-}"
        if [[ -z $cst ]]; then
            case "$(uname -s 2>/dev/null)" in
            MINGW* | MSYS* | CYGWIN*) cst="CodeSignTool.bat" ;;
            *) cst="CodeSignTool.sh" ;;
            esac
        fi
    else
        cst=$(resolve_codesigntool)
    fi

    local -a cmd
    cmd=(
        "$cst" sign
        "-username=$ES_USERNAME"
        "-password=$ES_PASSWORD"
        "-credential_id=$CREDENTIAL_ID"
        "-input_file_path=$file"
        "-totp_secret=$ES_TOTP_SECRET"
    )
    if [[ $ext == "msi" && -n ${ESIGNER_PROGRAM_NAME-} ]]; then
        cmd+=("-program_name=$ESIGNER_PROGRAM_NAME")
    fi

    if [[ $DRY_RUN == "true" ]]; then
        echo "[DRY-RUN] $cst sign -username=*** -password=*** -credential_id=*** -input_file_path=$file -totp_secret=*** -output_dir_path=<tmpdir>"
        if [[ $ext == "msi" && -n ${ESIGNER_PROGRAM_NAME-} ]]; then
            echo "[DRY-RUN]   -program_name=$ESIGNER_PROGRAM_NAME"
        fi
        return 0
    fi

    local outdir
    outdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$outdir'" RETURN
    cmd+=("-output_dir_path=$outdir")

    echo "  Running CodeSignTool sign for: $file"
    run "${cmd[@]}"

    local base outpath
    base=$(basename "$file")
    outpath="$outdir/$base"
    if [[ ! -f $outpath ]]; then
        echo "ERROR: Expected signed output not found: $outpath" >&2
        exit 1
    fi
    mv -f "$outpath" "$file"
}

# --- Main ---
main() {
    local cst_display
    cst_display="${CODESIGNTOOL-}"
    if [[ -z $cst_display ]]; then
        case "$(uname -s 2>/dev/null)" in
        MINGW* | MSYS* | CYGWIN*) cst_display="CodeSignTool.bat (PATH)" ;;
        *) cst_display="CodeSignTool.sh (PATH)" ;;
        esac
    fi

    echo "============================================"
    echo "Windows Artifact Signing (eSigner)"
    echo "============================================"
    echo "Source directory: $SOURCE_DIR"
    echo "Target directory: $TARGET_DIR"
    echo "Artifact glob:   $ARTIFACT_GLOB"
    echo "Dry run:         $DRY_RUN"
    echo "CodeSignTool:    $cst_display"
    echo "MSI program name: ${ESIGNER_PROGRAM_NAME:-<not set>}"
    echo "============================================"

    echo "==> Copying full artifact tree to $TARGET_DIR"
    mkdir -p "$TARGET_DIR"
    if [[ -n "$(ls -A "$SOURCE_DIR" 2>/dev/null)" ]]; then
        cp -R "$SOURCE_DIR"/* "$TARGET_DIR/"
    else
        echo "WARNING: Source directory is empty: $SOURCE_DIR" >&2
        return 0
    fi

    echo "==> Artifact tree contents:"
    find "$TARGET_DIR" -type f | sort

    local signed_count=0
    local skipped_count=0

    echo "==> Processing artifacts for signing"
    while IFS= read -r file; do
        if [[ $file =~ \.(asc|sha256)$ ]]; then
            continue
        fi

        local relative_path="${file#"$TARGET_DIR"/}"
        if ! matches_glob "$relative_path" "$ARTIFACT_GLOB"; then
            ((skipped_count++)) || true
            continue
        fi

        local ext
        ext=$(lower_ext "$file")

        case "$ext" in
        exe | msi | msix)
            echo ""
            echo "--- Processing .$ext: $relative_path ---"
            sign_one_file "$file"
            ((signed_count++)) || true
            ;;
        *)
            ((skipped_count++)) || true
            ;;
        esac
    done < <(find "$TARGET_DIR" -type f | sort)

    echo ""
    echo "============================================"
    echo "Signing complete"
    echo "  Files signed:       $signed_count"
    echo "  Files skipped:      $skipped_count (glob mismatch or non-Windows types)"
    echo "============================================"
}

main

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
                         Use a single pattern, or several comma-separated patterns (optional spaces),
                         e.g. '*.exe,*.msi,*.msix'. Controls signing scope only; the full tree is always copied.
  --dry-run              Print commands without executing
  --help                 Show this help message

Environment variables (required when not dry-run):
  ES_OV_USERNAME       SSL.com account username (OV / Authenticode signing)
  ES_OV_PASSWORD       SSL.com account password
  ES_OV_CREDENTIAL_ID  eSigner credential ID
  ES_OV_TOTP_SECRET    TOTP secret for automated OTP

Environment variables (optional):
  ESIGNER_PROGRAM_NAME   Passed to CodeSignTool as -program_name for MSI (UAC display name)
  CODESIGNTOOL           Path to CodeSignTool (CodeSignTool.bat on Windows, CodeSignTool.sh on Linux/macOS)
  CODE_SIGN_TOOL_PATH    (Windows .bat only) Absolute Windows path to the extracted CodeSignTool bundle root
                         (directory that contains jdk-*, jar/, CodeSignTool.bat). Required when the process
                         cwd is not that directory; reusable_sign-win-artifacts sets this after unzip.

Examples:
  entrypoint.sh --source-dir unsigned-artifacts --target-dir signed-output
  entrypoint.sh --source-dir unsigned-artifacts --target-dir signed-output --artifact-glob '*.exe,*.msi,*.msix'
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
    for var in ES_OV_USERNAME ES_OV_PASSWORD ES_OV_CREDENTIAL_ID ES_OV_TOTP_SECRET; do
        if [[ -z ${!var-} ]]; then
            echo "ERROR: $var environment variable is required (or use --dry-run)" >&2
            exit 1
        fi
    done
fi

# CodeSignTool.bat runs a Windows JVM: -input_file_path / -output_dir_path must be
# absolute Windows paths. cygpath -w alone keeps relative paths relative; the JVM
# then resolves them against the wrong working directory ("path not specified").
codesigntool_path_for_args() {
    local p="$1"
    case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*)
        if command -v cygpath >/dev/null 2>&1; then
            cygpath -wa "$p" 2>/dev/null || cygpath -w "$p" 2>/dev/null || echo "$p"
        else
            echo "$p"
        fi
        ;;
    *)
        echo "$p"
        ;;
    esac
}

# Prefer MSYS-style path so bash can exec CodeSignTool.bat without mixed D:\.../... segments.
normalize_codesigntool_exe() {
    local c="$1"
    case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*)
        if command -v cygpath >/dev/null 2>&1 && [[ -f $c ]]; then
            cygpath -u "$c" 2>/dev/null || echo "$c"
        else
            echo "$c"
        fi
        ;;
    *)
        echo "$c"
        ;;
    esac
}

resolve_codesigntool() {
    local c=""
    if [[ -n ${CODESIGNTOOL-} ]]; then
        c="$CODESIGNTOOL"
    elif command -v CodeSignTool.bat >/dev/null 2>&1; then
        c=$(command -v CodeSignTool.bat)
    elif command -v CodeSignTool.sh >/dev/null 2>&1; then
        c=$(command -v CodeSignTool.sh)
    else
        echo "ERROR: CodeSignTool not found. Set CODESIGNTOOL or install CodeSignTool.bat / CodeSignTool.sh on PATH." >&2
        exit 1
    fi

    normalize_codesigntool_exe "$c"
}

# --- Glob matching (same semantics as sign-mac-artifacts, plus comma-separated alternates) ---
_matches_single_glob() {
    local file="$1"
    local pattern="$2"

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

matches_glob() {
    local file="$1"
    local pattern="$2"

    if [[ $pattern == "**/*" ]]; then
        return 0
    fi

    # Multiple patterns: comma-separated (e.g. "*.exe,*.msi,*.msix")
    if [[ $pattern == *","* ]]; then
        local IFS=,
        local -a parts
        read -ra parts <<<"$pattern"
        local p trimmed
        for p in "${parts[@]}"; do
            trimmed="${p#"${p%%[![:space:]]*}"}"
            trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
            [[ -z $trimmed ]] && continue
            if matches_glob "$file" "$trimmed"; then
                return 0
            fi
        done
        return 1
    fi

    _matches_single_glob "$file" "$pattern"
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

# CodeSignTool / Java Authenticode expects real Windows binaries. Placeholders (e.g. /dev/zero)
# fail with: java.io.IOException: DOS header signature not found
preflight_windows_signable() {
    local path="$1"
    local ext="$2"
    case "$ext" in
    exe)
        if ! printf '\x4d\x5a' | cmp -s -n 2 - "$path" 2>/dev/null; then
            echo "ERROR: Not a valid PE executable (missing MZ DOS header): $path" >&2
            echo "Authenticode (.exe) requires a real Windows binary (e.g. MSVC or MinGW), not empty or arbitrary bytes." >&2
            return 1
        fi
        ;;
    msi)
        if ! printf '\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1' | cmp -s -n 8 - "$path" 2>/dev/null; then
            echo "ERROR: Not a valid MSI (missing compound file / structured storage header): $path" >&2
            echo "Authenticode (.msi) requires a real Windows Installer database." >&2
            return 1
        fi
        ;;
    msix)
        if ! printf '\x50\x4b\x03\x04' | cmp -s -n 4 - "$path" 2>/dev/null; then
            echo "ERROR: Not a valid MSIX package (expected ZIP local file header at offset 0): $path" >&2
            echo "Authenticode (.msix) requires a real MSIX (OPC / ZIP-based) file." >&2
            return 1
        fi
        ;;
    esac
    return 0
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
        echo "[DRY-RUN] $cst sign -username=*** -password=*** -credential_id=*** -input_file_path=$file -totp_secret=*** -output_dir_path=<tmpdir>"
        if [[ $ext == "msi" && -n ${ESIGNER_PROGRAM_NAME-} ]]; then
            echo "[DRY-RUN]   -program_name=$ESIGNER_PROGRAM_NAME"
        fi
        return 0
    fi

    cst=$(resolve_codesigntool)
    preflight_windows_signable "$file" "$ext" || exit 1

    local outdir
    case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*)
        if [[ -n ${RUNNER_TEMP-} ]]; then
            outdir="${RUNNER_TEMP}/signwin-out-$$-${RANDOM}"
            mkdir -p "$outdir"
        else
            outdir=$(mktemp -d)
        fi
        ;;
    *)
        outdir=$(mktemp -d)
        ;;
    esac
    # shellcheck disable=SC2064
    trap "rm -rf '$outdir'" RETURN

    local win_file win_outdir
    win_file=$(codesigntool_path_for_args "$file")
    win_outdir=$(codesigntool_path_for_args "$outdir")

    local -a cmd
    cmd=(
        "$cst" "sign"
        "-username=${ES_OV_USERNAME}"
        "-password=${ES_OV_PASSWORD}"
        "-credential_id=${ES_OV_CREDENTIAL_ID}"
        "-input_file_path=${win_file}"
        "-totp_secret=${ES_OV_TOTP_SECRET}"
    )
    if [[ $ext == "msi" && -n ${ESIGNER_PROGRAM_NAME-} ]]; then
        cmd+=("-program_name=${ESIGNER_PROGRAM_NAME}")
    fi

    cmd+=("-output_dir_path=${win_outdir}")

    # CodeSignTool.bat runs .\jdk-11...\java when CODE_SIGN_TOOL_PATH is unset; cwd is usually the repo root.
    case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*)
        if [[ ${cst,,} == *.bat ]]; then
            export CODE_SIGN_TOOL_PATH
            CODE_SIGN_TOOL_PATH=$(codesigntool_path_for_args "$(dirname "$cst")")
        fi
        ;;
    esac

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

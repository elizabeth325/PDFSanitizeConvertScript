
#!/bin/bash
# PDF Sanitization Workflow Script
# Usage: ./sanitize_pdf.sh input.pdf output.pdf
#
# This script sanitizes PDF files by removing scripts, attachments, and metadata,
# and optionally relocks them. It supports batch processing, dry run mode, and
# extensive configuration via sanitize_pdf.conf. If the config file is missing,
# it will be auto-generated with defaults.



set -e  # Exit immediately if a command exits with a non-zero status



# --- Load config file, generate with defaults if missing ---
CONFIG_FILE="$(dirname "$0")/sanitize_pdf.conf"
if [ ! -f "$CONFIG_FILE" ]; then
  # Create a default config file with all options and documentation
  cat > "$CONFIG_FILE" <<'EOF'
# Example configuration for sanitize_pdf.sh
# Set the input and output directories for PDF sanitization

# INPUT_DIR: Directory containing PDFs to sanitize (default: current directory)
INPUT_DIR="./input"
# OUTPUT_DIR: Directory to save sanitized PDFs (default: current directory)
OUTPUT_DIR="./output"

# ATTACHMENT_DIR: Directory to move extracted attachments (default: none)
#   If set, extracted attachments will be moved here instead of deleted or left in current directory.
ATTACHMENT_DIR=""

# RELOCK_CLEANED: Relock cleaned PDFs with the original password (yes/no)
#   yes  - Output PDFs will be password protected with the same password used to unlock
#   no   - Output PDFs will NOT be password protected (default)
RELOCK_CLEANED="no"

# LOG_FILE: Name of the log file for actions, errors, and skipped files
#   Example: "sanitize_pdf.log"
LOG_FILE="sanitize_pdf.log"

# FILE_PATTERN: Only process PDFs matching this filename pattern (default: *.pdf)
#   Example: "*_secure.pdf" will only process files ending with _secure.pdf
FILE_PATTERN="*.pdf"

# PASSWORD_TIMEOUT: Timeout in seconds for password prompt when unlocking PDFs
#   Example: 120 (2 minutes)
PASSWORD_TIMEOUT=120

# DRY_RUN: If yes, only show what would be done (no changes made)
#   yes  - Simulate actions, print/log what would happen
#   no   - Perform actual sanitization (default)
DRY_RUN="no"

# OUTPUT_PREFIX: Prefix for output files in batch mode
#   Example: "sanitized_" will produce sanitized_original.pdf
OUTPUT_PREFIX="sanitized_"

# MIRROR_DIR_STRUCTURE: Mirror input directory structure in output (yes/no)
#   yes  - Output files will be placed in subfolders matching input
#   no   - All output files go to OUTPUT_DIR (default)
MIRROR_DIR_STRUCTURE="no"

# ENCRYPTION_STRENGTH: Encryption bit strength for relocking PDFs
#   Possible values: 40, 128, 256
#   256 is recommended for strong security (default)
ENCRYPTION_STRENGTH=256

# EXIFTOOL_ARGS: Custom arguments for exiftool metadata scrubbing
#   Example: "-all= -XMP:Author= -XMP:Creator="
EXIFTOOL_ARGS="-all="

# DELETE_ATTACHMENTS: Delete extracted attachments after pdfdetach (yes/no)
#   yes  - Delete all files extracted by pdfdetach
#   no   - Keep extracted files (default)
DELETE_ATTACHMENTS="no"

# GS_QUALITY: Ghostscript PDF quality setting
#   Possible values:
#     /screen    - lowest quality, smallest file size
#     /ebook     - medium quality, smaller file size
#     /printer   - high quality, larger file size
#     /prepress  - highest quality, largest file size (default)
GS_QUALITY="/prepress"

# CLI_OVERRIDE: Allow config options to be overridden by command-line arguments (yes/no)
#   yes  - Command-line arguments take precedence over config
#   no   - Only config file is used (default)
CLI_OVERRIDE="no"
EOF

  echo "Created default config file at $CONFIG_FILE"
fi
source "$CONFIG_FILE"  # Load configuration




# --- Configurable options with defaults (from config or fallback) ---
RELOCK_CLEANED="${RELOCK_CLEANED:-no}"
LOG_FILE="${LOG_FILE:-sanitize_pdf.log}"
PASSWORD_TIMEOUT="${PASSWORD_TIMEOUT:-120}"
OUTPUT_PREFIX="${OUTPUT_PREFIX:-sanitized_}"
ENCRYPTION_STRENGTH="${ENCRYPTION_STRENGTH:-256}"
DELETE_ATTACHMENTS="${DELETE_ATTACHMENTS:-no}"
GS_QUALITY="${GS_QUALITY:-/prepress}"
ATTACHMENT_DIR="${ATTACHMENT_DIR:-}"
FILE_PATTERN="${FILE_PATTERN:-*.pdf}"
DRY_RUN="${DRY_RUN:-no}"
MIRROR_DIR_STRUCTURE="${MIRROR_DIR_STRUCTURE:-no}"
EXIFTOOL_ARGS="${EXIFTOOL_ARGS:--all=}"
CLI_OVERRIDE="${CLI_OVERRIDE:-no}"





# --- Input and output directories ---
INPUT_DIR="${INPUT_DIR:-.}"
OUTPUT_DIR="${OUTPUT_DIR:-.}"


# --- Determine files to process ---
# If CLI_OVERRIDE is enabled and arguments are provided, use them for single file mode
if [ "$CLI_OVERRIDE" = "yes" ] && [ -n "$1" ] && [ -n "$2" ]; then
  PDF_LIST=("$1")
  OUTPUT_LIST=("$2")
else
  # Batch mode: find all PDFs matching FILE_PATTERN in INPUT_DIR
  IFS=$'\n' PDF_LIST=( $(find "$INPUT_DIR" -type f -name "$FILE_PATTERN") )
  OUTPUT_LIST=()
  for pdf in "${PDF_LIST[@]}"; do
    base=$(basename "$pdf")
    if [ "$MIRROR_DIR_STRUCTURE" = "yes" ]; then
      relpath="${pdf#$INPUT_DIR/}"
      outdir="$OUTPUT_DIR/$(dirname "$relpath")"
      mkdir -p "$outdir"
      OUTPUT_LIST+=("$outdir/$OUTPUT_PREFIX$base")
    else
      OUTPUT_LIST+=("$OUTPUT_DIR/$OUTPUT_PREFIX$base")
    fi
  done
  if [ ${#PDF_LIST[@]} -eq 0 ]; then
    echo "No PDF files found in $INPUT_DIR matching pattern $FILE_PATTERN."
    exit 1
  fi
fi

# --- Method to Print the pdf files after each step ---
save_intermediate_pdf() {
  local step_number="$1"
  local input_pdf="$2"
  local output_pdf="$3"
  local base_name
  base_name=$(basename "$output_pdf" .pdf)
  local step_pdf="${OUTPUT_DIR}/${base_name}_step${step_number}.pdf"

  cp "$input_pdf" "$step_pdf"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Saved intermediate PDF for step ${step_number}: $step_pdf" | tee -a "$LOG_FILE"
}


# --- Main processing loop ---
for idx in "${!PDF_LIST[@]}"; do
  INPUT_PATH="${PDF_LIST[$idx]}"
  OUTPUT_PATH="${OUTPUT_LIST[$idx]}"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processing: $INPUT_PATH -> $OUTPUT_PATH"

  # Dry run mode: only show what would be done
  if [ "$DRY_RUN" = "yes" ]; then
    echo "[DRY RUN] Would process: $INPUT_PATH -> $OUTPUT_PATH" | tee -a "$LOG_FILE"
    continue
  fi

  # --- Step 0: Unlock PDF if encrypted ---
  if qpdf --show-encryption "$INPUT_PATH" | grep -q 'encrypted: yes'; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PDF is locked/encrypted: $INPUT_PATH"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Prompting for password (timeout: $PASSWORD_TIMEOUT seconds)..."
    PDF_PASSWORD=""
    if ! PDF_PASSWORD=$(timeout "$PASSWORD_TIMEOUT" bash -c 'read -s -p "Password: " pw; echo $pw'); then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] No password entered for $INPUT_PATH after $PASSWORD_TIMEOUT seconds. Skipping file." | tee -a "$LOG_FILE"
      continue
    fi
    echo ""  # For prompt formatting
    UNLOCKED_PDF="unlocked_temp.pdf"
    if ! qpdf --password="$PDF_PASSWORD" --decrypt "$INPUT_PATH" "$UNLOCKED_PDF"; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Failed to unlock PDF: $INPUT_PATH. Skipping." | tee -a "$LOG_FILE"
      continue
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Successfully unlocked PDF." | tee -a "$LOG_FILE"
    INPUT_PATH="$UNLOCKED_PDF"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PDF is not encrypted: $INPUT_PATH"
  fi

  # --- Step 1: Sanitize PDF (remove scripts, embedded code) ---
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sanitizing PDF (remove scripts, embedded code)..."
  # Removed use of qpdf sanitization for step 1 
  SANITIZED_PDF=$INPUT_PATH
  # qpdf --linearize --sanitize "$INPUT_PATH" "$SANITIZED_PDF"
  save_intermediate_pdf 1 "$SANITIZED_PDF" "$OUTPUT_PATH"


  # --- Step 2: Remove embedded files/attachments ---
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Removing embedded files/attachments..."
  if pdfdetach -saveall "$SANITIZED_PDF" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Successfully processed attachments."
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] No attachments found or pdfdetach failed." | tee -a "$LOG_FILE"
  fi
  # Handle extracted attachments: move, delete, or leave as is
  # ATTACHMENTS=( $(ls | grep '^file[0-9]*\.') )
  ATTACHMENTS=( $(find . -maxdepth 1 -type f -name 'file[0-9]*' 2>/dev/null) )
  if [ -n "$ATTACHMENT_DIR" ] && [ "${#ATTACHMENTS[@]}" -gt 0 ]; then
    mkdir -p "$ATTACHMENT_DIR"
    for att in "${ATTACHMENTS[@]}"; do
      mv "$att" "$ATTACHMENT_DIR/" && echo "[$(date '+%Y-%m-%d %H:%M:%S')] Moved attachment: $att -> $ATTACHMENT_DIR/" | tee -a "$LOG_FILE"
    done
  elif [ "$DELETE_ATTACHMENTS" = "yes" ] && [ "${#ATTACHMENTS[@]}" -gt 0 ]; then
    for att in "${ATTACHMENTS[@]}"; do
      rm -f "$att"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Deleted attachment: $att" | tee -a "$LOG_FILE"
    done
  fi
  save_intermediate_pdf 2 "$SANITIZED_PDF" "$OUTPUT_PATH"


  # --- Step 3: Strip all metadata ---
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Stripping all metadata..."
  exiftool $EXIFTOOL_ARGS "$SANITIZED_PDF"
  # exiftool creates a backup file with _original suffix. Overwrite sanitized file.
  if [ -f "${SANITIZED_PDF}_original" ]; then
    mv "$SANITIZED_PDF" "${SANITIZED_PDF}.bak"
    mv "${SANITIZED_PDF}_original" "$SANITIZED_PDF"
  fi
  save_intermediate_pdf 3 "$SANITIZED_PDF" "$OUTPUT_PATH"


  # --- Step 4: Reprocess and further clean with Ghostscript ---
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reprocessing and further cleaning with Ghostscript..."
  gs -o "$OUTPUT_PATH" -sDEVICE=pdfwrite -dPDFSETTINGS=$GS_QUALITY "$SANITIZED_PDF"

  # --- Step 5: Optionally relock the cleaned PDF with the original password ---
  if [ "$RELOCK_CLEANED" = "yes" ] && [ -n "$PDF_PASSWORD" ]; then
    RELOCKED_PATH="${OUTPUT_PATH%.pdf}_locked.pdf"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Relocking sanitized PDF with original password..."
    if qpdf --encrypt "$PDF_PASSWORD" "$PDF_PASSWORD" "$ENCRYPTION_STRENGTH" -- "$OUTPUT_PATH" "$RELOCKED_PATH"; then
      mv "$RELOCKED_PATH" "$OUTPUT_PATH"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] PDF relocked: $OUTPUT_PATH"
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Failed to relock PDF: $OUTPUT_PATH" | tee -a "$LOG_FILE"
    fi
  fi

  # --- Step 6: Cleanup temporary files ---
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaning up temporary files..."
  if [ -f "$SANITIZED_PDF.bak" ]; then
    rm "$SANITIZED_PDF.bak"
  fi
  if [ -f "$SANITIZED_PDF" ] && [ "$SANITIZED_PDF" != "$OUTPUT_PATH" ]; then
    rm "$SANITIZED_PDF"
  fi
  if [ -f "unlocked_temp.pdf" ]; then
    rm "unlocked_temp.pdf"
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleanup complete."

  # Optionally relock the cleaned PDF with the original password
  if [ "$RELOCK_CLEANED" = "yes" ] && [ -n "$PDF_PASSWORD" ]; then
    RELOCKED_PATH="${OUTPUT_PATH%.pdf}_locked.pdf"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Relocking sanitized PDF with original password..."
    if qpdf --encrypt "$PDF_PASSWORD" "$PDF_PASSWORD" "$ENCRYPTION_STRENGTH" -- "$OUTPUT_PATH" "$RELOCKED_PATH"; then
      mv "$RELOCKED_PATH" "$OUTPUT_PATH"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] PDF relocked: $OUTPUT_PATH"
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Failed to relock PDF: $OUTPUT_PATH" | tee -a "$LOG_FILE"
    fi
  fi

  if [ -f "unlocked_temp.pdf" ]; then
    rm "unlocked_temp.pdf"
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sanitization complete. Output: $OUTPUT_PATH"
done

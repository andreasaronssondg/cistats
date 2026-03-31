#!/usr/bin/env bash
set -euo pipefail

# Requires bash 5+ for associative arrays
if [[ "${BASH_VERSINFO[0]}" -lt 5 ]]; then
    echo "Error: bash 5+ required. You have bash ${BASH_VERSION}." >&2
    echo "  On macOS: brew install bash && /opt/homebrew/bin/bash $0 $*" >&2
    exit 1
fi

# --- Defaults ---
REPO="digitalroute/mz-drx"
DAYS=30
OUTPUT_DIR="./ci-metrics-data"
WORKFLOWS=("mz-ci.yaml" "pe-ci.yaml")
RELEVANT_LABELS=("mz-autotest" "pe-autotest")

# --- Usage ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Collect GitHub Actions workflow run data and produce CSV files grouped by PR labels.
Fetches per-job timing to separate queue wait from actual execution time.

Options:
  -r, --repo OWNER/REPO    Repository (default: $REPO)
  -d, --days N              Days to look back (default: $DAYS)
  -o, --output-dir DIR      Output directory (default: $OUTPUT_DIR)
  -h, --help                Show this help
EOF
    exit 0
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--repo)      REPO="$2"; shift 2 ;;
        -d|--days)      DAYS="$2"; shift 2 ;;
        -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)      usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# --- Prerequisites ---
for cmd in gh jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' is required but not found in PATH." >&2
        exit 1
    fi
done

if ! gh auth status &>/dev/null; then
    echo "Error: gh is not authenticated. Run 'gh auth login' first." >&2
    exit 1
fi

# --- Compute date threshold (cross-platform) ---
if [[ "$(uname)" == "Darwin" ]]; then
    SINCE=$(date -v-"${DAYS}"d +%Y-%m-%d)
else
    SINCE=$(date -d "${DAYS} days ago" +%Y-%m-%d)
fi

echo "Collecting runs since $SINCE for repo $REPO" >&2

mkdir -p "$OUTPUT_DIR"

# --- ISO 8601 to epoch (cross-platform) ---
iso_to_epoch() {
    local ts="$1"
    if [[ -z "$ts" || "$ts" == "null" ]]; then
        echo 0
        return
    fi
    # Strip fractional seconds if present
    ts="${ts%%.*}Z"
    ts="${ts%%ZZ}Z"
    if [[ "$(uname)" == "Darwin" ]]; then
        date -jf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo 0
    else
        date -d "$ts" +%s 2>/dev/null || echo 0
    fi
}

# --- PR label cache (bash 5 associative array) ---
declare -A PR_CACHE

fetch_pr_info() {
    local branch="$1"

    if [[ -n "${PR_CACHE[$branch]+x}" ]]; then
        echo "${PR_CACHE[$branch]}"
        return
    fi

    local pr_json pr_number label_group
    pr_json=$(gh pr list -R "$REPO" --head "$branch" --state all --json number,labels -L 1 2>/dev/null || echo "[]")

    if [[ "$pr_json" == "[]" ]] || [[ "$(echo "$pr_json" | jq 'length')" -eq 0 ]]; then
        PR_CACHE[$branch]="|no-labels"
        echo "|no-labels"
        return
    fi

    pr_number=$(echo "$pr_json" | jq -r '.[0].number // empty')

    label_group=$(echo "$pr_json" | jq -r --argjson relevant "$(printf '%s\n' "${RELEVANT_LABELS[@]}" | jq -R . | jq -s .)" \
        '[.[0].labels[].name] | map(select(. as $l | $relevant | index($l))) | sort | join("+")')

    if [[ -z "$label_group" ]]; then
        label_group="no-labels"
    fi

    PR_CACHE[$branch]="${pr_number:-}|${label_group}"
    echo "${PR_CACHE[$branch]}"
}

# --- Fetch job timing for a run ---
# Returns: first_job_started_at|last_job_completed_at|exec_seconds|exec_minutes|queue_seconds|queue_minutes
fetch_job_timing() {
    local run_id="$1" created_at="$2"

    local jobs_json
    jobs_json=$(gh api "repos/$REPO/actions/runs/$run_id/jobs" \
        --jq '[.jobs[] | select(.conclusion != null) | {started_at, completed_at}]' 2>/dev/null || echo "[]")

    if [[ "$jobs_json" == "[]" ]] || [[ "$(echo "$jobs_json" | jq 'length')" -eq 0 ]]; then
        echo "||0|0.0|0|0.0"
        return
    fi

    # First job started_at (earliest) and last job completed_at (latest)
    local first_started last_completed
    first_started=$(echo "$jobs_json" | jq -r '[.[].started_at] | sort | first')
    last_completed=$(echo "$jobs_json" | jq -r '[.[].completed_at] | sort | last')

    local first_epoch last_epoch created_epoch
    first_epoch=$(iso_to_epoch "$first_started")
    last_epoch=$(iso_to_epoch "$last_completed")
    created_epoch=$(iso_to_epoch "$created_at")

    # Execution time = last job completed - first job started
    local exec_seconds=0
    if [[ $last_epoch -gt 0 && $first_epoch -gt 0 ]]; then
        exec_seconds=$((last_epoch - first_epoch))
        if [[ $exec_seconds -lt 0 ]]; then exec_seconds=0; fi
    fi
    local exec_minutes
    exec_minutes=$(awk "BEGIN {printf \"%.1f\", $exec_seconds / 60.0}")

    # Queue time = first job started - run created
    local queue_seconds=0
    if [[ $first_epoch -gt 0 && $created_epoch -gt 0 ]]; then
        queue_seconds=$((first_epoch - created_epoch))
        if [[ $queue_seconds -lt 0 ]]; then queue_seconds=0; fi
    fi
    local queue_minutes
    queue_minutes=$(awk "BEGIN {printf \"%.1f\", $queue_seconds / 60.0}")

    echo "${first_started}|${last_completed}|${exec_seconds}|${exec_minutes}|${queue_seconds}|${queue_minutes}"
}

# --- CSV setup ---
CSV_HEADER="run_id,workflow_name,status,conclusion,created_at,updated_at,wall_clock_seconds,wall_clock_minutes,exec_seconds,exec_minutes,queue_seconds,queue_minutes,first_job_started,last_job_completed,head_branch,event,pr_number,label_group"

echo "$CSV_HEADER" > "$OUTPUT_DIR/all-runs.csv"

declare -A HEADER_WRITTEN

write_row() {
    local wf_slug="$1" label_group="$2" row="$3"
    local filename="${wf_slug}_${label_group}.csv"
    local filepath="$OUTPUT_DIR/$filename"

    if [[ -z "${HEADER_WRITTEN[$filepath]+x}" ]]; then
        echo "$CSV_HEADER" > "$filepath"
        HEADER_WRITTEN[$filepath]=1
    fi

    echo "$row" >> "$filepath"
    echo "$row" >> "$OUTPUT_DIR/all-runs.csv"
}

# --- Main loop ---
for wf in "${WORKFLOWS[@]}"; do
    wf_slug="${wf%.yaml}"
    echo "Fetching runs for workflow: $wf ..." >&2

    raw_json=$(gh run list -R "$REPO" -w "$wf" \
        --json databaseId,workflowName,status,conclusion,createdAt,updatedAt,headBranch,event \
        --created ">=${SINCE}" \
        -L 1000 2>&1)

    if ! echo "$raw_json" | jq empty 2>/dev/null; then
        echo "Warning: Failed to fetch runs for $wf: $raw_json" >&2
        continue
    fi

    # Filter to pull_request events only — skip everything else upfront
    runs_json=$(echo "$raw_json" | jq '[.[] | select(.event == "pull_request")]')
    total=$(echo "$raw_json" | jq 'length')
    run_count=$(echo "$runs_json" | jq 'length')
    echo "  Found $run_count PR runs (of $total total)" >&2

    kept=0
    for i in $(seq 0 $((run_count - 1))); do
        # Extract only headBranch first to check labels before doing expensive work
        head_branch=$(echo "$runs_json" | jq -r ".[$i].headBranch")

        pr_info=$(fetch_pr_info "$head_branch")
        pr_number="${pr_info%%|*}"
        label_group="${pr_info#*|}"

        # Skip runs with no relevant labels
        if [[ "$label_group" == "no-labels" ]]; then
            continue
        fi

        # Extract remaining fields
        run_id=$(echo "$runs_json" | jq -r ".[$i].databaseId")
        workflow_name=$(echo "$runs_json" | jq -r ".[$i].workflowName")
        status=$(echo "$runs_json" | jq -r ".[$i].status")
        conclusion=$(echo "$runs_json" | jq -r ".[$i].conclusion // \"n/a\"")
        created_at=$(echo "$runs_json" | jq -r ".[$i].createdAt")
        updated_at=$(echo "$runs_json" | jq -r ".[$i].updatedAt")

        # Wall-clock duration
        created_epoch=$(iso_to_epoch "$created_at")
        updated_epoch=$(iso_to_epoch "$updated_at")
        wall_seconds=$((updated_epoch - created_epoch))
        if [[ $wall_seconds -lt 0 ]]; then wall_seconds=0; fi
        wall_minutes=$(awk "BEGIN {printf \"%.1f\", $wall_seconds / 60.0}")

        # Fetch per-job timing (execution time excluding queue wait)
        job_timing=$(fetch_job_timing "$run_id" "$created_at")
        IFS='|' read -r first_started last_completed exec_seconds exec_minutes queue_seconds queue_minutes <<< "$job_timing"

        row="${run_id},${workflow_name},${status},${conclusion},${created_at},${updated_at},${wall_seconds},${wall_minutes},${exec_seconds},${exec_minutes},${queue_seconds},${queue_minutes},${first_started},${last_completed},${head_branch},pull_request,${pr_number},${label_group}"

        write_row "$wf_slug" "$label_group" "$row"

        kept=$((kept + 1))
        if (( kept % 25 == 0 )); then
            echo "  Fetched job timing for $kept runs..." >&2
        fi
    done

    echo "  Done processing $wf ($kept runs kept)" >&2
done

# --- Summary ---
echo "" >&2
echo "Output files:" >&2
for f in "$OUTPUT_DIR"/*.csv; do
    count=$(($(wc -l < "$f") - 1))
    echo "  $f ($count runs)" >&2
done

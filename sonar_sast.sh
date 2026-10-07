#!/bin/bash
# sonarqube_sast_scan.sh
#
# This script sets up a one-time SonarQube Community Edition server in Docker,
# performs a Static Application Security Testing (SAST) scan on the current
# directory's source code, and generates an HTML report of the findings.
#
# Requirements:
# - Docker must be installed and running on the host where this script is executed.
# - Internet connectivity to pull Docker images and CDN resources (Tailwind CSS).
# - 'curl' and 'jq' commands must be available on the system.
# - Python3 must be available for HTML report generation.
#
# Usage:
#   ./sonarqube_sast_scan.sh
#
# Override SONAR_PROJECT_KEY and SONAR_PROJECT_NAME through the environment
# to identify the scanned project.

# Exit immediately if a command exits with a non-zero status.
set -e

# Set SCAN_DEBUG=1 to print commands as they are executed; debugging is off by default.
: "${SCAN_DEBUG:=0}"
case "${SCAN_DEBUG}" in
    0) ;;
    1) set -x ;;
    *)
        echo "Error: SCAN_DEBUG must be 0 or 1."
        exit 1
        ;;
esac

# --- Configuration Variables ---
SONAR_QUBE_HOST="http://localhost:9000"       # SonarQube will be accessible on this host port
SONAR_CONTAINER_NAME="sonarqube-sast-temp"    # Name for the SonarQube Docker container
# These can be overridden with environment variables for a single run.
: "${SONAR_PROJECT_KEY:=my-sast-project}"      # Unique key for your SonarQube project
: "${SONAR_PROJECT_NAME:=My SAST Project}"     # Display name for your SonarQube project
DOCKER_NETWORK_NAME="sonarqube-sast-network"  # Custom Docker network for inter-container communication
: "${SRC_TO_SCAN:=$(pwd)}" # Source code directory to be scanned (current directory by default)
if [[ ! -d "${SRC_TO_SCAN}" ]]; then
    echo "Error: SRC_TO_SCAN is not an existing directory: ${SRC_TO_SCAN}"
    exit 1
fi
SRC_TO_SCAN="$(cd "${SRC_TO_SCAN}" && pwd -P)"
# Comma-separated SonarQube issue types to include in the report.
# Valid values: BUG, VULNERABILITY, CODE_SMELL.
: "${SONAR_ISSUE_TYPES:=BUG,VULNERABILITY,CODE_SMELL}"
# Maximum number of matching issues retrieved and displayed (SonarQube API maximum: 500).
: "${SONAR_ISSUE_LIMIT:=50}"
# Docker image used when a .NET solution is detected. Override it for a specific SDK version.
: "${DOTNET_SDK_IMAGE:=mcr.microsoft.com/dotnet/sdk:latest}"

# --- Internal Variables (Do not modify unless you know what's going on) ---
# We will now use a single GLOBAL_ANALYSIS_TOKEN for both API calls and scanner
GLOBAL_ANALYSIS_TOKEN=""
ANALYSIS_ID=""
REPORT_HTML_FILE="sonarqube_sast_report.html"
SONAR_ANALYSIS_LOGS_FILE="sonar_analysis_logs.txt"
# Internal host for scanner to reach SonarQube within the Docker network
SONAR_QUBE_INTERNAL_HOST="http://sonarqube:9000"
DOTNET_SOLUTION_FILES=()

if ! [[ "${SONAR_ISSUE_LIMIT}" =~ ^[1-9][0-9]*$ ]] || (( SONAR_ISSUE_LIMIT > 500 )); then
    echo "Error: SONAR_ISSUE_LIMIT must be an integer between 1 and 500."
    exit 1
fi
export SONAR_ISSUE_LIMIT

# --- Functions ---

# Function to clean up Docker container and network on exit or error
cleanup() {
    echo "--- Cleaning up Docker resources ---"
    if docker ps -a --format '{{.Names}}' | grep -q "${SONAR_CONTAINER_NAME}"; then
        echo "Stopping and removing container: ${SONAR_CONTAINER_NAME}"
        docker stop "${SONAR_CONTAINER_NAME}" > /dev/null 2>&1 || true
        docker rm "${SONAR_CONTAINER_NAME}" > /dev/null 2>&1 || true
        echo "Container ${SONAR_CONTAINER_NAME} removed."
    else
        echo "No SonarQube container found to clean up."
    fi

    if docker network ls --format '{{.Name}}' | grep -q "${DOCKER_NETWORK_NAME}"; then
        echo "Removing Docker network: ${DOCKER_NETWORK_NAME}"
        docker network rm "${DOCKER_NETWORK_NAME}" > /dev/null 2>&1 || true
        echo "Network ${DOCKER_NETWORK_NAME} removed."
    else
        echo "No Docker network '${DOCKER_NETWORK_NAME}' found to clean up."
    fi
}

# Register the cleanup function to be called on script exit
trap cleanup EXIT

# Function to wait for SonarQube server to be ready from the host machine using login endpoint
wait_for_sonarqube() {
    echo "--- Waiting for SonarQube to start at ${SONAR_QUBE_HOST} (from host machine, testing login) ---"
    # Give SonarQube a moment to fully initialize its internal services after container start
    sleep 30 # Added a small initial delay, adjust if needed

    for i in $(seq 1 60); do # Try for up to 5 minutes (60 * 5 seconds)
        # Use curl from the host to attempt a login, which confirms the server is up and responsive
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${SONAR_QUBE_HOST}/api/authentication/login" -d "login=admin&password=admin")
        if [ "$HTTP_CODE" -eq 200 ]; then
            echo "SonarQube is up and running and accessible from the host (login successful)!"
            return 0
        fi
        echo "SonarQube not ready yet or login failed (HTTP ${HTTP_CODE}), waiting 5 seconds... (Attempt $i/60)"
        sleep 10
    done
    echo "Error: SonarQube did not start or become accessible within the timeout."
    return 1
}

# Function to generate a global analysis token and create project
setup_sonarqube_api() {
    echo "--- Setting up SonarQube via API ---"

    # Generate a GLOBAL_ANALYSIS_TOKEN for the admin user
    # This token will be used for all subsequent API interactions and for the scanner.
    echo "Generating GLOBAL_ANALYSIS_TOKEN for admin user..."
    # First, try to revoke an existing token with the same name to ensure a fresh one
    curl -s -u admin:admin -X POST "${SONAR_QUBE_HOST}/api/user_tokens/revoke?name=admin_global_analysis_token" > /dev/null || true
    
    GLOBAL_ANALYSIS_TOKEN=$(curl -s -u admin:admin -X POST "${SONAR_QUBE_HOST}/api/user_tokens/generate?name=admin_global_analysis_token" | jq -r '.token')
    if [ -z "$GLOBAL_ANALYSIS_TOKEN" ] || [ "$GLOBAL_ANALYSIS_TOKEN" == "null" ]; then
        echo "Error: Failed to generate GLOBAL_ANALYSIS_TOKEN. Check SonarQube logs or credentials."
        return 1
    fi
    echo "GLOBAL_ANALYSIS_TOKEN generated successfully."

    # Create the SonarQube project
    echo "Creating SonarQube project '${SONAR_PROJECT_NAME}' (Key: ${SONAR_PROJECT_KEY})..."
    # Capture HTTP code and full response for debugging
    CREATE_HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer ${GLOBAL_ANALYSIS_TOKEN}" \
      "${SONAR_QUBE_HOST}/api/projects/create" \
      -d "project=${SONAR_PROJECT_KEY}&name=${SONAR_PROJECT_NAME}")
    # Check if project creation was successful (HTTP 200) or if it already exists (HTTP 400 with specific error)
    if [ "$CREATE_HTTP_CODE" -ne 200 ]; then
        echo "Project creation failed."
        return 1    
    fi

    # The GLOBAL_ANALYSIS_TOKEN is now ready to be used by the scanner
    return 0
}

# Find .NET solutions under the selected source directory. A repository may contain
# several independent modules, so every detected .sln or .slnx file is built.
find_dotnet_solutions() {
    DOTNET_SOLUTION_FILES=()

    while IFS= read -r -d '' solution_file; do
        DOTNET_SOLUTION_FILES+=("${solution_file#"${SRC_TO_SCAN}"/}")
    done < <(
        find "${SRC_TO_SCAN}" \
            \( -type d \( -name .git -o -name .scannerwork -o -name .sonarqube -o -name bin -o -name obj \) -prune \) -o \
            \( -type f \( -name '*.sln' -o -name '*.slnx' \) -print0 \)
    )
}

run_dotnet_scanner() {
    echo "Detected ${#DOTNET_SOLUTION_FILES[@]} .NET solution file(s); using SonarScanner for .NET."
    printf '  - %s\n' "${DOTNET_SOLUTION_FILES[@]}"

    docker run --rm \
        --network "${DOCKER_NETWORK_NAME}" \
        --user "$(id -u):$(id -g)" \
        -w /usr/src \
        -e HOME=/tmp \
        -e DOTNET_CLI_HOME=/tmp \
        -e DOTNET_CLI_TELEMETRY_OPTOUT=1 \
        -e SONAR_HOST_URL="${SONAR_QUBE_INTERNAL_HOST}" \
        -e SONAR_TOKEN="${GLOBAL_ANALYSIS_TOKEN}" \
        -e SONAR_PROJECT_KEY="${SONAR_PROJECT_KEY}" \
        -e SONAR_PROJECT_NAME="${SONAR_PROJECT_NAME}" \
        -v "${SRC_TO_SCAN}:/usr/src" \
        -v "$(pwd)/.scannerwork:/tmp/.scannerwork" \
        "${DOTNET_SDK_IMAGE}" \
        bash -ceu '
            dotnet tool install --tool-path /tmp/sonar-scanner dotnet-sonarscanner
            /tmp/sonar-scanner/dotnet-sonarscanner begin \
                /k:"${SONAR_PROJECT_KEY}" \
                /n:"${SONAR_PROJECT_NAME}" \
                /d:sonar.host.url="${SONAR_HOST_URL}" \
                /d:sonar.token="${SONAR_TOKEN}" \
                /d:sonar.scanner.metadataFilePath=/tmp/.scannerwork/report-task.txt
            for solution_file in "$@"; do
                echo "Building ${solution_file}"
                dotnet build "${solution_file}" --no-incremental
            done
            /tmp/sonar-scanner/dotnet-sonarscanner end /d:sonar.token="${SONAR_TOKEN}"
        ' -- "${DOTNET_SOLUTION_FILES[@]}"
}

# Function to run the SonarQube scanner
run_sonarqube_scanner() {
    echo "--- Running SonarQube Scanner ---"

    # Ensure .scannerwork directory exists for report-task.txt
    mkdir -p .scannerwork
    rm -f .scannerwork/report-task.txt

    find_dotnet_solutions
    if (( ${#DOTNET_SOLUTION_FILES[@]} > 0 )); then
        if ! run_dotnet_scanner; then
            echo "Error: SonarScanner for .NET failed. No analysis was submitted."
            return 1
        fi
    else
        echo "No .NET solution found; using the generic SonarQube Scanner."

        # Run the generic SonarQube Scanner using a Docker container.
        if ! docker run --rm \
            --network "${DOCKER_NETWORK_NAME}" \
            -e SONAR_HOST_URL="${SONAR_QUBE_INTERNAL_HOST}" \
            -e SONAR_TOKEN="${GLOBAL_ANALYSIS_TOKEN}" \
            -e SONAR_SCANNER_OPTS="-Xmx512m" \
            -v "${SRC_TO_SCAN}:/usr/src" \
            -v "$(pwd)/.scannerwork:/tmp/.scannerwork" \
            sonarsource/sonar-scanner-cli:latest \
            -Dsonar.scanner.keepReport=true \
            -Dsonar.working.directory=/tmp/.scannerwork \
            -Dsonar.projectKey="${SONAR_PROJECT_KEY}"; then
            echo "Error: The generic SonarQube Scanner failed."
            return 1
        fi
    fi

    # Extract analysis ID from the generated report-task.txt
    if [ ! -f ".scannerwork/report-task.txt" ]; then
        echo "Error: .scannerwork/report-task.txt not found. Analysis might not have completed."
        # Debug by listing the scanned source directory.
        echo "Scanned source directory contents:"
        find "${SRC_TO_SCAN}"
        return 1
    fi
    ANALYSIS_ID=$(grep "ceTaskId" .scannerwork/report-task.txt | cut -d'=' -f2)
    if [ -z "$ANALYSIS_ID" ]; then
        echo "Error: ceTaskId not found in .scannerwork/report-task.txt."
        return 1
    fi
    echo "Analysis ID: ${ANALYSIS_ID}"
    return 0
}

# Function to wait for analysis task to complete on SonarQube server
wait_for_analysis_completion() {
    echo "--- Waiting for SonarQube analysis task to complete on the server ---"
    for i in $(seq 1 120); do # Try for up to 10 minutes (120 * 5 seconds)
        STATUS=$(curl -s -H "Authorization: Bearer ${GLOBAL_ANALYSIS_TOKEN}" "${SONAR_QUBE_HOST}/api/ce/task?id=${ANALYSIS_ID}" | jq -r '.task.status')
        if [ "$STATUS" == "SUCCESS" ] || [ "$STATUS" == "FAILED" ]; then
            echo "SonarQube analysis task status: $STATUS"
            break
        fi
        echo "Analysis still in progress ($STATUS), waiting 10 seconds... (Attempt $i/120)"
        sleep 10
    done

    if [ "$STATUS" != "SUCCESS" ]; then
        echo "Error: SonarQube analysis failed or timed out. Please check SonarQube server logs for details."
        # Fetch SonarQube Compute Engine task logs for debugging
        echo "Fetching Compute Engine logs to ${SONAR_ANALYSIS_LOGS_FILE}..."
        curl -s -H "Authorization: Bearer ${GLOBAL_ANALYSIS_TOKEN}" "${SONAR_QUBE_HOST}/api/ce/task_logs?id=${ANALYSIS_ID}" > "${SONAR_ANALYSIS_LOGS_FILE}"
        return 1
    fi
    return 0
}

# Function to fetch results and generate HTML report
generate_html_report() {
    echo "--- Generating HTML Report ---"

    # Fetch issues and metrics from the SonarQube API
    echo "Fetching issues from SonarQube API..."
    curl -s -H "Authorization: Bearer ${GLOBAL_ANALYSIS_TOKEN}" \
      "${SONAR_QUBE_HOST}/api/issues/search?projectKeys=${SONAR_PROJECT_KEY}&types=${SONAR_ISSUE_TYPES}&ps=${SONAR_ISSUE_LIMIT}" > issues.json || { echo "Failed to fetch issues."; return 1; }

    echo "Fetching metrics from SonarQube API..."
    curl -s -H "Authorization: Bearer ${GLOBAL_ANALYSIS_TOKEN}" \
      "${SONAR_QUBE_HOST}/api/measures/component?component=${SONAR_PROJECT_KEY}&metricKeys=bugs,vulnerabilities,code_smells,security_hotspots,coverage,duplicated_lines_density,ncloc" > metrics.json || { echo "Failed to fetch metrics."; return 1; }

    # Execute the external Python script to generate the HTML report
    # Pass necessary parameters as command-line arguments
    # Export SONAR_PROJECT_NAME so it's available as an environment variable in the Python script
    export SONAR_PROJECT_NAME
    python3 report.py issues.json metrics.json "${REPORT_HTML_FILE}" "${SONAR_PROJECT_NAME}"
    if [ $? -ne 0 ]; then
        echo "Error: Python script 'report.py' failed to generate the HTML report."
        return 1
    fi

    echo "HTML report generated: ${REPORT_HTML_FILE}"
    return 0
}

# --- Main Script Execution ---

echo "--- Starting SonarQube SAST Scan Script ---"

# Create a custom Docker network for inter-container communication
echo "Creating Docker network: ${DOCKER_NETWORK_NAME}"
docker network create "${DOCKER_NETWORK_NAME}" || true # '|| true' to avoid error if network already exists

# 1. Start SonarQube Docker container
echo "Starting SonarQube container '${SONAR_CONTAINER_NAME}' on network '${DOCKER_NETWORK_NAME}'..."
docker run -d --name "${SONAR_CONTAINER_NAME}" \
    --network "${DOCKER_NETWORK_NAME}" \
    --network-alias sonarqube \
    -p 9000:9000 \
    sonarqube:community
if [ $? -ne 0 ]; then
    echo "Error: Failed to start SonarQube Docker container. Is Docker running?"
    exit 1
fi

# 2. Wait for SonarQube to be ready
wait_for_sonarqube || exit 1

# 3. Setup SonarQube via API (generate tokens, create project)
setup_sonarqube_api || exit 1

# 4. Run SonarQube Scanner
run_sonarqube_scanner || exit 1

# 5. Wait for analysis completion on SonarQube server
wait_for_analysis_completion || exit 1

# 6. Generate HTML report
generate_html_report || exit 1

if [[ "${SCAN_DEBUG}" == "1" ]]; then
    set +x
fi

echo "--- SonarQube SAST Scan Completed Successfully! ---"
echo "Your SAST report is available at: ${REPORT_HTML_FILE}"
echo "SonarQube Compute Engine logs (if any issues): ${SONAR_ANALYSIS_LOGS_FILE}"

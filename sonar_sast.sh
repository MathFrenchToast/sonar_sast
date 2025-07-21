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
# Customize the SONAR_PROJECT_KEY and SONAR_PROJECT_NAME variables below
# to match your project.

# Exit immediately if a command exits with a non-zero status.
set -e
set -x # Enable debugging: print commands and their arguments as they are executed

# --- Configuration Variables ---
SONAR_QUBE_HOST="http://localhost:9000"       # SonarQube will be accessible on this host port
SONAR_CONTAINER_NAME="sonarqube-sast-temp"    # Name for the SonarQube Docker container
SONAR_PROJECT_KEY="my-sast-project"           # Unique key for your SonarQube project
SONAR_PROJECT_NAME="My SAST Project"         # Display name for your SonarQube project
DOCKER_NETWORK_NAME="sonarqube-sast-network"  # Custom Docker network for inter-container communication

# --- Internal Variables (Do not modify unless you know what's going on) ---
# We will now use a single GLOBAL_ANALYSIS_TOKEN for both API calls and scanner
GLOBAL_ANALYSIS_TOKEN=""
ANALYSIS_ID=""
REPORT_HTML_FILE="sonarqube_sast_report.html"
SONAR_ANALYSIS_LOGS_FILE="sonar_analysis_logs.txt"
# Internal host for scanner to reach SonarQube within the Docker network
SONAR_QUBE_INTERNAL_HOST="http://sonarqube:9000"

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
    echo "Raw GLOBAL_ANALYSIS_TOKEN from API call: ${GLOBAL_ANALYSIS_TOKEN}" # Debugging output
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

# Function to run the SonarQube scanner
run_sonarqube_scanner() {
    echo "--- Running SonarQube Scanner ---"

    # Ensure .scannerwork directory exists for report-task.txt
    mkdir -p .scannerwork

    # Run the SonarQube Scanner using a Docker container
    # Connect to the custom Docker network so it can reach the SonarQube server
    # Mount the current directory as /usr/src inside the container
    # Pass necessary SonarQube properties as parameters
    # -Dsonar.analysis.jsonReport.enable=true is crucial for fetching detailed results later
    docker run --rm \
        --network "${DOCKER_NETWORK_NAME}" \
        -e SONAR_HOST_URL="${SONAR_QUBE_INTERNAL_HOST}" \
        -e SONAR_TOKEN="${GLOBAL_ANALYSIS_TOKEN}" \
        -e SONAR_SCANNER_OPTS="-Xmx512m" \
        -v "$(pwd):/usr/src" \
        sonarsource/sonar-scanner-cli:latest \
        -Dsonar.analysis.jsonReport.enable=true -Dsonar.projectKey="${SONAR_PROJECT_KEY}" \

    # Extract analysis ID from the generated report-task.txt
    if [ ! -f ".scannerwork/report-task.txt" ]; then
        echo "Error: .scannerwork/report-task.txt not found. Analysis might not have completed."
        # debug by listing contents of current directory
        echo "Current directory contents:"
        find .
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
        echo "Analysis still in progress ($STATUS), waiting 5 seconds... (Attempt $i/120)"
        sleep 5
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
      "${SONAR_QUBE_HOST}/api/issues/search?projectKeys=${SONAR_PROJECT_KEY}&ps=500" > issues.json || { echo "Failed to fetch issues."; return 1; }

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

echo "--- SonarQube SAST Scan Completed Successfully! ---"
echo "Your SAST report is available at: ${REPORT_HTML_FILE}"
echo "SonarQube Compute Engine logs (if any issues): ${SONAR_ANALYSIS_LOGS_FILE}"


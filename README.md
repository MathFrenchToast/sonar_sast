# SonarQube SAST Scan

This project provides a script to perform Static Application Security Testing (SAST) using SonarQube Community Edition in Docker. It scans the source code in the current directory and generates an HTML report of the findings.

## Features
- Sets up a temporary SonarQube server in Docker
- Scans your code for bugs, vulnerabilities, and code smells
- Generates a detailed HTML report
- Cleans up all resources after execution

## Requirements
- Docker (installed and running)
- Internet connectivity (to pull Docker images and CDN resources)
- `curl` and `jq` installed
- Python 3 (for HTML report generation)

## Usage
1. Customize the `SONAR_PROJECT_KEY` and `SONAR_PROJECT_NAME` variables in `sonar_sast.sh` to match your project.
2. Run the script:
   ```bash
   ./sonar_sast.sh
   ```
3. After completion, view the generated `sonarqube_sast_report.html` for results.

## Files
- `sonar_sast.sh`: Main script to run the scan and generate the report
- `report.py`: Python script for HTML report generation

## Notes
- The script uses default SonarQube admin credentials (`admin:admin`). Change these in production environments.
- All resources (Docker containers, temporary files) are cleaned up automatically.
- To avoid typing sudo every time you run a Docker command, add your user to the docker group. `sudo usermod -aG docker $USER`

## Troubleshooting
- If the scan fails, check `sonar_analysis_logs.txt` for SonarQube Compute Engine logs.

## License
This project is provided as-is for educational and internal use.

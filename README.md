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
1. Optionally set `SONAR_PROJECT_KEY` and `SONAR_PROJECT_NAME` for the scan.
   if you want to change the SRC_TO_SCAN, SONAR_ISSUE_LIMIT and SONAR_ISSUE_TYPES do so by exporting your values.
2. cp in your project sonar_sast.sh and rport.py 
3. Run the script:
   ```bash
   ./sonar_sast.sh
   ```
4. After completion, view the generated `sonarqube_sast_report.html` for results.

### Filter and limit reported issues

Override these defaults for a single run without editing the script:

```bash
SONAR_ISSUE_TYPES="BUG,VULNERABILITY" SONAR_ISSUE_LIMIT=100 ./sonar_sast.sh
```

- `SONAR_PROJECT_KEY` is the unique SonarQube identifier for the project; its default is `my-sast-project`.
- `SONAR_PROJECT_NAME` is the display name in SonarQube and the report; its default is `My SAST Project`.
- `SONAR_ISSUE_TYPES` is a comma-separated list of `BUG`, `VULNERABILITY`, and `CODE_SMELL`. By default, all three types are included.
- `SONAR_ISSUE_LIMIT` is the maximum number of matching issues fetched and displayed. It defaults to `50`; the maximum is `500`.
- `SCAN_DEBUG` controls shell command tracing. It defaults to `0`; set it to `1` to enable debugging output.

### Scan a subdirectory

Keep `sonar_sast.sh` and `report.py` at the repository root, then set `SRC_TO_SCAN` to the target directory:

```bash
SRC_TO_SCAN=client ./sonar_sast.sh
```

Relative paths are resolved from the repository root. The HTML report and scan artifacts remain there; only `client/` is analyzed.

### Automatic .NET scanning

The script automatically searches `SRC_TO_SCAN` for `.sln` and `.slnx` files. If it finds one or more, it uses a .NET SDK Docker container and SonarScanner for .NET, then builds every detected solution between the scanner's begin and end steps. No .NET SDK or Sonar scanner installation is needed on the host.

By default, it uses `mcr.microsoft.com/dotnet/sdk:latest`. If a repository requires a particular SDK release, it can be selected for one run:

```bash
DOTNET_SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:9.0 ./sonar_sast.sh
```

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

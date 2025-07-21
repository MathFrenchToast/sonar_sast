# report.py
import json
import os
import sys

def generate_html_report(issues_file, metrics_file, output_file, project_name):
    """
    Generates an HTML report from SonarQube issues and metrics JSON data.
    """
    issues = []
    try:
        with open(issues_file, 'r') as f:
            issues_data = json.load(f)
        issues = issues_data.get('issues', [])
    except FileNotFoundError:
        print(f"Warning: {issues_file} not found. No issues will be included in the report.")
    except json.JSONDecodeError:
        print(f"Warning: Could not decode JSON from {issues_file}. No issues will be included.")

    metrics = {}
    try:
        with open(metrics_file, 'r') as f:
            metrics_data = json.load(f)
        metrics_component = metrics_data.get('component', {})
        metrics_list = metrics_component.get('measures', [])
        metrics = {m['metric']: m['value'] for m in metrics_list}
    except FileNotFoundError:
        print(f"Warning: {metrics_file} not found. No metrics will be included in the report.")
    except json.JSONDecodeError:
        print(f"Warning: Could not decode JSON from {metrics_file}. No metrics will be included.")

    html_content = f"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>SonarQube SAST Report - {project_name}</title>
        <!-- Tailwind CSS for modern styling -->
        <link href="https://cdn.jsdelivr.net/npm/tailwindcss@2.2.19/dist/tailwind.min.css" rel="stylesheet">
        <style>
            /* Custom font for better readability */
            body {{ font-family: 'Inter', sans-serif; }}
            /* Card styling for metrics */
            .metric-card {{
                @apply bg-white rounded-lg shadow-md p-6 text-center;
            }}
            .metric-value {{
                @apply text-4xl font-bold mt-2;
            }}
            .metric-label {{
                @apply text-gray-600 text-sm;
            }}
            /* Table styling for issues */
            .issue-table th, .issue-table td {{
                @apply px-4 py-2 text-left border-b border-gray-200;
            }}
            /* Severity specific colors for better visual distinction */
            .severity-BLOCKER {{ color: #dc2626; font-weight: bold; }} /* Red */
            .severity-CRITICAL {{ color: #ea580c; font-weight: bold; }} /* Orange */
            .severity-MAJOR {{ color: #facc15; }} /* Yellow */
            .severity-MINOR {{ color: #22c55e; }} /* Green */
            .severity-INFO {{ color: #60a5fa; }} /* Blue */
        </style>
    </head>
    <body class="bg-gray-100 p-8">
        <div class="max-w-7xl mx-auto bg-white rounded-lg shadow-xl p-8">
            <h1 class="text-4xl font-extrabold text-gray-800 mb-6 text-center">
                SonarQube SAST Report
            </h1>
            <p class="text-lg text-gray-600 mb-8 text-center">
                Analysis for project: <span class="font-semibold">{project_name}</span>
            </p>

            <!-- Metrics Overview Section -->
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-10">
                <div class="metric-card">
                    <div class="metric-value text-red-600">{metrics.get('bugs', 'N/A')}</div>
                    <div class="metric-label">Bugs</div>
                </div>
                <div class="metric-card">
                    <div class="metric-value text-orange-600">{metrics.get('vulnerabilities', 'N/A')}</div>
                    <div class="metric-label">Vulnerabilities</div>
                </div>
                <div class="metric-card">
                    <div class="metric-value text-blue-600">{metrics.get('code_smells', 'N/A')}</div>
                    <div class="metric-label">Code Smells</div>
                </div>
                <div class="metric-card">
                    <div class="metric-value text-purple-600">{metrics.get('security_hotspots', 'N/A')}</div>
                    <div class="metric-label">Security Hotspots</div>
                </div>
            </div>

            <!-- Additional Key Metrics -->
            <h2 class="text-3xl font-bold text-gray-800 mb-6">Key Metrics</h2>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 mb-10">
                <div class="bg-gray-50 p-4 rounded-lg shadow-sm">
                    <span class="font-semibold">Coverage:</span> {metrics.get('coverage', 'N/A')}%
                </div>
                <div class="bg-gray-50 p-4 rounded-lg shadow-sm">
                    <span class="font-semibold">Duplicated Lines Density:</span> {metrics.get('duplicated_lines_density', 'N/A')}%
                </div>
                <div class="bg-gray-50 p-4 rounded-lg shadow-sm">
                    <span class="font-semibold">Lines of Code (NCLOC):</span> {metrics.get('ncloc', 'N/A')}
                </div>
            </div>

            <!-- Top Issues Table -->
            <h2 class="text-3xl font-bold text-gray-800 mb-6">Top Issues ({len(issues)} found)</h2>
            <div class="overflow-x-auto">
                <table class="min-w-full bg-white rounded-lg shadow-md issue-table">
                    <thead>
                        <tr class="bg-gray-200 text-gray-700 uppercase text-sm leading-normal">
                            <th class="py-3 px-6">Severity</th>
                            <th class="py-3 px-6">Type</th>
                            <th class="py-3 px-6">Message</th>
                            <th class="py-3 px-6">File</th>
                            <th class="py-3 px-6">Line</th>
                        </tr>
                    </thead>
                    <tbody class="text-gray-600 text-sm font-light">
                        {"".join([f'''
                        <tr class="border-b border-gray-200 hover:bg-gray-100">
                            <td class="py-3 px-6 whitespace-nowrap"><span class="severity-{issue.get('severity', 'INFO')}">{issue.get('severity', 'N/A')}</span></td>
                            <td class="py-3 px-6">{issue.get('type', 'N/A')}</td>
                            <td class="py-3 px-6">{issue.get('message', 'N/A')}</td>
                            <td class="py-3 px-6">{issue.get('component', '').split(':')[-1].replace(project_name + '/', '')}</td>
                            <td class="py-3 px-6">{issue.get('textRange', {}).get('startLine', 'N/A')}</td>
                        </tr>
                        ''' for issue in issues[:50]])} <!-- Limiting to top 50 issues for brevity in the report -->
                        {"".join([f'''
                        <tr>
                            <td colspan="5" class="py-3 px-6 text-center text-gray-500">No issues found.</td>
                        </tr>
                        ''' if not issues else ''])}
                    </tbody>
                </table>
            </div>

            <!-- Footer with report generation details -->
            <div class="mt-10 text-center text-gray-500 text-sm">
                Report generated for: {project_name}
                <br>
                For full details and interactive exploration, visit the SonarQube dashboard at {os.environ.get('SONAR_QUBE_HOST', '#')}
                (Note: The SonarQube server is ephemeral and will be shut down after the script completes).
            </div>
        </div>
    </body>
    </html>
    """

    with open(output_file, 'w') as f:
        f.write(html_content)
    print(f"HTML report generated at {output_file}")

if __name__ == "__main__":
    # Get arguments passed from the bash script
    if len(sys.argv) > 4:
        issues_file = sys.argv[1]
        metrics_file = sys.argv[2]
        output_file = sys.argv[3]
        project_name = sys.argv[4]
    else:
        # Fallback for direct execution or if arguments are missing
        issues_file = 'issues.json'
        metrics_file = 'metrics.json'
        output_file = 'sonarqube_sast_report.html'
        project_name = os.environ.get('SONAR_PROJECT_NAME', 'Default Project') # Use env var as fallback

    generate_html_report(issues_file, metrics_file, output_file, project_name)

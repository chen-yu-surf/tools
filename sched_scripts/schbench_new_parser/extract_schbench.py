import re
import sys

def parse_schbench_output(file_path):
    """
    Parse schbench output file to extract specific metrics from the last measurement
    
    Args:
        file_path (str): Path to the schbench output file
        
    Returns:
        dict: Dictionary containing the extracted metrics
    """
    # Read the entire file content
    with open(file_path, 'r') as file:
        content = file.read()
    
    # Patterns to find the last occurrences of each section
    # Look for the last Wakeup Latencies section with 99.0th value
    wakeup_pattern = r'Wakeup Latencies percentiles \(usec\) runtime \d+ \(s\)[\s\S]*?99\.0th:\s*(\d+)'
    wakeup_matches = re.findall(wakeup_pattern, content)
    last_wakeup_99 = wakeup_matches[-1] if wakeup_matches else None
    
    # Look for the last Request Latencies section with 99.0th value
    request_pattern = r'Request Latencies percentiles \(usec\) runtime \d+ \(s\)[\s\S]*?99\.0th:\s*(\d+)'
    request_matches = re.findall(request_pattern, content)
    last_request_99 = request_matches[-1] if request_matches else None
    
    # Look for the last RPS percentiles section with 50.0th value
    rps_pattern = r'RPS percentiles \(requests\) runtime \d+ \(s\)[\s\S]*?50\.0th:\s*(\d+)'
    rps_matches = re.findall(rps_pattern, content)
    last_rps_50 = rps_matches[-1] if rps_matches else None
    
    # Look for the last average rps value
    avg_rps_pattern = r'average rps:\s*([\d.]+)'
    avg_rps_matches = re.findall(avg_rps_pattern, content)
    last_avg_rps = avg_rps_matches[-1] if avg_rps_matches else None
    
    # Return the extracted metrics as a dictionary
    return {
        'last_wakeup_99th_percentile': last_wakeup_99,
        'last_request_99th_percentile': last_request_99,
        'last_rps_50th_percentile': last_rps_50,
        'last_average_rps': last_avg_rps
    }

def write_results_to_file(metrics, output_file):
    """
    Write extracted metrics to a file in space-separated format
    
    Args:
        metrics (dict): Dictionary containing the extracted metrics
        output_file (str): Path to the output file
    """
    # Extract values in order and convert to strings
    values = [
        str(metrics['last_wakeup_99th_percentile']),
        str(metrics['last_request_99th_percentile']),
        str(metrics['last_rps_50th_percentile']),
        str(metrics['last_average_rps'])
    ]
    
    # Join values with spaces
    line = ' '.join(values) + '\n'
    
    # Append to the output file
    with open(output_file, 'a') as f:
        f.write(line)

if __name__ == "__main__":
    # Check if correct number of arguments is provided
    if len(sys.argv) != 3:
        print("Usage: python schbench_parser.py <input_file_path> <output_file_path>")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    # Parse the file and get the metrics
    metrics = parse_schbench_output(input_file)
    
    # Print the results to console
    print("Extracted metrics from the last measurement:")
    print(f"Last Wakeup Latencies 99.0th percentile: {metrics['last_wakeup_99th_percentile']} usec")
    print(f"Last Request Latencies 99.0th percentile: {metrics['last_request_99th_percentile']} usec")
    print(f"Last RPS 50.0th percentile: {metrics['last_rps_50th_percentile']} requests")
    print(f"Last average rps: {metrics['last_average_rps']}")
    
    # Write results to file in append mode
    write_results_to_file(metrics, output_file)
    print(f"Results appended to {output_file}")
    

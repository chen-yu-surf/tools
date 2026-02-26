import sys
import math

def calculate_statistics(file_path):
    """
    Calculate mean and standard deviation for each of the four columns in the input file
    
    Args:
        file_path (str): Path to the input file containing the data
        
    Returns:
        list: List of dictionaries containing mean and std for each column
    """
    # Initialize lists to store values from each column
    column1 = []  # Wakeup Latencies percentiles 99.0th
    column2 = []  # Request Latencies percentiles 99.0th
    column3 = []  # RPS percentiles 50.0th
    column4 = []  # average rps
    
    # Read and parse the file
    with open(file_path, 'r') as file:
        for line_num, line in enumerate(file, 1):
            line = line.strip()
            if not line:
                continue
                
            # Split line into values
            parts = line.split()
            if len(parts) != 4:
                print(f"Warning: Line {line_num} does not contain exactly 4 values. Skipping.")
                continue
                
            try:
                # Convert to appropriate numeric types and add to columns
                column1.append(float(parts[0]))
                column2.append(float(parts[1]))
                column3.append(float(parts[2]))
                column4.append(float(parts[3]))
            except ValueError:
                print(f"Warning: Could not convert values in line {line_num} to numbers. Skipping.")
                continue
    
    # Check if we have any data
    if not column1:
        print("Error: No valid data found in the file.")
        return None
    
    # Function to calculate mean
    def mean(values):
        return sum(values) / len(values)
    
    # Function to calculate standard deviation
    def std_dev(values, mean_val):
        if len(values) <= 1:
            return 0.0
        variance = sum((x - mean_val) **2 for x in values) / (len(values) - 1)
        return math.sqrt(variance)
    
    # Calculate statistics for each column
    stats = [
        {
            'name': 'Wakeup Latencies 99.0th',
            'mean': mean(column1),
            'std': std_dev(column1, mean(column1))
        },
        {
            'name': 'Request Latencies 99.0th',
            'mean': mean(column2),
            'std': std_dev(column2, mean(column2))
        },
        {
            'name': 'RPS 50.0th',
            'mean': mean(column3),
            'std': std_dev(column3, mean(column3))
        },
        {
            'name': 'Average RPS',
            'mean': mean(column4),
            'std': std_dev(column4, mean(column4))
        }
    ]
    
    return stats

def write_statistics_to_file(stats, output_file):
    """
    Write statistics to output file in a single line, space-separated
    
    Args:
        stats (list): List of statistics dictionaries
        output_file (str): Path to the output file
    """
    # Prepare values in order: mean1 std1 mean2 std2 mean3 std3 mean4 std4
    values = []
    for stat in stats:
        values.append(f"{stat['mean']:.2f}")
        values.append(f"{stat['std']:.2f}")
    
    # Join all values with spaces
    line = ' '.join(values) + '\n'
    
    # Write to file
    with open(output_file, 'w') as f:
        f.write(line)

def main():
    # Check if correct number of arguments is provided
    if len(sys.argv) != 3:
        print("Usage: python calc_average.py <input_file_path> <output_file_path>")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    # Calculate statistics
    stats = calculate_statistics(input_file)
    
    if stats:
        # Print results with 2 decimal places
        print("Statistics (mean ± standard deviation):")
        for stat in stats:
            print(f"{stat['name']}: {stat['mean']:.2f} ± {stat['std']:.2f}")
        
        # Write results to output file
        write_statistics_to_file(stats, output_file)
        print(f"Statistics written to {output_file}")

if __name__ == "__main__":
    main()
    

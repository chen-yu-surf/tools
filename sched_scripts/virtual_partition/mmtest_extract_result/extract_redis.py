import os
import re
import sys
from collections import defaultdict

def extract_rps_values(directory):
    # Regular expression to match the file pattern
    file_pattern = re.compile(r'redis-\d+-\d+\.log')

    # Dictionary to store test names and their corresponding RPS values
    rps_data = defaultdict(list)

    # Iterate over all files in the directory
    for filename in os.listdir(directory):
        if file_pattern.match(filename):
            file_path = os.path.join(directory, filename)
            with open(file_path, 'r') as file:
                # Skip the header line
                next(file)
                for line in file:
                    # Split the line by commas and strip quotes
                    parts = line.strip().split(',')
                    if len(parts) > 1:
                        test_name = parts[0].strip('"')
                        rps_value = parts[1].strip('"')
                        rps_data[test_name].append(rps_value)

    # Sort the test names and print the results
    for test_name in sorted(rps_data.keys()):
        for rps_value in rps_data[test_name]:
            print(f"{test_name} {rps_value}")

if __name__ == "__main__":
    # Check if the directory path is provided as a command-line argument
    if len(sys.argv) != 2:
        print("Usage: python extract_rps.py <directory_path>")
        sys.exit(1)

    # Get the directory path from the command-line argument
    user_directory = sys.argv[1]
    extract_rps_values(user_directory)

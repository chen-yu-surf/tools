import os
import re
import sys

def extract_total_times(directory):
    # Regular expression to match the file pattern
    file_pattern = re.compile(r'hackbench-\d+-\d+')
    # Regular expression to extract the total time
    time_pattern = re.compile(r'Total time:\s*([\d.]+)\s*\[sec\]')

    # List to store total times
    total_times = []

    # Iterate over all files in the directory
    for filename in os.listdir(directory):
        if file_pattern.match(filename):
            file_path = os.path.join(directory, filename)
            with open(file_path, 'r') as file:
                for line in file:
                    match = time_pattern.search(line)
                    if match:
                        total_time = match.group(1)
                        total_times.append(f"Time {total_time}")
                        break  # Stop after finding the first match in the file

    # Print all total times
    for total_time in total_times:
        print(total_time)

if __name__ == "__main__":
    # Check if the directory path is provided as a command-line argument
    if len(sys.argv) != 2:
        print("Usage: python extract_total_times.py <directory_path>")
        sys.exit(1)

    # Get the directory path from the command-line argument
    user_directory = sys.argv[1]
    extract_total_times(user_directory)

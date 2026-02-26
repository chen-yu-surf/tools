import os
import re
import sys

def extract_elapsed_times(directory):
    # Regular expression to match the file pattern
    file_pattern = re.compile(r'kernbench-\d+-\d+\.time')
    # Regular expression to extract the elapsed time
    elapsed_pattern = re.compile(r'(\d+:\d+\.\d+)elapsed')

    # List to store elapsed times
    elapsed_times = []

    # Iterate over all files in the directory
    for filename in os.listdir(directory):
        if file_pattern.match(filename):
            file_path = os.path.join(directory, filename)
            with open(file_path, 'r') as file:
                for line in file:
                    match = elapsed_pattern.search(line)
                    if match:
                        elapsed_time = match.group(1)
                        elapsed_times.append(f"elapsed {elapsed_time}")
                        break  # Stop after finding the first match in the file

    # Print all elapsed times
    for elapsed_time in elapsed_times:
        print(elapsed_time)

if __name__ == "__main__":
    # Check if the directory path is provided as a command-line argument
    if len(sys.argv) != 2:
        print("Usage: python extract_elapsed.py <directory_path>")
        sys.exit(1)

    # Get the directory path from the command-line argument
    user_directory = sys.argv[1]
    extract_elapsed_times(user_directory)

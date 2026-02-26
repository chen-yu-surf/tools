import csv
import sys

def extract_test_data(file_path):
    test_counter = {}
    with open(file_path, mode='r', newline='') as file:
        reader = csv.reader(file)
        
        next(reader)
        
        for row in reader:
            full_test_name = row[0].strip('"')
            test_prefix = full_test_name.split()[0]
            if test_prefix not in test_counter:
                test_counter[test_prefix] = 1
            else:
                test_counter[test_prefix] += 1
        
        file.seek(0)
        next(reader)
        
        for row in reader:
            full_test_name = row[0].strip('"')
            rps = row[1].strip('"')
            
            test_prefix = full_test_name.split()[0]
            
            if test_counter[test_prefix] > 1:
                test_name = f"{test_prefix}{test_counter[test_prefix] - 1}"
                test_counter[test_prefix] -= 1
            else:
                test_name = test_prefix
            
            print(f"{test_name},{rps}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python script.py <path_to_csv_file>")
        sys.exit(1)
    
    file_path = sys.argv[1]
    extract_test_data(file_path)

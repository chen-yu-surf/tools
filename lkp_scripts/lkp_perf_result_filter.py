import os
import sys
import json
import re
import operator
import shutil

benchmarks = [ "aim7", "aim9", "apachebench", "stress-ng", "schbench", "fileio", "dbench", "hackbench", "kernbench", "linpack", "netperf", "tbench"]
#ratio = []

class Result():
    def __init__(self, name, fname, ratio):
      self.name = name
      self.fname = fname
      self.ratio = ratio

    def __lt__(self, other):
      return self.ratio < other.ratio

result_ratio = []
tests = {""}
job_idx = 0

for b in benchmarks:
  fname = []
  path = "/result/"
  path = os.path.join(path, b)
  for root,d_names,f_names in os.walk(path):
    for f in f_names:
      fname = os.path.join(root, f)
      perf_json = os.path.basename(fname)
      if perf_json == "perf-profile.json":

        with open(fname, 'r') as perf_file:
          data = json.load(perf_file)
          #print(json.dumps(data, indent=4))
          #print(data)
          for key, value in data.items():
            pattern = re.compile("update_sd_lb_stats")
            if pattern.search(key):
              for item in value:
                if item >= 1.0:
                  bench = fname.split("/")
                  #print(fname, key, item)
                  isExist = os.path.exists(bench[2])
                  if not isExist:
                    os.makedirs(bench[2])
                  dir_path = os.path.dirname(fname)
                  src_job_file = os.path.join(str(dir_path), "job.yaml")
                  dst_job_file = "".join([str(job_idx), "_job.yaml"])
                  dst_job_file = os.path.join(str(bench[2]), dst_job_file)
                  job_idx = job_idx + 1
                  tests.add(bench[2])
                  shutil.copyfile(src_job_file, dst_job_file)

                  result_ratio.append(Result(key, fname, item))

result_ratio.sort(reverse=True)
print("The update_sd_lb_stats ratio sorted from high to low:")

print(tests)

for i in range(0, len(result_ratio)):
    print("\n") 
    print(result_ratio[i].ratio)
    print(result_ratio[i].name)
    print(result_ratio[i].fname)

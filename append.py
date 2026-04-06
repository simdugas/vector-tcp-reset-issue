import argparse
import time

parser = argparse.ArgumentParser()
parser.add_argument("file", nargs="?", default="pipe.log", help="Path to the log file")
parser.add_argument("--interval", "-i", type=float, default=5, help="Sleep interval in seconds (default: 5)")
args = parser.parse_args()

with open(args.file, "a") as f:
    i = 1
    while True:
        f.write(f"{i}\n")
        f.flush()
        i += 1
        time.sleep(args.interval)

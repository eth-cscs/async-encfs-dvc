#!/usr/bin/env python

import sys
import os

inference_output_argv_index = sys.argv.index('--inference-output')
if inference_output_argv_index == -1:
    raise RuntimeError("Commandline option --inference-output is required")
else:
    inference_output = sys.argv[inference_output_argv_index + 1]

print(f"Running inference ({sys.argv[0]}, output-dir {inference_output}) with args\n{sys.argv}\n")
